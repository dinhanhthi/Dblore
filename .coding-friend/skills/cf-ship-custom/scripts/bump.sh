#!/usr/bin/env bash
# bump.sh — set the app version in the Xcode project for SQLNotebook.
#
# Usage: bash bump.sh <new_version>
#   e.g. bash bump.sh 0.2.0
#
# The version is always the numeric core X.Y.Z: Apple requires three integers
# for CFBundleShortVersionString. A prerelease suffix (-rc.N / -beta.N) lives
# only in the git tag and the CHANGELOG heading, never in the project file.
#
# ONE file carries the version: SQLNotebook.xcodeproj/project.pbxproj. Every
# build configuration has its own copy of two settings, and all of them move:
#   MARKETING_VERSION        -> <new_version>           (CFBundleShortVersionString)
#   CURRENT_PROJECT_VERSION  -> max(current) + 1        (CFBundleVersion)
# The build number is the SAME integer everywhere, so Debug and Release can
# never disagree about which build they are.
#
# Writes the file atomically (temp file + mv) and nothing else: no git
# operation, no commit, no tag.
#
# Test hook. Never set during a real release.
#   BUMP_PBXPROJ=/path/to/copy.pbxproj  -> edit that file instead of the
#     git-tracked project file.

set -euo pipefail

# scripts -> cf-ship-custom -> skills -> .coding-friend -> repo root = four levels.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
NEW_VERSION="${1:-}"

usage() {
  echo "Usage: bash bump.sh <new_version>    e.g. 0.2.0 (numeric X.Y.Z only)"
}

if [[ -z "$NEW_VERSION" ]]; then
  usage
  exit 1
fi

# Numeric core only. A prerelease suffix is a tag-only concern.
if [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+- ]]; then
  echo "Error: prerelease goes in the tag only; pass the core version (got '$NEW_VERSION', use '${NEW_VERSION%%-*}')"
  usage
  exit 1
fi
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must be X.Y.Z (got '$NEW_VERSION')"
  usage
  exit 1
fi

PBXPROJ_REL="SQLNotebook.xcodeproj/project.pbxproj"
PBXPROJ="${BUMP_PBXPROJ:-$REPO_ROOT/$PBXPROJ_REL}"
if [[ ! -f "$PBXPROJ" ]]; then
  echo "Error: $PBXPROJ not found"
  if [[ -z "${BUMP_PBXPROJ:-}" ]]; then
    echo "The relative path from this script to the repository root is wrong."
  fi
  exit 1
fi

# ─── Rewrite ──────────────────────────────────────────────────────────────────
#
# Only lines of the exact form `KEY = value;` are touched, so a mention of the
# key inside a string or a comment elsewhere cannot be hit. Values may be
# quoted or bare; the new version is always written bare (it is numeric). The
# temp file lives next to the target so the
# final mv is a same-filesystem rename, i.e. atomic.

TMP_FILE="$(mktemp "$PBXPROJ.bump.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT

echo "Bumping SQLNotebook to ${NEW_VERSION}…"
python3 - "$PBXPROJ" "$TMP_FILE" "$NEW_VERSION" <<'PY'
import re, sys

src_path, tmp_path, version = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_path, encoding="utf-8").read()

LINE = r'(?m)^([ \t]*%s = )("?)([^";\n]*)\2;'
mv_re = re.compile(LINE % "MARKETING_VERSION")
bv_re = re.compile(LINE % "CURRENT_PROJECT_VERSION")

old_versions = sorted({m.group(3) for m in mv_re.finditer(src)})
old_builds = [m.group(3) for m in bv_re.finditer(src)]
if not old_versions:
    sys.exit("Error: no MARKETING_VERSION found in %s" % src_path)
if not old_builds:
    sys.exit("Error: no CURRENT_PROJECT_VERSION found in %s" % src_path)
bad = sorted({b for b in old_builds if not re.fullmatch(r"[0-9]+", b)})
if bad:
    sys.exit("Error: CURRENT_PROJECT_VERSION is not an integer: %s" % ", ".join(bad))

new_build = max(int(b) for b in old_builds) + 1
out = mv_re.sub(lambda m: m.group(1) + version + ";", src)
out = bv_re.sub(lambda m: m.group(1) + str(new_build) + ";", out)

with open(tmp_path, "w", encoding="utf-8") as f:
    f.write(out)

print("  MARKETING_VERSION:        %s -> %s" % (", ".join(old_versions), version))
print("  CURRENT_PROJECT_VERSION:  %s -> %d"
      % (", ".join(sorted(set(old_builds), key=int)), new_build))
PY

# Python validated every build value as an integer, so this cannot misparse.
EXPECTED_BUILD="$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION = ' "$PBXPROJ" \
  | sed -E 's/.*= *"?([^";]*)"?;.*/\1/' | sort -n | tail -n 1)"
EXPECTED_BUILD=$((EXPECTED_BUILD + 1))

# mktemp creates the file 0600; keep the original's permissions.
chmod "$(stat -f '%Lp' "$PBXPROJ")" "$TMP_FILE"
mv "$TMP_FILE" "$PBXPROJ"
trap - EXIT

# ─── Verify ───────────────────────────────────────────────────────────────────
#
# Re-read from disk: a silent partial bump (one configuration left behind)
# would ship Debug and Release with different versions.

echo ""
echo "Verifying $PBXPROJ:"
values_of() {
  grep -E "^[[:space:]]*$1 = " "$PBXPROJ" \
    | sed -E 's/.*= *"?([^";]*)"?;.*/\1/' \
    | sort -u || true
}
ACTUAL_VERSIONS="$(values_of MARKETING_VERSION)"
ACTUAL_BUILDS="$(values_of CURRENT_PROJECT_VERSION)"

FAILED=0
if [[ "$ACTUAL_VERSIONS" == "$NEW_VERSION" ]]; then
  echo "  ok    MARKETING_VERSION = $NEW_VERSION (all configurations)"
else
  echo "  FAIL  MARKETING_VERSION values: $(printf '%s ' $ACTUAL_VERSIONS)(expected $NEW_VERSION)"
  FAILED=1
fi
if [[ "$ACTUAL_BUILDS" == "$EXPECTED_BUILD" ]]; then
  echo "  ok    CURRENT_PROJECT_VERSION = $EXPECTED_BUILD (all configurations)"
else
  echo "  FAIL  CURRENT_PROJECT_VERSION values: $(printf '%s ' $ACTUAL_BUILDS)(expected $EXPECTED_BUILD)"
  FAILED=1
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo ""
  echo "The project file did not take the new version. Nothing was reverted —"
  echo "inspect with: git diff"
  exit 1
fi

echo ""
echo "Done. Next: update CHANGELOG.md, commit, then tag v$NEW_VERSION (or v$NEW_VERSION-rc.N / -beta.N for a prerelease)."
