# Vetty macOS Terminal App Design

## Status

Approved on 2026-05-02.

## Context

Vetty is a new native macOS terminal app built in the project root at `/Users/guidodorsi/workspace/vetty`.

The local `ghostty/` directory is reference material only. It must not be committed, and Vetty must not depend on that directory at build time. Any Ghostty code Vetty needs must be copied or adapted into Vetty's own source tree with clear attribution.

Ghostty is MIT licensed, so copied/adapted code must keep license notices. Vetty will include a vendor notice for Ghostty-derived code.

## Goals

- Build a native macOS app.
- Use Ghostty's terminal core through the same style of C API used by the Ghostty macOS app.
- Copy/adapt Ghostty's macOS terminal stack as the starting point.
- Keep the richer Ghostty app features in version 1:
  - multiple windows
  - settings UI
  - command palette
  - search UI
  - AppleScript/AppIntents adapted to Vetty windows, groups, tabs, and focused terminal panes
- Add a Codex-like vertical sidebar for organizing tabs into manual groups.
- Let each group contain terminal tabs.
- Show the selected tab in the main terminal area.
- Let each tab own a recursive split-pane tree.
- Start a fresh shell when creating a new pane.
- Start split panes in the same working directory as the pane being split.
- Persist the workspace structure across app restarts.

## Non-Goals For Version 1

- Windows support.
- Linux support.
- Drag-and-drop reordering of groups or tabs.
- Saving live terminal output across restarts.
- Restoring running shell processes across restarts.
- Session syncing between machines.

## Main Product Shape

The app window has two main areas:

```text
+----------------+--------------------------------+
| Sidebar        | Selected tab terminal area     |
|                |                                |
| Work           | +-------------+--------------+ |
|   API          | | pane        | pane         | |
|   Frontend     | +-------------+--------------+ |
|                |                                |
| Personal       |                                |
|   Notes        |                                |
+----------------+--------------------------------+
```

The sidebar contains manual groups. A group is just a user-created label, such as `Work`, `Personal`, or `Servers`. It does not need to match a folder on disk.

Each group contains tabs. A tab has a name, a working directory, and a pane tree.

The selected tab's pane tree fills the main terminal area.

## Architecture

Vetty is a Ghostty-derived macOS app with a new workspace model.

Ghostty-derived code handles terminal behavior. Vetty-owned code handles organization.

```text
Vetty App
+-- Workspace UI
|   +-- Sidebar groups
|   +-- Tabs inside groups
|   +-- Selected group/tab state
|   +-- Workspace persistence
|
+-- Ghostty-derived macOS terminal stack
    +-- Terminal surface/view
    +-- PTY and shell process handling
    +-- Metal terminal rendering
    +-- Keyboard and mouse input
    +-- Copy/paste
    +-- Search UI
    +-- Command palette
    +-- Settings UI
    +-- AppleScript/AppIntents support
```

Vetty replaces Ghostty's normal tab/window organization with:

```text
Window
+-- Workspace sidebar
    +-- Groups
        +-- Tabs
            +-- Split panes
```

The terminal pane implementation stays close to Ghostty's macOS `SurfaceView` and terminal controller behavior so that Vetty starts as a real working terminal, not as a UI mock.

## Copied And Adapted Code

The implementation starts by copying/adapting these Ghostty source areas into Vetty-owned paths. The local `ghostty/` reference copy is the source for the first import only; Vetty's build uses the copied files, not the reference directory.

```text
Reference source path                                      Vetty destination
ghostty/macos/Sources/Ghostty/                             Vetty/Sources/GhosttyDerived/Ghostty/
ghostty/macos/Sources/Features/Terminal/                   Vetty/Sources/GhosttyDerived/Features/Terminal/
ghostty/macos/Sources/Features/Splits/                     Vetty/Sources/GhosttyDerived/Features/Splits/
ghostty/macos/Sources/Features/Settings/                   Vetty/Sources/GhosttyDerived/Features/Settings/
ghostty/macos/Sources/Features/Command Palette/            Vetty/Sources/GhosttyDerived/Features/CommandPalette/
ghostty/macos/Sources/Features/App Intents/                Vetty/Sources/GhosttyDerived/Features/AppIntents/
ghostty/macos/Sources/Features/AppleScript/                Vetty/Sources/GhosttyDerived/Features/AppleScript/
ghostty/macos/Sources/Features/ClipboardConfirmation/      Vetty/Sources/GhosttyDerived/Features/ClipboardConfirmation/
ghostty/macos/Sources/Features/Secure Input/               Vetty/Sources/GhosttyDerived/Features/SecureInput/
ghostty/macos/Sources/Helpers/                             Vetty/Sources/GhosttyDerived/Helpers/
ghostty/macos/Sources/App/macOS/                           Vetty/Sources/App/
ghostty/macos/Ghostty.sdef                                 Vetty/Resources/Vetty.sdef
```

Ghostty source areas copied only because the terminal stack references them, such as update UI or custom icon helpers, must be reduced to the smallest compiling form unless the feature is explicitly listed in this spec.

The copied code must be trimmed only where a feature conflicts with Vetty's workspace model.

Examples of behavior that must change:

- "New tab" creates a tab in the selected Vetty group.
- "Close tab" closes the selected Vetty tab.
- "Split right/down/left/up" modifies the selected tab's pane tree.
- Search acts on the focused terminal pane.
- Settings remain app-wide in version 1.
- AppleScript/AppIntents target Vetty windows, groups, tabs, and focused terminal panes instead of Ghostty's original tab model.

## Workspace Data Model

Vetty persists workspace structure as JSON at:

```text
~/Library/Application Support/Vetty/workspace.json
```

Top-level shape:

```text
Workspace
+-- windows: [WindowState]
```

Window state:

```text
WindowState
+-- id: UUID
+-- frame: optional window frame
+-- selectedGroupID: UUID
+-- selectedTabID: UUID
+-- groups: [Group]
```

Group:

```text
Group
+-- id: UUID
+-- name: String
+-- isExpanded: Bool
+-- selectedTabID: UUID?
+-- tabs: [TerminalTab]
```

Terminal tab:

```text
TerminalTab
+-- id: UUID
+-- name: String
+-- workingDirectory: String
+-- paneTree: PaneNode
```

Pane node:

```text
PaneNode
+-- terminal pane
|   +-- id: UUID
|   +-- workingDirectory: String
|
+-- split node
    +-- id: UUID
    +-- direction: horizontal | vertical
    +-- ratio: Double
    +-- first: PaneNode
    +-- second: PaneNode
```

This recursive pane tree is the only split model. There are no special cases for two panes, three panes, or nested panes.

## Runtime Behavior

When Vetty launches:

1. Read `workspace.json`.
2. Recreate windows.
3. Recreate each window's groups and tabs.
4. Recreate each tab's pane tree.
5. Start a fresh shell for every restored terminal pane.
6. Start each shell in the saved working directory for that pane.

Vetty does not restore old output or old running processes.

When creating a new group:

1. Add a group with a unique ID and user-visible name.
2. Select the new group.
3. Create an initial tab if the group would otherwise be empty.

When creating a new tab:

1. Add the tab to the selected group.
2. Set its working directory to the focused pane's current working directory, if available.
3. Fall back to the selected tab's working directory.
4. Fall back to the user's home directory.
5. Create one terminal pane and start a fresh shell.

When splitting a pane:

1. Ask the focused pane for its current working directory.
2. Fall back to the pane's saved working directory.
3. Fall back to the tab's working directory.
4. Fall back to the user's home directory.
5. Create a fresh terminal pane in that directory.
6. Replace the focused pane leaf with a split node containing the old pane and new pane.
7. Focus the new pane.

## Command Palette

The command palette is a searchable command popup. It lets users type an action name and run it.

Vetty's command palette includes Ghostty's terminal commands and Vetty-specific workspace commands:

- New Group
- Rename Group
- Delete Group
- New Tab
- Rename Tab
- Close Tab
- Move Tab to Group
- Split Pane Right
- Split Pane Down
- Split Pane Left
- Split Pane Up
- Close Pane
- Focus Pane Left/Right/Up/Down
- Open Settings
- Search Focused Terminal

Commands operate on the current window, selected group, selected tab, and focused terminal pane.

## Search

Search is in scope for version 1.

Search targets the focused terminal pane. If no terminal pane is focused, Vetty focuses the selected tab's most recently focused pane, then opens search.

The search UI remains close to Ghostty's search behavior except for layout changes required by Vetty's sidebar.

## Settings

Settings are in scope for version 1.

Settings remain app-wide in version 1. Vetty keeps the Ghostty-derived settings UI working and adds only the Vetty-specific settings listed below.

Vetty-specific settings for version 1:

- workspace file location display, read-only
- default group name for first launch
- default tab name for new tabs

## Multiple Windows

Multiple windows are in scope for version 1.

Each window has its own sidebar, group list, selected group, selected tab, and split pane state.

The workspace file saves all windows.

App-wide commands use the key window. If no window is key, they create or focus a window before acting.

## AppleScript And AppIntents

AppleScript/AppIntents are in scope for Vetty windows, groups, tabs, and focused terminal panes.

The scripting model exposes:

- windows
- groups
- tabs
- focused terminal pane
- commands to create groups and tabs
- commands to split and focus panes
- commands to send text/key input to the focused pane

Ghostty commands that refer to the old tab model must be adapted to Vetty groups and tabs.

## Error Handling

If workspace JSON cannot be read:

1. Keep the bad file by renaming it with a timestamp suffix.
2. Start with a fresh workspace containing one group and one tab.
3. Show a simple warning to the user.

If a saved working directory no longer exists:

1. Start the pane in the user's home directory.
2. Keep the saved path in the tab metadata until the user changes directories or saves again.

If a shell cannot be started:

1. Show a terminal error view in that pane.
2. Keep the tab and pane in the workspace.
3. Allow the user to close the pane or retry.

## Build And Repository Structure

Initial structure:

```text
Vetty.xcodeproj
Vetty/
  Sources/
  Tests/
  Resources/
  VendorNotices/
docs/
  superpowers/
    specs/
      2026-05-02-vetty-macos-terminal-design.md
```

The root `.gitignore` must ignore the local reference clone:

```text
ghostty/
```

The implementation must not import files from `/Users/guidodorsi/workspace/vetty/ghostty` at build time.

## Testing

Unit tests cover Vetty-owned logic:

- create group
- rename group
- delete group
- create tab
- rename tab
- close tab
- select group and tab
- encode workspace JSON
- decode workspace JSON
- handle invalid workspace JSON
- insert horizontal split
- insert vertical split
- restore recursive split pane tree
- choose working directory for new tab
- choose working directory for new split pane

Manual app checks cover real terminal behavior:

- app launches
- shell opens
- typing works
- terminal resizes
- copy/paste works
- tabs switch correctly
- groups expand/collapse
- split panes open fresh shells
- split panes start in the same working directory as the source pane
- search opens for focused pane
- command palette opens and runs Vetty commands
- settings opens
- multiple windows open and restore
- AppleScript/AppIntents commands target Vetty's model
- workspace restores after quit and reopen

## Risks

The biggest risk is that Ghostty's macOS app code is designed for Ghostty's own model. Copying it gives Vetty a real terminal faster, but it may bring tightly coupled code.

The mitigation is to keep a clear boundary:

- Ghostty-derived code owns terminal behavior.
- Vetty-owned code owns groups, tabs, selection, and persistence.
- Old Ghostty tab/window assumptions are adapted at the command boundary.

The second risk is API churn in Ghostty internals. Vetty copies a known working snapshot, keeps local attribution, and updates intentionally instead of tracking the reference clone directly.
