import SwiftUI

// MARK: - State settings (Settings → State → Flow reset)

struct StateSettingsView: View {
    @Environment(FlowViewState.self) private var flow
    @State private var showResetConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("State")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.stLabel)
                    Text("Durable navigation and filter choices that survive an app restart.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.stMuted)
                }
                .padding(.bottom, 28)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Flow")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.stLabel)
                    Text("Selected tab, repository scope, issue/PR queries, selected repository, and searches.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.stMuted)

                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Text("Reset Flow View State")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.red.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.stSurface)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.stBorder))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 4)
                }
            }
            .padding(28)
        }
        .background(Color.stBg)
        .confirmationDialog(
            "Reset Flow View State?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { flow.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears the selected tab, repository scope, queries, selected repository, and searches.")
        }
    }
}
