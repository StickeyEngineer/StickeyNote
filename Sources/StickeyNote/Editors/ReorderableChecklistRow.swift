import SwiftUI
import UniformTypeIdentifiers
import StickeyCore

private struct ChecklistItemDrag: Codable, Transferable {
    let noteID: UUID
    let itemID: UUID

    static let contentType = UTType(exportedAs: "com.stickeynote.checklist-item", conformingTo: .data)
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType).visibility(.ownProcess)
    }
}

struct ReorderableChecklistRow<Content: View>: View {
    let noteID: UUID
    let item: ChecklistItem
    @Binding var items: [ChecklistItem]
    var compact = false
    @ViewBuilder var content: () -> Content

    @State private var height: CGFloat = 0
    @State private var insertionEdge: VerticalEdge?

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 5 : 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: compact ? 11 : 14, weight: .medium))
                .foregroundStyle(Palette.noteInk.opacity(0.5))
                .frame(width: compact ? 20 : 30, height: compact ? 18 : 26)
                .contentShape(Rectangle())
                .draggable(ChecklistItemDrag(noteID: noteID, itemID: item.id)) {
                    Label(item.text.isEmpty ? "Checklist item" : item.text,
                          systemImage: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .lineLimit(2).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                #if os(macOS)
                .background {
                    if compact {
                        // Give the grip a control hit region in the background-draggable desktop panel.
                        Button(action: {}) { Color.clear }
                            .buttonStyle(.borderless).disabled(true).accessibilityHidden(true)
                    }
                }
                #endif
                .accessibilityLabel("Reorder \(item.text.isEmpty ? "checklist item" : item.text)")
                .help("Drag to reorder")
            content()
        }
        .padding(.vertical, compact ? 4 : 11)
        .contentShape(Rectangle())
        .background {
            GeometryReader { row in
                Color.clear.onChange(of: row.size.height, initial: true) { _, newHeight in height = newHeight }
            }
        }
        .overlay(alignment: insertionEdge == .bottom ? .bottom : .top) {
            if insertionEdge != nil {
                Capsule().fill(Palette.noteInk.opacity(0.7)).frame(height: 2).allowsHitTesting(false)
            }
        }
        .overlay {
            // Keep the drop target above the native text field while ordinary clicks pass through.
            Color.clear
                .allowsHitTesting(false)
                .onDrop(of: [ChecklistItemDrag.contentType], delegate: ChecklistRowDrop(
                    noteID: noteID, targetID: item.id, items: $items, height: height, insertionEdge: $insertionEdge
                ))
        }
    }
}

private struct ChecklistRowDrop: DropDelegate {
    let noteID: UUID
    let targetID: UUID
    @Binding var items: [ChecklistItem]
    let height: CGFloat
    @Binding var insertionEdge: VerticalEdge?

    private func edge(at info: DropInfo) -> VerticalEdge {
        info.location.y < height / 2 ? .top : .bottom
    }

    func dropEntered(info: DropInfo) { insertionEdge = edge(at: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        insertionEdge = edge(at: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { insertionEdge = nil }

    func performDrop(info: DropInfo) -> Bool {
        insertionEdge = nil
        let edge = edge(at: info)
        guard let provider = info.itemProviders(for: [ChecklistItemDrag.contentType]).first else { return false }
        _ = provider.loadTransferable(type: ChecklistItemDrag.self) { result in
            guard case let .success(drag) = result, drag.noteID == noteID else { return }
            Task { @MainActor in
                guard let source = items.firstIndex(where: { $0.id == drag.itemID }),
                      let target = items.firstIndex(where: { $0.id == targetID }) else { return }
                let destination = edge == .top ? target : target + 1
                guard destination != source && destination != source + 1 else { return }
                items.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
            }
        }
        return true
    }
}
