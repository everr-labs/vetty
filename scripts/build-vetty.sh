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
