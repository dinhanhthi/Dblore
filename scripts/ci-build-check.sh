#!/bin/bash

# Archives the app like release.yml, with the Xcode pinned in .xcode-version (the CI toolchain).
# Catches compiler differences between your Xcode and CI's before anything is pushed.
# Needs that Xcode installed side by side, e.g. /Applications/Xcode_27.app.

set -euo pipefail
cd "$(dirname "$0")/.."

want="$(tr -d '[:space:]' < .xcode-version)"
dev=""
for xcode in /Applications/Xcode*.app; do
  have="$(DEVELOPER_DIR="$xcode/Contents/Developer" xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}')"
  if [[ "$have" == "$want" ]]; then dev="$xcode/Contents/Developer"; break; fi
done
if [[ -z "$dev" ]]; then
  echo "Xcode $want (CI toolchain, from .xcode-version) is not installed in /Applications."
  echo "Install it side by side (developer.apple.com/download/all) as /Applications/Xcode_$want.app."
  exit 2
fi

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
echo "==> Archiving with $dev"
# Both skip flags are needed (mlx-swift CudaBuild plugin + macros), and they are global to the
# invocation; the resolved-file-only options bound that exposure to the committed Package.resolved.
DEVELOPER_DIR="$dev" xcodebuild archive \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -project Dblore.xcodeproj \
  -scheme Dblore \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$out/dd" \
  -archivePath "$out/Dblore.xcarchive" \
  CODE_SIGNING_ALLOWED=NO \
  | grep -E "error:|warning: .*(data race|Sendable|isolat)|\*\* ARCHIVE" || true
test -d "$out/Dblore.xcarchive" && echo "CI build check: OK (Xcode $want)"
