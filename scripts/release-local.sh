#!/bin/bash

# Release Dblore from this Mac: build, notarize, sign the appcast, then tag,
# publish the GitHub release and push appcast.xml (which triggers pages.yml).
# Nothing is tagged or published unless the build and the signed appcast succeed.

set -euo pipefail

REPO="dinhanhthi/Dblore"
SCHEME="Dblore"
PROJECT="Dblore.xcodeproj"
TEAM_ID="86H6CNLN4C"
IDENTITY="Developer ID Application: Anh-Thi Dinh ($TEAM_ID)"
NOTARY_PROFILE="DbloreNotary"
SPARKLE_ACCOUNT="sqlnotebook"
PLUGIN_CATALOG="Dblore/Utilities/Plugins/DuckDBPluginCatalog.json"

usage() {
  cat <<EOF
Usage: scripts/release-local.sh --expect-version <version> [--dry-run]
       scripts/release-local.sh --check-plugin-only

  --expect-version <v>      <v> is X.Y.Z, the version to release as tag v<v>
  --dry-run                 Run the preflight checks only (no build, tag or push)
  --check-plugin-only       Only check that the DuckDB plugin asset named in
                            $PLUGIN_CATALOG is published
                            and matches its SHA-256 (part of every preflight)
  -h, --help                Show this help
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

VERSION=""
DRY_RUN=0
CHECK_PLUGIN_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect-version)
      [[ $# -ge 2 ]] || fail "--expect-version requires a value"
      VERSION="$2"
      shift
      ;;
    --dry-run) DRY_RUN=1 ;;
    --check-plugin-only) CHECK_PLUGIN_ONLY=1 ;;
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

WORK_DIR=""
NOTES=""
PLUGIN_TMP=""
cleanup() {
  [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
  [[ -n "$NOTES" ]] && rm -f "$NOTES"
  [[ -n "$PLUGIN_TMP" ]] && rm -rf "$PLUGIN_TMP"
  return 0
}
trap cleanup EXIT

# The app installs the DuckDB plugin from the catalog URL only when its SHA-256
# matches, so never ship a catalog whose asset is missing or different.
check_plugin_asset() {
  echo "==> Checking the DuckDB plugin asset"
  [[ -f "$PLUGIN_CATALOG" ]] || fail "$PLUGIN_CATALOG not found"
  local version url expected_sha max_size http_code actual_sha
  version=$(plutil -extract version raw -o - "$PLUGIN_CATALOG") || fail "no version in $PLUGIN_CATALOG"
  url=$(plutil -extract url raw -o - "$PLUGIN_CATALOG") || fail "no url in $PLUGIN_CATALOG"
  expected_sha=$(plutil -extract sha256 raw -o - "$PLUGIN_CATALOG") || fail "no sha256 in $PLUGIN_CATALOG"
  max_size=$(plutil -extract maxSize raw -o - "$PLUGIN_CATALOG") || fail "no maxSize in $PLUGIN_CATALOG"
  [[ "$url" == https://* ]] || fail "plugin url in $PLUGIN_CATALOG is not https: $url"
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || fail "plugin sha256 in $PLUGIN_CATALOG is not 64 lowercase hex characters"
  [[ "$max_size" =~ ^[0-9]+$ ]] || fail "plugin maxSize in $PLUGIN_CATALOG is not an integer"

  PLUGIN_TMP=$(mktemp -d -t dblore-plugin-check)
  local curl_status=0
  http_code=$(curl -sSL --proto '=https' --proto-redir '=https' --max-filesize "$max_size" \
    --connect-timeout 20 --max-time 600 -w '%{http_code}' -o "$PLUGIN_TMP/asset" "$url") ||
    curl_status=$?
  [[ "$http_code" != "404" ]] ||
    fail "DuckDB plugin $version asset not published ($url returned HTTP 404) — run scripts/release-plugin.sh --publish, commit the updated catalog, then rerun"
  [[ $curl_status -eq 0 && "$http_code" == "200" ]] ||
    fail "could not download the DuckDB plugin asset $url (curl exit $curl_status, HTTP ${http_code:-none}; network error, timeout or larger than $max_size bytes)"
  actual_sha=$(shasum -a 256 "$PLUGIN_TMP/asset" | awk '{ print $1 }')
  [[ "$actual_sha" == "$expected_sha" ]] ||
    fail "DuckDB plugin SHA-256 mismatch: $PLUGIN_CATALOG has $expected_sha, the published asset is $actual_sha"
  echo "plugin: DuckDB $version asset matches $PLUGIN_CATALOG"
}

if [[ $CHECK_PLUGIN_ONLY -eq 1 ]]; then
  check_plugin_asset
  exit 0
fi

[[ -n "$VERSION" ]] || {
  usage >&2
  fail "--expect-version is required"
}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "--expect-version must be X.Y.Z (got $VERSION)"
TAG="v$VERSION"
DMG="dist/$SCHEME-$VERSION.dmg"

echo "==> Preflight for $TAG"

# Machine checks
expected_xcode=$(tr -d '[:space:]' <.xcode-version)
xcode_line=$(xcodebuild -version)
xcode_line=${xcode_line%%$'\n'*}
[[ "$xcode_line" == "Xcode $expected_xcode" ]] ||
  fail "selected Xcode is '$xcode_line', .xcode-version wants $expected_xcode"

identities=$(security find-identity -v -p codesigning)
grep -qF "$IDENTITY" <<<"$identities" || fail "signing identity not found: $IDENTITY"

if [[ -z "${NOTARY_KEY_PATH:-}" || -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" ]]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 ||
    fail "notary profile $NOTARY_PROFILE not found. Run once: xcrun notarytool store-credentials $NOTARY_PROFILE --key docs/AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER_ID>"
fi

# Sparkle's generate_keys stores the private key under this service
security find-generic-password -s "https://sparkle-project.org" -a "$SPARKLE_ACCOUNT" >/dev/null 2>&1 ||
  fail "Sparkle private key not found in the keychain (account $SPARKLE_ACCOUNT)"

gh auth status >/dev/null 2>&1 || fail "gh is not authenticated. Run: gh auth login"

# Repo checks
branch=$(git rev-parse --abbrev-ref HEAD)
[[ "$branch" == "main" ]] || fail "must release from main, on $branch"
[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean"
git fetch -q origin
release_sha=$(git rev-parse HEAD)
[[ "$release_sha" == "$(git rev-parse origin/main)" ]] || fail "HEAD is not origin/main; push or pull first"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists locally"
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null; then
  fail "tag $TAG already exists on origin"
fi

project_version=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *MARKETING_VERSION = / { print $2; exit }')
[[ "$project_version" == "$VERSION" ]] ||
  fail "MARKETING_VERSION is ${project_version:-missing}, expected $VERSION"

[[ -f CHANGELOG.md ]] || fail "CHANGELOG.md not found"
NOTES=$(mktemp -t dblore-release-notes)
awk -v heading="## $TAG" '
  found && /^## / { exit }
  found { print }
  $0 == heading || index($0, heading " ") == 1 { found = 1 }
' CHANGELOG.md >"$NOTES"
grep -q '[^[:space:]]' "$NOTES" || fail "CHANGELOG.md has no non-empty '## $TAG' section"

check_plugin_asset

if [[ $DRY_RUN -eq 1 ]]; then
  echo "dry run: preflight passed for $TAG"
  exit 0
fi

scripts/build-release.sh --expect-version "$VERSION"
[[ -f "$DMG" && -f "$DMG.sha256" ]] || fail "build did not produce $DMG and $DMG.sha256"

[[ "$(git rev-parse HEAD)" == "$release_sha" && -z "$(git status --porcelain)" ]] ||
  fail "source changed during build; nothing was published"
git fetch -q origin
[[ "$(git rev-parse origin/main)" == "$release_sha" ]] ||
  fail "origin/main moved during the build; nothing was published"

# Only this project's Sparkle artifact: another project's DerivedData may hold a different tool version.
generate_appcast=""
for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/Dblore-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast; do
  if [[ -f "$candidate" ]]; then
    generate_appcast="$candidate"
    break
  fi
done
[[ -n "$generate_appcast" ]] || fail "generate_appcast not found in DerivedData/Dblore-*; nothing was published"

# A wrong key still signs, but every client would reject the update: match it to the app's key.
generate_keys="$(dirname "$generate_appcast")/generate_keys"
[[ -f "$generate_keys" ]] || fail "generate_keys not found next to generate_appcast; nothing was published"
app_public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Dblore/Info.plist) ||
  fail "SUPublicEDKey not found in Dblore/Info.plist; nothing was published"
keychain_public_key=$("$generate_keys" --account "$SPARKLE_ACCOUNT" -p) ||
  fail "could not read the Sparkle public key (account $SPARKLE_ACCOUNT); nothing was published"
[[ -n "$app_public_key" && "$keychain_public_key" == "$app_public_key" ]] ||
  fail "Sparkle key for account $SPARKLE_ACCOUNT does not match SUPublicEDKey in Dblore/Info.plist; nothing was published"

echo "==> Generating appcast (approve the keychain prompt with \"Always Allow\")"
WORK_DIR=$(mktemp -d -t dblore-appcast)
cp appcast.xml "$WORK_DIR/"
cp "$DMG" "$WORK_DIR/"
"$generate_appcast" "$WORK_DIR" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --full-release-notes-url "https://github.com/$REPO/releases"
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$WORK_DIR/appcast.xml" ||
  fail "appcast.xml has no item for $VERSION; nothing was published"
grep -q 'sparkle:edSignature=' "$WORK_DIR/appcast.xml" ||
  fail "appcast.xml has no EdDSA signature; nothing was published"

echo "==> Tagging $TAG at $release_sha"
git tag -a "$TAG" -m "$SCHEME $VERSION" "$release_sha"
git push origin "refs/tags/$TAG"

echo "==> Creating GitHub release $TAG"
gh release create "$TAG" "$DMG" "$DMG.sha256" --title "$SCHEME $VERSION" --notes-file "$NOTES" ||
  fail "tag $TAG is pushed but the release failed. Never delete the tag; rerun:
  gh release create $TAG $DMG $DMG.sha256 --title \"$SCHEME $VERSION\" --notes-file <notes>"

echo "==> Publishing appcast"
cp "$WORK_DIR/appcast.xml" appcast.xml
git add appcast.xml
git commit -m "chore(release): appcast v$VERSION"
# This push triggers pages.yml
git push origin main ||
  fail "release $TAG is published but pushing appcast.xml failed; rerun: git pull --rebase origin main && git push origin main"

echo "==> Done"
echo "release: $(gh release view "$TAG" --json url -q .url)"
echo "feed:    https://dinhanhthi.github.io/Dblore/appcast.xml"
