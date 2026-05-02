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
}

struct VettyWorkspaceGroup: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var tabs: [VettyWorkspaceTab]

    init(id: UUID = UUID(), name: String, tabs: [VettyWorkspaceTab]) {
        self.id = id
        self.name = name
        self.tabs = tabs
    }
}

struct VettyWorkspaceTab: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var workingDirectory: String
    var paneTree: VettyPaneTree

    init(
        id: UUID = UUID(),
        name: String,
        workingDirectory: String,
        paneTree: VettyPaneTree
    ) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
        self.paneTree = paneTree
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
