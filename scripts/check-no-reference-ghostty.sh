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
[[ -f "$root/scripts/build-vetty.sh" ]] && paths+=("$root/scripts/build-vetty.sh")
[[ -f "$root/scripts/build-ghostty-kit.sh" ]] && paths+=("$root/scripts/build-ghostty-kit.sh")
[[ -f "$root/Package.swift" ]] && paths+=("$root/Package.swift")

if (( ${#paths[@]} > 0 )); then
  if rg -n --hidden --glob '!*.md' '/workspace/vetty/ghostty|\\.\\./ghostty|ghostty/macos|ghostty/src' "${paths[@]}" >/tmp/vetty-ghostty-reference-check.txt; then
    cat /tmp/vetty-ghostty-reference-check.txt >&2
    echo "Build-time references to the local ghostty/ reference clone are not allowed." >&2
    exit 1
  fi
fi

echo "No build-time references to local ghostty/ clone found."
