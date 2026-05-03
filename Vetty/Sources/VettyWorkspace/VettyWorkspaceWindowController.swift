import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import GhosttyKit

final class VettyWorkspaceWindowController: BaseTerminalController {
    @Published private(set) var workspace: VettyWorkspace
    @Published fileprivate var liveTabTitles: [UUID: String] = [:]
    @Published fileprivate var draggingPayload: VettyDragPayload?

    private let store: VettyWorkspaceStore
    private var runtimeTrees: [UUID: SplitTree<Ghostty.SurfaceView>] = [:]
    private var selectedRuntimeTabID: UUID?
    private var titleCancellables: [UUID: AnyCancellable] = [:]
    private var pendingWorkspaceSave: DispatchWorkItem?

    static var all: [VettyWorkspaceWindowController] {
        NSApplication.shared.windows.compactMap {
            $0.windowController as? VettyWorkspaceWindowController
        }
    }

    static var preferred: VettyWorkspaceWindowController? {
        all.first { $0.window?.isMainWindow ?? false } ?? all.last
    }

    static func newWindow(_ ghostty: Ghostty.App) -> VettyWorkspaceWindowController {
        let controller = VettyWorkspaceWindowController(ghostty)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    init(_ ghostty: Ghostty.App, store: VettyWorkspaceStore = .init()) {
        self.store = store
        self.workspace = (try? store.loadSync()) ?? .default()

        super.init(ghostty, surfaceTree: .init())

        normalizeWorkspaceSelection()
        configureWindow()
        if let selectedTabID = workspace.selectedTabID {
            selectTab(selectedTabID)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    override func surfaceTreeDidChange(
        from oldValue: SplitTree<Ghostty.SurfaceView>,
        to newValue: SplitTree<Ghostty.SurfaceView>
    ) {
        super.surfaceTreeDidChange(from: oldValue, to: newValue)
        guard let selectedRuntimeTabID else { return }
        runtimeTrees[selectedRuntimeTabID] = newValue
        installTitleSubscription(for: selectedRuntimeTabID, tree: newValue)
        syncWorkspacePaneTree(for: selectedRuntimeTabID, from: newValue)
        saveWorkspace()
    }

    override func newSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        let newView = super.newSplit(at: oldView, direction: direction, baseConfig: config)
        if let newView, newView.pwd == nil {
            newView.pwd = config?.workingDirectory ?? oldView.pwd
            persistSelectedRuntimeTree()
            saveWorkspace()
        }
        return newView
    }

    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        if surfaceTree.root == node, let selectedRuntimeTabID {
            closeTab(selectedRuntimeTabID, withConfirmation: withConfirmation)
            return
        }

        super.closeSurface(node, withConfirmation: withConfirmation)
    }

    override func windowWillClose(_ notification: Notification) {
        persistSelectedRuntimeTree()
        saveWorkspace()
        super.windowWillClose(notification)
    }

    override func promptTabTitle() {
        // Vetty manages tab names through its own sidebar; suppress Ghostty's
        // prompt because titleOverride is shared across every tab in the
        // workspace controller and would bleed across rows.
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(changeTabTitle(_:)) { return false }
        return super.validateMenuItem(item)
    }

    var selectedGroup: VettyWorkspaceGroup? {
        guard let selectedGroupID = workspace.selectedGroupID else { return workspace.groups.first }
        return workspace.groups.first { $0.id == selectedGroupID } ?? workspace.groups.first
    }

    var selectedTabs: [VettyWorkspaceTab] {
        selectedGroup?.tabs ?? []
    }

    func selectGroup(_ groupID: UUID, focusTerminal: Bool = true) {
        persistSelectedRuntimeTree()
        setGroupExpanded(groupID, true, persist: false)
        workspace.selectedGroupID = groupID
        workspace.selectedTabID = workspace.groups
            .first { $0.id == groupID }?
            .tabs
            .first?
            .id

        if let tabID = workspace.selectedTabID {
            selectTab(tabID, focusTerminal: focusTerminal)
        } else {
            selectedRuntimeTabID = nil
            surfaceTree = .init()
            saveWorkspace()
        }
    }

    func isGroupExpanded(_ groupID: UUID) -> Bool {
        workspace.groups.first { $0.id == groupID }?.isExpanded ?? false
    }

    func toggleGroup(_ groupID: UUID) {
        guard let groupIndex = workspace.groups.firstIndex(where: { $0.id == groupID }) else { return }
        workspace.selectedGroupID = groupID
        workspace.groups[groupIndex].isExpanded.toggle()
        saveWorkspace()
    }

    func setGroupExpanded(_ groupID: UUID, _ expanded: Bool, persist: Bool = true) {
        guard let groupIndex = workspace.groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard workspace.groups[groupIndex].isExpanded != expanded else { return }
        workspace.groups[groupIndex].isExpanded = expanded
        if persist { saveWorkspace() }
    }

    func selectTab(_ tabID: UUID, focusTerminal: Bool = true) {
        persistSelectedRuntimeTree()
        guard let tab = workspace.tab(id: tabID) else { return }

        workspace.selectedTabID = tabID
        if let group = workspace.groups.first(where: { $0.tabs.contains(where: { $0.id == tabID }) }) {
            workspace.selectedGroupID = group.id
            setGroupExpanded(group.id, true, persist: false)
        }

        selectedRuntimeTabID = tabID
        let tree = runtimeTrees[tabID] ?? makeRuntimeTree(from: tab.paneTree)
        runtimeTrees[tabID] = tree
        installTitleSubscription(for: tabID, tree: tree)
        surfaceTree = tree
        window?.title = displayTitle(for: tab)

        if focusTerminal, let firstSurface = tree.firstSurface {
            focusSurface(firstSurface)
        }
        saveWorkspace()
    }

    func displayTitle(for tab: VettyWorkspaceTab) -> String {
        tab.displayTitle(liveTitle: liveTabTitles[tab.id])
    }

    private func installTitleSubscription(for tabID: UUID, tree: SplitTree<Ghostty.SurfaceView>) {
        titleCancellables[tabID]?.cancel()
        guard let firstSurface = tree.firstSurface else {
            liveTabTitles.removeValue(forKey: tabID)
            refreshWindowTitleIfNeeded(for: tabID)
            return
        }

        updateComputedTitle(firstSurface.title, for: tabID)

        titleCancellables[tabID] = firstSurface.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTitle in
                guard let self else { return }
                self.updateComputedTitle(newTitle, for: tabID)
            }
    }

    private func updateComputedTitle(_ rawTitle: String, for tabID: UUID) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty else {
            liveTabTitles.removeValue(forKey: tabID)
            refreshWindowTitleIfNeeded(for: tabID)
            return
        }

        liveTabTitles[tabID] = title

        do {
            if try workspace.setLastComputedTitle(tabID, to: title) {
                scheduleWorkspaceSave()
            }
        } catch {
            Ghostty.logger.error("failed to store Vetty terminal title: \(String(describing: error))")
        }

        refreshWindowTitleIfNeeded(for: tabID)
    }

    private func refreshWindowTitleIfNeeded(for tabID: UUID) {
        guard workspace.selectedTabID == tabID, let tab = workspace.tab(id: tabID) else { return }
        window?.title = displayTitle(for: tab)
    }

    @discardableResult
    func addPlaceholderGroup() -> UUID {
        let workingDirectory = focusedSurface?.pwd
            ?? workspace.tab(id: workspace.selectedTabID ?? UUID())?.workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let groupID = workspace.addPlaceholderGroup(workingDirectory: workingDirectory)
        selectGroup(groupID, focusTerminal: false)
        return groupID
    }

    func addTabToSelectedGroup(withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil) {
        guard let groupID = workspace.selectedGroupID ?? workspace.groups.first?.id else { return }
        addTab(toGroup: groupID, withBaseConfig: baseConfig)
    }

    func addTab(toGroup groupID: UUID, withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil) {
        let wasSelectedGroup = groupID == workspace.selectedGroupID
        let groupWorkingDirectory = workspace.groups
            .first { $0.id == groupID }?
            .tabs
            .last?
            .workingDirectory

        setGroupExpanded(groupID, true, persist: false)
        workspace.selectedGroupID = groupID

        let workingDirectory = baseConfig?.workingDirectory
            ?? (wasSelectedGroup ? focusedSurface?.pwd : nil)
            ?? (wasSelectedGroup ? workspace.tab(id: workspace.selectedTabID ?? UUID())?.workingDirectory : nil)
            ?? groupWorkingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        do {
            let tabID = try workspace.addTab(
                named: "Terminal",
                workingDirectory: workingDirectory,
                toGroup: groupID
            )
            if let tab = workspace.tab(id: tabID),
               case .terminal(let pane) = tab.paneTree {
                let tree = makeSingleRuntimeTree(
                    paneID: pane.id,
                    workingDirectory: workingDirectory,
                    baseConfig: baseConfig
                )
                runtimeTrees[tabID] = tree
                installTitleSubscription(for: tabID, tree: tree)
            }
            saveWorkspace()
            selectTab(tabID)
        } catch {
            presentError(error)
        }
    }

    func moveTab(_ tabID: UUID, toIndex: Int) {
        do {
            try workspace.moveTab(tabID, toIndex: toIndex)
            saveWorkspace()
        } catch {
            presentError(error)
        }
    }

    func moveGroup(_ groupID: UUID, toIndex: Int) {
        do {
            try workspace.moveGroup(groupID, toIndex: toIndex)
            saveWorkspace()
        } catch {
            presentError(error)
        }
    }

    func groupID(for tabID: UUID) -> UUID? {
        workspace.groups.first { $0.tabs.contains { $0.id == tabID } }?.id
    }

    func tabIndex(for tabID: UUID) -> (groupID: UUID, index: Int)? {
        for group in workspace.groups {
            if let i = group.tabs.firstIndex(where: { $0.id == tabID }) {
                return (group.id, i)
            }
        }
        return nil
    }

    func groupIndex(for groupID: UUID) -> Int? {
        workspace.groups.firstIndex { $0.id == groupID }
    }

    func renameGroup(_ groupID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try workspace.renameGroup(groupID, to: trimmed)
            saveWorkspace()
        } catch {
            presentError(error)
        }
    }

    func renameTab(_ tabID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try workspace.setTabTitleOverride(tabID, to: trimmed.isEmpty ? nil : trimmed)
            refreshWindowTitleIfNeeded(for: tabID)
            saveWorkspace()
        } catch {
            presentError(error)
        }
    }

    func closeGroup(_ groupID: UUID, withConfirmation: Bool = true) {
        guard let group = workspace.groups.first(where: { $0.id == groupID }) else { return }
        let needsConfirmation = group.tabs.contains { tab in
            runtimeTree(for: tab.id)?.contains(where: { $0.needsConfirmQuit }) ?? false
        }

        guard withConfirmation, needsConfirmation else {
            closeGroupImmediately(groupID)
            return
        }

        confirmClose(
            messageText: "Close Group?",
            informativeText: "One or more terminals in this group still have running processes. If you close the group, those processes will be killed."
        ) { [weak self] in
            self?.closeGroupImmediately(groupID)
        }
    }

    func closeTab(_ tabID: UUID, withConfirmation: Bool = true) {
        let needsConfirmation = runtimeTree(for: tabID)?.contains(where: { $0.needsConfirmQuit }) ?? false

        guard withConfirmation, needsConfirmation else {
            closeTabImmediately(tabID)
            return
        }

        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab, the process will be killed."
        ) { [weak self] in
            self?.closeTabImmediately(tabID)
        }
    }

    private func configureWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vetty"
        window.minSize = NSSize(width: 760, height: 460)
        window.delegate = self
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: VettyWorkspaceRootView(controller: self))
        self.window = window
    }

    private func closeGroupImmediately(_ groupID: UUID) {
        guard let group = workspace.groups.first(where: { $0.id == groupID }) else { return }
        let tabIDs = group.tabs.map(\.id)
        let wasSelected = workspace.selectedGroupID == groupID
            || tabIDs.contains(where: { $0 == selectedRuntimeTabID })

        if wasSelected {
            selectedRuntimeTabID = nil
        }

        for tabID in tabIDs {
            runtimeTrees.removeValue(forKey: tabID)
            titleCancellables.removeValue(forKey: tabID)
            liveTabTitles.removeValue(forKey: tabID)
        }

        do {
            try workspace.removeGroup(groupID)
            showWorkspaceSelectionAfterRemoval(wasSelected: wasSelected)
        } catch {
            presentError(error)
        }
    }

    private func closeTabImmediately(_ tabID: UUID) {
        let wasSelected = workspace.selectedTabID == tabID || selectedRuntimeTabID == tabID

        if wasSelected {
            selectedRuntimeTabID = nil
        }

        runtimeTrees.removeValue(forKey: tabID)
        titleCancellables.removeValue(forKey: tabID)
        liveTabTitles.removeValue(forKey: tabID)

        do {
            try workspace.removeTab(tabID)
            showWorkspaceSelectionAfterRemoval(wasSelected: wasSelected)
        } catch {
            presentError(error)
        }
    }

    private func showWorkspaceSelectionAfterRemoval(wasSelected: Bool) {
        guard wasSelected else {
            saveWorkspace()
            return
        }

        if let selectedGroupID = workspace.selectedGroupID {
            setGroupExpanded(selectedGroupID, true, persist: false)
        }

        if let selectedTabID = workspace.selectedTabID {
            selectTab(selectedTabID)
        } else {
            surfaceTree = .init()
            window?.title = selectedGroup?.name ?? "Vetty"
            saveWorkspace()
        }
    }

    private func runtimeTree(for tabID: UUID) -> SplitTree<Ghostty.SurfaceView>? {
        if tabID == selectedRuntimeTabID {
            return surfaceTree
        }

        return runtimeTrees[tabID]
    }

    private func normalizeWorkspaceSelection() {
        if workspace.groups.isEmpty {
            workspace = .default()
            return
        }

        if let selectedGroupID = workspace.selectedGroupID,
           workspace.groups.contains(where: { $0.id == selectedGroupID }) {
        } else {
            workspace.selectedGroupID = workspace.groups[0].id
        }

        guard let groupIndex = workspace.groups.firstIndex(where: { $0.id == workspace.selectedGroupID }) else {
            workspace.selectedGroupID = workspace.groups[0].id
            workspace.selectedTabID = workspace.groups[0].tabs.first?.id
            return
        }

        if workspace.groups[groupIndex].tabs.isEmpty {
            let workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
            let pane = VettyTerminalPane(workingDirectory: workingDirectory)
            let tab = VettyWorkspaceTab(
                name: "Terminal",
                workingDirectory: workingDirectory,
                paneTree: .terminal(pane)
            )
            workspace.groups[groupIndex].tabs.append(tab)
            workspace.selectedTabID = tab.id
            return
        }

        if let selectedTabID = workspace.selectedTabID,
           workspace.groups[groupIndex].tabs.contains(where: { $0.id == selectedTabID }) {
            return
        }

        workspace.selectedTabID = workspace.groups[groupIndex].tabs[0].id
    }

    private func makeRuntimeTree(from paneTree: VettyPaneTree) -> SplitTree<Ghostty.SurfaceView> {
        guard let root = makeRuntimeNode(from: paneTree) else { return .init() }
        return SplitTree(root: root, zoomed: nil)
    }

    private func makeSingleRuntimeTree(
        paneID: UUID,
        workingDirectory: String,
        baseConfig: Ghostty.SurfaceConfiguration?
    ) -> SplitTree<Ghostty.SurfaceView> {
        guard let ghosttyApp = ghostty.app else { return .init() }
        var config = baseConfig ?? Ghostty.SurfaceConfiguration()
        config.workingDirectory = workingDirectory
        return .init(view: Ghostty.SurfaceView(
            ghosttyApp,
            baseConfig: config,
            uuid: paneID
        ))
    }

    private func makeRuntimeNode(from paneTree: VettyPaneTree) -> SplitTree<Ghostty.SurfaceView>.Node? {
        guard let ghosttyApp = ghostty.app else { return nil }

        switch paneTree {
        case .terminal(let pane):
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = pane.workingDirectory
            return .leaf(view: Ghostty.SurfaceView(
                ghosttyApp,
                baseConfig: config,
                uuid: pane.id
            ))

        case .split(let split):
            guard let first = makeRuntimeNode(from: split.first),
                  let second = makeRuntimeNode(from: split.second) else {
                return nil
            }
            return .split(.init(
                direction: split.direction.splitTreeDirection,
                ratio: split.ratio,
                left: first,
                right: second
            ))
        }
    }

    private func syncWorkspacePaneTree(for tabID: UUID, from runtimeTree: SplitTree<Ghostty.SurfaceView>) {
        guard let paneTree = runtimeTree.workspacePaneTree else { return }

        for groupIndex in workspace.groups.indices {
            guard let tabIndex = workspace.groups[groupIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
                continue
            }

            workspace.groups[groupIndex].tabs[tabIndex].paneTree = paneTree
            workspace.groups[groupIndex].tabs[tabIndex].workingDirectory = paneTree.firstWorkingDirectory
                ?? workspace.groups[groupIndex].tabs[tabIndex].workingDirectory
            return
        }
    }

    private func persistSelectedRuntimeTree() {
        guard let selectedRuntimeTabID else { return }
        runtimeTrees[selectedRuntimeTabID] = surfaceTree
        syncWorkspacePaneTree(for: selectedRuntimeTabID, from: surfaceTree)
    }

    private func scheduleWorkspaceSave() {
        pendingWorkspaceSave?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWorkspaceSave = nil
            self.saveWorkspace()
        }
        pendingWorkspaceSave = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: workItem)
    }

    private func saveWorkspace() {
        pendingWorkspaceSave?.cancel()
        pendingWorkspaceSave = nil

        do {
            try store.saveSync(workspace)
        } catch {
            Ghostty.logger.error("failed to save Vetty workspace: \(String(describing: error))")
        }
    }
}

private struct VettyWorkspaceRootView: View {
    @ObservedObject var controller: VettyWorkspaceWindowController

    var body: some View {
        HStack(spacing: 0) {
            VettyWorkspaceSidebar(controller: controller)
                .frame(width: 244)

            Divider()

            TerminalView(
                ghostty: controller.ghostty,
                viewModel: controller,
                delegate: controller
            )
        }
        .frame(minWidth: 760, minHeight: 460)
    }
}

fileprivate enum VettyDragPayload: Equatable {
    case tab(groupID: UUID, tabID: UUID)
    case group(UUID)

    var encoded: String {
        switch self {
        case .tab(let groupID, let tabID): return "tab:\(groupID.uuidString):\(tabID.uuidString)"
        case .group(let groupID): return "group:\(groupID.uuidString)"
        }
    }

    init?(_ string: String) {
        let parts = string.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 3, parts[0] == "tab",
           let groupID = UUID(uuidString: String(parts[1])),
           let tabID = UUID(uuidString: String(parts[2])) {
            self = .tab(groupID: groupID, tabID: tabID)
        } else if parts.count == 2, parts[0] == "group",
                  let groupID = UUID(uuidString: String(parts[1])) {
            self = .group(groupID)
        } else {
            return nil
        }
    }
}

fileprivate struct TabDropDelegate: DropDelegate {
    let targetTabID: UUID
    let groupID: UUID
    let controller: VettyWorkspaceWindowController
    let approxRowHeight: CGFloat

    private func sourceTabID() -> UUID? {
        guard case .tab(let sourceGroupID, let sourceTabID) = controller.draggingPayload,
              sourceGroupID == groupID else { return nil }
        return sourceTabID
    }

    func validateDrop(info: DropInfo) -> Bool {
        sourceTabID() != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let sourceTabID = sourceTabID() else {
            return DropProposal(operation: .forbidden)
        }
        guard sourceTabID != targetTabID,
              let targetIndex = controller.tabIndex(for: targetTabID)?.index,
              let sourceIndex = controller.tabIndex(for: sourceTabID)?.index else {
            return DropProposal(operation: .move)
        }
        let insertBefore = info.location.y < approxRowHeight / 2
        let destination = insertBefore ? targetIndex : targetIndex + 1
        let finalIndex = sourceIndex < destination ? destination - 1 : destination
        guard finalIndex != sourceIndex else {
            return DropProposal(operation: .move)
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            controller.moveTab(sourceTabID, toIndex: destination)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        controller.draggingPayload = nil
        return true
    }
}

fileprivate struct GroupDropDelegate: DropDelegate {
    let targetGroupID: UUID
    let controller: VettyWorkspaceWindowController
    let approxRowHeight: CGFloat

    private func sourceGroupID() -> UUID? {
        guard case .group(let id) = controller.draggingPayload else { return nil }
        return id
    }

    func validateDrop(info: DropInfo) -> Bool {
        sourceGroupID() != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let sourceGroupID = sourceGroupID() else {
            return DropProposal(operation: .forbidden)
        }
        guard sourceGroupID != targetGroupID,
              let targetIndex = controller.groupIndex(for: targetGroupID),
              let sourceIndex = controller.groupIndex(for: sourceGroupID) else {
            return DropProposal(operation: .move)
        }
        let insertBefore = info.location.y < approxRowHeight / 2
        let destination = insertBefore ? targetIndex : targetIndex + 1
        let finalIndex = sourceIndex < destination ? destination - 1 : destination
        guard finalIndex != sourceIndex else {
            return DropProposal(operation: .move)
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            controller.moveGroup(sourceGroupID, toIndex: destination)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        controller.draggingPayload = nil
        return true
    }
}

private struct VettyWorkspaceSidebar: View {
    @ObservedObject var controller: VettyWorkspaceWindowController
    @State private var editingGroupID: UUID?
    @State private var editingTabID: UUID?

    private let background = Color(red: 0.13, green: 0.13, blue: 0.13)
    private let secondaryText = Color(red: 0.58, green: 0.58, blue: 0.58)

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.workspace.groups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            VettyWorkspaceGroupRow(
                                group: group,
                                controller: controller,
                                isEditing: editingGroupID == group.id,
                                beginEdit: { editingGroupID = group.id },
                                endEdit: { editingGroupID = nil }
                            )

                            if controller.isGroupExpanded(group.id) {
                                ForEach(group.tabs) { tab in
                                    VettyWorkspaceTabRow(
                                        tab: tab,
                                        groupID: group.id,
                                        controller: controller,
                                        isEditing: editingTabID == tab.id,
                                        beginEdit: { editingTabID = tab.id },
                                        endEdit: { editingTabID = nil }
                                    )
                                }
                                .transition(
                                    .opacity.animation(.easeOut(duration: 0.1))
                                    .combined(with: .offset(CGSize(width: 0, height: -4)))
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 14)
            }
        }
        .background(background)
    }

    private var header: some View {
        HStack {
            Text("Workspaces")
                .font(.system(size: 13))
                .foregroundStyle(secondaryText)
            Spacer()
            Button {
                editingGroupID = controller.addPlaceholderGroup()
                editingTabID = nil
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondaryText)
            }
            .buttonStyle(.borderless)
            .help("New group")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.top, 9)
        .padding(.bottom, 12)
    }
}

private struct VettyWorkspaceGroupRow: View {
    let group: VettyWorkspaceGroup
    let controller: VettyWorkspaceWindowController
    let isEditing: Bool
    let beginEdit: () -> Void
    let endEdit: () -> Void

    @State private var draftName: String = ""
    @FocusState private var isFieldFocused: Bool

    private let secondaryText = Color(red: 0.58, green: 0.58, blue: 0.58)
    private let approxRowHeight: CGFloat = 30

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(secondaryText)

                if isEditing {
                    TextField("", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(secondaryText)
                        .focused($isFieldFocused)
                        .onSubmit(commitEdit)
                        .onExitCommand(perform: endEdit)
                        .onAppear {
                            draftName = group.name
                            DispatchQueue.main.async {
                                isFieldFocused = true
                                DispatchQueue.main.async {
                                    (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
                                }
                            }
                        }
                        .onChange(of: isFieldFocused) { focused in
                            if !focused { commitEdit() }
                        }
                } else {
                    Text(group.name)
                        .font(.system(size: 14))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isEditing else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    controller.toggleGroup(group.id)
                }
            }

            if isEditing {
                Button(action: commitEdit) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondaryText)
                        .frame(width: 20, height: 24)
                }
                .buttonStyle(.plain)
                .help("Confirm name")
            } else {
                Button {
                    controller.addTab(toGroup: group.id)
                } label: {
                    Image(systemName: "apple.terminal")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondaryText)
                        .frame(width: 20, height: 24)
                }
                .buttonStyle(.plain)
                .help("New tab in \(group.name)")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .padding(.top, 2)
        .contextMenu {
            Button("Rename workspace") { beginEdit() }
            Button("Delete workspace") { controller.closeGroup(group.id) }
        }
        .onDrag {
            controller.draggingPayload = .group(group.id)
            return NSItemProvider(object: VettyDragPayload.group(group.id).encoded as NSString)
        }
        .onDrop(of: [.text], delegate: GroupDropDelegate(
            targetGroupID: group.id,
            controller: controller,
            approxRowHeight: approxRowHeight
        ))
    }

    private func commitEdit() {
        guard isEditing else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != group.name {
            controller.renameGroup(group.id, to: trimmed)
        }
        endEdit()
    }
}

private struct VettyWorkspaceTabRow: View {
    let tab: VettyWorkspaceTab
    let groupID: UUID
    let controller: VettyWorkspaceWindowController
    let isEditing: Bool
    let beginEdit: () -> Void
    let endEdit: () -> Void

    @State private var isRowHovered = false
    @State private var isCloseHovered = false
    @State private var draftName: String = ""
    @FocusState private var isFieldFocused: Bool

    private let selectedBackground = Color(red: 0.24, green: 0.24, blue: 0.24)
    private let primaryText = Color(red: 0.86, green: 0.86, blue: 0.86)
    private let secondaryText = Color(red: 0.58, green: 0.58, blue: 0.58)
    private let approxRowHeight: CGFloat = 31

    private var showClose: Bool { isRowHovered || isCloseHovered }

    var body: some View {
        let isSelected = tab.id == controller.workspace.selectedTabID
        let displayTitle = controller.displayTitle(for: tab)

        HStack(spacing: 2) {
            HStack(spacing: 8) {
                if isEditing {
                    TextField("", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? Color.white : primaryText)
                        .focused($isFieldFocused)
                        .onSubmit(commitEdit)
                        .onExitCommand(perform: endEdit)
                        .onAppear {
                            draftName = tab.titleOverride ?? displayTitle
                            DispatchQueue.main.async {
                                isFieldFocused = true
                                DispatchQueue.main.async {
                                    (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
                                }
                            }
                        }
                        .onChange(of: isFieldFocused) { focused in
                            if !focused { commitEdit() }
                        }
                } else {
                    Text(displayTitle)
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? Color.white : primaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isEditing else { return }
                controller.selectTab(tab.id)
            }

            if isEditing {
                Button(action: commitEdit) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(secondaryText)
                        .frame(width: 18, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Confirm name")
            } else {
                Button {
                    controller.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(secondaryText)
                        .frame(width: 18, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close \(tab.name)")
                .opacity(showClose ? 1 : 0)
                .onHover { isCloseHovered = $0 }
            }
        }
        .padding(.leading, 31)
        .padding(.trailing, 6)
        .background(isSelected ? selectedBackground : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { isRowHovered = $0 }
        .contextMenu {
            Button("Rename Tab") { beginEdit() }
            Button("Close Tab") { controller.closeTab(tab.id) }
        }
        .onDrag {
            controller.draggingPayload = .tab(groupID: groupID, tabID: tab.id)
            return NSItemProvider(object: VettyDragPayload.tab(groupID: groupID, tabID: tab.id).encoded as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(
            targetTabID: tab.id,
            groupID: groupID,
            controller: controller,
            approxRowHeight: approxRowHeight
        ))
    }

    private func commitEdit() {
        guard isEditing else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != (tab.titleOverride ?? "") {
            controller.renameTab(tab.id, to: trimmed)
        }
        endEdit()
    }
}

private extension VettySplitDirection {
    var splitTreeDirection: SplitTree<Ghostty.SurfaceView>.Direction {
        switch self {
        case .horizontal: .horizontal
        case .vertical: .vertical
        }
    }
}

private extension SplitTree.Direction {
    var vettyDirection: VettySplitDirection {
        switch self {
        case .horizontal: .horizontal
        case .vertical: .vertical
        }
    }
}

private extension SplitTree where ViewType == Ghostty.SurfaceView {
    var firstSurface: Ghostty.SurfaceView? {
        root?.leftmostLeaf()
    }

    var workspacePaneTree: VettyPaneTree? {
        root?.workspacePaneTree
    }
}

private extension SplitTree.Node where ViewType == Ghostty.SurfaceView {
    var workspacePaneTree: VettyPaneTree {
        switch self {
        case .leaf(let view):
            return .terminal(VettyTerminalPane(
                id: view.id,
                workingDirectory: view.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            ))

        case .split(let split):
            return .split(VettySplitPane(
                direction: split.direction.vettyDirection,
                first: split.left.workspacePaneTree,
                second: split.right.workspacePaneTree,
                ratio: split.ratio
            ))
        }
    }
}

private extension VettyPaneTree {
    var firstWorkingDirectory: String? {
        switch self {
        case .terminal(let pane):
            pane.workingDirectory
        case .split(let split):
            split.first.firstWorkingDirectory ?? split.second.firstWorkingDirectory
        }
    }
}
