#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ghostty_kit="$root/Vetty/Frameworks/GhosttyKit.xcframework"

team_id="${VETTY_TEAM_ID:-6R3U885H6A}"
notary_profile="${VETTY_NOTARY_PROFILE:-vetty-notary}"
archs="${VETTY_ARCHS:-arm64}"
archive_code_sign_identity="${VETTY_ARCHIVE_CODE_SIGN_IDENTITY:-Apple Development}"
release_stamp="${VETTY_RELEASE_STAMP:-$(date +%Y%m%d-%H%M%S)}"
release_dir="${VETTY_RELEASE_DIR:-$root/build/release-$release_stamp}"

archive_path="$release_dir/Vetty.xcarchive"
export_path="$release_dir/export"
app_path="$export_path/Vetty.app"
export_options_plist="$release_dir/ExportOptions.plist"
notary_upload_zip="$release_dir/Vetty-notary-upload.zip"
notary_submit_log="$release_dir/notary-submit.json"
final_zip="$release_dir/Vetty-notarized.zip"
verify_dir="$release_dir/verify-final-zip"

xcode_path="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
metadata_entry_pattern='(^|/)(__MACOSX|\.DS_Store|\._)'

create_zip_without_macos_metadata() {
  local source_path="$1"
  local zip_path="$2"

  # Resource forks and extended metadata become ._ AppleDouble files in zip
  # archives. Those files can break nested code signatures when users extract
  # with common non-ditto unzip tools.
  DITTONORSRC=1 ditto -c -k --norsrc --keepParent "$source_path" "$zip_path"

  if zipinfo -1 "$zip_path" | /usr/bin/grep -Eq "$metadata_entry_pattern"; then
    echo "Zip contains macOS metadata files that can invalidate code signatures:" >&2
    zipinfo -1 "$zip_path" | /usr/bin/grep -E "$metadata_entry_pattern" | sed -n '1,40p' >&2
    exit 1
  fi
}

if [[ ! -d "$ghostty_kit" ]]; then
  echo "Missing Vetty/Frameworks/GhosttyKit.xcframework." >&2
  echo "This script does not rebuild GhosttyKit. Run scripts/build-ghostty-kit.sh first." >&2
  exit 1
fi

if [[ -z "$team_id" ]]; then
  echo "Missing Apple Developer Team ID." >&2
  echo "Set VETTY_TEAM_ID, for example: VETTY_TEAM_ID=6R3U885H6A scripts/build-vetty-release.sh" >&2
  exit 1
fi

echo "Checking notarization keychain profile '$notary_profile'..."
xcrun notarytool history \
  --keychain-profile "$notary_profile" \
  --output-format json \
  >/dev/null

mkdir -p "$release_dir"
rm -rf "$archive_path" "$export_path" "$verify_dir"
rm -f "$export_options_plist" "$notary_upload_zip" "$notary_submit_log" "$final_zip"

echo "Release output: $release_dir"
echo "Archiving Vetty..."
env -i \
  "HOME=$HOME" \
  "PATH=$xcode_path" \
  xcodebuild \
    -project "$root/Vetty.xcodeproj" \
    -scheme Vetty \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$archive_path" \
    DEVELOPMENT_TEAM="$team_id" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="$archive_code_sign_identity" \
    ARCHS="$archs" \
    -allowProvisioningUpdates \
    archive

echo "Writing export options..."
/usr/bin/plutil -create xml1 "$export_options_plist"
/usr/bin/plutil -insert method -string developer-id "$export_options_plist"
/usr/bin/plutil -insert teamID -string "$team_id" "$export_options_plist"
/usr/bin/plutil -insert signingStyle -string automatic "$export_options_plist"
/usr/bin/plutil -insert destination -string export "$export_options_plist"

echo "Exporting Developer ID signed app..."
env -i \
  "HOME=$HOME" \
  "PATH=$xcode_path" \
  xcodebuild \
    -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$export_options_plist" \
    -allowProvisioningUpdates

echo "Verifying Developer ID signature..."
codesign --verify --deep --strict --verbose=2 "$app_path"

echo "Creating notarization upload zip..."
create_zip_without_macos_metadata "$app_path" "$notary_upload_zip"

echo "Submitting app for notarization..."
xcrun notarytool submit "$notary_upload_zip" \
  --keychain-profile "$notary_profile" \
  --wait \
  --output-format json \
  | tee "$notary_submit_log"

notary_status="$(/usr/bin/plutil -extract status raw -o - "$notary_submit_log")"
if [[ "$notary_status" != "Accepted" ]]; then
  notary_id="$(/usr/bin/plutil -extract id raw -o - "$notary_submit_log" 2>/dev/null || true)"
  echo "Notarization finished with status '$notary_status'." >&2
  if [[ -n "$notary_id" ]]; then
    echo "Fetch the detailed log with:" >&2
    echo "xcrun notarytool log $notary_id --keychain-profile $notary_profile" >&2
  fi
  exit 1
fi

echo "Stapling notarization ticket..."
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"

echo "Creating final notarized zip..."
create_zip_without_macos_metadata "$app_path" "$final_zip"

echo "Verifying final zip contents..."
mkdir -p "$verify_dir"
/usr/bin/unzip -q "$final_zip" -d "$verify_dir"
xcrun stapler validate "$verify_dir/Vetty.app"
codesign --verify --deep --strict --verbose=2 "$verify_dir/Vetty.app"

if command -v syspolicy_check >/dev/null 2>&1; then
  syspolicy_check distribution "$verify_dir/Vetty.app"
else
  spctl -a -vvv -t execute "$verify_dir/Vetty.app"
fi

echo "Release zip ready:"
echo "$final_zip"
