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
}
