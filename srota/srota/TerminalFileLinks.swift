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
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
            return
        }
        guard let editor = EditorsStore.shared?.defaultEditor else { return }
        if let line = link.line {
            EditorsStore.shared?.openAtLine(editor, path: link.path, line: line, column: link.column)
        } else {
            EditorsStore.shared?.open(editor, at: link.path)
        }
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
        var path = components.path

        if let fragment = components.fragment, !fragment.isEmpty {
            let digits = fragment.hasPrefix("L") ? String(fragment.dropFirst()) : fragment
            return FileLink(path: path, line: Int(digits), column: nil)
        }

        // Colons aren't valid in macOS filenames, so a trailing ":<line>" or ":<line>:<col>"
        // unambiguously belongs to the line reference, not the path.
        let parts = path.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, let line = Int(parts[1]) else {
            return FileLink(path: path, line: nil, column: nil)
        }
        path = String(parts[0])
        let column = parts.count >= 3 ? Int(parts[2]) : nil
        return FileLink(path: path, line: line, column: column)
    }
}
