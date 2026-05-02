import Foundation

enum VettyWorkspaceError: Error, Equatable {
    case groupNotFound(UUID)
    case tabNotFound(UUID)
    case paneNotFound(UUID)
}

struct VettyWorkspace: Codable, Equatable, Sendable {
    var groups: [VettyWorkspaceGroup]
    var selectedGroupID: UUID?
    var selectedTabID: UUID?

    static func `default`(workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> VettyWorkspace {
        let pane = VettyTerminalPane(workingDirectory: workingDirectory)
        let tab = VettyWorkspaceTab(
            name: "Terminal",
            workingDirectory: workingDirectory,
            paneTree: .terminal(pane)
        )
        let group = VettyWorkspaceGroup(name: "General", tabs: [tab])

        return VettyWorkspace(
            groups: [group],
            selectedGroupID: group.id,
            selectedTabID: tab.id
        )
    }

    @discardableResult
    mutating func addGroup(named name: String) -> UUID {
        let group = VettyWorkspaceGroup(name: name, tabs: [])
        groups.append(group)
        selectedGroupID = group.id
        selectedTabID = nil
        return group.id
    }

    @discardableResult
    mutating func addPlaceholderGroup(
        workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> UUID {
        let pane = VettyTerminalPane(workingDirectory: workingDirectory)
        let tab = VettyWorkspaceTab(
            name: "Terminal",
            workingDirectory: workingDirectory,
            paneTree: .terminal(pane)
        )
        let group = VettyWorkspaceGroup(name: "Group \(groups.count + 1)", tabs: [tab])

        groups.append(group)
        selectedGroupID = group.id
        selectedTabID = tab.id
        return group.id
    }

    @discardableResult
    mutating func addTab(
        named name: String,
        workingDirectory: String,
        toGroup groupID: UUID
    ) throws -> UUID {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else {
            throw VettyWorkspaceError.groupNotFound(groupID)
        }

        let pane = VettyTerminalPane(workingDirectory: workingDirectory)
        let tab = VettyWorkspaceTab(
            name: name,
            workingDirectory: workingDirectory,
            paneTree: .terminal(pane)
        )

        groups[groupIndex].tabs.append(tab)
        selectedGroupID = groupID
        selectedTabID = tab.id
        return tab.id
    }

    func tab(id tabID: UUID) -> VettyWorkspaceTab? {
        for group in groups {
            if let tab = group.tabs.first(where: { $0.id == tabID }) {
                return tab
            }
        }
        return nil
    }

    mutating func renameGroup(_ groupID: UUID, to name: String) throws {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else {
            throw VettyWorkspaceError.groupNotFound(groupID)
        }

        groups[groupIndex].name = name
    }

    mutating func renameTab(_ tabID: UUID, to name: String) throws {
        guard let location = tabLocation(for: tabID) else {
            throw VettyWorkspaceError.tabNotFound(tabID)
        }

        groups[location.groupIndex].tabs[location.tabIndex].name = name
    }

    mutating func setTabTitleOverride(_ tabID: UUID, to override: String?) throws {
        guard let location = tabLocation(for: tabID) else {
            throw VettyWorkspaceError.tabNotFound(tabID)
        }

        let normalized = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        groups[location.groupIndex].tabs[location.tabIndex].titleOverride =
            (normalized?.isEmpty == false) ? normalized : nil
    }

    @discardableResult
    mutating func setLastComputedTitle(_ tabID: UUID, to title: String) throws -> Bool {
        guard let location = tabLocation(for: tabID) else {
            throw VettyWorkspaceError.tabNotFound(tabID)
        }

        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let current = groups[location.groupIndex].tabs[location.tabIndex].lastComputedTitle
        guard current != normalized else { return false }

        groups[location.groupIndex].tabs[location.tabIndex].lastComputedTitle = normalized
        return true
    }

    mutating func removeGroup(_ groupID: UUID) throws {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else {
            throw VettyWorkspaceError.groupNotFound(groupID)
        }

        let removedGroup = groups.remove(at: groupIndex)
        let removedSelectedTab = selectedTabID.map { selectedTabID in
            removedGroup.tabs.contains { $0.id == selectedTabID }
        } ?? false

        if selectedGroupID == groupID || removedSelectedTab || selectedGroupID == nil {
            selectGroupAfterRemoval(preferredIndex: groupIndex)
        }
    }

    mutating func removeTab(_ tabID: UUID) throws {
        guard let location = tabLocation(for: tabID) else {
            throw VettyWorkspaceError.tabNotFound(tabID)
        }

        groups[location.groupIndex].tabs.remove(at: location.tabIndex)

        if selectedTabID == tabID {
            selectTabAfterRemoval(
                groupIndex: location.groupIndex,
                preferredTabIndex: location.tabIndex
            )
        }
    }

    @discardableResult
    mutating func splitPane(
        tabID: UUID,
        paneID: UUID,
        direction: VettySplitDirection
    ) throws -> UUID {
        for groupIndex in groups.indices {
            guard let tabIndex = groups[groupIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
                continue
            }

            let newPaneID = UUID()
            let splitID = UUID()
            let changed = groups[groupIndex].tabs[tabIndex].paneTree.splitPane(
                paneID: paneID,
                newPaneID: newPaneID,
                splitID: splitID,
                direction: direction
            )

            guard changed else {
                throw VettyWorkspaceError.paneNotFound(paneID)
            }

            selectedGroupID = groups[groupIndex].id
            selectedTabID = tabID
            return newPaneID
        }

        throw VettyWorkspaceError.tabNotFound(tabID)
    }

    private func tabLocation(for tabID: UUID) -> (groupIndex: Int, tabIndex: Int)? {
        for groupIndex in groups.indices {
            if let tabIndex = groups[groupIndex].tabs.firstIndex(where: { $0.id == tabID }) {
                return (groupIndex, tabIndex)
            }
        }

        return nil
    }

    private mutating func selectGroupAfterRemoval(preferredIndex: Int) {
        guard !groups.isEmpty else {
            selectedGroupID = nil
            selectedTabID = nil
            return
        }

        let groupIndex = min(preferredIndex, groups.count - 1)
        selectedGroupID = groups[groupIndex].id
        selectedTabID = groups[groupIndex].tabs.first?.id
    }

    private mutating func selectTabAfterRemoval(groupIndex: Int, preferredTabIndex: Int) {
        guard groups.indices.contains(groupIndex) else {
            selectedGroupID = groups.first?.id
            selectedTabID = groups.first?.tabs.first?.id
            return
        }

        selectedGroupID = groups[groupIndex].id

        guard !groups[groupIndex].tabs.isEmpty else {
            selectedTabID = nil
            return
        }

        let tabIndex = min(preferredTabIndex, groups[groupIndex].tabs.count - 1)
        selectedTabID = groups[groupIndex].tabs[tabIndex].id
    }
}

struct VettyWorkspaceGroup: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var isExpanded: Bool
    var tabs: [VettyWorkspaceTab]

    init(id: UUID = UUID(), name: String, isExpanded: Bool = true, tabs: [VettyWorkspaceTab]) {
        self.id = id
        self.name = name
        self.isExpanded = isExpanded
        self.tabs = tabs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isExpanded, tabs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.isExpanded = try c.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        self.tabs = try c.decode([VettyWorkspaceTab].self, forKey: .tabs)
    }
}

struct VettyWorkspaceTab: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var titleOverride: String?
    var lastComputedTitle: String?
    var workingDirectory: String
    var paneTree: VettyPaneTree

    init(
        id: UUID = UUID(),
        name: String,
        titleOverride: String? = nil,
        lastComputedTitle: String? = nil,
        workingDirectory: String,
        paneTree: VettyPaneTree
    ) {
        self.id = id
        self.name = name
        self.titleOverride = titleOverride
        self.lastComputedTitle = lastComputedTitle
        self.workingDirectory = workingDirectory
        self.paneTree = paneTree
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, titleOverride, lastComputedTitle, workingDirectory, paneTree
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.titleOverride = try c.decodeIfPresent(String.self, forKey: .titleOverride)
        self.lastComputedTitle = try c.decodeIfPresent(String.self, forKey: .lastComputedTitle)
        self.workingDirectory = try c.decode(String.self, forKey: .workingDirectory)
        self.paneTree = try c.decode(VettyPaneTree.self, forKey: .paneTree)
    }

    func displayTitle(liveTitle: String?) -> String {
        if let override = titleOverride, !override.isEmpty { return override }

        let live = liveTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let live, !live.isEmpty { return live }

        let persisted = lastComputedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let persisted, !persisted.isEmpty { return persisted }

        return name
    }
}

struct VettyTerminalPane: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var workingDirectory: String

    init(id: UUID = UUID(), workingDirectory: String) {
        self.id = id
        self.workingDirectory = workingDirectory
    }
}

struct VettySplitPane: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var direction: VettySplitDirection
    var first: VettyPaneTree
    var second: VettyPaneTree
    var ratio: Double

    init(
        id: UUID = UUID(),
        direction: VettySplitDirection,
        first: VettyPaneTree,
        second: VettyPaneTree,
        ratio: Double = 0.5
    ) {
        self.id = id
        self.direction = direction
        self.first = first
        self.second = second
        self.ratio = ratio
    }
}

enum VettySplitDirection: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

indirect enum VettyPaneTree: Codable, Equatable, Sendable {
    case terminal(VettyTerminalPane)
    case split(VettySplitPane)

    private enum Kind: String, Codable {
        case terminal
        case split
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case terminal
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .terminal:
            self = .terminal(try container.decode(VettyTerminalPane.self, forKey: .terminal))
        case .split:
            self = .split(try container.decode(VettySplitPane.self, forKey: .split))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal(let pane):
            try container.encode(Kind.terminal, forKey: .kind)
            try container.encode(pane, forKey: .terminal)
        case .split(let split):
            try container.encode(Kind.split, forKey: .kind)
            try container.encode(split, forKey: .split)
        }
    }

    mutating func splitPane(
        paneID: UUID,
        newPaneID: UUID,
        splitID: UUID,
        direction: VettySplitDirection
    ) -> Bool {
        switch self {
        case .terminal(let pane) where pane.id == paneID:
            self = .split(VettySplitPane(
                id: splitID,
                direction: direction,
                first: .terminal(pane),
                second: .terminal(VettyTerminalPane(
                    id: newPaneID,
                    workingDirectory: pane.workingDirectory
                ))
            ))
            return true

        case .terminal:
            return false

        case .split(var split):
            if split.first.splitPane(
                paneID: paneID,
                newPaneID: newPaneID,
                splitID: splitID,
                direction: direction
            ) {
                self = .split(split)
                return true
            }

            if split.second.splitPane(
                paneID: paneID,
                newPaneID: newPaneID,
                splitID: splitID,
                direction: direction
            ) {
                self = .split(split)
                return true
            }

            return false
        }
    }
}

struct VettyWorkspaceStore: Sendable {
    let fileURL: URL

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vetty", isDirectory: true)
            .appendingPathComponent("workspace.json")
    }

    init(fileURL: URL = VettyWorkspaceStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() async throws -> VettyWorkspace {
        try loadSync()
    }

    func loadSync() throws -> VettyWorkspace {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .default()
        }

        let data = try Data(contentsOf: fileURL)
        return try Self.decoder.decode(VettyWorkspace.self, from: data)
    }

    func save(_ workspace: VettyWorkspace) async throws {
        try saveSync(workspace)
    }

    func saveSync(_ workspace: VettyWorkspace) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(workspace)
        try data.write(to: fileURL, options: [.atomic])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
