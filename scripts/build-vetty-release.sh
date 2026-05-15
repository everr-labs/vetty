#!/usr/bin/env bash
set -euo pipefail

# Build, sign, notarize, and package Vetty.app as a notarized DMG.
#
# This script intentionally does NOT depend on the Xcode project's signing
# configuration. xcodebuild produces an unsigned bundle and every binary is
# signed manually with `codesign` from the inside out. That way the signing
# identity, entitlements, and hardened-runtime flags are owned by this script
# and a stray Xcode setting can't silently change what ships.
#
# Required environment:
#   VETTY_SIGN_IDENTITY  Developer ID Application identity. Accepts any string
#                        `codesign --sign` accepts (common name, SHA-1 hash, or
#                        partial name). Example:
#                          "Developer ID Application: Jane Doe (6R3U885H6A)"
#
# Optional environment:
#   VETTY_TEAM_ID         Apple Developer Team ID. Default: 6R3U885H6A
#   VETTY_NOTARY_PROFILE  notarytool keychain profile. Default: vetty-notary
#   VETTY_ARCHS           Architectures to build. Default: arm64
#   VETTY_ENTITLEMENTS    Path to entitlements plist for the main app binary.
#                         Default: Vetty/Resources/Vetty.entitlements
#   VETTY_RELEASE_STAMP   Suffix for the release directory. Default: timestamp
#   VETTY_RELEASE_DIR     Output directory. Default: build/release-<stamp>
#   VETTY_DMG_VOLNAME     DMG volume name. Default: Vetty
#   VETTY_RELEASE_TAG     Release tag (e.g. v0.2.0). Prompted if unset.
#   VETTY_RELEASE_TITLE   GitHub release title. Prompted if unset.
#   VETTY_RELEASE_NOTES   Optional release notes body. Falls back to autogen.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ghostty_kit="$root/Vetty/Frameworks/GhosttyKit.xcframework"

# Auto-load .env from the repo root. Values already present in the environment
# take precedence, so `VETTY_FOO=bar scripts/build-vetty-release.sh` still wins.
env_file="${VETTY_ENV_FILE:-$root/.env}"
if [[ -f "$env_file" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ "${val:0:1}" == '"' && "${val: -1}" == '"' ]]; then
      val="${val:1:${#val}-2}"
    elif [[ "${val:0:1}" == "'" && "${val: -1}" == "'" ]]; then
      val="${val:1:${#val}-2}"
    fi
    if [[ -z "${!key+x}" ]]; then
      export "$key=$val"
    fi
  done < "$env_file"
fi

sign_identity="${VETTY_SIGN_IDENTITY:-}"
team_id="${VETTY_TEAM_ID:-6R3U885H6A}"
notary_profile="${VETTY_NOTARY_PROFILE:-vetty-notary}"
archs="${VETTY_ARCHS:-arm64}"
entitlements="${VETTY_ENTITLEMENTS:-$root/Vetty/Resources/Vetty.entitlements}"
release_stamp="${VETTY_RELEASE_STAMP:-$(date +%Y%m%d-%H%M%S)}"
release_dir="${VETTY_RELEASE_DIR:-$root/build/release-$release_stamp}"
dmg_volname="${VETTY_DMG_VOLNAME:-Vetty}"

derived_data="$release_dir/DerivedData"
build_products="$derived_data/Build/Products/Release"
app_path="$build_products/Vetty.app"
notary_upload_zip="$release_dir/Vetty-notary-upload.zip"
notary_submit_log="$release_dir/notary-submit.json"
dmg_staging="$release_dir/dmg-staging"
dmg_path="$release_dir/Vetty.dmg"
dmg_notary_log="$release_dir/dmg-notary-submit.json"

xcode_path="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

if [[ ! -d "$ghostty_kit" ]]; then
  echo "Missing Vetty/Frameworks/GhosttyKit.xcframework." >&2
  echo "Run scripts/build-ghostty-kit.sh first." >&2
  exit 1
fi

if [[ -z "$sign_identity" ]]; then
  echo "Missing VETTY_SIGN_IDENTITY." >&2
  echo "Example:" >&2
  echo "  VETTY_SIGN_IDENTITY='Developer ID Application: Your Name ($team_id)' \\" >&2
  echo "    scripts/build-vetty-release.sh" >&2
  exit 1
fi

if [[ ! -f "$entitlements" ]]; then
  echo "Entitlements file not found: $entitlements" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required to publish the release." >&2
  exit 1
fi

release_tag="${VETTY_RELEASE_TAG:-}"
release_title="${VETTY_RELEASE_TITLE:-}"

echo "Most recent release:"
last_release_line="$(
  gh release list --limit 1 \
    --json tagName,name,publishedAt \
    --jq '.[0] | "  \(.tagName) — \(.name)  (\(.publishedAt))"' \
    2>/dev/null || true
)"
if [[ -n "$last_release_line" ]]; then
  echo "$last_release_line"
else
  echo "  (no previous GitHub releases)"
fi
echo

if [[ -z "$release_tag" ]]; then
  if [[ ! -t 0 ]]; then
    echo "VETTY_RELEASE_TAG is unset and stdin is not a TTY." >&2
    exit 1
  fi
  read -r -p "New release tag (e.g. v0.2.0): " release_tag
fi
release_tag="${release_tag#"${release_tag%%[![:space:]]*}"}"
release_tag="${release_tag%"${release_tag##*[![:space:]]}"}"
if [[ -z "$release_tag" ]]; then
  echo "Release tag cannot be empty." >&2
  exit 1
fi

if gh release view "$release_tag" >/dev/null 2>&1; then
  echo "GitHub release '$release_tag' already exists — choose a different tag." >&2
  exit 1
fi

if [[ -z "$release_title" ]]; then
  if [[ ! -t 0 ]]; then
    echo "VETTY_RELEASE_TITLE is unset and stdin is not a TTY." >&2
    exit 1
  fi
  read -r -p "Release title: " release_title
fi
release_title="${release_title#"${release_title%%[![:space:]]*}"}"
release_title="${release_title%"${release_title##*[![:space:]]}"}"
if [[ -z "$release_title" ]]; then
  echo "Release title cannot be empty." >&2
  exit 1
fi

echo "Checking notarization keychain profile '$notary_profile'..."
xcrun notarytool history \
  --keychain-profile "$notary_profile" \
  --output-format json \
  >/dev/null

mkdir -p "$release_dir"
rm -rf "$derived_data" "$dmg_staging"
rm -f "$notary_upload_zip" "$notary_submit_log" "$dmg_path" "$dmg_notary_log"

echo "Release output: $release_dir"
echo
echo "==> Building unsigned Vetty.app..."
env -i \
  "HOME=$HOME" \
  "PATH=$xcode_path" \
  xcodebuild \
    -project "$root/Vetty.xcodeproj" \
    -scheme Vetty \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$derived_data" \
    ARCHS="$archs" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

if [[ ! -d "$app_path" ]]; then
  echo "xcodebuild succeeded but $app_path is missing." >&2
  exit 1
fi

sign_item() {
  local item="$1"
  shift
  codesign \
    --force \
    --timestamp \
    --options runtime \
    --sign "$sign_identity" \
    "$@" \
    "$item"
}

echo
echo "==> Signing nested bundles and dylibs (inside-out)..."
# -depth walks deepest paths first so a framework's inner XPC services are
# signed before the enclosing framework, which is what codesign requires.
while IFS= read -r -d '' item; do
  rel="${item#"$app_path"/}"
  echo "  sign: $rel"
  sign_item "$item"
done < <(
  find -E "$app_path" -depth \
    -regex '.*\.(framework|bundle|plugin|app|appex|xpc|dylib|so)' \
    ! -path "$app_path" \
    -print0
)

echo
echo "==> Signing any remaining Mach-O binaries..."
# Catches command-line helpers or scripts shipped inside Resources/ that happen
# to be Mach-O. The main Vetty executable is signed last with entitlements.
main_binary="$app_path/Contents/MacOS/Vetty"
while IFS= read -r -d '' item; do
  [[ "$item" == "$main_binary" ]] && continue
  if /usr/bin/file -b "$item" | grep -qE '^Mach-O'; then
    rel="${item#"$app_path"/}"
    echo "  sign: $rel"
    sign_item "$item"
  fi
done < <(find "$app_path/Contents" -type f -print0)

echo
echo "==> Signing main Vetty.app with entitlements..."
sign_item "$app_path" --entitlements "$entitlements"

echo
echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$app_path"
codesign --display --verbose=4 --entitlements - "$app_path" \
  | grep -E '^(Identifier|TeamIdentifier|Authority|Sealed Resources|com\.apple\.security)' \
  || true

echo
echo "==> Creating notarization upload zip..."
# DITTONORSRC + --norsrc keep AppleDouble resource forks and ._ metadata
# files out of the zip; those entries can invalidate nested signatures when
# the user extracts with non-ditto tools.
DITTONORSRC=1 ditto -c -k --norsrc --keepParent "$app_path" "$notary_upload_zip"

echo
echo "==> Submitting app for notarization..."
xcrun notarytool submit "$notary_upload_zip" \
  --keychain-profile "$notary_profile" \
  --wait \
  --output-format json \
  | tee "$notary_submit_log"

notary_status="$(/usr/bin/plutil -extract status raw -o - "$notary_submit_log")"
if [[ "$notary_status" != "Accepted" ]]; then
  notary_id="$(/usr/bin/plutil -extract id raw -o - "$notary_submit_log" 2>/dev/null || true)"
  echo "App notarization finished with status '$notary_status'." >&2
  if [[ -n "$notary_id" ]]; then
    echo "Fetch the detailed log with:" >&2
    echo "  xcrun notarytool log $notary_id --keychain-profile $notary_profile" >&2
  fi
  exit 1
fi

echo
echo "==> Stapling notarization ticket to Vetty.app..."
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"

echo
echo "==> Building DMG..."
mkdir -p "$dmg_staging"
ditto "$app_path" "$dmg_staging/Vetty.app"
ln -s /Applications "$dmg_staging/Applications"

hdiutil create \
  -volname "$dmg_volname" \
  -srcfolder "$dmg_staging" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$dmg_path"

echo
echo "==> Signing DMG..."
codesign \
  --force \
  --timestamp \
  --sign "$sign_identity" \
  "$dmg_path"
codesign --verify --verbose=2 "$dmg_path"

echo
echo "==> Submitting DMG for notarization..."
xcrun notarytool submit "$dmg_path" \
  --keychain-profile "$notary_profile" \
  --wait \
  --output-format json \
  | tee "$dmg_notary_log"

dmg_status="$(/usr/bin/plutil -extract status raw -o - "$dmg_notary_log")"
if [[ "$dmg_status" != "Accepted" ]]; then
  dmg_id="$(/usr/bin/plutil -extract id raw -o - "$dmg_notary_log" 2>/dev/null || true)"
  echo "DMG notarization finished with status '$dmg_status'." >&2
  if [[ -n "$dmg_id" ]]; then
    echo "Fetch the detailed log with:" >&2
    echo "  xcrun notarytool log $dmg_id --keychain-profile $notary_profile" >&2
  fi
  exit 1
fi

echo
echo "==> Stapling notarization ticket to DMG..."
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"

echo
echo "==> Gatekeeper assessment..."
spctl -a -vvv -t open --context context:primary-signature "$dmg_path"

echo
echo "==> Creating GitHub release '$release_tag'..."
gh_release_args=(
  "$release_tag"
  --title "$release_title"
  --target "$(git -C "$root" rev-parse HEAD)"
)
if [[ -n "${VETTY_RELEASE_NOTES:-}" ]]; then
  gh_release_args+=(--notes "$VETTY_RELEASE_NOTES")
else
  gh_release_args+=(--generate-notes)
fi
gh_release_args+=("$dmg_path")
gh release create "${gh_release_args[@]}"

echo
echo "Release DMG ready:"
echo "  $dmg_path"
echo "Published GitHub release:"
gh release view "$release_tag" --json url --jq '"  \(.url)"'
