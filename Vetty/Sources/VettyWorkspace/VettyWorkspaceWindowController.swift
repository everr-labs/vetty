import AppKit
import SwiftUI
import GhosttyKit

final class VettyWorkspaceWindowController: BaseTerminalController {
    @Published private(set) var workspace: VettyWorkspace

    private let store: VettyWorkspaceStore
    private var runtimeTrees: [UUID: SplitTree<Ghostty.SurfaceView>] = [:]
    private var selectedRuntimeTabID: UUID?

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

    override func windowWillClose(_ notification: Notification) {
        persistSelectedRuntimeTree()
        saveWorkspace()
        super.windowWillClose(notification)
    }

    var selectedGroup: VettyWorkspaceGroup? {
        guard let selectedGroupID = workspace.selectedGroupID else { return workspace.groups.first }
        return workspace.groups.first { $0.id == selectedGroupID } ?? workspace.groups.first
    }

    var selectedTabs: [VettyWorkspaceTab] {
        selectedGroup?.tabs ?? []
    }

    func selectGroup(_ groupID: UUID) {
        persistSelectedRuntimeTree()
        workspace.selectedGroupID = groupID
        workspace.selectedTabID = workspace.groups
            .first { $0.id == groupID }?
            .tabs
            .first?
            .id

        if let tabID = workspace.selectedTabID {
            selectTab(tabID)
        } else {
            surfaceTree = .init()
            selectedRuntimeTabID = nil
            saveWorkspace()
        }
    }

    func selectTab(_ tabID: UUID) {
        persistSelectedRuntimeTree()
        guard let tab = workspace.tab(id: tabID) else { return }

        workspace.selectedTabID = tabID
        if let group = workspace.groups.first(where: { $0.tabs.contains(where: { $0.id == tabID }) }) {
            workspace.selectedGroupID = group.id
        }

        selectedRuntimeTabID = tabID
        let tree = runtimeTrees[tabID] ?? makeRuntimeTree(from: tab.paneTree)
        runtimeTrees[tabID] = tree
        surfaceTree = tree
        window?.title = tab.name

        if let firstSurface = tree.firstSurface {
            focusSurface(firstSurface)
        }
        saveWorkspace()
    }

    func promptAddGroup() {
        let alert = NSAlert()
        alert.messageText = "New Group"
        alert.informativeText = "Choose a label for this group."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "Group \(workspace.groups.count + 1)"
        alert.accessoryView = field

        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let groupID = workspace.addGroup(named: name.isEmpty ? "Group" : name)
            saveWorkspace()
            selectGroup(groupID)
        }
    }

    func addTabToSelectedGroup(withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil) {
        guard let groupID = workspace.selectedGroupID ?? workspace.groups.first?.id else { return }
        let workingDirectory = baseConfig?.workingDirectory
            ?? focusedSurface?.pwd
            ?? workspace.tab(id: workspace.selectedTabID ?? UUID())?.workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        do {
            let tabID = try workspace.addTab(
                named: "Terminal",
                workingDirectory: workingDirectory,
                toGroup: groupID
            )
            if let tab = workspace.tab(id: tabID),
               case .terminal(let pane) = tab.paneTree {
                runtimeTrees[tabID] = makeSingleRuntimeTree(
                    paneID: pane.id,
                    workingDirectory: workingDirectory,
                    baseConfig: baseConfig
                )
            }
            saveWorkspace()
            selectTab(tabID)
        } catch {
            presentError(error)
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

    private func saveWorkspace() {
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

private struct VettyWorkspaceSidebar: View {
    @ObservedObject var controller: VettyWorkspaceWindowController

    var body: some View {
        VStack(spacing: 0) {
            header
            groupList
            Divider()
            tabList
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Vetty")
                .font(.headline)
            Spacer()
            Button {
                controller.promptAddGroup()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New group")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var groupList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(controller.workspace.groups) { group in
                Button {
                    controller.selectGroup(group.id)
                } label: {
                    HStack {
                        Text(group.name)
                            .lineLimit(1)
                        Spacer()
                        Text("\(group.tabs.count)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(group.id == controller.workspace.selectedGroupID ? Color.accentColor.opacity(0.18) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var tabList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(controller.selectedGroup?.name ?? "Tabs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    controller.addTabToSelectedGroup()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New tab")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(controller.selectedTabs) { tab in
                        Button {
                            controller.selectTab(tab.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.name)
                                    .lineLimit(1)
                                Text((tab.workingDirectory as NSString).lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(tab.id == controller.workspace.selectedTabID ? Color.accentColor.opacity(0.18) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
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
