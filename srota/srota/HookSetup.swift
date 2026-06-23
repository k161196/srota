import Foundation
import SwiftUI

// MARK: - Model

struct HookSetupResult: Identifiable {
    let id = UUID()
    var claudeStatus: String
    var codexStatus: String
    var notifyScript: String

    var needsSetup: Bool {
        claudeStatus == "missing" || codexStatus == "missing"
    }

    var agentsNeedingSetup: [String] {
        var out: [String] = []
        if claudeStatus == "missing" { out.append("Claude") }
        if codexStatus == "missing" { out.append("Codex") }
        return out
    }
}

// MARK: - Runner

private func agentHookEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let existingPath = env["PATH"] ?? ""
    let extraPaths = [
        "\(NSHomeDirectory())/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]
    let pathParts = extraPaths + existingPath.split(separator: ":").map(String.init)
    env["PATH"] = pathParts.joined(separator: ":")
    return env
}

func checkAgentHooks(scriptPath: String) async -> HookSetupResult? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [scriptPath]
    process.environment = agentHookEnvironment()

    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }

        return HookSetupResult(
            claudeStatus: json["claude"] ?? "not_installed",
            codexStatus: json["codex"] ?? "not_installed",
            notifyScript: json["notifyScript"] ?? ""
        )
    } catch {
        return nil
    }
}

func configureAgentHooks(scriptPath: String, notifyScriptPath: String) async -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [scriptPath, "--configure", "--notify-script", notifyScriptPath]
    process.environment = agentHookEnvironment()
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

// MARK: - Sheet

struct HookSetupSheet: View {
    let result: HookSetupResult
    let checkScriptPath: String
    var onDismiss: () -> Void

    @State private var isConfiguring = false
    @State private var configureResult: Bool? = nil

    private static let bg = Color(red: 0.067, green: 0.067, blue: 0.075)
    private static let panel = Color.white.opacity(0.05)
    private static let primary = Color.white
    private static let muted = Color.white.opacity(0.65)
    private static let orange = Color(red: 1.0, green: 0.62, blue: 0.21)

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bell.badge")
                .font(.system(size: 30))
                .foregroundStyle(Self.orange)

            Text("Enable Agent Notifications")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Self.primary)

            Text("Srota can notify you when \(agentList) finishes or needs approval.")
                .font(.system(size: 13))
                .foregroundStyle(Self.muted)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text("This will update the local hook config for the missing agents.")
                Text("Claude: \(result.claudeStatus)")
                Text("Codex: \(result.codexStatus)")
            }
            .font(.system(size: 12))
            .foregroundStyle(Self.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Self.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if let ok = configureResult {
                HStack(spacing: 8) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(ok ? .green : .red)
                    Text(ok ? "Configured successfully" : "Configuration failed. Check file permissions and installed CLIs.")
                        .font(.system(size: 12))
                        .foregroundStyle(Self.muted)
                }
            }

            HStack(spacing: 12) {
                Button("Not Now") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Self.muted)

                Button {
                    Task { await configure() }
                } label: {
                    HStack(spacing: 6) {
                        if isConfiguring {
                            ProgressView().scaleEffect(0.7)
                        }
                        Text(isConfiguring ? "Configuring…" : "Enable")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(Self.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isConfiguring)
            }
        }
        .padding(40)
        .frame(width: 400)
        .background(Self.bg)
    }

    private var agentList: String {
        result.agentsNeedingSetup.joined(separator: " and ")
    }

    private func configure() async {
        isConfiguring = true
        let ok = await configureAgentHooks(
            scriptPath: checkScriptPath,
            notifyScriptPath: result.notifyScript
        )

        await MainActor.run {
            isConfiguring = false
            configureResult = ok
            if ok {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    onDismiss()
                }
            }
        }
    }
}
