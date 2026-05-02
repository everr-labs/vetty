#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ghostty_kit="$root/Vetty/Frameworks/GhosttyKit.xcframework"

if [[ ! -d "$ghostty_kit" ]]; then
  echo "Missing Vetty/Frameworks/GhosttyKit.xcframework." >&2
  echo "This script does not rebuild GhosttyKit. Run scripts/build-ghostty-kit.sh first." >&2
  exit 1
fi

env -i \
  "HOME=$HOME" \
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" \
  xcodebuild \
    -project "$root/Vetty.xcodeproj" \
    -scheme Vetty \
    -configuration Release \
    "SYMROOT=$root/Vetty/build" \
    build
