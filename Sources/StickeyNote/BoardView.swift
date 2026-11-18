import SwiftUI
import StickeyCore

struct BoardView: View {
    @Bindable var store: NoteStore
    @State private var section = "all"
    @State private var search = ""
    @State private var kindFilter = "all"
    @State private var sort = "edited"
    @State private var listLayout = false
    @State private var showGroups = false
    @State private var groupName = ""
    @State private var renaming: UUID?
    @State private var settings = false
    @State private var scanner = false
    @State private var sidebarVisible = false
    @State private var widgetRefresh: Task<Void, Never>?
    @State private var selection = BoardSelection()
    @State private var selecting = false
    @State private var cardFrames: [UUID: CGRect] = [:]
    @State private var visibleCardFrames: [UUID: CGRect] = [:]
    @State private var groupFrames: [UUID: CGRect] = [:]
    @State private var groupViewport = CGRect.zero
    @State private var groupDragIDs: [UUID]?
    @State private var groupDragLocation: CGPoint?
    @State private var groupDragCancelled = false
    @State private var securityAction: BulkNoteSecurityAction?
    @State private var securityNoteIDs: [UUID] = []
    @State private var selectionDragCancelled = false
    @GestureState private var draggingSelection = false
    @GestureState private var draggingGroupNotes = false
    @FocusState private var searchFocused: Bool
    @ObservedObject private var sync = CloudKitSyncService.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    private var active: [StickyNote] { store.notes.filter { $0.deletedAt == nil } }
    private var selectedNotes: [StickyNote] { filtered.filter { selection.selectedIDs.contains($0.id) } }
    private var groupID: UUID? { section.hasPrefix("group:") ? UUID(uuidString: String(section.dropFirst(6))) : nil }
    private var title: String {
        switch section {
        case "pinned": return "Pinned notes"
        case "recent": return "Recently edited"
        case "trash": return "Recently deleted"
        default: return store.groups.first { $0.id == groupID }?.name ?? "All notes"
        }
    }
    private var filtered: [StickyNote] {
        store.notes.filter { note in
            if section == "trash" { guard note.deletedAt != nil else { return false } }
            else { guard note.deletedAt == nil else { return false } }
            if section == "pinned" && !note.isPinned { return false }
            if section == "recent" && note.updatedAt < Date().addingTimeInterval(-7 * 86400) { return false }
            if let groupID, note.groupID != groupID { return false }
            if kindFilter != "all" && note.kind.rawValue != kindFilter { return false }
            return search.isEmpty || (!store.isLocked(note.id) && (note.content.plainText.localizedStandardContains(search)))
        }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if sort == "title" { return $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
            if sort == "created" { return $0.createdAt > $1.createdAt }
            return $0.updatedAt > $1.updatedAt
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > 720
            HStack(spacing: 0) {
                if wide { sidebar.frame(width: 220) }
                VStack(spacing: 0) {
                    header(wide: wide)
                    boardToolbar
                    selectionToolbar
                    if filtered.isEmpty {
                        EmptyState(symbol: search.isEmpty ? "note.text" : "magnifyingglass", title: search.isEmpty ? "A little room to think." : "No notes found", message: search.isEmpty ? "Capture an idea, make a list, or leave yourself a little reminder." : "Try another word or look in a different group.")
                        if search.isEmpty && section != "trash" { Button("Create a note") { create(.text) }.buttonStyle(PillButtonStyle(filled: true)).padding(.bottom, 60) }
                    } else {
                        notesGrid(wide: wide)
                    }
                    footer
                }.background(Palette.paper)
            }
            .foregroundStyle(Palette.ink)
            .coordinateSpace(name: "noteBoardRoot")
            .onPreferenceChange(NoteGroupFramesKey.self) { groupFrames = $0 }
            .onPreferenceChange(NoteGroupViewportKey.self) { groupViewport = $0 }
            .overlay(alignment: .topLeading) {
                if let ids = groupDragIDs, let location = groupDragLocation {
                    Label("\(ids.count) \(ids.count == 1 ? "note" : "notes")", systemImage: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Palette.accentInk)
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        .offset(x: location.x + 14, y: location.y + 14)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
        .sheet(isPresented: $sidebarVisible) { sidebar.frame(minWidth: 280).presentationDetents([.medium, .large]) }
        .sheet(isPresented: Binding(get: { store.selectedNoteID != nil }, set: { if !$0 { store.selectedNoteID = nil } })) {
            if let id = store.selectedNoteID { NoteDetailView(store: store, noteID: id).id(id) }
        }
        .sheet(isPresented: $settings) { SettingsView(store: store, sync: sync) }
        .sheet(item: $securityAction) { action in
            BulkNoteSecurityView(store: store, noteIDs: securityNoteIDs, action: action) {
                finishSelection()
            }
        }
        .sheet(isPresented: $scanner) { ScanCodeView { value in
            let id = store.createNote(groupID: groupID)
            store.updateNote(id) { $0.content.title = "Scanned code"; $0.content.text = value }
            scanner = false; store.selectedNoteID = id
        } }
        .alert(renaming == nil ? "New group" : "Rename group", isPresented: $showGroups) {
            TextField("Group name", text: $groupName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                if let id = renaming { store.renameGroup(id, name: name) }
                else { section = "group:" + store.addGroup(name: name).uuidString }
                renaming = nil
            }.disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("Give your ideas a place of their own.") }
        .alert("Something needs attention", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .task { WidgetSnapshotWriter.update(notes: store.notes); if sync.wasEnabled { sync.start(store: store) } }
        #if os(macOS)
        .onAppear {
            FloatingNoteWindows.shared.openMainNote = { id in
                openWindow(id: "main", value: MainWindowIdentity.library)
                NSApp.activate(ignoringOtherApps: true)
                store.selectedNoteID = id
            }
        }
        #endif
        .onChange(of: store.notes) { old, current in
            widgetRefresh?.cancel()
            let sensitiveChange = current.contains { n in
                guard let before = old.first(where: { $0.id == n.id }) else { return false }
                return before.isPasswordProtected != n.isPasswordProtected || before.deletedAt != n.deletedAt
            }
            if sensitiveChange { WidgetSnapshotWriter.update(notes: current) }
            else {
                widgetRefresh = Task {
                    do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                    WidgetSnapshotWriter.update(notes: store.notes)
                }
            }
        }
        .background { Button("Find notes") { searchFocused = true }.keyboardShortcut("f").hidden().accessibilityHidden(true) }
        .onChange(of: section) { _, _ in finishSelection() }
        .onChange(of: search) { _, _ in finishSelection() }
        .onChange(of: kindFilter) { _, _ in finishSelection() }
        .onChange(of: listLayout) { _, _ in cancelSelectionDrag(); cardFrames = [:] }
        .onChange(of: Set(filtered.map(\.id))) { _, ids in
            cancelSelectionDrag()
            cancelGroupDrag()
            selection.retainOnly(ids)
        }
        .onChange(of: draggingSelection) { _, dragging in
            if !dragging { selection.end(); selectionDragCancelled = false; cardFrames = visibleCardFrames }
        }
        .onChange(of: draggingGroupNotes) { _, dragging in
            if !dragging {
                groupDragIDs = nil
                groupDragLocation = nil
                groupDragCancelled = false
            }
        }
        #if os(macOS)
        .onExitCommand { finishSelection() }
        .background {
            if selecting && !searchFocused && store.selectedNoteID == nil && securityAction == nil {
                Button("Select all notes") { selection.selectAll(filtered.map(\.id)) }
                    .keyboardShortcut("a").hidden().accessibilityHidden(true)
            }
        }
        #endif
    }

    private func notesGrid(wide: Bool) -> some View {
        GeometryReader { viewport in
            ScrollView {
                LazyVGrid(columns: listLayout ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: wide ? 245 : 280), spacing: 20)], alignment: .leading, spacing: 20) {
                    ForEach(filtered) { note in
                        selectableCard(note)
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(key: NoteCardFramesKey.self, value: [note.id: proxy.frame(in: .named("noteBoard"))])
                                }
                            }
                    }
                }
                .padding(wide ? 30 : 20).padding(.top, 2)
                .frame(minHeight: viewport.size.height, alignment: .top)
                .contentShape(Rectangle())
                .coordinateSpace(name: "noteBoard")
                .overlay(alignment: .topLeading) {
                    if let rectangle = selection.marquee {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Palette.accent.opacity(0.2))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(hex: "81934F"), lineWidth: 1))
                            .frame(width: rectangle.width, height: rectangle.height)
                            .offset(x: rectangle.minX, y: rectangle.minY)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                #if os(macOS)
                // Claim a drag before card buttons/links can activate. A plain click
                // still opens a note; holding and dragging anywhere selects a region.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("noteBoard"))
                        .updating($draggingSelection) { _, state, _ in state = true }
                        .onChanged { value in
                            guard !selectionDragCancelled else { return }
                            if selection.marquee == nil {
                                searchFocused = false
                                selecting = true
                                let additive = !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty
                                selection.begin(at: value.startLocation, additive: additive)
                            }
                            selection.update(to: value.location, frames: cardFrames)
                        }
                        .onEnded { _ in selection.end(); selectionDragCancelled = false }
                )
                #endif
                .onPreferenceChange(NoteCardFramesKey.self) { frames in
                    visibleCardFrames = frames
                    if selection.marquee != nil {
                        // Lazy grids discard offscreen cells while scrolling. Their
                        // content-space frames stay valid for the current marquee.
                        cardFrames.merge(frames, uniquingKeysWith: { _, new in new })
                    } else { cardFrames = frames }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func selectableCard(_ note: StickyNote) -> some View {
        let selected = selection.selectedIDs.contains(note.id)
        return NoteCard(note: note, locked: store.isLocked(note.id), group: store.groups.first { $0.id == note.groupID }?.name, compact: listLayout, onOpen: {
            guard !draggingSelection else { return }
            #if os(macOS)
            if !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty {
                selecting = true
                selection.toggle(note.id)
                return
            }
            #endif
            if selecting { selection.toggle(note.id) }
            else { store.selectedNoteID = note.id }
        }, onCheck: { itemID in
            guard !selecting && !draggingSelection else { return }
            #if os(macOS)
            if !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty {
                selecting = true
                selection.toggle(note.id)
                return
            }
            #endif
            store.updateNote(note.id) { n in
                if let i = n.content.items.firstIndex(where: { $0.id == itemID }) { n.content.items[i].isCompleted.toggle() }
            }
        })
        .environment(\.openURL, OpenURLAction { _ in
            #if os(macOS)
            if !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty {
                selecting = true
                selection.toggle(note.id)
                return .handled
            }
            #endif
            return selecting || draggingSelection ? .handled : .systemAction
        })
        .allowsHitTesting(!selecting)
        .accessibilityHidden(selecting)
        .overlay {
            if selecting {
                Button {
                    guard !draggingSelection else { return }
                    selection.toggle(note.id)
                } label: {
                    RoundedRectangle(cornerRadius: 15).fill(.clear)
                        .contentShape(RoundedRectangle(cornerRadius: 15))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.isLocked(note.id) ? "Locked note" : note.displayTitle)
                .accessibilityValue(selected ? "Selected" : "Not selected")
                .accessibilityHint("Toggle selection for bulk actions")
            }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 15).strokeBorder(Color(hex: "81934F"), lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(selected ? Palette.accentInk : Palette.noteInk.opacity(0.55))
                    .background(selected ? Palette.accent : Color.white.opacity(0.8), in: Circle())
                    .padding(16).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .contextMenu {
            if selecting && selected { bulkActions }
            else {
                Button("Select note", systemImage: "checkmark.circle") { selecting = true; selection.toggle(note.id) }
                noteMenu(note)
            }
        }
        #if !os(macOS)
        .draggable(note.id.uuidString)
        #endif
    }

    private var selectionToolbar: some View {
        HStack(spacing: 12) {
            if selecting {
                selectionSummary
                Button("Select all") { selection.selectAll(filtered.map(\.id)) }
                    .disabled(filtered.isEmpty)
                Spacer(minLength: 0)
                Menu { bulkActions } label: { Label("Actions", systemImage: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(selection.selectedIDs.isEmpty)
                Button("Done") { finishSelection() }
                    .fontWeight(.semibold).keyboardShortcut(.cancelAction)
            } else {
                Button { selecting = true; searchFocused = false } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }.disabled(filtered.isEmpty)
                #if os(macOS)
                Text("Click and drag across notes to select").foregroundStyle(Palette.secondary).lineLimit(1)
                #endif
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain).font(.system(size: 12))
        .frame(height: 30).padding(.horizontal, 30).padding(.bottom, 8)
    }

    private var selectionSummary: some View {
        Label("\(selection.selectedIDs.count) selected", systemImage: "hand.draw")
            .fontWeight(.medium).foregroundStyle(Palette.ink)
            #if os(macOS)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named("noteBoardRoot"))
                    .updating($draggingGroupNotes) { _, state, _ in state = true }
                    .onChanged { value in
                        guard !groupDragCancelled, selecting, section != "trash" else { return }
                        if groupDragIDs == nil {
                            let ids = selectedNotes.map(\.id)
                            guard !ids.isEmpty else { return }
                            groupDragIDs = ids
                        }
                        groupDragLocation = value.location
                    }
                    .onEnded { value in finishGroupDrag(at: value.location) }
            )
            .help("Drag selected notes to a group")
            #endif
    }

    private func groupDestination(at point: CGPoint) -> UUID? {
        guard groupViewport.contains(point) else { return nil }
        return store.groups.first { groupFrames[$0.id]?.contains(point) == true }?.id
    }

    private func finishGroupDrag(at point: CGPoint) {
        let ids = groupDragIDs ?? []
        let destination = groupDestination(at: point)
        let canMove = !groupDragCancelled && selecting && section != "trash"
        groupDragIDs = nil
        groupDragLocation = nil
        groupDragCancelled = false
        guard canMove, let destination, !ids.isEmpty else { return }
        let liveIDs = Set(active.map(\.id))
        for id in ids where liveIDs.contains(id) {
            store.updateNote(id) { $0.groupID = destination }
        }
        finishSelection()
    }

    private func cancelGroupDrag() {
        if draggingGroupNotes { groupDragCancelled = true }
        groupDragIDs = nil
        groupDragLocation = nil
    }

    @ViewBuilder private var bulkActions: some View {
        if section == "trash" {
            Button("Restore selected notes", systemImage: "arrow.uturn.backward") {
                let ids = selectedNotes.map(\.id)
                for id in ids { store.restoreNote(id) }
                store.selectedNoteID = nil
                finishSelection()
            }
        } else {
            #if os(macOS)
            Button("Keep on desktop", systemImage: "macwindow.on.rectangle") {
                let ids = selectedNotes.map(\.id)
                for id in ids { FloatingNoteWindows.shared.pin(id) }
                finishSelection()
            }
            #endif
            Menu("Move to group", systemImage: "folder") {
                Button("No group") { moveSelectedNotes(to: nil) }
                ForEach(store.groups) { group in
                    Button(group.name) { moveSelectedNotes(to: group.id) }
                }
            }
            Button("Lock selected notes", systemImage: "lock") { beginSecurityAction(.lock) }
                .disabled(!selectedNotes.contains { !store.isLocked($0.id) })
            Button("Unlock selected notes", systemImage: "lock.open") { beginSecurityAction(.unlock) }
                .disabled(!selectedNotes.contains { store.isLocked($0.id) })
            Divider()
            Button("Move to Recently Deleted", systemImage: "trash", role: .destructive) {
                let ids = selectedNotes.map(\.id)
                for id in ids { store.deleteNote(id) }
                finishSelection()
            }
        }
    }

    private func moveSelectedNotes(to groupID: UUID?) {
        let ids = selectedNotes.map(\.id)
        for id in ids { store.updateNote(id) { $0.groupID = groupID } }
        finishSelection()
    }

    private func beginSecurityAction(_ action: BulkNoteSecurityAction) {
        securityNoteIDs = selectedNotes.filter { action == .lock ? !store.isLocked($0.id) : store.isLocked($0.id) }.map(\.id)
        guard !securityNoteIDs.isEmpty else { return }
        securityAction = action
    }

    private func finishSelection() {
        cancelSelectionDrag()
        cancelGroupDrag()
        selection.clear()
        selecting = false
    }

    private func cancelSelectionDrag() {
        if draggingSelection { selectionDragCancelled = true }
        selection.end()
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) { BrandMark(size: 30); (Text("stickey").fontWeight(.bold) + Text(" notes").fontWeight(.light)).font(.system(size: 20, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8) }
                .padding(.top, 48).padding(.horizontal, 22).padding(.bottom, 35)
            Text("YOUR SPACE").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(Palette.secondary).padding(.horizontal, 25).padding(.bottom, 12)
            navRow("All notes", symbol: "square.grid.2x2", key: "all", count: active.count)
            navRow("Pinned", symbol: "pin", key: "pinned", count: active.filter(\.isPinned).count)
            navRow("Recently edited", symbol: "clock", key: "recent", count: nil)
            HStack {
                Text("MY GROUPS").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(Palette.secondary)
                Spacer()
                Button { renaming = nil; groupName = ""; showGroups = true } label: { Image(systemName: "plus").font(.system(size: 12)) }.buttonStyle(.plain).help("New group")
            }.padding(.horizontal, 25).padding(.top, 33).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Array(store.groups.enumerated()), id: \.element.id) { index, group in
                        navRow(group.name, symbol: group.symbol, key: "group:" + group.id.uuidString, count: active.filter { $0.groupID == group.id }.count, tint: [Color(hex: "A5B377"),Color(hex: "C8A5D1"),Color(hex: "D8AE79"),Color(hex: "8AB6C8")][index % 4])
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: NoteGroupFramesKey.self, value: [group.id: proxy.frame(in: .named("noteBoardRoot"))])
                            }
                        }
                        .overlay {
                            if let location = groupDragLocation, groupDestination(at: location) == group.id {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Palette.accent.opacity(0.25))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "81934F"), lineWidth: 2))
                                    .padding(.horizontal, 12)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        .dropDestination(for: String.self) { values, _ in
                            let ids = Set(values.flatMap { $0.split(separator: "\n") }.compactMap { UUID(uuidString: String($0)) })
                                .intersection(active.map(\.id))
                            for id in ids { store.updateNote(id) { $0.groupID = group.id } }
                            if !ids.isEmpty { finishSelection() }
                            return !ids.isEmpty
                        }
                        .contextMenu {
                            Button("Rename group") { renaming = group.id; groupName = group.name; showGroups = true }
                            Button("Remove group", role: .destructive) { store.deleteGroup(group.id); section = "all" }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: NoteGroupViewportKey.self, value: proxy.frame(in: .named("noteBoardRoot")))
                }
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 21, weight: .light)).foregroundStyle(Color(hex: "929C76"))
                Text("Small notes.\nRoom for big ideas.").font(.system(size: 17, weight: .medium, design: .serif)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                Text("A quieter place for your mind.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12)).padding(16)
            navRow("Recently deleted", symbol: "trash", key: "trash", count: store.notes.filter { $0.deletedAt != nil }.count)
            HStack {
                Button { settings = true } label: { Label("Settings", systemImage: "gearshape").font(.system(size: 12)) }.buttonStyle(.plain)
                Spacer()
                Circle().fill(sync.isEnabled ? Color(hex: "85A66B") : Palette.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Text(sync.isEnabled ? "iCloud" : "On this device").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }.padding(.horizontal, 24).padding(.vertical, 21)
        }.background(Palette.sidebar).overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
    }
    private func navRow(_ label: String, symbol: String, key: String, count: Int?, tint: Color? = nil) -> some View {
        Button {
            section = key; sidebarVisible = false
        } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 15, weight: section == key ? .semibold : .regular)).foregroundStyle(tint ?? Palette.ink.opacity(0.75)).frame(width: 19)
                Text(label).font(.system(size: 13, weight: section == key ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 3)
                if let count, count > 0 { Text("\(count)").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
            }.padding(.horizontal, 12).frame(height: 39).background(section == key ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 12)
    }
    private func header(wide: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if !wide { IconButton(symbol: "sidebar.left", help: "Show groups") { sidebarVisible = true } }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: wide ? 30 : 25, weight: .semibold, design: .rounded))
                Text(section == "trash" ? "Your notes, ready when you need them again." : "A home for everything on your mind.").font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Button("New note", systemImage: "note.text") { create(.text) }
                Button("New checklist", systemImage: "checklist") { create(.checklist) }
                Divider()
                Button("Scan QR or barcode", systemImage: "qrcode.viewfinder") { scanner = true }
            } label: { HStack(spacing: 7) { Image(systemName: "plus"); Text("New note"); Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) } }
                .menuStyle(.borderlessButton).fixedSize().buttonStyle(PillButtonStyle(filled: true)).foregroundStyle(Palette.accentInk).tint(Palette.accentInk).padding(10).background(Palette.accent, in: RoundedRectangle(cornerRadius: 9))
        }.padding(.horizontal, wide ? 30 : 20).padding(.top, wide ? 44 : 25).padding(.bottom, 26)
    }
    private var boardToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack { filters; Spacer(); searchField.frame(width: 200); sortMenu; layoutButton }
            VStack(spacing: 14) { HStack { filters; Spacer(); sortMenu; layoutButton }; searchField }
        }.padding(.horizontal, 30).padding(.bottom, 16)
    }
    private var filters: some View {
        HStack(spacing: 4) {
            ForEach([("all", "All"), ("text", "Notes"), ("checklist", "Checklists")], id: \.0) { key, label in
                Button { kindFilter = key } label: { Text(label).font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 7).foregroundStyle(kindFilter == key ? Palette.ink : Palette.secondary).background(kindFilter == key ? Palette.filter : .clear, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain)
            }
        }
    }
    private var searchField: some View {
        HStack(spacing: 7) { Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary); TextField("Search your notes", text: $search).textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused); if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) } }.padding(9).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line)).accessibilityLabel("Search notes")
    }
    private var sortMenu: some View {
        Menu { Picker("Sort by", selection: $sort) { Text("Last edited").tag("edited"); Text("Date created").tag("created"); Text("Title").tag("title") } } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 28, height: 30) }.menuStyle(.borderlessButton).fixedSize().help("Sort notes")
    }
    private var layoutButton: some View { IconButton(symbol: listLayout ? "square.grid.2x2" : "rectangle.grid.1x2", help: listLayout ? "Grid view" : "List view") { listLayout.toggle() } }
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: "9DAC81")).frame(width: 5, height: 5)
            Text(store.saveStatus).font(.system(size: 10))
            Spacer()
            Text("\(filtered.count) \(filtered.count == 1 ? "note" : "notes")").font(.system(size: 10))
            #if os(macOS)
            Text("·").padding(.horizontal, 5)
            Text("⌘ N  new note").font(.system(size: 10))
            #endif
        }.foregroundStyle(Palette.secondary).padding(.horizontal, 30).padding(.vertical, 14).overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
    private func create(_ kind: NoteKind) { store.selectedNoteID = store.createNote(kind: kind, groupID: groupID) }
    @ViewBuilder private func noteMenu(_ note: StickyNote) -> some View {
        if note.deletedAt != nil { Button("Restore note", systemImage: "arrow.uturn.backward") { store.restoreNote(note.id) } }
        else {
            Button(store.isLocked(note.id) ? "Unlock note" : "Open", systemImage: store.isLocked(note.id) ? "lock.open" : "arrow.up.right.square") { store.selectedNoteID = note.id }
            if note.isPasswordProtected && !store.isLocked(note.id) { Button("Lock now", systemImage: "lock") { store.relockNote(note.id) } }
            Button(note.isPinned ? "Unpin" : "Pin note", systemImage: note.isPinned ? "pin.slash" : "pin") { store.updateNote(note.id) { $0.isPinned.toggle() } }
            Button("Duplicate", systemImage: "doc.on.doc") { _ = store.duplicateNote(note.id) }
            #if os(macOS)
            Button("Keep on desktop", systemImage: "macwindow.on.rectangle") { FloatingNoteWindows.shared.pin(note.id) }
            #endif
            Menu("Move to group") {
                Button("No group") { store.updateNote(note.id) { $0.groupID = nil } }
                ForEach(store.groups) { group in Button(group.name) { store.updateNote(note.id) { $0.groupID = group.id } } }
            }
            Divider()
            Button("Move to Recently Deleted", systemImage: "trash", role: .destructive) { store.deleteNote(note.id) }
        }
    }
}

private struct NoteCardFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct NoteGroupFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct NoteGroupViewportKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

struct NoteCard: View {
    let note: StickyNote
    let locked: Bool
    let group: String?
    var compact = false
    let onOpen: () -> Void
    let onCheck: (UUID) -> Void
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 6) {
                Image(systemName: locked ? "lock" : note.kind == .checklist ? "checklist" : note.content.strokes.isEmpty ? "note.text" : "pencil.tip")
                Text(group ?? (note.kind == .checklist ? "Checklist" : "Note")).font(.system(size: 10, weight: .medium))
                Spacer()
                if note.isPinned { Image(systemName: "pin.fill").rotationEffect(.degrees(30)) }
                if note.isPasswordProtected && !locked { Image(systemName: "lock.open") }
                Button(action: onOpen) { Image(systemName: "arrow.up.right").opacity(hovering ? 1 : 0.3) }.buttonStyle(.plain).accessibilityLabel("Open \(note.displayTitle)")
            }.font(.system(size: 11)).foregroundStyle(Palette.noteInk.opacity(0.56))
            Text(locked ? "Note locked" : note.displayTitle).font(.system(size: compact ? 19 : 22, weight: .semibold, design: .rounded)).lineLimit(2).lineSpacing(2)
            if locked {
                VStack(spacing: compact ? 6 : 12) {
                    if !compact { Image(systemName: "lock.shield").font(.system(size: 32, weight: .ultraLight)) }
                    Text("Unlock to view this note").font(.system(size: 12))
                    Button(action: onOpen) { Label("Unlock", systemImage: "lock.open").font(.system(size: 12, weight: .semibold)) }.buttonStyle(PillButtonStyle())
                }.foregroundStyle(Palette.noteInk.opacity(0.7)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if note.kind == .checklist {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(note.content.items.prefix(compact ? 3 : 5)) { item in
                        HStack(alignment: .top, spacing: 9) {
                            Button { onCheck(item.id) } label: { Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square").font(.system(size: 16, weight: .light)).foregroundStyle(Palette.noteInk.opacity(item.isCompleted ? 0.45 : 0.75)) }.buttonStyle(.plain).accessibilityLabel("\(item.isCompleted ? "Uncheck" : "Complete") \(item.text)")
                            Text(linkedPreview(item.text)).strikethrough(item.isCompleted).font(.system(size: 13)).foregroundStyle(Palette.noteInk.opacity(item.isCompleted ? 0.4 : 0.85)).lineLimit(2)
                        }
                    }
                    if note.content.items.count > 5 { Text("+ \(note.content.items.count - 5) more").font(.system(size: 10)).foregroundStyle(Palette.noteInk.opacity(0.5)) }
                }
            } else {
                Text(linkedPreview(note.content.text)).noteFont(note.font, size: 13).lineSpacing(6).lineLimit(compact ? 3 : note.content.strokes.isEmpty ? 7 : 3).foregroundStyle(Palette.noteInk.opacity(0.83))
                if !note.content.strokes.isEmpty && !compact { DrawingPreview(strokes: note.content.strokes).frame(height: 65) }
            }
            Spacer(minLength: 0)
            HStack {
                Text(note.updatedAt, style: .relative).font(.system(size: 10))
                Spacer()
                if note.kind == .checklist && !locked {
                    Text("\(note.content.items.filter(\.isCompleted).count) / \(note.content.items.count)").font(.system(size: 10, weight: .medium))
                    Circle().trim(from: 0, to: CGFloat(note.content.items.filter(\.isCompleted).count) / CGFloat(max(1, note.content.items.count))).stroke(Palette.noteInk.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90)).background(Circle().stroke(Palette.noteInk.opacity(0.12), lineWidth: 2)).frame(width: 12, height: 12)
                } else { Image(systemName: "ellipsis").font(.system(size: 14)) }
            }.foregroundStyle(Palette.noteInk.opacity(0.45))
        }.padding(22).frame(maxWidth: .infinity, alignment: .topLeading).frame(height: compact ? 205 : 285)
            .foregroundStyle(Palette.noteInk)
            .background(Color(hex: note.color.hex).gradient, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Palette.noteInk.opacity(0.025)))
            .shadow(color: Palette.noteInk.opacity(hovering ? 0.09 : 0.025), radius: hovering ? 12 : 4, x: 0, y: hovering ? 5 : 2)
            .contentShape(RoundedRectangle(cornerRadius: 15)).onTapGesture(perform: onOpen).onHover { hovering = $0 }
            .environment(\.colorScheme, .light)
            .accessibilityElement(children: .contain)
    }

    private func linkedPreview(_ text: String) -> AttributedString {
        var value = AttributedString(text)
        for match in NoteLinks.detectedLinks(in: text) {
            guard let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: value),
                  let upper = AttributedString.Index(range.upperBound, within: value) else { continue }
            value[lower..<upper].link = match.url
            value[lower..<upper].foregroundColor = .blue
            value[lower..<upper].underlineStyle = .single
        }
        return value
    }
}

struct DrawingPreview: View {
    let strokes: [DrawingStroke]
    var body: some View {
        Canvas { context, size in
            for stroke in strokes {
                var path = Path()
                for (index, point) in stroke.points.enumerated() { let p = CGPoint(x: point.x * size.width, y: point.y * size.height); if index == 0 { path.move(to: p) } else { path.addLine(to: p) } }
                context.stroke(path, with: .color(Color(hex: stroke.color)), style: StrokeStyle(lineWidth: max(1, stroke.width * 0.5), lineCap: .round, lineJoin: .round))
            }
        }.accessibilityLabel("Note drawing")
    }
}
