# Contributing to Dblore

Thanks for your interest — contributions are welcome!

## How to contribute

- **Found a bug or have an idea?** Open an issue to discuss it first.
- **Sending code?**
  1. Build from source (Xcode 27+ on macOS 26+; the app itself runs on macOS 14+) and make sure the unit tests pass:

     ```bash
     SKIP_INTEGRATION_TESTS=true xcodebuild test -scheme Dblore \
       -destination 'platform=macOS,arch=arm64' -enableCodeCoverage NO \
       -skipPackagePluginValidation -skipMacroValidation
     ```

     Build requirements for the on-device AI models (MLX):

     - **Apple Silicon only.** The project builds for arm64 only (`ARCHS = arm64`); Intel
       Macs are not supported.
     - **Metal toolchain.** Install it once with `xcodebuild -downloadComponent MetalToolchain`.
     - **Every `xcodebuild` invocation** (build, test, archive) needs
       `-skipPackagePluginValidation -skipMacroValidation`. The plugin flag is required
       because the mlx-swift `CudaBuild` plugin otherwise blocks the build; the macro flag
       skips the macro trust prompt of the Swift package dependencies.
     - **Release and CI builds** (`scripts/build-release.sh`, `scripts/ci-build-check.sh`,
       `build-check.yml`) also pass `-disableAutomaticPackageResolution
       -onlyUsePackageVersionsFromResolvedFile`. The skip flags disable trust checks for the
       whole build, so these options limit it to the reviewed, committed `Package.resolved`
       pins. Change dependency versions only by committing an updated `Package.resolved`.
     - **Model revisions are pinned.** Each `LocalModelCatalog` entry carries a full commit SHA
       (`revision`) that downloads are fixed to. Bump it deliberately, after reviewing the
       upstream repo, never to a floating branch.

     If your change touches database code, also run the integration tests against the
     test PostgreSQL container (`docker/README.md`, "Integration Test Database").
  2. Match the existing style: the project is Swift 6 with strict concurrency, formatted
     with `swift-format` (`.swift-format`). Check the files you changed with
     `swift-format lint --strict <files>`.
  3. Keep pull requests focused, and describe what changed and why.

## License

Dblore is open source under the **GNU Affero General Public License v3.0**. By
submitting a contribution, you agree that it is licensed under the same terms. You
confirm that the contribution is your own original work, or that you are authorized to
submit it.

No Contributor License Agreement is required.
