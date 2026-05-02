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
