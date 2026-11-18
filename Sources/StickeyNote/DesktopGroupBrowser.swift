#if os(macOS)
import StickeyCore
import SwiftUI

struct DesktopGroupBrowser: View {
    let store: NoteStore
    let openNote: (UUID) -> Void
    @State private var selectedGroupID: UUID?

    init(store: NoteStore, initialGroupID: UUID?, openNote: @escaping (UUID) -> Void) {
        self.store = store
        self.openNote = openNote
        _selectedGroupID = State(initialValue: initialGroupID)
    }

    var body: some View {
        let groups = store.groups
        let selected = groups.first { $0.id == selectedGroupID }
        let groupIDs = Set(groups.map(\.id))
        let notes = store.notes.filter { note in
            guard note.deletedAt == nil else { return false }
            if let selected { return note.groupID == selected.id }
            // A synced note can outlive its group.
            return note.groupID.map { !groupIDs.contains($0) } ?? true
        }.sorted { $0.updatedAt > $1.updatedAt }

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Groups").font(.headline).padding(.horizontal, 14).padding(.vertical, 10)
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: -6) {
                            ForEach(groups) { group in
                                DesktopGroupTab(group: group, selected: selected?.id == group.id) {
                                    selectedGroupID = group.id
                                }
                                .id(Optional(group.id))
                            }
                            DesktopGroupTab(group: nil, selected: selected == nil) {
                                selectedGroupID = nil
                            }
                            .id(nil as UUID?)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 3)
                    }
                    .onAppear { reader.scrollTo(selected?.id, anchor: .center) }
                }
            }
            .frame(width: 158)
            .background(Palette.sidebar)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(selected?.name ?? "No group").font(.headline).lineLimit(1)
                    Spacer()
                    Text("\(notes.count)").font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.secondary)
                        .accessibilityLabel("\(notes.count) notes")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                if notes.isEmpty {
                    Text("No notes in this group")
                        .font(.callout).foregroundStyle(Palette.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(notes) { note in
                                DesktopNotePreview(note: note, locked: store.isLocked(note.id)) {
                                    openNote(note.id)
                                }
                            }
                        }
                        .padding(.horizontal, 10).padding(.bottom, 10)
                    }
                    .id(selected?.id)
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.paper)
        .frame(width: 414, height: 266)
    }
}

private struct DesktopGroupTab: View {
    let group: NoteGroup?
    let selected: Bool
    let select: () -> Void
    @State private var hovered = false

    var body: some View {
        let name = group?.name ?? "No group"
        let shape = RoundedRectangle(cornerRadius: 9)
        Button(action: select) {
            HStack(spacing: 7) {
                Image(systemName: group?.symbol ?? "folder").frame(width: 14)
                Text(name).lineLimit(1)
                Spacer(minLength: 0)
                if selected { Image(systemName: "chevron.right").font(.caption2) }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.bottom, 3)
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(selected ? Palette.selection : Palette.surface, in: shape)
            .overlay(shape.strokeBorder(Palette.ink.opacity(0.14)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .task(id: hovered) {
            guard hovered, !selected else { return }
            // Crossing another tab on the way to a preview should keep that preview in place.
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            select()
        }
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("desktop.group.\(group?.id.uuidString ?? "none")")
        .help(name)
    }
}

private struct DesktopNotePreview: View {
    let note: StickyNote
    let locked: Bool
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: locked ? "lock.fill" : note.kind == .checklist ? "checklist" : "note.text")
                    .font(.system(size: 12)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(locked ? "Locked note" : note.displayTitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                    if !locked {
                        let snippet = String(note.previewText.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !snippet.isEmpty {
                            Text(snippet).font(.caption).lineLimit(2).foregroundStyle(Palette.noteInk.opacity(0.75))
                        } else if !note.content.strokes.isEmpty {
                            DrawingPreview(strokes: note.content.strokes).frame(height: 24)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Palette.noteInk)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: note.color.hex), in: shape)
            .overlay(shape.strokeBorder(Palette.noteInk.opacity(hovered ? 0.45 : 0.08)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityHint("Open note")
        .accessibilityIdentifier("desktop.preview.\(note.id.uuidString)")
    }
}
#endif
