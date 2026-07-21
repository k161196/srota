import AppKit
import Foundation
import GhosttyTerminal

/// Cmd-click / hover support for hyperlinks inside a terminal pane. `file://` links open at the
/// referenced line in the user's default editor (see EditorsStore); anything else opens in the
/// default browser, matching how iTerm2/kitty treat OSC 8 links today (currently a dead click,
/// since Srota didn't conform to either delegate before this).
///
/// This only fires for links the terminal already recognizes (real OSC 8 hyperlinks, or bare
/// http(s) URLs Ghostty auto-detects) — plain-text file mentions in raw compiler/tool output
/// aren't covered without a custom scanner, which is a separate, larger piece of work.
extension TerminalViewState: TerminalSurfaceOpenURLDelegate, TerminalSurfaceHoverLinkDelegate {
    public func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        guard let link = FileLink.parse(url) else {
            if let url = URL(string: url), url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard let editor = EditorsStore.shared?.defaultEditor else { return }
        EditorsStore.shared?.openAtLine(editor, path: link.path, line: link.line, column: link.column)
    }

    public func terminalDidUpdateHoverLink(_ url: String?) {
        if url != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}

struct FileLink: Equatable {
    let path: String
    let line: Int?
    let column: Int?

    /// Parses a `file://` URL into a filesystem path plus an optional line/column, tolerating
    /// the handful of suffix styles different hyperlink emitters use: `#L143`, `#143`,
    /// `:143`, `:143:5`. Returns nil for anything not a file:// URL.
    static func parse(_ raw: String) -> FileLink? {
        guard let components = URLComponents(string: raw), components.scheme == "file" else { return nil }
        let path = components.path

        if let fragment = components.fragment, !fragment.isEmpty {
            let digits = fragment.hasPrefix("L") ? String(fragment.dropFirst()) : fragment
            let line = Int(digits).flatMap { $0 > 0 ? $0 : nil }
            return FileLink(path: path, line: line, column: nil)
        }

        // macOS filenames CAN contain ':', so a trailing ":<line>" or ":<line>:<col>" is only
        // recognized by checking the LAST one or two colon-separated segments — anchored from
        // the end, not a fixed position, so an earlier colon in the filename itself (e.g.
        // "a:b.swift:143") isn't mistaken for the line reference. Line numbers are 1-based; a
        // non-positive value isn't provably a line reference (e.g. "report:0" could be a real
        // filename), so the complete, untouched path is preserved rather than truncated.
        let parts = path.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 3, let rawLine = Int(parts[parts.count - 2]), let rawCol = Int(parts[parts.count - 1]) {
            guard rawLine > 0 else { return FileLink(path: path, line: nil, column: nil) }
            let column = rawCol > 0 ? rawCol : nil
            return FileLink(path: parts[0..<(parts.count - 2)].joined(separator: ":"), line: rawLine, column: column)
        }
        if parts.count >= 2, let rawLine = Int(parts[parts.count - 1]) {
            guard rawLine > 0 else { return FileLink(path: path, line: nil, column: nil) }
            return FileLink(path: parts[0..<(parts.count - 1)].joined(separator: ":"), line: rawLine, column: nil)
        }
        return FileLink(path: path, line: nil, column: nil)
    }

    #if DEBUG
    /// Runnable regression check for the parsing branches above — no XCTest target exists in
    /// this project, so this asserts on every debug launch instead (see srotaApp.init()).
    static func runSelfCheck() {
        assert(parse("https://example.com") == nil)
        assert(parse("file:///a/b.swift") == FileLink(path: "/a/b.swift", line: nil, column: nil))
        assert(parse("file:///a/b.swift#L143") == FileLink(path: "/a/b.swift", line: 143, column: nil))
        assert(parse("file:///a/b.swift#143") == FileLink(path: "/a/b.swift", line: 143, column: nil))
        assert(parse("file:///a/b.swift:143") == FileLink(path: "/a/b.swift", line: 143, column: nil))
        assert(parse("file:///a/b.swift:143:5") == FileLink(path: "/a/b.swift", line: 143, column: 5))
        // Invalid/non-positive line references fall back to no line jump, but keep the path.
        assert(parse("file:///a/b.swift#abc") == FileLink(path: "/a/b.swift", line: nil, column: nil))
        assert(parse("file:///a/b.swift#-5") == FileLink(path: "/a/b.swift", line: nil, column: nil))
        assert(parse("file:///a/b.swift#0") == FileLink(path: "/a/b.swift", line: nil, column: nil))
        // A non-positive trailing number isn't provably a line reference — e.g. "report:0"
        // could be a real filename — so the complete path is preserved rather than truncated.
        assert(parse("file:///a/b.swift:0") == FileLink(path: "/a/b.swift:0", line: nil, column: nil))
        assert(parse("file:///a/b.swift:-5") == FileLink(path: "/a/b.swift:-5", line: nil, column: nil))
        assert(parse("file:///a/b.swift:-5:3") == FileLink(path: "/a/b.swift:-5:3", line: nil, column: nil))
        assert(parse("file:///tmp/report:0") == FileLink(path: "/tmp/report:0", line: nil, column: nil))
        // Columns are validated the same way as lines: non-positive falls back to no column,
        // without discarding an otherwise-valid line.
        assert(parse("file:///a/b.swift:143:0") == FileLink(path: "/a/b.swift", line: 143, column: nil))
        assert(parse("file:///a/b.swift:143:-2") == FileLink(path: "/a/b.swift", line: 143, column: nil))
        // End-anchored: if the true tail isn't numeric, there's no line ref at all (an earlier
        // segment can't be reinterpreted as "the line" once the anchor position fails to match).
        assert(parse("file:///a/b.swift:143:abc") == FileLink(path: "/a/b.swift:143:abc", line: nil, column: nil))
        // Regression: colons inside the filename itself (legal on macOS at the POSIX layer)
        // must not be mistaken for the line/column separator — only the trailing numeric
        // segment(s) are consumed, whatever comes before stays part of the path.
        assert(parse("file:///tmp/a:b.swift:143") == FileLink(path: "/tmp/a:b.swift", line: 143, column: nil))
        assert(parse("file:///tmp/a:b.swift:143:5") == FileLink(path: "/tmp/a:b.swift", line: 143, column: 5))
        assert(parse("file:///tmp/a:b.swift") == FileLink(path: "/tmp/a:b.swift", line: nil, column: nil))
        // Inherent ambiguity, not fully resolvable without a filesystem check: "a:143" reads as
        // path "a" at line 143, matching the trailing-":<line>" convention every hyperlink
        // emitter (ripgrep, tsc, vim errorformat) uses — even though "a:143" could in principle
        // be a real filename.
        assert(parse("file:///tmp/a:143") == FileLink(path: "/tmp/a", line: 143, column: nil))
    }
    #endif
}
