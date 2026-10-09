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
       `ci.yml`) also pass `-disableAutomaticPackageResolution
       -onlyUsePackageVersionsFromResolvedFile`. The skip flags disable trust checks for the
       whole build, so these options limit it to the reviewed, committed `Package.resolved`
       pins. Change dependency versions only by committing an updated `Package.resolved`.
     - **Model revisions are pinned.** Each `LocalModelCatalog` entry carries a full commit SHA
       (`revision`) that downloads are fixed to. Bump it deliberately, after reviewing the
       upstream repo, never to a floating branch.

     If your change touches database code, also run the integration tests against the
     test PostgreSQL container (`docker/README.md`, "Integration Test Database"):

     ```bash
     docker compose -f docker/postgresql/docker-compose.test.yml up -d
     xcodebuild test -scheme Dblore \
       -destination 'platform=macOS,arch=arm64' -enableCodeCoverage NO \
       -skipPackagePluginValidation -skipMacroValidation
     ```

  2. Match the existing style: the project is Swift 6 with strict concurrency, formatted
     with `swift-format` (`.swift-format`). Check the files you changed with
     `swift-format lint --strict <files>`.
  3. Keep pull requests focused, and describe what changed and why.

## Markdown editor bundle

The WYSIWYG preview of Markdown notes runs [Milkdown](https://milkdown.dev) in a
`WKWebView`. Its bundle (`Dblore/Resources/MarkdownEditor/markdown-editor.{js,css}` plus
`markdown-editor-licenses.txt`) is vendored: `xcodebuild` never runs npm. Rebuild it with:

```bash
cd scripts/markdown-editor && npm ci && npm run build
```

To upgrade, bump both exact pins in `scripts/markdown-editor/package.json`
(`@milkdown/kit`, `esbuild`), run `npm install`, rebuild, then review the bundle diff and
`markdown-editor-licenses.txt` before committing. `markdown-editor.html` is hand-written.

## DuckDB plugin

DuckDB ships as an optional plugin, not inside the app: users install it from
Settings > Plugins, which downloads the `libduckdb.dylib` named in
`Dblore/Utilities/Plugins/DuckDBPluginCatalog.json` and refuses it unless its SHA-256
matches. `scripts/release-plugin.sh` builds that artifact: it downloads the pinned official
DuckDB release, checks the upstream SHA-256, re-signs the dylib with the Developer ID
(hardened runtime) and notarizes it.

- **Local tests:** `scripts/release-plugin.sh --install-dev` writes the signed dylib, an
  ad-hoc-signed copy and `dev-catalog.json` into the gitignored `.plugin-dev/`. The DuckDB
  suites that load it are gated; run them with
  `TEST_RUNNER_DUCKDB_PLUGIN_TESTS=1 DUCKDB_PLUGIN_TESTS=1` in front of the `xcodebuild test`
  command above.
- **Publish (maintainer only, manual):** `scripts/release-plugin.sh --publish` creates the
  public GitHub release `plugin-duckdb-v<version>` with `--latest=false`, so
  `releases/latest` keeps pointing at the app DMG, and rewrites the catalog SHA-256. Review
  and commit the catalog.
- **Before an app release:** `scripts/release-local.sh --check-plugin-only` downloads the
  published asset and checks it against the catalog. The full release preflight runs the
  same check and refuses to build while the asset is missing (not published yet) or its
  SHA-256 differs from the catalog.
- **Bumping DuckDB:** change `DUCKDB_VERSION` and `UPSTREAM_SHA256` in
  `scripts/release-plugin.sh` after reviewing the upstream release, then publish again.

## Website

The landing page and docs live in `website/` (plain HTML and CSS, no build step). Preview
locally with `python3 -m http.server -d website`. Pushes to `main` that touch `website/`
deploy it through `.github/workflows/pages.yml`, which also publishes `appcast.xml` (the
Sparkle update feed), so keep that file at the repo root.

- **One-time setup (manual):** Settings > Pages > Source = "GitHub Actions" (keep it set,
  otherwise the Sparkle feed breaks). For the custom domain `dblore.dinhanhthi.com`, add a
  DNS CNAME record `dblore` -> `dinhanhthi.github.io`, then set the custom domain in
  Settings > Pages and enable Enforce HTTPS.
- **Feed check:** before and after enabling the custom domain, run
  `curl -IL https://dinhanhthi.github.io/Dblore/appcast.xml`; it must end at HTTP 200.
  `SUFeedURL` in `Info.plist` is unchanged and relies on that URL still resolving (the
  redirect to the custom domain is assumed, so verify it).
- **Rollback:** remove the custom domain in Settings > Pages so github.io serves directly
  again. If the workflow itself is the problem, `git revert` the commit that merged
  `pages.yml` (restores `deploy-appcast.yml`).

## License

Dblore is open source under the **GNU Affero General Public License v3.0**. By
submitting a contribution, you agree that it is licensed under the same terms. You
confirm that the contribution is your own original work, or that you are authorized to
submit it.

No Contributor License Agreement is required.
