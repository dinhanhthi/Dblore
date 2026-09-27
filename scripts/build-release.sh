#!/bin/bash

# Build, sign, notarize and package SQLNotebook as a Developer ID DMG.
# Used both locally and by CI. Output: dist/SQLNotebook-<version>.dmg (+ .sha256)

set -euo pipefail

SCHEME="SQLNotebook"
PROJECT="SQLNoteBook.xcodeproj"
TEAM_ID="86H6CNLN4C"
IDENTITY="Developer ID Application: Anh-Thi Dinh ($TEAM_ID)"
NOTARY_PROFILE="SQLNotebookNotary"

usage() {
  cat <<EOF
Usage: scripts/build-release.sh [--skip-notarize] [--expect-version <version>]

  --skip-notarize           Skip notarization, stapling and Gatekeeper check
  --expect-version <v>      Fail unless MARKETING_VERSION equals <v>
  -h, --help                Show this help

Notarization uses the keychain profile "$NOTARY_PROFILE", or an App Store
Connect API key when NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID are set.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

SKIP_NOTARIZE=0
EXPECT_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --expect-version)
      [[ $# -ge 2 ]] || fail "--expect-version requires a value"
      EXPECT_VERSION="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
  shift
done

cd "$(dirname "$0")/.."

DIST="dist"
ARCHIVE="$DIST/archive/$SCHEME.xcarchive"
EXPORT_DIR="$DIST/export"
APP="$EXPORT_DIR/$SCHEME.app"

VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *MARKETING_VERSION = / { print $2; exit }')
[[ -n "$VERSION" ]] || fail "could not read MARKETING_VERSION from build settings"
if [[ -n "$EXPECT_VERSION" && "$EXPECT_VERSION" != "$VERSION" ]]; then
  fail "MARKETING_VERSION is $VERSION, expected $EXPECT_VERSION"
fi
DMG="$DIST/$SCHEME-$VERSION.dmg"
echo "==> Building $SCHEME $VERSION"

# Check notarization credentials before the long build
NOTARY_AUTH=()
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  if [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
    NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  else
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null ||
      fail "notary credentials not found. Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id $TEAM_ID"
  fi
fi

rm -rf "$DIST/archive" "$EXPORT_DIR" "$DMG" "$DMG.sha256"
mkdir -p "$DIST"

# Ship from archive + exportArchive only: a plain Release build injects get-task-allow
echo "==> Archiving"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE"

echo "==> Exporting"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$EXPORT_DIR"
[[ -d "$APP" ]] || fail "exported app not found at $APP"

if codesign -d --entitlements - "$APP" 2>/dev/null | grep get-task-allow >/dev/null; then
  fail "exported app has the get-task-allow entitlement; notarization would reject it"
fi

echo "==> Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Creating $DMG"
hdiutil create -volname "$SCHEME" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  echo "==> Notarizing"
  xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple "$DMG"
  spctl -a -vvv -t install "$DMG"
else
  echo "==> Skipping notarization (--skip-notarize)"
fi

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "==> Done: $DMG"
