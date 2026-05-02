import Foundation
import Testing
@testable import Ghostty

struct VettyWorkspaceTests {
    @Test
    func defaultWorkspaceCreatesOneGeneralGroupWithOneTerminalTab() throws {
        let workspace = VettyWorkspace.default(workingDirectory: "/Users/dev/project")

        #expect(workspace.groups.count == 1)
        #expect(workspace.selectedGroupID == workspace.groups[0].id)
        #expect(workspace.selectedTabID == workspace.groups[0].tabs[0].id)
        #expect(workspace.groups[0].name == "General")
        #expect(workspace.groups[0].tabs[0].name == "Terminal")
        #expect(workspace.groups[0].tabs[0].workingDirectory == "/Users/dev/project")

        guard case .terminal(let pane) = workspace.groups[0].tabs[0].paneTree else {
            Issue.record("Expected the first tab to start with one terminal pane")
            return
        }

        #expect(pane.workingDirectory == "/Users/dev/project")
    }

    @Test
    func splitPaneCreatesFreshTerminalInSameWorkingDirectory() throws {
        var workspace = VettyWorkspace.default(workingDirectory: "/Users/dev/project")
        let tabID = try #require(workspace.selectedTabID)

        guard case .terminal(let originalPane) = workspace.groups[0].tabs[0].paneTree else {
            Issue.record("Expected a terminal pane before splitting")
            return
        }

        let newPaneID = try workspace.splitPane(
            tabID: tabID,
            paneID: originalPane.id,
            direction: .horizontal
        )

        guard case .split(let split) = workspace.groups[0].tabs[0].paneTree else {
            Issue.record("Expected the tab pane tree to become a split")
            return
        }

        #expect(split.direction == .horizontal)
        #expect(split.ratio == 0.5)

        guard case .terminal(let keptPane) = split.first else {
            Issue.record("Expected the existing pane to remain on the first side")
            return
        }

        guard case .terminal(let newPane) = split.second else {
            Issue.record("Expected a new terminal pane on the second side")
            return
        }

        #expect(keptPane.id == originalPane.id)
        #expect(newPane.id == newPaneID)
        #expect(newPane.workingDirectory == originalPane.workingDirectory)
    }

    @Test
    func storePersistsWorkspaceStructureAsJSON() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("workspace.json")
        let store = VettyWorkspaceStore(fileURL: fileURL)

        var workspace = VettyWorkspace.default(workingDirectory: "/Users/dev/project")
        let groupID = workspace.addGroup(named: "Work")
        let tabID = try workspace.addTab(
            named: "API",
            workingDirectory: "/Users/dev/api",
            toGroup: groupID
        )

        guard case .terminal(let pane) = workspace.tab(id: tabID)?.paneTree else {
            Issue.record("Expected a terminal pane in the added tab")
            return
        }
        _ = try workspace.splitPane(tabID: tabID, paneID: pane.id, direction: .vertical)

        try await store.save(workspace)
        let loaded = try await store.load()

        #expect(loaded == workspace)
    }

    @Test
    func storePersistsLastComputedTerminalTitle() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("workspace.json")
        let store = VettyWorkspaceStore(fileURL: fileURL)

        var workspace = VettyWorkspace.default(workingDirectory: "/Users/dev/project")
        let tabID = try #require(workspace.selectedTabID)

        try workspace.setLastComputedTitle(tabID, to: "npm test")

        try await store.save(workspace)
        let loaded = try await store.load()

        #expect(loaded.tab(id: tabID)?.lastComputedTitle == "npm test")
    }

    @Test
    func decodingWorkspaceWithoutLastComputedTitleKeepsItNil() throws {
        let groupID = UUID()
        let tabID = UUID()
        let paneID = UUID()
        let json = """
        {
          "groups": [
            {
              "id": "\(groupID.uuidString)",
              "name": "General",
              "tabs": [
                {
                  "id": "\(tabID.uuidString)",
                  "name": "Terminal",
                  "workingDirectory": "/Users/dev/project",
                  "paneTree": {
                    "kind": "terminal",
                    "terminal": {
                      "id": "\(paneID.uuidString)",
                      "workingDirectory": "/Users/dev/project"
                    }
                  }
                }
              ]
            }
          ],
          "selectedGroupID": "\(groupID.uuidString)",
          "selectedTabID": "\(tabID.uuidString)"
        }
        """

        let workspace = try JSONDecoder().decode(VettyWorkspace.self, from: Data(json.utf8))

        #expect(workspace.tab(id: tabID)?.lastComputedTitle == nil)
    }

    @Test
    func tabDisplayTitleUsesManualLivePersistedThenDefaultOrder() {
        let tabID = UUID()
        let pane = VettyTerminalPane(workingDirectory: "/Users/dev/project")
        let baseTab = VettyWorkspaceTab(
            id: tabID,
            name: "Terminal",
            lastComputedTitle: "Persisted title",
            workingDirectory: "/Users/dev/project",
            paneTree: .terminal(pane)
        )

        var manuallyNamedTab = baseTab
        manuallyNamedTab.titleOverride = "Manual title"

        #expect(manuallyNamedTab.displayTitle(liveTitle: "Live title") == "Manual title")
        #expect(baseTab.displayTitle(liveTitle: "Live title") == "Live title")
        #expect(baseTab.displayTitle(liveTitle: "   ") == "Persisted title")
        #expect(baseTab.displayTitle(liveTitle: nil) == "Persisted title")

        let defaultTab = VettyWorkspaceTab(
            name: "Terminal",
            workingDirectory: "/Users/dev/project",
            paneTree: .terminal(pane)
        )

        #expect(defaultTab.displayTitle(liveTitle: nil) == "Terminal")
    }

    @Test
    func blankComputedTitlesDoNotOverwritePreviousUsefulTitle() throws {
        var workspace = VettyWorkspace.default(workingDirectory: "/Users/dev/project")
        let tabID = try #require(workspace.selectedTabID)

        try workspace.setLastComputedTitle(tabID, to: "  swift build  ")
        try workspace.setLastComputedTitle(tabID, to: "   ")

        #expect(workspace.tab(id: tabID)?.lastComputedTitle == "swift build")
    }

    @Test
    func addingPlaceholderGroupCreatesSelectedTerminalTab() throws {
        var workspace = VettyWorkspace.default(workingDirectory: "/Users/dev/project")

        let groupID = workspace.addPlaceholderGroup(workingDirectory: "/Users/dev/new")

        #expect(workspace.groups.map(\.name) == ["General", "Group 2"])
        #expect(workspace.groups[1].id == groupID)
        #expect(workspace.groups[1].tabs.count == 1)
        #expect(workspace.groups[1].tabs[0].name == "Terminal")
        #expect(workspace.groups[1].tabs[0].workingDirectory == "/Users/dev/new")
        #expect(workspace.selectedGroupID == groupID)
        #expect(workspace.selectedTabID == workspace.groups[1].tabs[0].id)

        guard case .terminal(let pane) = workspace.groups[1].tabs[0].paneTree else {
            Issue.record("Expected the placeholder group to start with one terminal pane")
            return
        }

        #expect(pane.workingDirectory == workspace.groups[1].tabs[0].workingDirectory)
    }

    @Test
    func removingSelectedTabSelectsNeighborAndRemovesEntry() throws {
        var workspace = VettyWorkspace.default(workingDirectory: "/Users/dev/first")
        let groupID = try #require(workspace.selectedGroupID)
        let firstTabID = try #require(workspace.selectedTabID)
        let secondTabID = try workspace.addTab(
            named: "Second",
            workingDirectory: "/Users/dev/second",
            toGroup: groupID
        )

        try workspace.removeTab(firstTabID)

        #expect(workspace.groups[0].tabs.map(\.id) == [secondTabID])
        #expect(workspace.selectedGroupID == groupID)
        #expect(workspace.selectedTabID == secondTabID)
    }

    @Test
    func removingLastTabLeavesGroupSelectedWithoutSelectedTab() throws {
        var workspace = VettyWorkspace.default(workingDirectory: "/Users/dev/project")
        let groupID = try #require(workspace.selectedGroupID)
        let tabID = try #require(workspace.selectedTabID)

        try workspace.removeTab(tabID)

        #expect(workspace.groups[0].tabs.isEmpty)
        #expect(workspace.selectedGroupID == groupID)
        #expect(workspace.selectedTabID == nil)
    }

    @Test
    func renamingTabsAndGroupsUpdatesWorkspaceNames() throws {
        var workspace = VettyWorkspace.default(workingDirectory: "/Users/dev/project")
        let groupID = try #require(workspace.selectedGroupID)
        let tabID = try #require(workspace.selectedTabID)

        try workspace.renameGroup(groupID, to: "Work")
        try workspace.renameTab(tabID, to: "Build")

        #expect(workspace.groups[0].name == "Work")
        #expect(workspace.groups[0].tabs[0].name == "Build")
    }

    @Test
    func removingSelectedGroupSelectsRemainingGroup() throws {
        var workspace = VettyWorkspace.default(workingDirectory: "/Users/dev/general")
        let generalGroupID = try #require(workspace.selectedGroupID)
        let workGroupID = workspace.addGroup(named: "Work")
        let workTabID = try workspace.addTab(
            named: "API",
            workingDirectory: "/Users/dev/api",
            toGroup: workGroupID
        )

        try workspace.removeGroup(workGroupID)

        #expect(workspace.groups.map(\.id) == [generalGroupID])
        #expect(workspace.selectedGroupID == generalGroupID)
        #expect(workspace.selectedTabID == workspace.groups[0].tabs[0].id)
        #expect(workspace.selectedTabID != workTabID)
    }
}
