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
     test PostgreSQL container (`docker/README.md`, "Integration tests"):

     ```bash
     docker compose -f docker/postgresql/docker-compose.test.yml up -d
     TEST_RUNNER_POSTGRES_TESTS=1 xcodebuild test -scheme Dblore \
       -destination 'platform=macOS,arch=arm64' -enableCodeCoverage NO \
       -parallel-testing-enabled NO \
       -skipPackagePluginValidation -skipMacroValidation
     ```

     The MongoDB suites are opt-in. Start `docker/mongodb` (`docker/README.md`, "MongoDB"
     and "Integration tests") and put `TEST_RUNNER_MONGO_TESTS=1` in front of the integration test
     command above (`xcodebuild` passes it to the tests as `MONGO_TESTS`; either form turns
     the gate on). The TLS suites also need `TEST_RUNNER_MONGO_TLS_TESTS=1`
     (`MONGO_TLS_TESTS`), the certificates from `docker/mongodb/scripts/gen-mongo-tls.sh` and
     the `tls` compose profile. Both gates stay off with `SKIP_INTEGRATION_TESTS=true`.

  2. Match the existing style: the project is Swift 6 with strict concurrency, formatted
     with `swift-format` (`.swift-format`). Check the files you changed with
     `swift-format lint --strict <files>`.
  3. Keep pull requests focused, and describe what changed and why.

## mysql-nio fork

The MySQL driver comes from the [dinhanhthi/mysql-nio](https://github.com/dinhanhthi/mysql-nio)
fork: upstream mysql-nio 1.9.1 plus Dblore's patches on the branch `dblore-patches`, released
as tags `1.9.1-dblore.<n>` (currently `1.9.1-dblore.3`). The app pins the tag's commit as an
exact revision, never a branch or a version range. To change the driver (maintainer only):

1. Commit the patch on `dblore-patches` in a local clone of the fork, with tests.
2. Run the fork's packet tests: `swift test --package-path ~/git/mysql-nio --filter MySQLPacket`
   (adjust the path to your clone; add other filters for the code you touched).
3. Tag the commit `1.9.1-dblore.<n+1>` and push the branch and the tag to the fork.
4. Set the new commit SHA as the `revision` of the mysql-nio package reference in
   `Dblore.xcodeproj/project.pbxproj` and in
   `Dblore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, check that
   no other pin moved, and run the MySQL suites (`TEST_RUNNER_MYSQL_TESTS=1`, containers from
   `docker/mysql`) before committing.

The MySQL full-authentication guard (`Dblore/Database/MySQL/MySQLFullAuthGuard.swift`) depends
on this fork's pipeline layout: the fork appends its codec and connection handler at `.last`
and puts `NIOSSLClientHandler` at `.first`, so the guard, added before
`MySQLConnection.connect(over:)`, sees decrypted packets before the packet decoder. Check
that layout, and the guard's tests, whenever you bump the fork.

## Connection scripts

A connection can run scripts before connecting, after disconnecting and as a password
command. They run through `NSUserUnixTask` (`Dblore/Utilities/ConnectionScriptRunner.swift`)
from `~/Library/Application Scripts/ace.thi.Dblore`, the only place a sandboxed app may run
user scripts: a script is a plain file name in that folder, never a path. Scripts receive
host, port, user and database as arguments (refused if one starts with `-` or holds a control
character). `NSUserUnixTask` cannot stop a script, so a timed-out script is abandoned, still
running. Do not log script output or the password command's result. Dblore has no socket
entitlement (only network client and server): PostgreSQL Unix sockets are not supported.

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

## Plugins

Heavy database engines and other heavy features ship as optional plugins, not inside the app
(a C ABI library, signed with the app's Team ID, notarized, SHA-pinned in the catalog). The
on-device AI runtime is the one exception and stays built in. DuckDB is the only plugin so
far: users install it from Settings > Plugins, which downloads the `libduckdb.dylib` named by
the `duckdb` entry of the plugin catalog `Dblore/Utilities/Plugins/PluginCatalog.json` and
refuses it unless its SHA-256 matches.

The catalog is `schemaVersion` 2 with a `plugins` array; each entry has `id`, `version`,
`url`, `sha256`, `maxSize` and `libraryFileName`. Decoding is strict and a bad catalog is
refused as a whole: ids are unique and match `[a-z0-9][a-z0-9-]*`, `version` is
dot-separated digits, `sha256` is 64 lowercase hex digits, the URL is the https github.com
release asset named `libraryFileName` under the tag `plugin-<id>-v<version>`,
`libraryFileName` is a `.dylib` basename and `maxSize` is positive and at most 256 MiB. The install path is
`Plugins/<id>/<version>/<libraryFileName>`. `PluginLoader` opens the file without following
symlinks, checks the size and SHA-256 of the opened file and the Team ID before `dlopen`.

`scripts/release-plugin.sh --plugin <id>` (default `duckdb`; an id not in
the catalog is refused) builds a plugin artifact; DuckDB is the only build recipe: it
downloads the pinned official DuckDB release, checks the upstream SHA-256, re-signs the
dylib with the Developer ID (hardened runtime) and notarizes it.

- **Local tests:** `scripts/release-plugin.sh --install-dev` writes the signed dylib, an
  ad-hoc-signed copy and `dev-catalog.json` into the gitignored `.plugin-dev/`. The DuckDB
  suites that load it are gated; run them as their own command, with
  `TEST_RUNNER_DUCKDB_PLUGIN_TESTS=1 DUCKDB_PLUGIN_TESTS=1` in front of the `xcodebuild test`
  command above and without `SKIP_INTEGRATION_TESTS=true` (that variable turns the gate off).
- **Publish (maintainer only, manual):** `scripts/release-plugin.sh --plugin <id> --publish`
  creates the public GitHub release `plugin-<id>-v<version>` with `--latest=false`, so
  `releases/latest` keeps pointing at the app DMG, and rewrites the version, URL and
  SHA-256 of that plugin's catalog entry only. Review and commit the catalog.
- **Before an app release:** `scripts/release-local.sh --check-plugin-only` downloads the
  published asset of every catalog entry and checks it against the catalog (add
  `--plugin <id>` to check one entry). The full release preflight runs the same check on
  every entry and refuses to build while an asset is missing (not published yet) or its
  SHA-256 differs from the catalog.
- **Bumping DuckDB:** change `DUCKDB_VERSION` and `UPSTREAM_SHA256` in
  `scripts/release-plugin.sh` after reviewing the upstream release, then publish again.

## No other products in the codebase

Dblore is an independent product. Never name a competing database client anywhere in the
tracked code, comments, tests, commit messages, changelog, README or website, and never write
"similar to X" or "inspired by X". Describe behavior in Dblore's own terms, or cite a public
spec (file format, protocol, RFC, vendor docs). The one exception is interop: an app's name may
appear where it names the source of a file the user imports (the connection importers, their
UI labels, enum cases, tests, and the import feature's docs).

## Website

The landing page and docs live in `website/` (plain HTML and CSS, no build step). Preview
locally with `python3 -m http.server -d website`. Pushes to `main` that touch `website/`
deploy it through `.github/workflows/pages.yml`, which also publishes `appcast.xml` (the
Sparkle update feed), so keep that file at the repo root.

- **Features catalog:** every entry of `website/features-data.js` needs a stable, unique
  numeric `id` (never reused or renumbered), a `version` that is a released tag, the project
  version, `Unreleased` or `Unknown`, existing `sources`, a `commit` and `evidence`.
  `node --test website/features.test.js` enforces this; never weaken that test to make an entry
  pass.
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
