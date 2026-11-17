import SwiftUI
import StickeyCore

enum BulkNoteSecurityAction: String, Identifiable {
    case lock, unlock
    var id: String { rawValue }
}

/// Keeps each note's existing authentication and auto-lock behavior during a batch.
struct BulkNoteSecurityView: View {
    @Bindable var store: NoteStore
    let noteIDs: [UUID]
    let action: BulkNoteSecurityAction
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var index = 0
    @State private var completed = 0
    @State private var skipped = 0
    @State private var legacySkipped = 0
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var operation = UUID()
    @State private var activeID: UUID?
    @State private var started = false

    private var finished: Bool { index >= noteIDs.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: action == .lock ? "lock.shield" : "lock.open")
                    .font(.system(size: 28, weight: .light))
                Spacer()
                IconButton(symbol: "xmark", help: finished ? "Close" : "Cancel remaining notes") {
                    close()
                }.keyboardShortcut(.escape, modifiers: [])
            }
            Text(action == .lock ? "Lock selected notes" : "Unlock selected notes")
                .font(.system(size: 25, weight: .semibold, design: .rounded))
            if finished {
                Text("Finished processing \(completed) \(completed == 1 ? "note" : "notes").")
                    .font(.system(size: 14))
                if skipped > 0 {
                    Text("\(skipped) \(skipped == 1 ? "note was" : "notes were") skipped.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            } else {
                Text("Note \(index + 1) of \(noteIDs.count)")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                ProgressView(value: Double(index), total: Double(max(noteIDs.count, 1)))
                Text(AppleAuthenticationCopy.unlockDescription + " Apple verifies your identity in its system prompt.")
                    .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                if action == .lock {
                    Text("New locks use Apple authentication on this device. Existing protected notes lock immediately.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red)
                }
                if task != nil {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(action == .lock ? "Locking…" : "Unlocking…")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                }
            }
            if legacySkipped > 0 {
                Text("\(legacySkipped) \(legacySkipped == 1 ? "note uses" : "notes use") an older lock and could not be unlocked here. Open the note’s lock settings to switch to Apple authentication before using bulk unlock.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            if action == .unlock {
                Text("Each note locks again after \(NoteLockDuration.label(store.autoLockSeconds)) from its unlock time.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            HStack {
                if !finished {
                    Button("Cancel") { close() }.buttonStyle(PillButtonStyle())
                    Spacer()
                    Button("Skip note") { skip() }.disabled(task != nil)
                    if task == nil {
                        Button("Retry") { process() }.buttonStyle(PillButtonStyle(filled: true))
                    }
                } else {
                    Spacer()
                    Button("Done") { onComplete(); dismiss() }
                        .buttonStyle(PillButtonStyle(filled: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(30)
        .frame(idealWidth: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.paper)
        .foregroundStyle(Palette.ink)
        .interactiveDismissDisabled(task != nil)
        .onAppear {
            guard !started else { return }
            started = true
            process()
        }
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
            if phase == .background { close() }
            #else
            if phase != .active && !AppleNoteSecurity.isPresentingSystemPrompt { close() }
            #endif
        }
        .onDisappear { cancelOperation() }
        .modifier(InactiveNotePrivacy())
    }

    private func process() {
        guard task == nil, !finished else { return }
        let attempt = UUID()
        operation = attempt
        error = nil
        task = Task { @MainActor in
            while index < noteIDs.count {
                guard operation == attempt, !Task.isCancelled else { return }
                let id = noteIDs[index]
                guard let note = store.notes.first(where: { $0.id == id }), note.deletedAt == nil else {
                    skipped += 1; index += 1
                    continue
                }
                store.relockExpiredNotes()
                if action == .unlock && store.isLocked(id) && !note.usesAppleAuthentication {
                    // Bulk authentication never changes or bypasses an older lock.
                    legacySkipped += 1; skipped += 1; index += 1
                    continue
                }
                activeID = id
                do {
                    try Task.checkCancellation()
                    if action == .lock {
                        if note.isPasswordProtected { store.relockNote(id) }
                        else { try await AppleNoteSecurity.protect(store: store, noteID: id) }
                    } else if store.isLocked(id) {
                        try await AppleNoteSecurity.unlock(store: store, noteID: id)
                    }
                    guard operation == attempt, !Task.isCancelled else { return }
                    activeID = nil
                    completed += 1
                    index += 1
                } catch {
                    guard operation == attempt, !Task.isCancelled else { return }
                    self.error = error is CancellationError
                        ? "Authentication was cancelled. Retry this note or skip it."
                        : error.localizedDescription
                    activeID = nil
                    task = nil
                    return
                }
            }
            if operation == attempt { task = nil }
        }
    }

    private func skip() {
        guard task == nil, !finished else { return }
        skipped += 1
        index += 1
        error = nil
        process()
    }

    private func cancelOperation() {
        operation = UUID()
        task?.cancel()
        if let activeID {
            AppleNoteSecurity.cancel(noteID: activeID)
            // Invalidates any encryption work that is still completing after cancellation.
            store.relockNote(activeID)
        }
        activeID = nil
        task = nil
    }

    private func close() {
        cancelOperation()
        if finished { onComplete() }
        dismiss()
    }
}
