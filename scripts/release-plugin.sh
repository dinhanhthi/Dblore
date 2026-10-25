#!/bin/bash

# Build a plugin artifact (--plugin <id>, default duckdb). For duckdb: download the
# pinned official libduckdb.dylib, verify its upstream SHA-256, re-sign it with the
# Developer ID (hardened runtime) and notarize it. --install-dev copies it into the
# gitignored .plugin-dev/ for tests; --publish (user-run only) uploads it to GitHub
# and rewrites that plugin's catalog entry, leaving the other entries as they are.
# For local-ai: archive the DbloreLocalAI.bundle plugin (loaded in the app's process) from
# Plugins/LocalAI, re-sign it inside out, notarize it, staple it, and zip it into
# dist/plugins/local-ai/ with its source fingerprint (only when notarized); --install-dev also
# fills .plugin-dev/local-ai/. Its --publish (user-run only) never rebuilds and never rewrites
# the catalog: it uploads that zip only when it matches the catalog's local-ai entry.

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
LOCAL_AI_DIST="dist/plugins/local-ai"

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
                    an id not in the catalog is refused, except local-ai, which builds
                    without an entry
  --install-dev     duckdb: write the signed dylib, an ad-hoc-signed copy and dev-catalog.json
                    into .plugin-dev/ at the repo root. local-ai: write the zip, an
                    ad-hoc-signed zip and their own dev-catalog.json into .plugin-dev/local-ai/
  --publish         Upload to GitHub release plugin-<id>-v<version> (--latest=false).
                    Manual, user-run only; afterwards
                    scripts/release-local.sh --check-plugin-only verifies the asset.
                    duckdb: builds, uploads and rewrites only the duckdb entry of the catalog.
                    local-ai: no build, no catalog change; uploads
                    $LOCAL_AI_DIST/$LOCAL_AI_ZIP only when its SHA-256 is the entry's,
                    the bundle in it is signed under $TEAM_ID with the entry's cdhash,
                    and its source.sha256 is the current source fingerprint
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

# Prints the kind, asset, version, sha256 and url of catalog entry <id>, plus the cdhash for a
# bundle, tab-separated. The asset is the libraryFileName, or <Name>.zip for a <Name>.bundle.
# Exits 3 when the catalog does not list <id>, and 1 when it is not schema version 3, lists <id>
# twice, or the entry has an unknown kind or a missing field.
catalog_entry() {
  python3 -I - "$1" "$2" <<'PY'
import json, re, sys
path, plugin_id = sys.argv[1:]
with open(path) as f:
    data = json.load(f)
if data.get("schemaVersion") != 3 or not isinstance(data.get("plugins"), list):
    sys.exit("not a schema version 3 catalog: " + path)
matches = [p for p in data["plugins"] if isinstance(p, dict) and p.get("id") == plugin_id]
if not matches:
    sys.exit(3)
if len(matches) != 1:
    sys.exit("plugin %s is listed more than once in %s" % (plugin_id, path))
entry = matches[0]
kind = entry.get("kind")
if kind == "library":
    asset = entry.get("libraryFileName")
elif kind == "bundle":
    name = entry.get("bundleName")
    if not isinstance(name, str) or not re.fullmatch(r".+\.bundle", name):
        sys.exit("plugin %s bundleName is not <Name>.bundle in %s" % (plugin_id, path))
    asset = name[: -len(".bundle")] + ".zip"
else:
    sys.exit("plugin %s has an unsupported kind in %s: %r" % (plugin_id, path, kind))
fields = [kind, asset, entry.get("version"), entry.get("sha256"), entry.get("url")]
if kind == "bundle":
    fields.append(entry.get("cdhash"))
if not all(isinstance(v, str) and re.fullmatch(r"\S+", v) for v in fields):
    sys.exit("plugin %s has a missing or malformed field in %s" % (plugin_id, path))
print("\t".join(fields))
PY
}

# Sets version, url and sha256 of catalog entry <id> only (and cdhash, a 6th argument a bundle
# needs), after checking them against the rules of PluginCatalog.swift; its other fields (kind,
# libraryFileName, bundleName, bundleIdentifier) and the other entries are kept as they are.
rewrite_catalog_entry() {
  python3 -I - "$@" <<'PY'
import json, os, re, sys
if len(sys.argv) not in (6, 7):
    sys.exit("rewrite_catalog_entry: expected 5 or 6 arguments")
path, plugin_id, version, url, sha = sys.argv[1:6]
cdhash = sys.argv[6] if len(sys.argv) == 7 else None
with open(path) as f:
    data = json.load(f)
if data.get("schemaVersion") != 3 or not isinstance(data.get("plugins"), list):
    sys.exit("not a schema version 3 catalog: " + path)
matches = [p for p in data["plugins"] if isinstance(p, dict) and p.get("id") == plugin_id]
if len(matches) != 1:
    sys.exit("plugin %s is not listed exactly once in %s" % (plugin_id, path))
entry = matches[0]
kind = entry.get("kind")
if kind == "library":
    if cdhash is not None:
        sys.exit("plugin %s is a library: it has no cdhash" % plugin_id)
    library = entry.get("libraryFileName", "")
elif kind == "bundle":
    if cdhash is None or not re.fullmatch(r"[0-9a-f]{40}", cdhash):
        sys.exit("plugin %s is a bundle: it needs a cdhash of 40 lowercase hex digits" % plugin_id)
    name = entry.get("bundleName")
    if not isinstance(name, str) or not re.fullmatch(r".+\.bundle", name):
        sys.exit("plugin %s bundleName is not <Name>.bundle in %s" % (plugin_id, path))
    library = name[: -len(".bundle")] + ".zip"
else:
    sys.exit("plugin %s has an unsupported kind in %s: %r" % (plugin_id, path, kind))
if not re.fullmatch(r"[0-9]+(\.[0-9]+)*", version):
    sys.exit("invalid version: " + version)
if not re.fullmatch(r"[0-9a-f]{64}", sha):
    sys.exit("invalid sha256: " + sha)
asset = r"https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/releases/download/%s/%s" % (
    re.escape("plugin-%s-v%s" % (plugin_id, version)), re.escape(library))
if not re.fullmatch(asset, url):
    sys.exit("url is not the release asset plugin-%s-v%s/%s: %s" % (plugin_id, version, library, url))
entry.update({"version": version, "url": url, "sha256": sha})
if cdhash is not None:
    entry["cdhash"] = cdhash
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

# Offline preflight of a local-ai --publish: the catalog's local-ai entry must pin the zip in
# dist/plugins/local-ai/ (its SHA-256, and the cdhash of the bundle in it, whose signature must
# verify under the Team ID), and that zip must come from the current source tree.
check_local_ai_publish() {
  local dist_zip="$LOCAL_AI_DIST/$LOCAL_AI_ZIP" expected_url zip_sha recorded_fp current_fp
  local unpacked bundle sig_info bundle_cdhash
  [[ "$ENTRY_KIND" == "bundle" ]] || fail "plugin local-ai is a $ENTRY_KIND in $CATALOG, not a bundle"
  [[ "$ASSET_NAME" == "$LOCAL_AI_ZIP" ]] ||
    fail "$CATALOG names the asset $ASSET_NAME for local-ai; the build produces $LOCAL_AI_ZIP"
  [[ "$ENTRY_VERSION" == "$PLUGIN_VERSION" ]] ||
    fail "the local-ai entry of $CATALOG is version $ENTRY_VERSION; $LOCAL_AI_DIR/project.yml is $PLUGIN_VERSION"
  expected_url="https://github.com/$REPO/releases/download/$TAG/$LOCAL_AI_ZIP"
  [[ "$ENTRY_URL" == "$expected_url" ]] ||
    fail "the local-ai url in $CATALOG is $ENTRY_URL; the upload lands at $expected_url"
  [[ "$ENTRY_CDHASH" =~ ^[0-9a-f]{40}$ ]] || fail "the local-ai cdhash in $CATALOG is not 40 lowercase hex digits"
  [[ -f "$dist_zip" ]] ||
    fail "$dist_zip not found; a rebuild gives a new zip, so its sha256 and cdhash go into $CATALOG first"
  [[ -f "$LOCAL_AI_DIST/source.sha256" ]] || fail "$LOCAL_AI_DIST/source.sha256 not found"
  zip_sha=$(shasum -a 256 "$dist_zip" | awk '{ print $1 }')
  [[ "$zip_sha" == "$ENTRY_SHA256" ]] ||
    fail "SHA-256 mismatch: $dist_zip is $zip_sha, the local-ai entry of $CATALOG pins $ENTRY_SHA256; nothing was published"
  # Unpacked into WORK_DIR, which the EXIT trap deletes when a check fails.
  WORK_DIR=$(mktemp -d -t dblore-plugin)
  unpacked="$WORK_DIR/unpacked"
  mkdir "$unpacked"
  ditto -x -k "$dist_zip" "$unpacked" || fail "cannot unpack $dist_zip; nothing was published"
  [[ "$(ls -A "$unpacked")" == "$LOCAL_AI_BUNDLE" ]] ||
    fail "$dist_zip does not hold exactly $LOCAL_AI_BUNDLE; nothing was published"
  bundle="$unpacked/$LOCAL_AI_BUNDLE"
  codesign --verify --strict --deep "$bundle" ||
    fail "codesign --verify --strict --deep failed for $LOCAL_AI_BUNDLE in $dist_zip; nothing was published"
  sig_info=$(codesign -dvvv "$bundle" 2>&1) ||
    fail "cannot read the signature of $LOCAL_AI_BUNDLE in $dist_zip; nothing was published"
  grep -qx "TeamIdentifier=$TEAM_ID" <<<"$sig_info" ||
    fail "the signature TeamIdentifier of $LOCAL_AI_BUNDLE in $dist_zip is not $TEAM_ID; nothing was published"
  bundle_cdhash=$(sed -n 's/^CDHash=//p' <<<"$sig_info")
  [[ "$bundle_cdhash" == "$ENTRY_CDHASH" ]] ||
    fail "cdhash mismatch: $LOCAL_AI_BUNDLE in $dist_zip is ${bundle_cdhash:-unreadable}, the local-ai entry of $CATALOG pins $ENTRY_CDHASH; nothing was published"
  rm -rf "$WORK_DIR"
  WORK_DIR=""
  recorded_fp=$(<"$LOCAL_AI_DIST/source.sha256")
  current_fp=$(local_ai_source_fingerprint)
  [[ "$recorded_fp" == "$current_fp" ]] ||
    fail "source fingerprint mismatch: $dist_zip was built from $recorded_fp, the tree is now $current_fp (scripts/release-plugin.sh --print-source-fingerprint); nothing was published"
  echo "local-ai: $dist_zip matches $CATALOG (sha256 $zip_sha, cdhash $bundle_cdhash, source fingerprint $current_fp)"
}

# Uploads exactly the checked dist zip to release $TAG; the catalog is not touched.
publish_local_ai() {
  local zip zip_sha
  WORK_DIR=$(mktemp -d -t dblore-plugin)
  zip="$WORK_DIR/$LOCAL_AI_ZIP"
  cp "$LOCAL_AI_DIST/$LOCAL_AI_ZIP" "$zip"
  zip_sha=$(shasum -a 256 "$zip" | awk '{ print $1 }')
  [[ "$zip_sha" == "$ENTRY_SHA256" ]] ||
    fail "$LOCAL_AI_DIST/$LOCAL_AI_ZIP changed after the preflight ($zip_sha); nothing was published"
  echo "==> Publishing GitHub release $TAG"
  # --latest=false keeps releases/latest pointing at the app DMG.
  gh release create "$TAG" "$zip" \
    --repo "$REPO" --latest=false \
    --title "On-device AI plugin $PLUGIN_VERSION" \
    --notes "$LOCAL_AI_BUNDLE $PLUGIN_VERSION, signed with Developer ID ($TEAM_ID), notarized and stapled. $LOCAL_AI_ZIP sha256: $zip_sha, bundle cdhash: $ENTRY_CDHASH" ||
    fail "gh release create failed; the catalog was not changed"
  echo "release: $(gh release view "$TAG" --repo "$REPO" --json url -q .url)"
  echo "$CATALOG is unchanged; run scripts/release-local.sh --check-plugin-only --plugin local-ai"
}

if [[ $PRINT_SOURCE_FINGERPRINT -eq 1 ]]; then
  local_ai_source_fingerprint
  exit 0
fi

[[ "$PLUGIN_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "invalid plugin id: $PLUGIN_ID"
[[ -f "$CATALOG" ]] || fail "$CATALOG not found"
# local-ai builds without a catalog entry; only its --publish reads one
if [[ "$PLUGIN_ID" != "local-ai" || $PUBLISH -eq 1 ]]; then
  entry_status=0
  entry=$(catalog_entry "$CATALOG" "$PLUGIN_ID") || entry_status=$?
  if [[ $entry_status -eq 3 ]]; then
    [[ "$PLUGIN_ID" == "local-ai" ]] &&
      fail "plugin local-ai is not in $CATALOG; add the local-ai entry first"
    fail "plugin $PLUGIN_ID is not in $CATALOG"
  fi
  [[ $entry_status -eq 0 ]] || fail "the $PLUGIN_ID entry of $CATALOG is not usable"
  IFS=$'\t' read -r ENTRY_KIND ASSET_NAME ENTRY_VERSION ENTRY_SHA256 ENTRY_URL ENTRY_CDHASH <<<"$entry"
fi

case "$PLUGIN_ID" in
  duckdb)
    PLUGIN_VERSION="$DUCKDB_VERSION"
    [[ "$ENTRY_KIND" == "library" ]] || fail "plugin duckdb is a $ENTRY_KIND in $CATALOG, not a library"
    LIBRARY_FILE_NAME="$ASSET_NAME"
    [[ "$LIBRARY_FILE_NAME" == "libduckdb.dylib" ]] ||
      fail "$CATALOG names $LIBRARY_FILE_NAME for duckdb; the build produces libduckdb.dylib"
    PUBLISH_SUMMARY="uploads $LIBRARY_FILE_NAME to it and rewrites the $PLUGIN_ID entry of $CATALOG."
    ;;
  local-ai)
    PLUGIN_VERSION=$(awk '$1 == "MARKETING_VERSION:" { print $2 }' "$LOCAL_AI_DIR/project.yml")
    [[ "$PLUGIN_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] ||
      fail "$LOCAL_AI_DIR/project.yml needs exactly one MARKETING_VERSION (got: $PLUGIN_VERSION)"
    if [[ $PUBLISH -eq 1 ]]; then
      [[ $INSTALL_DEV -eq 0 ]] || fail "--publish --plugin local-ai never rebuilds; drop --install-dev"
      PUBLISH_SUMMARY="uploads $LOCAL_AI_DIST/$LOCAL_AI_ZIP to it; $CATALOG is not changed."
    fi
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

if [[ "$PLUGIN_ID" == "local-ai" && $PUBLISH -eq 1 ]]; then
  check_local_ai_publish
fi

echo "==> Preflight"
# A local-ai --publish signs and notarizes nothing
if [[ "$PLUGIN_ID" != "local-ai" || $PUBLISH -eq 0 ]]; then
  identities=$(security find-identity -v -p codesigning)
  grep -qF "$SIGN_IDENTITY" <<<"$identities" || fail "signing identity not found: $SIGN_IDENTITY"

  if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 ||
      fail "notary profile $NOTARY_PROFILE not found (or use --skip-notarize)"
  fi
fi

if [[ $PUBLISH -eq 1 ]]; then
  gh auth status >/dev/null 2>&1 || fail "gh is not authenticated. Run: gh auth login"
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    fail "release $TAG already exists on $REPO"
  fi
  cat >&2 <<EOF

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! --publish creates a PUBLIC GitHub release $TAG on $REPO,
!! $PUBLISH_SUMMARY
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
  if [[ $PUBLISH -eq 1 ]]; then
    publish_local_ai
  else
    release_local_ai
  fi
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
