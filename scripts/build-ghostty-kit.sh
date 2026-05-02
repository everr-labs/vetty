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

zig_bin="${VETTY_ZIG:-}"
if [[ -z "$zig_bin" && -x /opt/homebrew/opt/zig@0.15/bin/zig ]]; then
  zig_bin="/opt/homebrew/opt/zig@0.15/bin/zig"
fi
if [[ -z "$zig_bin" ]]; then
  zig_bin="$(command -v zig)"
fi

if [[ "$("$zig_bin" version)" != "0.15.2" ]]; then
  echo "GhosttyKit requires Zig 0.15.2. Set VETTY_ZIG=/path/to/zig-0.15.2 or install brew zig@0.15." >&2
  echo "Found $zig_bin version $("$zig_bin" version)." >&2
  exit 1
fi

optimize="${VETTY_GHOSTTY_OPTIMIZE:-ReleaseFast}"

(
  cd "$vendor"
  "$zig_bin" build \
    -Doptimize="$optimize" \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Dxcframework-target=native
)

rm -rf "$out/GhosttyKit.xcframework"
cp -R "$vendor/macos/GhosttyKit.xcframework" "$out/GhosttyKit.xcframework"

echo "Built Vetty/Frameworks/GhosttyKit.xcframework with -Doptimize=$optimize."
