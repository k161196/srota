import SwiftUI

private extension Color {
    static let ptBg      = Color(red: 0.067, green: 0.067, blue: 0.075)
    static let ptSurface = Color(red: 0.10,  green: 0.10,  blue: 0.11)
    static let ptBorder  = Color.white.opacity(0.07)
    static let ptAccent  = Color(red: 1.0, green: 0.45, blue: 0.15)
    static let ptLabel   = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let ptMuted   = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.40)
}

struct PromptsPanel: View {
    @Binding var isPresented: Bool
    @Environment(PromptsStore.self) private var store

    @State private var searchText   = ""
    @State private var selectedID:  UUID? = nil
    @State private var pendingNewID: UUID? = nil
    @State private var editName        = ""
    @State private var editDescription = ""
    @State private var editContent     = ""
    private var isNew: Bool { pendingNewID == selectedID && selectedID != nil }

    private var filtered: [PromptItem] {
        guard !searchText.isEmpty else { return store.items }
        return store.items.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            listPanel
            Rectangle().fill(Color.ptBorder).frame(width: 1)
            detailPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ptBg)
    }

    // MARK: - Left panel

    private var listPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button(action: { isPresented = false }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.ptMuted)
                }
                .buttonStyle(.plain)

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ptMuted)

                TextField("Search…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ptLabel)

                Spacer()

                Button(action: startNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.ptAccent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.ptSurface)

            Rectangle().fill(Color.ptBorder).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { item in
                        PromptListRow(item: item, isSelected: selectedID == item.id) {
                            loadItem(item)
                        }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 260)
        .background(Color.ptBg)
    }

    // MARK: - Right panel

    @ViewBuilder
    private var detailPanel: some View {
        if selectedID != nil {
            VStack(alignment: .leading, spacing: 0) {
                // Name
                TextField("Name", text: $editName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.ptLabel)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 6)

                // Description
                TextField("Short description…", text: $editDescription)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ptMuted)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                Rectangle().fill(Color.ptBorder).frame(height: 1)

                // Markdown content
                ZStack(alignment: .topTrailing) {
                    TextEditor(text: $editContent)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.ptLabel)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(16)
                    CopyButton(text: editContent)
                        .padding(10)
                }

                Rectangle().fill(Color.ptBorder).frame(height: 1)

                // Footer
                HStack {
                    if !isNew {
                        Button("Delete") {
                            if let id = selectedID { store.delete(id: id); selectedID = nil }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red.opacity(0.7))
                    }
                    Spacer()
                    Button("Save", action: saveEdit)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.ptAccent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.ptAccent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.ptBg)
        } else {
            VStack {
                Text("Select or add a prompt / skill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ptMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.ptBg)
        }
    }

    // MARK: - Actions

    private func loadItem(_ item: PromptItem) {
        pendingNewID   = nil
        selectedID     = item.id
        editName        = item.name
        editDescription = item.description
        editContent     = item.content
    }

    private func startNew() {
        let newID       = UUID()
        pendingNewID    = newID
        selectedID      = newID
        editName        = ""
        editDescription = ""
        editContent     = ""
    }

    private func saveEdit() {
        guard let id = selectedID else { return }
        let item = PromptItem(id: id, name: editName, description: editDescription, content: editContent)
        if isNew {
            store.add(item)
            pendingNewID = nil
        } else {
            store.update(item)
        }
    }
}

// MARK: - List row

private struct PromptListRow: View {
    let item: PromptItem
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center) {
                    Text(item.name.isEmpty ? "Untitled" : item.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.ptLabel)
                        .lineLimit(1)
                    Spacer()
                    if hovered && !item.content.isEmpty {
                        CopyButton(text: item.content)
                    }
                }
                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ptMuted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.ptAccent.opacity(0.12) :
                (hovered   ? Color.white.opacity(0.05)    : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Copy button

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(copied ? Color.ptAccent : Color.ptMuted)
        }
        .buttonStyle(.plain)
    }
}
