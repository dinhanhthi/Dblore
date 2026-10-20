#!/bin/bash

# Build a plugin artifact (--plugin <id>, default duckdb). For duckdb: download the
# pinned official libduckdb.dylib, verify its upstream SHA-256, re-sign it with the
# Developer ID (hardened runtime) and notarize it. --install-dev copies it into the
# gitignored .plugin-dev/ for tests; --publish (user-run only) uploads it to GitHub
# and rewrites that plugin's catalog entry, leaving the other entries as they are.

set -euo pipefail

REPO="dinhanhthi/Dblore"
DUCKDB_VERSION="1.5.6"
ASSET_URL="https://github.com/duckdb/duckdb/releases/download/v$DUCKDB_VERSION/libduckdb-osx-universal.zip"
UPSTREAM_SHA256="e0bc007d9b0094c0970ac1847a8601d10aad07cbd2910ce586ec810f77b638d6"
TEAM_ID="86H6CNLN4C"
SIGN_IDENTITY="Developer ID Application: Anh-Thi Dinh ($TEAM_ID)"
NOTARY_PROFILE="DbloreNotary"
CATALOG="Dblore/Utilities/Plugins/PluginCatalog.json"

usage() {
  cat <<EOF
Usage: scripts/release-plugin.sh [--plugin <id>] [--install-dev] [--publish [--yes]] [--skip-notarize]

Builds the library of catalog plugin <id>, signs it with "$SIGN_IDENTITY",
notarizes it and prints its SHA-256. duckdb is the only build recipe: it downloads
DuckDB $DUCKDB_VERSION (libduckdb-osx-universal.zip) and verifies the upstream SHA-256.

  --plugin <id>     Plugin id in $CATALOG (default duckdb);
                    an id not in the catalog is refused
  --install-dev     Write the signed dylib, an ad-hoc-signed copy and dev-catalog.json
                    into .plugin-dev/ at the repo root
  --publish         Upload to GitHub release plugin-<id>-v<version> (--latest=false) and
                    rewrite only the <id> entry of $CATALOG.
                    Manual, user-run only; afterwards
                    scripts/release-local.sh --check-plugin-only verifies the asset
  --yes             Skip the interactive confirmation of --publish
  --skip-notarize   Sign only (not allowed with --publish)
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

[[ "$PLUGIN_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "invalid plugin id: $PLUGIN_ID"
[[ -f "$CATALOG" ]] || fail "$CATALOG not found"
LIBRARY_FILE_NAME=$(catalog_library_file_name "$CATALOG" "$PLUGIN_ID") ||
  fail "plugin $PLUGIN_ID is not in $CATALOG"

case "$PLUGIN_ID" in
  duckdb)
    PLUGIN_VERSION="$DUCKDB_VERSION"
    [[ "$LIBRARY_FILE_NAME" == "libduckdb.dylib" ]] ||
      fail "$CATALOG names $LIBRARY_FILE_NAME for duckdb; the build produces libduckdb.dylib"
    ;;
  *)
    fail "plugin $PLUGIN_ID has no build recipe in scripts/release-plugin.sh (only duckdb has one)"
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
