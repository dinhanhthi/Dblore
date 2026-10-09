#!/bin/bash

# Build the DuckDB plugin artifact: download the pinned official libduckdb.dylib,
# verify its upstream SHA-256, re-sign it with the Developer ID (hardened runtime)
# and notarize it. --install-dev copies it into the gitignored .plugin-dev/ for
# tests; --publish (user-run only) uploads it to GitHub and rewrites the catalog.

set -euo pipefail

REPO="dinhanhthi/Dblore"
DUCKDB_VERSION="1.5.6"
ASSET_URL="https://github.com/duckdb/duckdb/releases/download/v$DUCKDB_VERSION/libduckdb-osx-universal.zip"
UPSTREAM_SHA256="e0bc007d9b0094c0970ac1847a8601d10aad07cbd2910ce586ec810f77b638d6"
TEAM_ID="86H6CNLN4C"
SIGN_IDENTITY="Developer ID Application: Anh-Thi Dinh ($TEAM_ID)"
NOTARY_PROFILE="DbloreNotary"
TAG="plugin-duckdb-v$DUCKDB_VERSION"
CATALOG="Dblore/Utilities/Plugins/DuckDBPluginCatalog.json"

usage() {
  cat <<EOF
Usage: scripts/release-plugin.sh [--install-dev] [--publish [--yes]] [--skip-notarize]

Downloads DuckDB $DUCKDB_VERSION (libduckdb-osx-universal.zip), verifies the upstream
SHA-256, signs libduckdb.dylib with "$SIGN_IDENTITY",
notarizes it and prints its SHA-256.

  --install-dev     Write the signed dylib, an ad-hoc-signed copy and dev-catalog.json
                    into .plugin-dev/ at the repo root
  --publish         Upload to GitHub release $TAG (--latest=false) and rewrite
                    $CATALOG. Manual, user-run only; afterwards
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

INSTALL_DEV=0
PUBLISH=0
ASSUME_YES=0
SKIP_NOTARIZE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
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
!! uploads libduckdb.dylib to it and rewrites $CATALOG.
!! Every user installing the DuckDB plugin downloads this file.
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

  url="https://github.com/$REPO/releases/download/$TAG/libduckdb.dylib"
  mkdir -p "$(dirname "$CATALOG")"
  python3 -I - "$CATALOG" "$DUCKDB_VERSION" "$url" "$DYLIB_SHA256" <<'PY'
import json, os, sys
path, version, url, sha = sys.argv[1:]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
data.update({"version": version, "url": url, "sha256": sha})
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  echo "release: $(gh release view "$TAG" --repo "$REPO" --json url -q .url)"
  echo "updated $CATALOG; review and commit it, then run scripts/release-local.sh --check-plugin-only"
fi

echo "==> Done"
