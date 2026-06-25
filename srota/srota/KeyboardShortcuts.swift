import AppKit
import Observation
import SwiftUI

// MARK: - Key combo

struct KeyCombo: Equatable {
    let modifiers: NSEvent.ModifierFlags
    let key: String

    init?(_ string: String) {
        let parts = string.lowercased().components(separatedBy: "+")
        guard let k = parts.last, !k.isEmpty else { return nil }
        var mods: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control":      mods.insert(.control)
            case "cmd", "command":       mods.insert(.command)
            case "opt", "option", "alt": mods.insert(.option)
            case "shift":                mods.insert(.shift)
            default: return nil
            }
        }
        self.modifiers = mods
        self.key = k
    }

    func matches(_ event: NSEvent) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.control, .command, .option, .shift]
        guard event.modifierFlags.intersection(relevant) == modifiers else { return false }
        return (event.charactersIgnoringModifiers?.lowercased() ?? "") == key
    }

    var display: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option)  { parts.append("⌥") }
        if modifiers.contains(.shift)   { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(key.uppercased())
        return parts.joined()
    }
}

// MARK: - Manager

@Observable @MainActor
final class KeyboardShortcutManager {
    var prefixKey: String = "ctrl+b" {
        didSet { prefixCombo = KeyCombo(prefixKey) }
    }
    private(set) var awaitingChord = false
    var actions: [String: () -> Void] = [:]

    private var prefixCombo: KeyCombo? = KeyCombo("ctrl+b")
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) ? nil : event }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Don't intercept when user is editing text
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return false
        }

        guard let combo = prefixCombo else { return false }

        if awaitingChord {
            awaitingChord = false
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if let action = actions[key] { action(); return true }
            return false
        }

        if combo.matches(event) {
            awaitingChord = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.awaitingChord = false
            }
            return true
        }
        return false
    }
}

// MARK: - TerminalTab pane focus (directional)

extension TerminalTab {
    enum FocusDirection { case left, right, up, down }

    func focusPane(direction: FocusDirection) {
        let currentID = focusedPaneID
        guard let cl = paneLayouts[currentID] else { return }
        var bestID:   UUID?    = nil
        var bestDist: CGFloat  = .infinity

        for entry in panes where entry.id != currentID {
            guard let l = paneLayouts[entry.id] else { continue }
            let dist: CGFloat
            switch direction {
            case .left:
                guard l.x + l.w <= cl.x + 0.01 else { continue }
                dist = cl.x - (l.x + l.w)
            case .right:
                guard l.x >= cl.x + cl.w - 0.01 else { continue }
                dist = l.x - (cl.x + cl.w)
            case .up:
                guard l.y + l.h <= cl.y + 0.01 else { continue }
                dist = cl.y - (l.y + l.h)
            case .down:
                guard l.y >= cl.y + cl.h - 0.01 else { continue }
                dist = l.y - (cl.y + cl.h)
            }
            if dist < bestDist { bestDist = dist; bestID = entry.id }
        }

        if let bestID { focusedPaneID = bestID }
    }
}

// MARK: - Workspace tab navigation

extension Workspace {
    func selectNextTab() {
        guard !tabs.isEmpty else { return }
        guard let id = selectedTabID,
              let idx = tabs.firstIndex(where: { $0.id == id }) else {
            selectedTabID = tabs.first?.id; return
        }
        selectedTabID = tabs[(idx + 1) % tabs.count].id
    }

    func selectPrevTab() {
        guard !tabs.isEmpty else { return }
        guard let id = selectedTabID,
              let idx = tabs.firstIndex(where: { $0.id == id }) else {
            selectedTabID = tabs.last?.id; return
        }
        selectedTabID = tabs[(idx - 1 + tabs.count) % tabs.count].id
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTabID = tabs[index].id
    }
}

// MARK: - Chord indicator overlay

struct ChordIndicator: View {
    let display: String

    var body: some View {
        HStack(spacing: 8) {
            Text(display)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.15))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(red: 1.0, green: 0.45, blue: 0.15).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.35))
            Text("waiting for key…")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(red: 1.0, green: 0.45, blue: 0.15).opacity(0.3)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
    }
}

// MARK: - PrefixKeyRecorder

struct PrefixKeyRecorder: NSViewRepresentable {
    @Binding var value: String

    func makeNSView(context: Context) -> KeyRecorderView {
        let v = KeyRecorderView()
        v.onCapture = { [context] combo in
            context.coordinator.parent.value = combo
        }
        v.update(display: KeyCombo(value)?.display ?? value, recording: false)
        return v
    }

    func updateNSView(_ v: KeyRecorderView, context: Context) {
        if !v.isRecording {
            v.update(display: KeyCombo(value)?.display ?? value, recording: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    class Coordinator { var parent: PrefixKeyRecorder; init(parent: PrefixKeyRecorder) { self.parent = parent } }

    // MARK: NSView
    class KeyRecorderView: NSView {
        var onCapture: ((String) -> Void)?
        var isRecording = false
        private let label = NSTextField(labelWithString: "")

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.borderWidth = 1
            addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.alignment = .center
            label.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            ])
            addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        }

        required init?(coder: NSCoder) { fatalError() }

        func update(display: String, recording: Bool) {
            isRecording = recording
            if recording {
                label.stringValue = "Type shortcut…"
                label.textColor = .white.withAlphaComponent(0.4)
                layer?.borderColor = NSColor(red: 1.0, green: 0.45, blue: 0.15, alpha: 1).cgColor
            } else {
                label.stringValue = display.isEmpty ? "–" : display
                label.textColor = NSColor(red: 0.92, green: 0.92, blue: 0.93, alpha: 1)
                layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
            }
            layer?.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1).cgColor
        }

        override var acceptsFirstResponder: Bool { true }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            update(display: "", recording: true)
            return true
        }

        override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }
            if isRecording { update(display: "", recording: false) }
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { window?.makeFirstResponder(nil); return } // Escape
            let relevant: NSEvent.ModifierFlags = [.control, .command, .option, .shift]
            let mods = event.modifierFlags.intersection(relevant)
            guard !mods.isEmpty else { return }
            guard let k = event.charactersIgnoringModifiers?.lowercased(), !k.isEmpty else { return }
            var parts: [String] = []
            if mods.contains(.control) { parts.append("ctrl") }
            if mods.contains(.option)  { parts.append("opt") }
            if mods.contains(.shift)   { parts.append("shift") }
            if mods.contains(.command) { parts.append("cmd") }
            parts.append(k)
            onCapture?(parts.joined(separator: "+"))
            window?.makeFirstResponder(nil)
        }

        @objc private func clicked() { window?.makeFirstResponder(self) }
    }
}
