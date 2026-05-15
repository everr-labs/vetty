# Vetty

A macOS terminal built on Ghostty with a sidebar for organizing terminals into groups.

> ⚠️ Vetty is still in heavy development. Things will break, change, or move without warning.

![Vetty screenshot](screenshot.png)

## Why

I built Vetty because I work across multiple projects at the same time, with several terminal sessions open in each, and I want all of them accessible immediately — no hunting through windows or rebuilding context.

I tried other vertical-tab terminals first, but none of them gave me what I actually wanted: a **project + session** structure, with multiple **panes inside each session**. So I built one.

## What it is

Vetty embeds [Ghostty](https://ghostty.org/) (via the vendored `GhosttyKit.xcframework`) and wraps it in a workspace window. Rendering, input, splits, the command palette, font controls, and shell handling all come from Ghostty. Vetty adds a single thing on top: a 244pt left sidebar that organizes terminals into **groups → tabs → panes**.

- **Groups** are top-level rows in the sidebar. Each one collapses/expands and can be renamed.
- **Tabs** sit inside a group. Each tab owns its own working directory and a pane tree.
- **Panes** can be split horizontally or vertically, recursively, inside a tab.

Both groups and tabs can be drag-and-drop reordered. Groups can also be renamed inline.

## Tab titles

Each tab's display title falls back through three sources:

1. A manual override you set via the sidebar.
2. The live title reported by the shell/program running in the first pane.
3. The last non-empty title Vetty observed (persisted across launches).

## State persistence

The full workspace — groups, tabs, expanded/collapsed state, selection, pane trees, working directories, tab titles — is serialized as JSON to:

```
~/Library/Application Support/Vetty/workspace.json
```

On launch Vetty restores from that file. If it's missing or empty, you get one group ("General") with one terminal in your home directory.

## Window

- Default size: 1120 × 720
- Minimum size: 760 × 460
- macOS-native tabbing is disabled — Vetty's sidebar is the tab UI.

## Requirements

- macOS 13.0 (Ventura) or later
- Bundle ID: `com.guidodorsi.vetty`

## Install

Download the latest `.dmg` from the [Releases page](https://github.com/gdorsi/vetty/releases), open it, and drag `Vetty.app` into `/Applications`.

## File handling

Vetty registers as a handler for shell scripts (`.command`, `.tool`, `.sh`, `.zsh`, `.csh`, `.pl`), folders, and Unix executables, so you can open them directly from Finder.

## Building from source

Vetty has three build scripts under `scripts/`:

```bash
# 1. Build the vendored Ghostty into an xcframework (only needed once,
#    or when ghostty/ changes)
./scripts/build-ghostty-kit.sh

# 2. Local debug build
./scripts/build-vetty-debug.sh

# 3. Signed + notarized release DMG (requires Developer ID, notary profile)
./scripts/build-vetty-release.sh
```

The release script signs every binary manually with `codesign`, submits the bundle to `notarytool`, staples the ticket, and packages a notarized DMG. Required environment variables are documented at the top of `scripts/build-vetty-release.sh`.

## Layout

```
Vetty/Sources/
├── App/                  # AppDelegate, main, Ghostty wiring
├── VettyWorkspace/       # Sidebar UI + workspace model/persistence
└── GhosttyDerived/       # Glue code adapted from Ghostty's macOS app
ghostty/                  # Vendored Ghostty source
scripts/                  # Build, sign, notarize, package
```
