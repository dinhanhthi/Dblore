#!/bin/bash

# Build script with strict concurrency checking
# This mimics GitHub Actions build settings to catch concurrency issues locally

set -e

echo "🔍 Building with strict concurrency checking (mimicking GitHub Actions)..."
echo ""

# Build with settings similar to GitHub Actions
xcodebuild \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -scheme Dblore \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="\$(inherited) -Xfrontend -warn-concurrency -Xfrontend -enable-actor-data-race-checks" \
  clean build

echo ""
echo "✅ Build successful with strict checking!"
echo ""
echo "💡 If you see concurrency warnings or errors, fix them before pushing to GitHub."
