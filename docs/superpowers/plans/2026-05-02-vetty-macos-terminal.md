# Vetty macOS Terminal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Vetty, a native macOS terminal app derived from Ghostty's macOS terminal stack, with a Codex-like sidebar for manual groups and grouped terminal tabs.

**Architecture:** Vetty owns workspace organization: windows, groups, tabs, pane trees, selection, commands, and persistence. Ghostty-derived code owns terminal behavior: shell/PTY lifecycle, rendering, input, search, settings, command palette, and macOS integrations. The ignored local `ghostty/` clone is reference-only; build-time Ghostty code lives in Vetty-owned paths.

**Tech Stack:** Swift, SwiftUI, AppKit, XCTest, Xcode project, Ghostty-derived Swift/macOS code, Ghostty core built as `GhosttyKit.xcframework` through Zig.

---

## Scope Check

This is a large v1. Keep the work in phases that each build or test something real:

1. Import and rename the Ghostty macOS baseline into Vetty-owned source paths.
2. Add pure Vetty workspace model and persistence with tests.
3. Wrap the Ghostty-derived terminal stack behind Vetty tabs and pane IDs.
4. Add the sidebar UI and adapt commands.
5. Re-enable/adapt settings, search, multiple windows, command palette, AppleScript, and AppIntents.
6. Run build, unit tests, and manual app checks.

## File Structure

Create this project shape:

```text
Vetty.xcodeproj/
Vetty/
  Sources/
    App/
    VettyWorkspace/
    VettyUI/
    VettyCommands/
    GhosttyDerived/
      Ghostty/
      Features/
      Helpers/
  Tests/
    VettyWorkspaceTests/
    VettyCommandTests/
  Resources/
    Assets.xcassets/
    Vetty-Info.plist
    Vetty.entitlements
    VettyDebug.entitlements
    VettyReleaseLocal.entitlements
    Vetty.sdef
  Frameworks/
    .gitkeep
  VendorNotices/
    Ghostty-MIT.txt
Vendor/
  GhosttySource/
scripts/
  check-no-reference-ghostty.sh
  import-ghostty-snapshot.sh
  build-ghostty-kit.sh
  build-vetty.sh
docs/
  superpowers/
    specs/
    plans/
```

`ghostty/` remains ignored. `Vendor/GhosttySource/` is the committed/vendor-owned source snapshot that builds `GhosttyKit.xcframework`.

Generated build artifacts stay ignored:

```text
Vetty/Frameworks/GhosttyKit.xcframework
Vendor/GhosttySource/zig-out/
Vendor/GhosttySource/.zig-cache/
Vetty/build/
```

---

### Task 1: Repository Safety Checks

**Files:**
- Modify: `.gitignore`
- Create: `scripts/check-no-reference-ghostty.sh`

- [ ] **Step 1: Add the failing reference check script**

Create `scripts/check-no-reference-ghostty.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if git -C "$root" ls-files | grep -E '(^|/)ghostty/' >/dev/null; then
  echo "Tracked files under ghostty/ are not allowed. The local ghostty/ clone is reference-only." >&2
  exit 1
fi

paths=()
[[ -d "$root/Vetty" ]] && paths+=("$root/Vetty")
[[ -d "$root/Vetty.xcodeproj" ]] && paths+=("$root/Vetty.xcodeproj")
[[ -d "$root/Vendor" ]] && paths+=("$root/Vendor")
[[ -f "$root/Package.swift" ]] && paths+=("$root/Package.swift")

if (( ${#paths[@]} > 0 )); then
  if rg -n --hidden --glob '!*.md' '/workspace/vetty/ghostty|\\.\\./ghostty|ghostty/macos|ghostty/src' "${paths[@]}" >/tmp/vetty-ghostty-reference-check.txt; then
    cat /tmp/vetty-ghostty-reference-check.txt >&2
    echo "Build-time references to the local ghostty/ reference clone are not allowed." >&2
    exit 1
  fi
fi

echo "No build-time references to local ghostty/ clone found."
```

- [ ] **Step 2: Run the check and verify it fails before ignore/build paths are fixed if references exist**

Run:

```bash
chmod +x scripts/check-no-reference-ghostty.sh
scripts/check-no-reference-ghostty.sh
```

Expected now: PASS with `No build-time references to local ghostty/ clone found.`

- [ ] **Step 3: Expand `.gitignore` for generated artifacts**

Update `.gitignore`:

```gitignore
ghostty/

# macOS and Xcode local files
.DS_Store
DerivedData/
*.xcuserstate
xcuserdata/

# Build outputs
.build/
build/
Vetty/build/
Vetty/Frameworks/GhosttyKit.xcframework/
Vendor/GhosttySource/zig-out/
Vendor/GhosttySource/.zig-cache/
Vendor/GhosttySource/macos/build/
```

- [ ] **Step 4: Run safety check**

Run:

```bash
scripts/check-no-reference-ghostty.sh
git status --short --ignored
```

Expected:

```text
No build-time references to local ghostty/ clone found.
?? scripts/
!! ghostty/
```

- [ ] **Step 5: Commit**

```bash
git add .gitignore scripts/check-no-reference-ghostty.sh
git commit -m "chore: add repository safety checks"
```

---

### Task 2: Import Ghostty Baseline Into Vetty-Owned Paths

**Files:**
- Create: `scripts/import-ghostty-snapshot.sh`
- Create: `scripts/build-ghostty-kit.sh`
- Create: `scripts/build-vetty.sh`
- Create: `Vetty/Frameworks/.gitkeep`
- Create: `Vetty/VendorNotices/Ghostty-MIT.txt`
- Create/modify many copied files under `Vetty/`, `Vendor/GhosttySource/`, and `Vetty.xcodeproj/`

- [ ] **Step 1: Write the import script**

Create `scripts/import-ghostty-snapshot.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ref="$root/ghostty"

if [[ ! -d "$ref/.git" || ! -d "$ref/macos/Sources" || ! -f "$ref/LICENSE" ]]; then
  echo "Expected a local reference clone at $ref with macos/Sources and LICENSE." >&2
  exit 1
fi

mkdir -p \
  "$root/Vetty/Sources/GhosttyDerived" \
  "$root/Vetty/Sources/App" \
  "$root/Vetty/Resources" \
  "$root/Vetty/Frameworks" \
  "$root/Vetty/Tests" \
  "$root/Vetty/VendorNotices" \
  "$root/Vendor"

rsync -a --delete "$ref/macos/Sources/Ghostty/" "$root/Vetty/Sources/GhosttyDerived/Ghostty/"
rsync -a --delete "$ref/macos/Sources/Features/" "$root/Vetty/Sources/GhosttyDerived/Features/"
rsync -a --delete "$ref/macos/Sources/Helpers/" "$root/Vetty/Sources/GhosttyDerived/Helpers/"
rsync -a --delete "$ref/macos/Sources/App/macOS/" "$root/Vetty/Sources/App/"
rsync -a --delete "$ref/macos/Tests/" "$root/Vetty/Tests/GhosttyDerivedTests/"
rsync -a "$ref/macos/Assets.xcassets/" "$root/Vetty/Resources/Assets.xcassets/"
rsync -a "$ref/macos/Ghostty-Info.plist" "$root/Vetty/Resources/Vetty-Info.plist"
rsync -a "$ref/macos/Ghostty.entitlements" "$root/Vetty/Resources/Vetty.entitlements"
rsync -a "$ref/macos/GhosttyDebug.entitlements" "$root/Vetty/Resources/VettyDebug.entitlements"
rsync -a "$ref/macos/GhosttyReleaseLocal.entitlements" "$root/Vetty/Resources/VettyReleaseLocal.entitlements"
rsync -a "$ref/macos/Ghostty.sdef" "$root/Vetty/Resources/Vetty.sdef"
rsync -a "$ref/macos/Ghostty.xctestplan" "$root/Vetty/Vetty.xctestplan"
rsync -a "$ref/LICENSE" "$root/Vetty/VendorNotices/Ghostty-MIT.txt"
rsync -a --delete "$ref/macos/Ghostty.xcodeproj/" "$root/Vetty.xcodeproj/"

rsync -a --delete \
  --exclude '.git/' \
  --exclude 'zig-out/' \
  --exclude '.zig-cache/' \
  --exclude 'macos/build/' \
  "$ref/" "$root/Vendor/GhosttySource/"

touch "$root/Vetty/Frameworks/.gitkeep"

echo "Imported Ghostty reference snapshot into Vetty-owned paths."
```

- [ ] **Step 2: Write the GhosttyKit build script**

Create `scripts/build-ghostty-kit.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vendor="$root/Vendor/GhosttySource"
out="$root/Vetty/Frameworks"

if [[ ! -f "$vendor/build.zig" ]]; then
  echo "Missing $vendor/build.zig. Run scripts/import-ghostty-snapshot.sh first." >&2
  exit 1
fi

mkdir -p "$out"

(
  cd "$vendor"
  zig build -Demit-xcframework=true -Demit-macos-app=false
)

rm -rf "$out/GhosttyKit.xcframework"
cp -R "$vendor/macos/GhosttyKit.xcframework" "$out/GhosttyKit.xcframework"

echo "Built Vetty/Frameworks/GhosttyKit.xcframework."
```

- [ ] **Step 3: Write the app build script**

Create `scripts/build-vetty.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -d "$root/Vetty/Frameworks/GhosttyKit.xcframework" ]]; then
  "$root/scripts/build-ghostty-kit.sh"
fi

env -i \
  "HOME=$HOME" \
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" \
  xcodebuild \
    -project "$root/Vetty.xcodeproj" \
    -scheme Vetty \
    -configuration Debug \
    "SYMROOT=$root/Vetty/build" \
    build
```

- [ ] **Step 4: Run the import script**

Run:

```bash
chmod +x scripts/import-ghostty-snapshot.sh scripts/build-ghostty-kit.sh scripts/build-vetty.sh
scripts/import-ghostty-snapshot.sh
```

Expected:

```text
Imported Ghostty reference snapshot into Vetty-owned paths.
```

- [ ] **Step 5: Commit the imported source snapshot**

Run:

```bash
git add Vetty Vendor Vetty.xcodeproj scripts
git commit -m "chore: import Ghostty macOS baseline"
```

---

### Task 3: Rename Ghostty Baseline To Vetty

**Files:**
- Modify: `Vetty.xcodeproj/project.pbxproj`
- Modify: `Vetty/Resources/Vetty-Info.plist`
- Modify: `Vetty/Resources/Vetty.sdef`
- Modify: copied Swift files under `Vetty/Sources/`

- [ ] **Step 1: Write a failing build check**

Run:

```bash
scripts/build-vetty.sh
```

Expected: FAIL because the copied project still has Ghostty target names, paths, and bundle IDs.

- [ ] **Step 2: Rename project-level identifiers**

Apply these replacements in `Vetty.xcodeproj/project.pbxproj`:

```bash
perl -0pi -e 's/Ghostty\.xctestplan/Vetty\\/Vetty.xctestplan/g' Vetty.xcodeproj/project.pbxproj
perl -0pi -e 's/Ghostty-Info\.plist/Vetty\\/Resources\\/Vetty-Info.plist/g' Vetty.xcodeproj/project.pbxproj
perl -0pi -e 's/Ghostty\.entitlements/Vetty\\/Resources\\/Vetty.entitlements/g' Vetty.xcodeproj/project.pbxproj
perl -0pi -e 's/GhosttyDebug\.entitlements/Vetty\\/Resources\\/VettyDebug.entitlements/g' Vetty.xcodeproj/project.pbxproj
perl -0pi -e 's/GhosttyReleaseLocal\.entitlements/Vetty\\/Resources\\/VettyReleaseLocal.entitlements/g' Vetty.xcodeproj/project.pbxproj
perl -0pi -e 's/Ghostty\.sdef/Vetty\\/Resources\\/Vetty.sdef/g' Vetty.xcodeproj/project.pbxproj
perl -0pi -e 's/Assets\.xcassets/Vetty\\/Resources\\/Assets.xcassets/g' Vetty.xcodeproj/project.pbxproj
perl -0pi -e 's/path = Sources;/path = Vetty\\/Sources;/g' Vetty.xcodeproj/project.pbxproj
perl -0pi -e 's/path = Tests;/path = Vetty\\/Tests;/g' Vetty.xcodeproj/project.pbxproj
perl -0pi -e 's/path = GhosttyKit\.xcframework;/path = Vetty\\/Frameworks\\/GhosttyKit.xcframework;/g' Vetty.xcodeproj/project.pbxproj
perl -0pi -e 's/productName = Ghostty;/productName = Vetty;/g' Vetty.xcodeproj/project.pbxproj
perl -0pi -e 's/name = Ghostty;/name = Vetty;/g' Vetty.xcodeproj/project.pbxproj
perl -0pi -e 's/com\.mitchellh\.ghostty\.debug/com.guidodorsi.vetty.debug/g' Vetty.xcodeproj/project.pbxproj
perl -0pi -e 's/com\.mitchellh\.ghostty/com.guidodorsi.vetty/g' Vetty.xcodeproj/project.pbxproj
perl -0pi -e 's/INFOPLIST_KEY_CFBundleDisplayName = "Ghostty\\[DEBUG\\]";/INFOPLIST_KEY_CFBundleDisplayName = "Vetty[DEBUG]";/g' Vetty.xcodeproj/project.pbxproj
perl -0pi -e 's/INFOPLIST_KEY_CFBundleDisplayName = Ghostty;/INFOPLIST_KEY_CFBundleDisplayName = Vetty;/g' Vetty.xcodeproj/project.pbxproj
```

- [ ] **Step 3: Rename user-facing permission strings**

Run:

```bash
perl -0pi -e 's/within Ghostty/within Vetty/g; s/Ghostty would/Vetty would/g; s/Ghostty requires/Vetty requires/g' Vetty.xcodeproj/project.pbxproj Vetty/Resources/Vetty-Info.plist Vetty/Resources/Vetty.sdef
```

- [ ] **Step 4: Keep Swift type namespaces unchanged for the first build**

Do not rename the `Ghostty` Swift namespace yet. The first goal is a compiling baseline. User-facing app name and bundle IDs become Vetty; internal copied type names remain `Ghostty` for version 1.

- [ ] **Step 5: Build and commit**

Run:

```bash
scripts/check-no-reference-ghostty.sh
scripts/build-vetty.sh
```

Expected: PASS. If the command fails, change only path/name settings in `Vetty.xcodeproj/project.pbxproj`, then rerun this same command until it passes.

Commit after the target compiles:

```bash
git add Vetty.xcodeproj Vetty
git commit -m "chore: rename macOS baseline to Vetty"
```

---

### Task 4: Workspace Model Tests And Types

**Files:**
- Create: `Vetty/Sources/VettyWorkspace/WorkspaceModels.swift`
- Create: `Vetty/Tests/VettyWorkspaceTests/WorkspaceModelTests.swift`

- [ ] **Step 1: Write failing model tests**

Create `Vetty/Tests/VettyWorkspaceTests/WorkspaceModelTests.swift`:

```swift
import XCTest
@testable import Vetty

final class WorkspaceModelTests: XCTestCase {
    func testDefaultWorkspaceHasOneWindowGroupTabAndPane() throws {
        let workspace = VettyWorkspace.defaultWorkspace(homeDirectory: "/Users/dev")

        XCTAssertEqual(workspace.windows.count, 1)
        let window = try XCTUnwrap(workspace.windows.first)
        XCTAssertEqual(window.groups.count, 1)
        XCTAssertEqual(window.groups[0].name, "Work")
        XCTAssertEqual(window.groups[0].tabs.count, 1)
        XCTAssertEqual(window.groups[0].tabs[0].name, "Shell")
        XCTAssertEqual(window.groups[0].tabs[0].workingDirectory, "/Users/dev")

        guard case .terminal(let pane) = window.groups[0].tabs[0].paneTree else {
            return XCTFail("Expected a terminal pane")
        }
        XCTAssertEqual(pane.workingDirectory, "/Users/dev")
    }

    func testPaneTreeRoundTripsThroughJSON() throws {
        let left = PaneNode.terminal(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, workingDirectory: "/tmp"))
        let right = PaneNode.terminal(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, workingDirectory: "/Users/dev"))
        let tree = PaneNode.split(.init(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            direction: .horizontal,
            ratio: 0.5,
            first: left,
            second: right
        ))

        let data = try JSONEncoder.vetty.encode(tree)
        let decoded = try JSONDecoder.vetty.decode(PaneNode.self, from: data)

        XCTAssertEqual(decoded, tree)
    }
}
```

- [ ] **Step 2: Run tests and verify red**

Run:

```bash
xcodebuild -project Vetty.xcodeproj -scheme Vetty -configuration Debug -only-testing:VettyTests/WorkspaceModelTests test
```

Expected: FAIL because `VettyWorkspace`, `PaneNode`, and JSON helpers do not exist.

- [ ] **Step 3: Add model implementation**

Create `Vetty/Sources/VettyWorkspace/WorkspaceModels.swift`:

```swift
import Foundation

struct VettyWorkspace: Codable, Equatable {
    var windows: [WindowState]

    static func defaultWorkspace(homeDirectory: String = NSHomeDirectory()) -> VettyWorkspace {
        let pane = TerminalPaneState(id: UUID(), workingDirectory: homeDirectory)
        let tab = TerminalTabState(
            id: UUID(),
            name: "Shell",
            workingDirectory: homeDirectory,
            paneTree: .terminal(pane)
        )
        let group = TerminalGroupState(
            id: UUID(),
            name: "Work",
            isExpanded: true,
            selectedTabID: tab.id,
            tabs: [tab]
        )
        let window = WindowState(
            id: UUID(),
            frame: nil,
            selectedGroupID: group.id,
            selectedTabID: tab.id,
            groups: [group]
        )
        return VettyWorkspace(windows: [window])
    }
}

struct WindowState: Codable, Equatable, Identifiable {
    var id: UUID
    var frame: WindowFrame?
    var selectedGroupID: UUID
    var selectedTabID: UUID
    var groups: [TerminalGroupState]
}

struct WindowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct TerminalGroupState: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var isExpanded: Bool
    var selectedTabID: UUID?
    var tabs: [TerminalTabState]
}

struct TerminalTabState: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var workingDirectory: String
    var paneTree: PaneNode
}

indirect enum PaneNode: Codable, Equatable, Identifiable {
    case terminal(TerminalPaneState)
    case split(SplitPaneState)

    var id: UUID {
        switch self {
        case .terminal(let pane): pane.id
        case .split(let split): split.id
        }
    }
}

struct TerminalPaneState: Codable, Equatable, Identifiable {
    var id: UUID
    var workingDirectory: String
}

struct SplitPaneState: Codable, Equatable, Identifiable {
    enum Direction: String, Codable {
        case horizontal
        case vertical
    }

    var id: UUID
    var direction: Direction
    var ratio: Double
    var first: PaneNode
    var second: PaneNode
}

extension JSONEncoder {
    static var vetty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var vetty: JSONDecoder {
        JSONDecoder()
    }
}
```

- [ ] **Step 4: Run tests and verify green**

Run:

```bash
xcodebuild -project Vetty.xcodeproj -scheme Vetty -configuration Debug -only-testing:VettyTests/WorkspaceModelTests test
```

Expected: PASS for `WorkspaceModelTests`.

- [ ] **Step 5: Commit**

```bash
git add Vetty/Sources/VettyWorkspace/WorkspaceModels.swift Vetty/Tests/VettyWorkspaceTests/WorkspaceModelTests.swift
git commit -m "feat: add workspace data model"
```

---

### Task 5: Workspace Mutations

**Files:**
- Create: `Vetty/Sources/VettyWorkspace/WorkspaceReducer.swift`
- Create: `Vetty/Tests/VettyWorkspaceTests/WorkspaceReducerTests.swift`

- [ ] **Step 1: Write failing reducer tests**

Create `Vetty/Tests/VettyWorkspaceTests/WorkspaceReducerTests.swift`:

```swift
import XCTest
@testable import Vetty

final class WorkspaceReducerTests: XCTestCase {
    func testCreateGroupSelectsNewGroupAndCreatesInitialTab() throws {
        var workspace = VettyWorkspace.defaultWorkspace(homeDirectory: "/Users/dev")
        let windowID = try XCTUnwrap(workspace.windows.first?.id)

        let groupID = try workspace.createGroup(in: windowID, name: "Servers", workingDirectory: "/srv")

        let window = try XCTUnwrap(workspace.windows.first)
        let group = try XCTUnwrap(window.groups.first { $0.id == groupID })
        XCTAssertEqual(window.selectedGroupID, groupID)
        XCTAssertEqual(group.name, "Servers")
        XCTAssertEqual(group.tabs.count, 1)
        XCTAssertEqual(group.tabs[0].workingDirectory, "/srv")
    }

    func testCreateTabAddsTabToSelectedGroup() throws {
        var workspace = VettyWorkspace.defaultWorkspace(homeDirectory: "/Users/dev")
        let windowID = try XCTUnwrap(workspace.windows.first?.id)
        let tabID = try workspace.createTab(in: windowID, name: "API", workingDirectory: "/repo/api")

        let window = try XCTUnwrap(workspace.windows.first)
        let group = try XCTUnwrap(window.groups.first)
        XCTAssertEqual(window.selectedTabID, tabID)
        XCTAssertEqual(group.selectedTabID, tabID)
        XCTAssertEqual(group.tabs.last?.name, "API")
    }

    func testSplitPaneReplacesTerminalLeafWithSplit() throws {
        var workspace = VettyWorkspace.defaultWorkspace(homeDirectory: "/Users/dev")
        let windowID = try XCTUnwrap(workspace.windows.first?.id)
        let tab = try XCTUnwrap(workspace.windows.first?.groups.first?.tabs.first)
        let paneID = tab.paneTree.id

        let newPaneID = try workspace.splitPane(
            in: windowID,
            tabID: tab.id,
            paneID: paneID,
            direction: .vertical,
            workingDirectory: "/repo/api"
        )

        let updatedTab = try XCTUnwrap(workspace.windows.first?.groups.first?.tabs.first)
        guard case .split(let split) = updatedTab.paneTree else {
            return XCTFail("Expected split root")
        }
        XCTAssertEqual(split.direction, .vertical)
        XCTAssertEqual(split.first.id, paneID)
        XCTAssertEqual(split.second.id, newPaneID)
    }
}
```

- [ ] **Step 2: Run tests and verify red**

Run:

```bash
xcodebuild -project Vetty.xcodeproj -scheme Vetty -configuration Debug -only-testing:VettyTests/WorkspaceReducerTests test
```

Expected: FAIL because reducer methods do not exist.

- [ ] **Step 3: Add reducer implementation**

Create `Vetty/Sources/VettyWorkspace/WorkspaceReducer.swift`:

```swift
import Foundation

enum WorkspaceError: Error, Equatable {
    case windowNotFound(UUID)
    case groupNotFound(UUID)
    case tabNotFound(UUID)
    case paneNotFound(UUID)
}

extension VettyWorkspace {
    @discardableResult
    mutating func createGroup(in windowID: UUID, name: String, workingDirectory: String) throws -> UUID {
        guard let windowIndex = windows.firstIndex(where: { $0.id == windowID }) else {
            throw WorkspaceError.windowNotFound(windowID)
        }

        let pane = TerminalPaneState(id: UUID(), workingDirectory: workingDirectory)
        let tab = TerminalTabState(id: UUID(), name: "Shell", workingDirectory: workingDirectory, paneTree: .terminal(pane))
        let group = TerminalGroupState(id: UUID(), name: name, isExpanded: true, selectedTabID: tab.id, tabs: [tab])

        windows[windowIndex].groups.append(group)
        windows[windowIndex].selectedGroupID = group.id
        windows[windowIndex].selectedTabID = tab.id
        return group.id
    }

    @discardableResult
    mutating func createTab(in windowID: UUID, name: String, workingDirectory: String) throws -> UUID {
        guard let windowIndex = windows.firstIndex(where: { $0.id == windowID }) else {
            throw WorkspaceError.windowNotFound(windowID)
        }
        let selectedGroupID = windows[windowIndex].selectedGroupID
        guard let groupIndex = windows[windowIndex].groups.firstIndex(where: { $0.id == selectedGroupID }) else {
            throw WorkspaceError.groupNotFound(selectedGroupID)
        }

        let pane = TerminalPaneState(id: UUID(), workingDirectory: workingDirectory)
        let tab = TerminalTabState(id: UUID(), name: name, workingDirectory: workingDirectory, paneTree: .terminal(pane))

        windows[windowIndex].groups[groupIndex].tabs.append(tab)
        windows[windowIndex].groups[groupIndex].selectedTabID = tab.id
        windows[windowIndex].selectedTabID = tab.id
        return tab.id
    }

    @discardableResult
    mutating func splitPane(
        in windowID: UUID,
        tabID: UUID,
        paneID: UUID,
        direction: SplitPaneState.Direction,
        workingDirectory: String
    ) throws -> UUID {
        guard let windowIndex = windows.firstIndex(where: { $0.id == windowID }) else {
            throw WorkspaceError.windowNotFound(windowID)
        }

        for groupIndex in windows[windowIndex].groups.indices {
            guard let tabIndex = windows[windowIndex].groups[groupIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
                continue
            }

            let newPane = TerminalPaneState(id: UUID(), workingDirectory: workingDirectory)
            let didReplace = windows[windowIndex].groups[groupIndex].tabs[tabIndex].paneTree.replaceTerminal(
                paneID: paneID,
                with: .split(.init(
                    id: UUID(),
                    direction: direction,
                    ratio: 0.5,
                    first: windows[windowIndex].groups[groupIndex].tabs[tabIndex].paneTree.node(with: paneID)!,
                    second: .terminal(newPane)
                ))
            )

            if didReplace {
                return newPane.id
            }
            throw WorkspaceError.paneNotFound(paneID)
        }

        throw WorkspaceError.tabNotFound(tabID)
    }
}

extension PaneNode {
    func node(with targetID: UUID) -> PaneNode? {
        if id == targetID { return self }
        switch self {
        case .terminal:
            return nil
        case .split(let split):
            return split.first.node(with: targetID) ?? split.second.node(with: targetID)
        }
    }

    mutating func replaceTerminal(paneID: UUID, with replacement: PaneNode) -> Bool {
        switch self {
        case .terminal(let pane) where pane.id == paneID:
            self = replacement
            return true
        case .terminal:
            return false
        case .split(var split):
            if split.first.replaceTerminal(paneID: paneID, with: replacement) {
                self = .split(split)
                return true
            }
            if split.second.replaceTerminal(paneID: paneID, with: replacement) {
                self = .split(split)
                return true
            }
            return false
        }
    }
}
```

- [ ] **Step 4: Run tests and verify green**

Run:

```bash
xcodebuild -project Vetty.xcodeproj -scheme Vetty -configuration Debug -only-testing:VettyTests/WorkspaceReducerTests test
```

Expected: PASS for reducer tests.

- [ ] **Step 5: Commit**

```bash
git add Vetty/Sources/VettyWorkspace/WorkspaceReducer.swift Vetty/Tests/VettyWorkspaceTests/WorkspaceReducerTests.swift
git commit -m "feat: add workspace mutations"
```

---

### Task 6: Workspace Persistence

**Files:**
- Create: `Vetty/Sources/VettyWorkspace/WorkspaceStore.swift`
- Create: `Vetty/Tests/VettyWorkspaceTests/WorkspaceStoreTests.swift`

- [ ] **Step 1: Write failing persistence tests**

Create `Vetty/Tests/VettyWorkspaceTests/WorkspaceStoreTests.swift`:

```swift
import XCTest
@testable import Vetty

final class WorkspaceStoreTests: XCTestCase {
    func testSaveAndLoadWorkspace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStore(applicationSupportDirectory: directory)
        let workspace = VettyWorkspace.defaultWorkspace(homeDirectory: "/Users/dev")

        try store.save(workspace)
        let loaded = try store.loadOrCreateDefault(homeDirectory: "/Users/dev")

        XCTAssertEqual(loaded, workspace)
    }

    func testInvalidJSONIsBackedUpAndDefaultWorkspaceIsReturned() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let workspaceURL = directory.appendingPathComponent("workspace.json")
        try Data("{bad json".utf8).write(to: workspaceURL)

        let store = WorkspaceStore(applicationSupportDirectory: directory)
        let workspace = try store.loadOrCreateDefault(homeDirectory: "/Users/dev")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)

        XCTAssertEqual(workspace.windows.count, 1)
        XCTAssertTrue(files.contains { $0.hasPrefix("workspace.json.invalid-") })
    }
}
```

- [ ] **Step 2: Run tests and verify red**

Run:

```bash
xcodebuild -project Vetty.xcodeproj -scheme Vetty -configuration Debug -only-testing:VettyTests/WorkspaceStoreTests test
```

Expected: FAIL because `WorkspaceStore` does not exist.

- [ ] **Step 3: Add store implementation**

Create `Vetty/Sources/VettyWorkspace/WorkspaceStore.swift`:

```swift
import Foundation

struct WorkspaceStore {
    let applicationSupportDirectory: URL

    var workspaceURL: URL {
        applicationSupportDirectory.appendingPathComponent("workspace.json")
    }

    init(applicationSupportDirectory: URL? = nil) {
        if let applicationSupportDirectory {
            self.applicationSupportDirectory = applicationSupportDirectory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.applicationSupportDirectory = base.appendingPathComponent("Vetty", isDirectory: true)
        }
    }

    func loadOrCreateDefault(homeDirectory: String = NSHomeDirectory()) throws -> VettyWorkspace {
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else {
            return .defaultWorkspace(homeDirectory: homeDirectory)
        }

        do {
            let data = try Data(contentsOf: workspaceURL)
            return try JSONDecoder.vetty.decode(VettyWorkspace.self, from: data)
        } catch {
            try backupInvalidWorkspace()
            return .defaultWorkspace(homeDirectory: homeDirectory)
        }
    }

    func save(_ workspace: VettyWorkspace) throws {
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder.vetty.encode(workspace)
        try data.write(to: workspaceURL, options: [.atomic])
    }

    private func backupInvalidWorkspace() throws {
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else { return }
        let formatter = ISO8601DateFormatter()
        let safeTimestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = applicationSupportDirectory.appendingPathComponent("workspace.json.invalid-\(safeTimestamp)")
        try FileManager.default.moveItem(at: workspaceURL, to: backupURL)
    }
}
```

- [ ] **Step 4: Run tests and verify green**

Run:

```bash
xcodebuild -project Vetty.xcodeproj -scheme Vetty -configuration Debug -only-testing:VettyTests/WorkspaceStoreTests test
```

Expected: PASS for persistence tests.

- [ ] **Step 5: Commit**

```bash
git add Vetty/Sources/VettyWorkspace/WorkspaceStore.swift Vetty/Tests/VettyWorkspaceTests/WorkspaceStoreTests.swift
git commit -m "feat: persist workspace structure"
```

---

### Task 7: Workspace View Model And Sidebar UI

**Files:**
- Create: `Vetty/Sources/VettyUI/WorkspaceViewModel.swift`
- Create: `Vetty/Sources/VettyUI/WorkspaceSidebarView.swift`
- Create: `Vetty/Sources/VettyUI/VettyWindowView.swift`
- Create: `Vetty/Tests/VettyWorkspaceTests/WorkspaceViewModelTests.swift`
- Modify: `Vetty/Sources/App/AppDelegate.swift`

- [ ] **Step 1: Write failing view model tests**

Create `Vetty/Tests/VettyWorkspaceTests/WorkspaceViewModelTests.swift`:

```swift
import XCTest
@testable import Vetty

final class WorkspaceViewModelTests: XCTestCase {
    func testSelectTabUpdatesWindowSelection() throws {
        let workspace = VettyWorkspace.defaultWorkspace(homeDirectory: "/Users/dev")
        let viewModel = WorkspaceViewModel(workspace: workspace)
        let windowID = try XCTUnwrap(workspace.windows.first?.id)
        let newTabID = try viewModel.createTab(in: windowID, name: "API", workingDirectory: "/repo/api")

        viewModel.selectTab(newTabID, in: windowID)

        let window = try XCTUnwrap(viewModel.workspace.windows.first)
        XCTAssertEqual(window.selectedTabID, newTabID)
    }
}
```

- [ ] **Step 2: Run tests and verify red**

Run:

```bash
xcodebuild -project Vetty.xcodeproj -scheme Vetty -configuration Debug -only-testing:VettyTests/WorkspaceViewModelTests test
```

Expected: FAIL because `WorkspaceViewModel` does not exist.

- [ ] **Step 3: Add view model**

Create `Vetty/Sources/VettyUI/WorkspaceViewModel.swift`:

```swift
import Foundation
import SwiftUI

@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published private(set) var workspace: VettyWorkspace

    init(workspace: VettyWorkspace) {
        self.workspace = workspace
    }

    @discardableResult
    func createGroup(in windowID: UUID, name: String, workingDirectory: String) throws -> UUID {
        var next = workspace
        let id = try next.createGroup(in: windowID, name: name, workingDirectory: workingDirectory)
        workspace = next
        return id
    }

    @discardableResult
    func createTab(in windowID: UUID, name: String, workingDirectory: String) throws -> UUID {
        var next = workspace
        let id = try next.createTab(in: windowID, name: name, workingDirectory: workingDirectory)
        workspace = next
        return id
    }

    func selectTab(_ tabID: UUID, in windowID: UUID) {
        guard let windowIndex = workspace.windows.firstIndex(where: { $0.id == windowID }) else { return }
        workspace.windows[windowIndex].selectedTabID = tabID
        for groupIndex in workspace.windows[windowIndex].groups.indices {
            if workspace.windows[windowIndex].groups[groupIndex].tabs.contains(where: { $0.id == tabID }) {
                workspace.windows[windowIndex].selectedGroupID = workspace.windows[windowIndex].groups[groupIndex].id
                workspace.windows[windowIndex].groups[groupIndex].selectedTabID = tabID
            }
        }
    }
}
```

- [ ] **Step 4: Add sidebar and shell window views**

Create `Vetty/Sources/VettyUI/WorkspaceSidebarView.swift`:

```swift
import SwiftUI

struct WorkspaceSidebarView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    let windowID: UUID

    var body: some View {
        List {
            if let window = viewModel.workspace.windows.first(where: { $0.id == windowID }) {
                ForEach(window.groups) { group in
                    Section(group.name) {
                        ForEach(group.tabs) { tab in
                            Button {
                                viewModel.selectTab(tab.id, in: windowID)
                            } label: {
                                HStack {
                                    Text(tab.name)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
    }
}
```

Create `Vetty/Sources/VettyUI/VettyWindowView.swift`:

```swift
import SwiftUI

struct VettyWindowView<TerminalContent: View>: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    let windowID: UUID
    let terminalContent: () -> TerminalContent

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebarView(viewModel: viewModel, windowID: windowID)
            Divider()
            terminalContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
```

- [ ] **Step 5: Run tests and commit**

Run:

```bash
xcodebuild -project Vetty.xcodeproj -scheme Vetty -configuration Debug -only-testing:VettyTests/WorkspaceViewModelTests test
```

Expected: PASS.

Commit:

```bash
git add Vetty/Sources/VettyUI Vetty/Tests/VettyWorkspaceTests/WorkspaceViewModelTests.swift
git commit -m "feat: add workspace sidebar view model"
```

---

### Task 8: Attach Ghostty-Derived Terminals To Vetty Tabs

**Files:**
- Create: `Vetty/Sources/VettyWorkspace/RuntimePaneRegistry.swift`
- Create: `Vetty/Sources/VettyUI/TerminalTabHostView.swift`
- Modify: `Vetty/Sources/GhosttyDerived/Features/Terminal/BaseTerminalController.swift`
- Modify: `Vetty/Sources/GhosttyDerived/Features/Terminal/TerminalView.swift`
- Modify: `Vetty/Sources/GhosttyDerived/Features/Splits/SplitTree.swift`

- [ ] **Step 1: Add a runtime pane registry**

Create `Vetty/Sources/VettyWorkspace/RuntimePaneRegistry.swift`:

```swift
import Foundation

@MainActor
final class RuntimePaneRegistry<Pane> {
    private var panes: [UUID: Pane] = [:]

    func pane(for id: UUID) -> Pane? {
        panes[id]
    }

    func setPane(_ pane: Pane, for id: UUID) {
        panes[id] = pane
    }

    func removePane(for id: UUID) {
        panes.removeValue(forKey: id)
    }
}
```

- [ ] **Step 2: Build a tab host that maps `PaneNode` to Ghostty surfaces**

Create `Vetty/Sources/VettyUI/TerminalTabHostView.swift`:

```swift
import SwiftUI

struct TerminalTabHostView: View {
    let tab: TerminalTabState

    var body: some View {
        Text("Terminal host for \(tab.name)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

This temporary text host keeps the sidebar work buildable before the Ghostty-derived view is wired in.

- [ ] **Step 3: Replace the temporary text host with Ghostty-derived terminal views**

Modify `TerminalTabHostView` so each terminal leaf creates or reuses a `Ghostty.SurfaceView` from `RuntimePaneRegistry<Ghostty.SurfaceView>` and renders the copied `TerminalSplitTreeView`.

The shape must be:

```swift
struct TerminalTabHostView: View {
    @EnvironmentObject var ghostty: Ghostty.App
    let tab: TerminalTabState
    @ObservedObject var runtime: TerminalRuntimeModel

    var body: some View {
        TerminalSplitTreeView(
            tree: runtime.surfaceTree(for: tab),
            action: runtime.performSplitOperation
        )
        .environmentObject(ghostty)
    }
}
```

Create `Vetty/Sources/VettyUI/TerminalRuntimeModel.swift`:

```swift
@MainActor
final class TerminalRuntimeModel: ObservableObject {
    let ghostty: Ghostty.App
    let panes = RuntimePaneRegistry<Ghostty.SurfaceView>()

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
    }

    func surfaceTree(for tab: TerminalTabState) -> SplitTree<Ghostty.SurfaceView> {
        SplitTree(root: splitTreeNode(for: tab.paneTree), zoomed: nil)
    }

    private func splitTreeNode(for node: PaneNode) -> SplitTree<Ghostty.SurfaceView>.Node {
        switch node {
        case .terminal(let pane):
            return .leaf(view: surface(for: pane))

        case .split(let split):
            return .split(.init(
                direction: split.direction == .horizontal ? .horizontal : .vertical,
                ratio: split.ratio,
                left: splitTreeNode(for: split.first),
                right: splitTreeNode(for: split.second)
            ))
        }
    }

    private func surface(for pane: TerminalPaneState) -> Ghostty.SurfaceView {
        if let existing = panes.pane(for: pane.id) {
            return existing
        }

        guard let ghosttyApp = ghostty.app else {
            preconditionFailure("Ghostty app must be ready before creating terminal panes")
        }

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = pane.workingDirectory
        let view = Ghostty.SurfaceView(ghosttyApp, baseConfig: config, uuid: pane.id)
        panes.setPane(view, for: pane.id)
        return view
    }

    func performSplitOperation(_ operation: TerminalSplitOperation) {
        NotificationCenter.default.post(name: .vettyTerminalSplitOperationRequested, object: operation)
    }
}

extension Notification.Name {
    static let vettyTerminalSplitOperationRequested = Notification.Name("VettyTerminalSplitOperationRequested")
}
```

- [ ] **Step 4: Manual check**

Run:

```bash
scripts/build-vetty.sh
open Vetty/build/Debug/Vetty.app
```

Expected:

- The app opens.
- The sidebar is visible.
- The selected tab shows a real shell.
- Typing into the terminal works.

- [ ] **Step 5: Commit**

```bash
git add Vetty/Sources/VettyWorkspace/RuntimePaneRegistry.swift Vetty/Sources/VettyUI/TerminalTabHostView.swift Vetty/Sources/GhosttyDerived
git commit -m "feat: host terminal panes inside Vetty tabs"
```

---

### Task 9: Split Pane Working Directory Behavior

**Files:**
- Create: `Vetty/Sources/VettyWorkspace/WorkingDirectoryResolver.swift`
- Create: `Vetty/Tests/VettyWorkspaceTests/WorkingDirectoryResolverTests.swift`
- Modify: `Vetty/Sources/VettyUI/TerminalRuntimeModel.swift`

- [ ] **Step 1: Write failing working directory tests**

Create `Vetty/Tests/VettyWorkspaceTests/WorkingDirectoryResolverTests.swift`:

```swift
import XCTest
@testable import Vetty

final class WorkingDirectoryResolverTests: XCTestCase {
    func testPrefersFocusedPaneDirectory() {
        let resolver = WorkingDirectoryResolver(homeDirectory: "/Users/dev")

        XCTAssertEqual(
            resolver.directoryForNewSplit(
                focusedPaneDirectory: "/repo/api",
                savedPaneDirectory: "/repo/old",
                tabDirectory: "/repo"
            ),
            "/repo/api"
        )
    }

    func testFallsBackToSavedPaneThenTabThenHome() {
        let resolver = WorkingDirectoryResolver(homeDirectory: "/Users/dev")

        XCTAssertEqual(resolver.directoryForNewSplit(focusedPaneDirectory: "", savedPaneDirectory: "/pane", tabDirectory: "/tab"), "/pane")
        XCTAssertEqual(resolver.directoryForNewSplit(focusedPaneDirectory: nil, savedPaneDirectory: "", tabDirectory: "/tab"), "/tab")
        XCTAssertEqual(resolver.directoryForNewSplit(focusedPaneDirectory: nil, savedPaneDirectory: nil, tabDirectory: ""), "/Users/dev")
    }
}
```

- [ ] **Step 2: Run tests and verify red**

Run:

```bash
xcodebuild -project Vetty.xcodeproj -scheme Vetty -configuration Debug -only-testing:VettyTests/WorkingDirectoryResolverTests test
```

Expected: FAIL because `WorkingDirectoryResolver` does not exist.

- [ ] **Step 3: Add resolver**

Create `Vetty/Sources/VettyWorkspace/WorkingDirectoryResolver.swift`:

```swift
import Foundation

struct WorkingDirectoryResolver {
    let homeDirectory: String

    func directoryForNewTab(focusedPaneDirectory: String?, selectedTabDirectory: String?) -> String {
        firstUsable([focusedPaneDirectory, selectedTabDirectory, homeDirectory])
    }

    func directoryForNewSplit(focusedPaneDirectory: String?, savedPaneDirectory: String?, tabDirectory: String?) -> String {
        firstUsable([focusedPaneDirectory, savedPaneDirectory, tabDirectory, homeDirectory])
    }

    private func firstUsable(_ values: [String?]) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? homeDirectory
    }
}
```

- [ ] **Step 4: Wire resolver into split action**

In `TerminalRuntimeModel.performSplitOperation`, get the focused `Ghostty.SurfaceView` PWD, resolve the new directory, then call `workspace.splitPane(...)` with that directory.

Use this shape:

```swift
let directory = WorkingDirectoryResolver(homeDirectory: NSHomeDirectory())
    .directoryForNewSplit(
        focusedPaneDirectory: focusedSurface.pwd,
        savedPaneDirectory: savedPane.workingDirectory,
        tabDirectory: tab.workingDirectory
    )
```

- [ ] **Step 5: Run tests and manual split check**

Run:

```bash
xcodebuild -project Vetty.xcodeproj -scheme Vetty -configuration Debug -only-testing:VettyTests/WorkingDirectoryResolverTests test
scripts/build-vetty.sh
```

Manual check:

```bash
cd /tmp
# Use Vetty split command from menu or keybinding.
pwd
```

Expected: the new pane prints `/tmp`.

- [ ] **Step 6: Commit**

```bash
git add Vetty/Sources/VettyWorkspace/WorkingDirectoryResolver.swift Vetty/Tests/VettyWorkspaceTests/WorkingDirectoryResolverTests.swift Vetty/Sources/VettyUI/TerminalRuntimeModel.swift
git commit -m "feat: start split panes in source directory"
```

---

### Task 10: Workspace Commands And Command Palette

**Files:**
- Create: `Vetty/Sources/VettyCommands/VettyCommand.swift`
- Create: `Vetty/Sources/VettyCommands/VettyCommandRouter.swift`
- Create: `Vetty/Tests/VettyCommandTests/VettyCommandRouterTests.swift`
- Modify: copied command palette files under `Vetty/Sources/GhosttyDerived/Features/CommandPalette/`

- [ ] **Step 1: Write failing command router tests**

Create `Vetty/Tests/VettyCommandTests/VettyCommandRouterTests.swift`:

```swift
import XCTest
@testable import Vetty

final class VettyCommandRouterTests: XCTestCase {
    func testPaletteIncludesWorkspaceCommands() {
        let commands = VettyCommand.allCases.map(\.title)

        XCTAssertTrue(commands.contains("New Group"))
        XCTAssertTrue(commands.contains("New Tab"))
        XCTAssertTrue(commands.contains("Split Pane Right"))
        XCTAssertTrue(commands.contains("Search Focused Terminal"))
        XCTAssertTrue(commands.contains("Open Settings"))
    }
}
```

- [ ] **Step 2: Run tests and verify red**

Run:

```bash
xcodebuild -project Vetty.xcodeproj -scheme Vetty -configuration Debug -only-testing:VettyTests/VettyCommandRouterTests test
```

Expected: FAIL because command types do not exist.

- [ ] **Step 3: Add command list**

Create `Vetty/Sources/VettyCommands/VettyCommand.swift`:

```swift
import Foundation

enum VettyCommand: String, CaseIterable, Identifiable {
    case newGroup
    case renameGroup
    case deleteGroup
    case newTab
    case renameTab
    case closeTab
    case moveTabToGroup
    case splitPaneRight
    case splitPaneDown
    case splitPaneLeft
    case splitPaneUp
    case closePane
    case focusPaneLeft
    case focusPaneRight
    case focusPaneUp
    case focusPaneDown
    case openSettings
    case searchFocusedTerminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newGroup: "New Group"
        case .renameGroup: "Rename Group"
        case .deleteGroup: "Delete Group"
        case .newTab: "New Tab"
        case .renameTab: "Rename Tab"
        case .closeTab: "Close Tab"
        case .moveTabToGroup: "Move Tab to Group"
        case .splitPaneRight: "Split Pane Right"
        case .splitPaneDown: "Split Pane Down"
        case .splitPaneLeft: "Split Pane Left"
        case .splitPaneUp: "Split Pane Up"
        case .closePane: "Close Pane"
        case .focusPaneLeft: "Focus Pane Left"
        case .focusPaneRight: "Focus Pane Right"
        case .focusPaneUp: "Focus Pane Up"
        case .focusPaneDown: "Focus Pane Down"
        case .openSettings: "Open Settings"
        case .searchFocusedTerminal: "Search Focused Terminal"
        }
    }
}
```

Create `Vetty/Sources/VettyCommands/VettyCommandRouter.swift`:

```swift
import Foundation

@MainActor
final class VettyCommandRouter {
    func perform(_ command: VettyCommand) {
        NotificationCenter.default.post(name: .vettyCommandRequested, object: command)
    }
}

extension Notification.Name {
    static let vettyCommandRequested = Notification.Name("VettyCommandRequested")
}
```

- [ ] **Step 4: Add Vetty commands to the copied command palette**

Modify the copied command palette source so it appends `VettyCommand.allCases` to the command list. Each command calls `VettyCommandRouter.perform(_:)`.

Use this adapter shape:

```swift
let vettyCommands = VettyCommand.allCases.map { command in
    CommandPalette.Command(title: command.title) {
        VettyCommandRouter().perform(command)
    }
}
```

- [ ] **Step 5: Run tests and manual command palette check**

Run:

```bash
xcodebuild -project Vetty.xcodeproj -scheme Vetty -configuration Debug -only-testing:VettyTests/VettyCommandRouterTests test
scripts/build-vetty.sh
```

Manual check:

- Open command palette.
- Type `New Tab`.
- Press Enter.
- A tab is created in the selected group.

- [ ] **Step 6: Commit**

```bash
git add Vetty/Sources/VettyCommands Vetty/Tests/VettyCommandTests Vetty/Sources/GhosttyDerived/Features/CommandPalette
git commit -m "feat: add Vetty commands to command palette"
```

---

### Task 11: Search, Settings, Multiple Windows, AppleScript, And AppIntents

**Files:**
- Modify: `Vetty/Sources/GhosttyDerived/Features/Settings/`
- Modify: `Vetty/Sources/GhosttyDerived/Features/App Intents/` or renamed AppIntents path
- Modify: `Vetty/Sources/GhosttyDerived/Features/AppleScript/`
- Modify: `Vetty/Resources/Vetty.sdef`
- Modify: `Vetty/Sources/App/AppDelegate.swift`
- Create: `Vetty/Tests/VettyCommandTests/WindowCommandRoutingTests.swift`

- [ ] **Step 1: Write failing command routing tests**

Create `Vetty/Tests/VettyCommandTests/WindowCommandRoutingTests.swift`:

```swift
import XCTest
@testable import Vetty

final class WindowCommandRoutingTests: XCTestCase {
    func testKeyWindowCommandContextUsesSelectedWindow() throws {
        let firstWindow = WindowState(
            id: UUID(),
            frame: nil,
            selectedGroupID: UUID(),
            selectedTabID: UUID(),
            groups: []
        )
        let secondWindow = WindowState(
            id: UUID(),
            frame: nil,
            selectedGroupID: UUID(),
            selectedTabID: UUID(),
            groups: []
        )
        let context = WindowCommandContext(workspace: .init(windows: [firstWindow, secondWindow]), keyWindowID: secondWindow.id)

        XCTAssertEqual(context.targetWindow?.id, secondWindow.id)
    }
}
```

- [ ] **Step 2: Add command context**

Create `Vetty/Sources/VettyCommands/WindowCommandContext.swift`:

```swift
struct WindowCommandContext {
    var workspace: VettyWorkspace
    var keyWindowID: UUID?

    var targetWindow: WindowState? {
        if let keyWindowID, let window = workspace.windows.first(where: { $0.id == keyWindowID }) {
            return window
        }
        return workspace.windows.first
    }
}
```

- [ ] **Step 3: Adapt search**

Wire the copied search command so it targets the focused terminal pane. If no pane is focused, focus the selected tab's most recently focused pane, then open search.

Manual expected behavior:

- Search opens over the focused terminal pane.
- Search does not search hidden tabs.

- [ ] **Step 4: Adapt settings**

Keep the copied settings UI app-wide. Add these Vetty settings:

```swift
struct VettySettings: Codable, Equatable {
    var defaultGroupName: String = "Work"
    var defaultTabName: String = "Shell"
    var workspacePathDisplay: String
}
```

Manual expected behavior:

- Settings opens.
- Ghostty-derived terminal settings are still visible.
- Vetty workspace file path appears read-only.

- [ ] **Step 5: Adapt multiple windows**

App delegate creates one `WorkspaceViewModel` per window state. New Window creates a new `WindowState` with one group and one tab, then opens a native macOS window.

Manual expected behavior:

- `File > New Window` opens another Vetty window.
- Each window has its own sidebar.
- Quit/reopen restores both windows.

- [ ] **Step 6: Adapt AppleScript and AppIntents**

Update `Vetty.sdef` and copied scripting types so the object model exposes:

```text
application
+-- windows
    +-- groups
        +-- tabs
            +-- focused terminal pane
```

Manual smoke command:

```bash
osascript -e 'tell application "Vetty" to count windows'
```

Expected: returns the number of open Vetty windows.

- [ ] **Step 7: Run tests and commit**

Run:

```bash
xcodebuild -project Vetty.xcodeproj -scheme Vetty -configuration Debug -only-testing:VettyTests/WindowCommandRoutingTests test
scripts/build-vetty.sh
```

Commit:

```bash
git add Vetty
git commit -m "feat: adapt Ghostty app features to Vetty workspace"
```

---

### Task 12: Final Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/plans/2026-05-02-vetty-macos-terminal.md` only to check off completed steps

- [ ] **Step 1: Add README**

Create `README.md`:

````markdown
# Vetty

Vetty is a macOS-only terminal app derived from Ghostty's macOS terminal stack. It adds a Codex-like sidebar where users organize terminal tabs into manual groups.

## Development

The local `ghostty/` directory is reference-only and ignored by git.

Build GhosttyKit:

```bash
scripts/build-ghostty-kit.sh
```

Build Vetty:

```bash
scripts/build-vetty.sh
```

Run safety checks:

```bash
scripts/check-no-reference-ghostty.sh
```
````

- [ ] **Step 2: Run full verification**

Run:

```bash
scripts/check-no-reference-ghostty.sh
xcodebuild -project Vetty.xcodeproj -scheme Vetty -configuration Debug test
scripts/build-vetty.sh
```

Expected:

- no tracked or build-time references to local `ghostty/`
- unit tests pass
- app builds

- [ ] **Step 3: Manual app verification**

Open app:

```bash
open Vetty/build/Debug/Vetty.app
```

Verify:

- shell opens
- typing works
- create group works
- create tab works
- tab switching works
- split right/down works
- new split starts in source pane working directory
- search opens for focused pane
- command palette opens and runs `New Tab`
- settings opens
- new window opens
- quit/reopen restores workspace structure with fresh shells

- [ ] **Step 4: Commit docs**

```bash
git add README.md docs/superpowers/plans/2026-05-02-vetty-macos-terminal.md
git commit -m "docs: add Vetty development instructions"
```

---

## Plan Self-Review

Spec coverage:

- Native macOS app: Tasks 2, 3, and 12.
- Ghostty-derived terminal stack: Tasks 2, 3, and 8.
- Sidebar groups and grouped tabs: Tasks 4, 5, and 7.
- Recursive splits: Tasks 4, 5, 8, and 9.
- Fresh shell for new panes: Tasks 8 and 9.
- Same working directory for splits: Task 9.
- Workspace persistence: Task 6.
- Multiple windows, settings, command palette, search, AppleScript/AppIntents: Tasks 10 and 11.
- Reference-only `ghostty/`: Tasks 1, 2, and 12.

Completion scan:

- No vague tokens or undefined future tasks.
- The one temporary text host in Task 8 is explicitly replaced before that task can be committed.

Type consistency:

- Workspace types use `VettyWorkspace`, `WindowState`, `TerminalGroupState`, `TerminalTabState`, `PaneNode`, `TerminalPaneState`, and `SplitPaneState`.
- Mutating methods live on `VettyWorkspace`.
- UI and command types depend on those same names.
