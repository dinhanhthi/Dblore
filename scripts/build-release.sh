#!/bin/bash

# Build, sign, notarize and package Dblore as a Developer ID DMG.
# Used both locally and by CI. Output: dist/Dblore-<version>.dmg (+ .sha256)

set -euo pipefail

SCHEME="Dblore"
PROJECT="Dblore.xcodeproj"
TEAM_ID="86H6CNLN4C"
IDENTITY="Developer ID Application: Anh-Thi Dinh ($TEAM_ID)"
NOTARY_PROFILE="DbloreNotary"

usage() {
  cat <<EOF
Usage: scripts/build-release.sh [--skip-notarize] [--expect-version <version>]

  --skip-notarize           Skip notarization, stapling and Gatekeeper check
  --expect-version <v>      <v> is X.Y.Z. Fail unless MARKETING_VERSION equals it
  -h, --help                Show this help

Notarization uses the keychain profile "$NOTARY_PROFILE", or an App Store
Connect API key when NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID are set.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

# Print the top-level string field $1 of the JSON document on stdin.
json_field() {
  plutil -extract "$1" raw -o - - 2>/dev/null
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
if [[ -n "$EXPECT_VERSION" ]]; then
  [[ "$EXPECT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "--expect-version must be X.Y.Z (got $EXPECT_VERSION)"
  [[ "$EXPECT_VERSION" == "$VERSION" ]] ||
    fail "MARKETING_VERSION is $VERSION, expected $EXPECT_VERSION"
fi
DMG="$DIST/$SCHEME-$VERSION.dmg"
echo "==> Building $SCHEME $VERSION"

# Test hook. Never set during a real release: stop after the version check.
if [[ -n "${BUILD_RELEASE_DRY_RUN:-}" ]]; then
  echo "DMG=$DMG"
  exit 0
fi

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
# Both skip flags are needed (mlx-swift CudaBuild plugin + macros), and they are global to the
# invocation; the resolved-file-only options bound that exposure to the committed Package.resolved.
xcodebuild archive \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
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

# Submit $1 to Apple and wait. notarytool can exit 0 for a rejected submission;
# trust only the JSON status.
notarize() {
  local json id status
  json=$(xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait --output-format json) || true
  echo "$json"
  id=$(json_field id <<<"$json" || true)
  status=$(json_field status <<<"$json" || true)
  if [[ "$status" != "Accepted" ]]; then
    echo "error: notarization of $1 is '${status:-unknown}' (submission id: ${id:-unknown})" >&2
    if [[ -n "$id" ]]; then
      xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
    fi
    exit 1
  fi
}

# Staple the app itself before it goes into the DMG, so the copy users drag out
# (and the one Sparkle installs) passes Gatekeeper offline too.
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  echo "==> Notarizing the app"
  APP_ZIP="$EXPORT_DIR/$SCHEME.zip"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  notarize "$APP_ZIP"
  rm -f "$APP_ZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

echo "==> Creating $DMG"
# App plus an Applications shortcut, so users can drag it across
DMG_STAGE="$DIST/dmg-stage"
rm -rf "$DMG_STAGE" && mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/$SCHEME.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "$SCHEME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG"
rm -rf "$DMG_STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  echo "==> Notarizing the DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl -a -vvv -t install "$DMG"
else
  echo "==> Skipping notarization (--skip-notarize)"
fi

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "==> Done: $DMG"
