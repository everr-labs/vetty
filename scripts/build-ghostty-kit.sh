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
