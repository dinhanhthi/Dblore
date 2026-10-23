#!/bin/bash

# Build a plugin artifact (--plugin <id>, default duckdb). For duckdb: download the
# pinned official libduckdb.dylib, verify its upstream SHA-256, re-sign it with the
# Developer ID (hardened runtime) and notarize it. --install-dev copies it into the
# gitignored .plugin-dev/ for tests; --publish (user-run only) uploads it to GitHub
# and rewrites that plugin's catalog entry, leaving the other entries as they are.
# For local-ai (not in the catalog yet, so never published): archive the DbloreLocalAI.bundle
# plugin (loaded in the app's process) from Plugins/LocalAI, re-sign it inside out, notarize it,
# staple it, and zip it into dist/plugins/local-ai/ with its source fingerprint (only when
# notarized); --install-dev also fills .plugin-dev/local-ai/.

set -euo pipefail

REPO="dinhanhthi/Dblore"
DUCKDB_VERSION="1.5.6"
ASSET_URL="https://github.com/duckdb/duckdb/releases/download/v$DUCKDB_VERSION/libduckdb-osx-universal.zip"
UPSTREAM_SHA256="e0bc007d9b0094c0970ac1847a8601d10aad07cbd2910ce586ec810f77b638d6"
TEAM_ID="86H6CNLN4C"
SIGN_IDENTITY="Developer ID Application: Anh-Thi Dinh ($TEAM_ID)"
NOTARY_PROFILE="DbloreNotary"
CATALOG="Dblore/Utilities/Plugins/PluginCatalog.json"
LOCAL_AI_DIR="Plugins/LocalAI"
LOCAL_AI_PROTOCOL="Dblore/Utilities/AI/LocalAIProtocol.swift"
LOCAL_AI_BUNDLE="DbloreLocalAI.bundle"
LOCAL_AI_ZIP="DbloreLocalAI.zip"

usage() {
  cat <<EOF
Usage: scripts/release-plugin.sh [--plugin <id>] [--install-dev] [--publish [--yes]] [--skip-notarize]
       scripts/release-plugin.sh --print-source-fingerprint

Builds the artifact of plugin <id>, signs it with "$SIGN_IDENTITY",
notarizes it and prints its SHA-256. Build recipes:
  duckdb    Downloads DuckDB $DUCKDB_VERSION (libduckdb-osx-universal.zip), verifies the
            upstream SHA-256 and re-signs libduckdb.dylib
  local-ai  Archives $LOCAL_AI_BUNDLE ($LOCAL_AI_DIR, version from project.yml), signs it
            inside out with no entitlements, staples it and prints its CDHash too. Once
            notarized, writes $LOCAL_AI_ZIP and source.sha256 to dist/plugins/local-ai/

  --plugin <id>     Plugin id in $CATALOG (default duckdb);
                    an id not in the catalog is refused, except local-ai
  --install-dev     duckdb: write the signed dylib, an ad-hoc-signed copy and dev-catalog.json
                    into .plugin-dev/ at the repo root. local-ai: write the zip, an
                    ad-hoc-signed zip and their own dev-catalog.json into .plugin-dev/local-ai/
  --publish         Upload to GitHub release plugin-<id>-v<version> (--latest=false) and
                    rewrite only the <id> entry of $CATALOG.
                    Manual, user-run only; afterwards
                    scripts/release-local.sh --check-plugin-only verifies the asset.
                    Refused for local-ai until catalog schema 3
  --yes             Skip the interactive confirmation of --publish
  --skip-notarize   Sign only (not allowed with --publish); local-ai leaves dist/ untouched
  --print-source-fingerprint
                    Print the local-ai source fingerprint (what source.sha256 holds) and exit
  -h, --help        Show this help
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

PLUGIN_ID="duckdb"
INSTALL_DEV=0
PUBLISH=0
ASSUME_YES=0
SKIP_NOTARIZE=0
PRINT_SOURCE_FINGERPRINT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin)
      [[ $# -ge 2 ]] || fail "--plugin requires a value"
      PLUGIN_ID="$2"
      shift
      ;;
    --install-dev) INSTALL_DEV=1 ;;
    --publish) PUBLISH=1 ;;
    --yes) ASSUME_YES=1 ;;
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --print-source-fingerprint) PRINT_SOURCE_FINGERPRINT=1 ;;
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
OUT_DIR="$PWD/.plugin-dev"

[[ $PUBLISH -eq 1 && $SKIP_NOTARIZE -eq 1 ]] && fail "--publish requires notarization; drop --skip-notarize"

# Prints the libraryFileName of catalog entry <id>; exits non-zero when the catalog is not
# schema version 2 or does not list <id> exactly once.
catalog_library_file_name() {
  python3 -I - "$1" "$2" <<'PY'
import json, sys
path, plugin_id = sys.argv[1:]
with open(path) as f:
    data = json.load(f)
if data.get("schemaVersion") != 2 or not isinstance(data.get("plugins"), list):
    sys.exit("not a schema version 2 catalog: " + path)
matches = [p for p in data["plugins"] if isinstance(p, dict) and p.get("id") == plugin_id]
if len(matches) != 1:
    sys.exit(1)
print(matches[0]["libraryFileName"])
PY
}

# Sets version, url and sha256 of catalog entry <id> only, after checking them against the
# rules of PluginCatalog.swift; its other fields and the other entries are kept as they are.
rewrite_catalog_entry() {
  python3 -I - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, os, re, sys
path, plugin_id, version, url, sha = sys.argv[1:]
with open(path) as f:
    data = json.load(f)
if data.get("schemaVersion") != 2 or not isinstance(data.get("plugins"), list):
    sys.exit("not a schema version 2 catalog: " + path)
matches = [p for p in data["plugins"] if isinstance(p, dict) and p.get("id") == plugin_id]
if len(matches) != 1:
    sys.exit("plugin %s is not listed exactly once in %s" % (plugin_id, path))
entry = matches[0]
library = entry.get("libraryFileName", "")
if not re.fullmatch(r"[0-9]+(\.[0-9]+)*", version):
    sys.exit("invalid version: " + version)
if not re.fullmatch(r"[0-9a-f]{64}", sha):
    sys.exit("invalid sha256: " + sha)
asset = r"https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/releases/download/%s/%s" % (
    re.escape("plugin-%s-v%s" % (plugin_id, version)), re.escape(library))
if not re.fullmatch(asset, url):
    sys.exit("url is not the release asset plugin-%s-v%s/%s: %s" % (plugin_id, version, library, url))
entry.update({"version": version, "url": url, "sha256": sha})
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

# Prints the source fingerprint of the local-ai plugin, from the repo root: one SHA-256 over
#   { find Plugins/LocalAI -type f -not -path '*/xcuserdata/*' -not -name .DS_Store -print0
#     printf '%s\0' Dblore/Utilities/AI/LocalAIProtocol.swift   # only when it exists
#   } | xargs -0 shasum -a 256 | LC_ALL=C sort | shasum -a 256
local_ai_source_fingerprint() {
  [[ -d "$LOCAL_AI_DIR" ]] || fail "$LOCAL_AI_DIR not found"
  {
    find "$LOCAL_AI_DIR" -type f -not -path '*/xcuserdata/*' -not -name .DS_Store -print0
    if [[ -f "$LOCAL_AI_PROTOCOL" ]]; then printf '%s\0' "$LOCAL_AI_PROTOCOL"; fi
  } | xargs -0 shasum -a 256 | LC_ALL=C sort | shasum -a 256 | awk '{ print $1 }'
}

# Zips the bundle <bundle> into <zip> the way the plugin asset is shipped.
zip_bundle() {
  ditto -c -k --keepParent --norsrc --noextattr --noacl "$1" "$2"
}

# The local-ai recipe: archive DbloreLocalAI.bundle, sign it inside out with the Developer ID and
# no entitlements (a loaded bundle runs with the app's), check the signature, notarize and staple
# it (unless --skip-notarize), then zip it into dist/plugins/local-ai/ (only when notarized) and,
# with --install-dev, into .plugin-dev/local-ai/.
release_local_ai() {
  local source_fp archive bundle exe item links archs kind exports symbol sig_info cdhash
  local notary_zip notary_json notary_id notary_status staple_output gatekeeper cdhash_stapled
  local notarized=false stapled=false zip zip_sha zip_size dist_dir dev_dir adhoc_bundle
  source_fp=$(local_ai_source_fingerprint)

  WORK_DIR=$(mktemp -d -t dblore-plugin)
  archive="$WORK_DIR/DbloreLocalAI.xcarchive"
  bundle="$WORK_DIR/$LOCAL_AI_BUNDLE"
  exe="$bundle/Contents/MacOS/DbloreLocalAI"

  # archive (not build) strips the executable (non-global: the C entry points stay exported).
  # The default DerivedData is kept, as for the app, so the package checkouts (mlx-swift's
  # submodules too) are reused instead of fetched again. Both skip flags are needed (mlx-swift
  # CudaBuild plugin + macros); the resolved-file-only options bound that exposure to the
  # plugin's committed Package.resolved. ARCHS=arm64 also applies to the package targets, which
  # would otherwise build an unused x86_64 slice too.
  echo "==> Archiving $LOCAL_AI_BUNDLE $PLUGIN_VERSION"
  xcodebuild archive \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    -project "$LOCAL_AI_DIR/DbloreLocalAI.xcodeproj" \
    -scheme DbloreLocalAI \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive" \
    ARCHS=arm64 ||
    fail "xcodebuild archive failed"
  # project.yml installs the bundle in Library/Bundles (SKIP_INSTALL = NO)
  [[ -d "$archive/Products/Library/Bundles/$LOCAL_AI_BUNDLE" ]] ||
    fail "$LOCAL_AI_BUNDLE not found in $archive/Products/Library/Bundles"
  ditto "$archive/Products/Library/Bundles/$LOCAL_AI_BUNDLE" "$bundle"

  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")" == "$PLUGIN_VERSION" ]] ||
    fail "$LOCAL_AI_BUNDLE is not version $PLUGIN_VERSION; regenerate the project from project.yml (xcodegen generate)"
  links=$(find "$bundle" -type l)
  [[ -z "$links" ]] || fail "$LOCAL_AI_BUNDLE contains symlinks:"$'\n'"$links"

  # Inside out: nested Mach-O files (the main executable goes with the bundle), then nested
  # bundles deepest first, then the bundle itself. Never --deep for signing.
  echo "==> Signing inside out"
  while IFS= read -r -d '' item; do
    [[ "$item" != "$exe" && "$(file -b "$item")" == Mach-O* ]] || continue
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$item"
  done < <(find "$bundle/Contents" -type f -print0)
  while IFS= read -r item; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$item"
  done < <(find "$bundle/Contents" -type d \( -name '*.bundle' -o -name '*.framework' -o -name '*.app' \
    -o -name '*.appex' -o -name '*.xpc' \) | awk -F/ '{ print NF "\t" $0 }' | sort -rn | cut -f2-)
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$bundle"

  echo "==> Checking the signature"
  codesign --verify --strict --deep "$bundle" || fail "codesign --verify --strict --deep failed"
  sig_info=$(codesign -dvvv "$bundle" 2>&1)
  grep -qx "TeamIdentifier=$TEAM_ID" <<<"$sig_info" || fail "signature TeamIdentifier is not $TEAM_ID"
  grep -q '^CodeDirectory .*flags=.*runtime' <<<"$sig_info" ||
    fail "signature lacks the hardened runtime flag"
  codesign -d --entitlements - --xml "$bundle" 2>/dev/null | python3 -I -c '
import plistlib, sys
data = sys.stdin.buffer.read()
if data.strip():
    try:
        ents = plistlib.loads(data)
    except Exception as error:
        sys.exit("unreadable entitlements: %s" % error)
    if ents != {}:
        sys.exit("entitlements: %r" % ents)
' || fail "$LOCAL_AI_BUNDLE must carry no entitlements"
  archs=$(lipo -archs "$exe")
  [[ "$archs" == "arm64" ]] || fail "the main executable must be arm64 only (has: $archs)"
  kind=$(file -b "$exe")
  [[ "$kind" == "Mach-O 64-bit bundle arm64" ]] || fail "the main executable is not a Mach-O bundle: $kind"
  exports=$(nm -gU "$exe")
  for symbol in _dblore_localai_protocol _dblore_localai_request; do
    grep -q " T $symbol\$" <<<"$exports" || fail "the main executable does not export $symbol"
  done
  cdhash=$(sed -n 's/^CDHash=//p' <<<"$sig_info")
  [[ "$cdhash" =~ ^[0-9a-f]{40}$ ]] || fail "unexpected CDHash: $cdhash"

  if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    echo "==> Notarizing (this can take several minutes)"
    notary_zip="$WORK_DIR/DbloreLocalAI-notarize.zip"
    ditto -c -k --keepParent "$bundle" "$notary_zip"
    notary_json=$(xcrun notarytool submit "$notary_zip" --keychain-profile "$NOTARY_PROFILE" \
      --wait --output-format json) || fail "notarytool submit failed: $notary_json"
    notary_id=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' <<<"$notary_json")
    notary_status=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' <<<"$notary_json")
    echo "notarization: $notary_status (submission $notary_id)"
    [[ "$notary_status" == "Accepted" ]] ||
      fail "notarization not accepted. Log: xcrun notarytool log $notary_id --keychain-profile $NOTARY_PROFILE"
    notarized=true

    echo "==> Stapling"
    staple_output=$(xcrun stapler staple "$bundle" 2>&1) || fail "stapling failed: $staple_output"
    echo "$staple_output"
    staple_output=$(xcrun stapler validate "$bundle" 2>&1) ||
      fail "stapling failed: stapler validate: $staple_output"
    echo "$staple_output"
    cdhash_stapled=$(codesign -dvvv "$bundle" 2>&1 | sed -n 's/^CDHash=//p')
    echo "cdhash before stapling: $cdhash"
    echo "cdhash after stapling:  $cdhash_stapled"
    [[ "$cdhash_stapled" == "$cdhash" ]] || fail "stapling changed the CDHash"
    stapled=true
    # Informational only: spctl has no assessment type made for a loadable bundle.
    gatekeeper=$(spctl --assess --type open --context context:primary-signature -vv "$bundle" 2>&1) || true
    echo "spctl --type open (informational): $gatekeeper"
  else
    echo "==> Skipping notarization (--skip-notarize): not stapled"
  fi

  zip="$WORK_DIR/$LOCAL_AI_ZIP"
  zip_bundle "$bundle" "$zip"
  zip_sha=$(shasum -a 256 "$zip" | awk '{ print $1 }')
  zip_size=$(stat -f %z "$zip")
  echo "$LOCAL_AI_ZIP sha256: $zip_sha"
  echo "$LOCAL_AI_BUNDLE cdhash: $cdhash"
  echo "$LOCAL_AI_ZIP size: $zip_size bytes"

  # Only a notarized zip goes to dist/: a sign-only run never replaces it.
  if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    dist_dir="$PWD/dist/plugins/local-ai"
    mkdir -p "$dist_dir"
    cp "$zip" "$dist_dir/$LOCAL_AI_ZIP"
    echo "$source_fp" >"$dist_dir/source.sha256"
    echo "dist: $dist_dir/$LOCAL_AI_ZIP (source fingerprint $source_fp)"
  else
    echo "==> Skipping dist/plugins/local-ai/ (--skip-notarize): left untouched"
  fi

  if [[ $INSTALL_DEV -eq 1 ]]; then
    dev_dir="$OUT_DIR/local-ai"
    echo "==> Installing dev artifacts into $dev_dir"
    mkdir -p "$dev_dir"
    cp "$zip" "$dev_dir/$LOCAL_AI_ZIP"
    # Same bundle signed ad hoc: the app's bundle check must reject it.
    adhoc_bundle="$WORK_DIR/adhoc/$LOCAL_AI_BUNDLE"
    mkdir "$WORK_DIR/adhoc"
    ditto "$bundle" "$adhoc_bundle"
    codesign --force --deep --sign - "$adhoc_bundle"
    zip_bundle "$adhoc_bundle" "$dev_dir/DbloreLocalAI-adhoc.zip"
    python3 -I - "$dev_dir/dev-catalog.json" "$PLUGIN_VERSION" "$zip_sha" "$cdhash" \
      "$LOCAL_AI_BUNDLE" "$dev_dir/$LOCAL_AI_ZIP" "$dev_dir/DbloreLocalAI-adhoc.zip" "$notarized" \
      "$stapled" <<'PY'
import json, sys
out, version, sha, cdhash, bundle, zip_path, adhoc, notarized, stapled = sys.argv[1:]
with open(out, "w") as f:
    json.dump({"version": version, "sha256": sha, "cdhash": cdhash, "bundleName": bundle,
               "zipPath": zip_path, "adhocZipPath": adhoc, "notarized": notarized == "true",
               "stapled": stapled == "true"}, f, indent=2)
    f.write("\n")
PY
    echo "dev catalog: $dev_dir/dev-catalog.json"
  fi
}

if [[ $PRINT_SOURCE_FINGERPRINT -eq 1 ]]; then
  local_ai_source_fingerprint
  exit 0
fi

[[ "$PLUGIN_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "invalid plugin id: $PLUGIN_ID"
[[ -f "$CATALOG" ]] || fail "$CATALOG not found"
# local-ai gets its catalog entry with catalog schema 3
if [[ "$PLUGIN_ID" != "local-ai" ]]; then
  LIBRARY_FILE_NAME=$(catalog_library_file_name "$CATALOG" "$PLUGIN_ID") ||
    fail "plugin $PLUGIN_ID is not in $CATALOG"
fi

case "$PLUGIN_ID" in
  duckdb)
    PLUGIN_VERSION="$DUCKDB_VERSION"
    [[ "$LIBRARY_FILE_NAME" == "libduckdb.dylib" ]] ||
      fail "$CATALOG names $LIBRARY_FILE_NAME for duckdb; the build produces libduckdb.dylib"
    ;;
  local-ai)
    [[ $PUBLISH -eq 1 ]] && fail "local-ai publishing arrives with catalog schema 3"
    PLUGIN_VERSION=$(awk '$1 == "MARKETING_VERSION:" { print $2 }' "$LOCAL_AI_DIR/project.yml")
    [[ "$PLUGIN_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] ||
      fail "$LOCAL_AI_DIR/project.yml needs exactly one MARKETING_VERSION (got: $PLUGIN_VERSION)"
    ;;
  *)
    fail "plugin $PLUGIN_ID has no build recipe in scripts/release-plugin.sh (only duckdb and local-ai have one)"
    ;;
esac
TAG="plugin-$PLUGIN_ID-v$PLUGIN_VERSION"

WORK_DIR=""
cleanup() {
  [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
  return 0
}
trap cleanup EXIT

echo "==> Preflight"
identities=$(security find-identity -v -p codesigning)
grep -qF "$SIGN_IDENTITY" <<<"$identities" || fail "signing identity not found: $SIGN_IDENTITY"

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 ||
    fail "notary profile $NOTARY_PROFILE not found (or use --skip-notarize)"
fi

if [[ $PUBLISH -eq 1 ]]; then
  gh auth status >/dev/null 2>&1 || fail "gh is not authenticated. Run: gh auth login"
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    fail "release $TAG already exists on $REPO"
  fi
  cat >&2 <<EOF

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! --publish creates a PUBLIC GitHub release $TAG on $REPO,
!! uploads $LIBRARY_FILE_NAME to it and rewrites the $PLUGIN_ID entry of $CATALOG.
!! Every user installing the $PLUGIN_ID plugin downloads this file.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

EOF
  if [[ $ASSUME_YES -eq 0 ]]; then
    [[ -t 0 ]] || fail "--publish needs an interactive terminal (or --yes)"
    read -r -p "Type yes to publish: " answer
    [[ "$answer" == "yes" ]] || fail "publish cancelled"
  fi
fi

if [[ "$PLUGIN_ID" == "local-ai" ]]; then
  release_local_ai
  echo "==> Done"
  exit 0
fi

WORK_DIR=$(mktemp -d -t dblore-plugin)
ZIP="$WORK_DIR/libduckdb-osx-universal.zip"
EXTRACT_DIR="$WORK_DIR/extract"
DYLIB="$WORK_DIR/libduckdb.dylib"

echo "==> Downloading DuckDB $DUCKDB_VERSION"
curl -fL --proto '=https' --proto-redir '=https' -o "$ZIP" "$ASSET_URL"
actual_sha=$(shasum -a 256 "$ZIP" | awk '{ print $1 }')
[[ "$actual_sha" == "$UPSTREAM_SHA256" ]] ||
  fail "upstream SHA-256 mismatch: expected $UPSTREAM_SHA256, got $actual_sha"

mkdir "$EXTRACT_DIR"
unzip -q "$ZIP" libduckdb.dylib -d "$EXTRACT_DIR"
[[ -f "$EXTRACT_DIR/libduckdb.dylib" && ! -L "$EXTRACT_DIR/libduckdb.dylib" ]] ||
  fail "libduckdb.dylib not found in the zip"
cp "$EXTRACT_DIR/libduckdb.dylib" "$DYLIB"

archs=$(lipo -archs "$DYLIB")
for arch in arm64 x86_64; do
  [[ " $archs " == *" $arch "* ]] || fail "libduckdb.dylib lacks $arch (has: $archs)"
done

echo "==> Signing ($archs)"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$DYLIB"
codesign --verify --strict "$DYLIB" || fail "codesign --verify failed"
sig_info=$(codesign -dv --verbose=2 "$DYLIB" 2>&1)
grep -qx "TeamIdentifier=$TEAM_ID" <<<"$sig_info" || fail "signature TeamIdentifier is not $TEAM_ID"
grep -q 'flags=.*runtime' <<<"$sig_info" || fail "signature lacks the hardened runtime flag"

NOTARIZED=false
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  # A bare dylib cannot be stapled: the ticket lives with Apple and Gatekeeper
  # looks it up online, so only the zip is submitted and nothing is stapled.
  echo "==> Notarizing (this can take several minutes)"
  NOTARY_ZIP="$WORK_DIR/libduckdb-notarize.zip"
  ditto -c -k --norsrc --noextattr "$DYLIB" "$NOTARY_ZIP"
  notary_json=$(xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json) || fail "notarytool submit failed: $notary_json"
  notary_id=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' <<<"$notary_json")
  notary_status=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' <<<"$notary_json")
  echo "notarization: $notary_status (submission $notary_id)"
  [[ "$notary_status" == "Accepted" ]] ||
    fail "notarization not accepted. Log: xcrun notarytool log $notary_id --keychain-profile $NOTARY_PROFILE"
  NOTARIZED=true
fi

DYLIB_SHA256=$(shasum -a 256 "$DYLIB" | awk '{ print $1 }')
echo "signed libduckdb.dylib sha256: $DYLIB_SHA256"

if [[ $INSTALL_DEV -eq 1 ]]; then
  echo "==> Installing dev artifacts into $OUT_DIR"
  mkdir -p "$OUT_DIR"
  cp "$DYLIB" "$OUT_DIR/libduckdb.dylib"
  # Same library signed ad hoc: the app's library validation must reject it.
  cp "$DYLIB" "$OUT_DIR/libduckdb-adhoc.dylib"
  codesign --force -s - "$OUT_DIR/libduckdb-adhoc.dylib"
  python3 -I - "$OUT_DIR/dev-catalog.json" "$DUCKDB_VERSION" "$DYLIB_SHA256" \
    "$OUT_DIR/libduckdb.dylib" "$OUT_DIR/libduckdb-adhoc.dylib" "$NOTARIZED" <<'PY'
import json, sys
out, version, sha, path, adhoc, notarized = sys.argv[1:]
with open(out, "w") as f:
    json.dump({"version": version, "sha256": sha, "path": path, "adhocPath": adhoc,
               "notarized": notarized == "true"}, f, indent=2)
    f.write("\n")
PY
  echo "dev catalog: $OUT_DIR/dev-catalog.json"
fi

if [[ $PUBLISH -eq 1 ]]; then
  echo "==> Publishing GitHub release $TAG"
  PUBLISH_DIR="$WORK_DIR/publish"
  mkdir "$PUBLISH_DIR"
  cp "$DYLIB" "$PUBLISH_DIR/libduckdb.dylib"
  (cd "$PUBLISH_DIR" && shasum -a 256 libduckdb.dylib >libduckdb.dylib.sha256)
  # --latest=false keeps releases/latest pointing at the app DMG.
  gh release create "$TAG" "$PUBLISH_DIR/libduckdb.dylib" "$PUBLISH_DIR/libduckdb.dylib.sha256" \
    --repo "$REPO" --latest=false \
    --title "DuckDB plugin $DUCKDB_VERSION" \
    --notes "Official DuckDB $DUCKDB_VERSION libduckdb.dylib (upstream sha256 $UPSTREAM_SHA256), re-signed with Developer ID ($TEAM_ID) and notarized. Signed sha256: $DYLIB_SHA256" ||
    fail "gh release create failed; the catalog was not changed"

  url="https://github.com/$REPO/releases/download/$TAG/$LIBRARY_FILE_NAME"
  rewrite_catalog_entry "$CATALOG" "$PLUGIN_ID" "$PLUGIN_VERSION" "$url" "$DYLIB_SHA256" ||
    fail "release $TAG is published but rewriting $CATALOG failed; set the $PLUGIN_ID entry by hand (url $url, sha256 $DYLIB_SHA256)"
  echo "release: $(gh release view "$TAG" --repo "$REPO" --json url -q .url)"
  echo "updated the $PLUGIN_ID entry of $CATALOG; review and commit it, then run scripts/release-local.sh --check-plugin-only --plugin $PLUGIN_ID"
fi

echo "==> Done"
