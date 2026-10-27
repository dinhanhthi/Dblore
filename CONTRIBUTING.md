# Contributing to Dblore

Thanks for your interest — contributions are welcome!

## How to contribute

- **Found a bug or have an idea?** Open an issue to discuss it first.
- **Sending code?**
  1. Build from source (Xcode 27+ on macOS 26+; the app itself runs on macOS 14+) and make sure the unit tests pass:

     ```bash
     SKIP_INTEGRATION_TESTS=true xcodebuild test -scheme Dblore \
       -destination 'platform=macOS,arch=arm64' -enableCodeCoverage NO
     ```

     The project builds for Apple Silicon only (`ARCHS = arm64`). Release and CI builds
     (`scripts/build-release.sh`, `scripts/ci-build-check.sh`, `ci.yml`) also pass
     `-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile`, so they use
     only the reviewed, committed `Package.resolved` pins: change dependency versions only by
     committing an updated `Package.resolved`.

     If your change touches database code, also run the integration tests against the
     test PostgreSQL container (`docker/README.md`, "Integration tests"):

     ```bash
     docker compose -f docker/postgresql/docker-compose.test.yml up -d
     TEST_RUNNER_POSTGRES_TESTS=1 xcodebuild test -scheme Dblore \
       -destination 'platform=macOS,arch=arm64' -enableCodeCoverage NO \
       -parallel-testing-enabled NO
     ```

     The MongoDB suites are opt-in. Start `docker/mongodb` (`docker/README.md`, "MongoDB"
     and "Integration tests") and put `TEST_RUNNER_MONGO_TESTS=1` in front of the integration test
     command above (`xcodebuild` passes it to the tests as `MONGO_TESTS`; either form turns
     the gate on). The TLS suites also need `TEST_RUNNER_MONGO_TLS_TESTS=1`
     (`MONGO_TLS_TESTS`), the certificates from `docker/mongodb/scripts/gen-mongo-tls.sh` and
     the `tls` compose profile. Both gates stay off with `SKIP_INTEGRATION_TESTS=true`.

  2. Match the existing style: the project is Swift 6 with strict concurrency, formatted
     with `swift-format` (`.swift-format`; format with
     `swift-format -i -r Dblore/ DbloreTests/ Plugins/LocalAI/`). Check the files you changed
     with `swift-format lint --strict <files>`.
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

## Lock

A locked workspace's files are written as envelope v1 (`Dblore/Utilities/Lock/LockEnvelope.swift`
has the byte layout): magic `89 44 42 4C 4B 0D 0A 1A`, version `1` (UInt16 big-endian), payload
kind (1 `.sqlws`, 2 `.dblore`, 3 `.sql`/`.js`, 4 `.md`, 5 launch-snapshot overlays), flags `0`,
the workspace id, then a password wrap block shared by every file of the workspace
(PBKDF2-HMAC-SHA256 over the NFC Lock password, 600,000 iterations written and
100,000...10,000,000 accepted, salt, and the AES-256-GCM-wrapped content key), then the
AES-256-GCM payload. The wrap AAD is bytes `0..<10`
plus `12..<49`; the payload AAD is the whole 121-byte header. Users keep these files, so v1 is a
contract:

- Never change what a v1 byte means. `LockEnvelopeTests.goldenV1` pins a golden file; never edit
  it to make a change pass. A new layout is version 2 with its own golden file, and every build
  keeps the v1 reader and Remove Lock.
- A newer version is refused as made by a newer Dblore and never overwritten; unknown kinds or
  flag bits are refused. Header checks run before any PBKDF2 or decryption.
- `LockedFileIO` is the only place that seals. A file read from an envelope is written back sealed
  with the same key until Remove Lock, and a failed seal is an error, never plain text.
- The Lock password and content keys live in the Keychain services `ace.thi.dblore.lock` and
  `ace.thi.dblore.lock.keys` (both in `SecretInventory`). Never log keys or passwords.

Lock tests never prompt and never use the real Keychain. Under the test host
(`SessionManager.isRunningAsTestHost`) `LockCenter` defaults to `InMemoryPasswordStore`,
`RefusingUnlockPrompter` and `UnavailableBiometricAuthenticator`, and `SessionManager` never
publishes locks into `LockRegistry.shared`. A test builds its own `LockRegistry()` and
`LockCenter` with an `UnlockPrompter` that answers yes or no, `GrantingOwnerTestAuthenticator`
(Debug only) for owner-authenticated reads, and `LockKeyStore(vault:modes:passcodeSet:)` over an
in-memory `KeychainBackend` (`OneServiceKeychain` in `LockedWorkspaceIOTests`) and a suite-scoped
`UserDefaults`.

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

A new feature or engine ships as a plugin by default when its dependency adds 5 MB or more, or
it holds a lot of memory or runs a process; it sits behind a narrow interface and needs no
private copy of the shared networking stack. Plugins load into Dblore's own process: a
sandboxed app cannot run a helper executable it downloaded (the sandbox quarantines the files
it writes and macOS refuses to execute them).

The catalog `Dblore/Utilities/Plugins/PluginCatalog.json` is `schemaVersion` 3 with a
`plugins` array. Every entry has `id`, `kind`, `version`, `url`, `sha256` and `maxSize`:

- `library` (`duckdb`): a signed, notarized `.dylib` named by `libraryFileName`.
  `PluginLoader` opens it without following symlinks and checks its size, SHA-256 and Team ID
  before `dlopen`.
- `bundle` (`local-ai`): a signed, notarized, stapled `.bundle` (`bundleName`,
  `bundleIdentifier`) shipped as `<Name>.zip`; the zip's SHA-256 is checked before it is
  unpacked, then `PluginLoader` checks the Team ID, the pinned `cdhash` and every sealed
  resource before `Bundle.load`.

Decoding is strict and a bad catalog is refused as a whole: ids are unique and match
`[a-z0-9][a-z0-9-]*`, `version` is dot-separated digits, `sha256` is 64 and `cdhash` 40
lowercase hex digits, the URL is the https github.com release asset under the tag
`plugin-<id>-v<version>`, and `maxSize` is positive and at most 256 MiB. A plugin installs to
`Plugins/<id>/<version>/` and is never unloaded: Remove deletes its files, and loaded code
stays until Dblore quits.

**On-device AI** is the `Plugins/LocalAI` project (version in `project.yml`; regenerate
`DbloreLocalAI.xcodeproj` with `xcodegen generate` after editing it). It shares only
`Dblore/Utilities/AI/LocalAIProtocol.swift` (protocol v1, one JSON object per request and
event) with the app. Only this project needs the Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`, once) and the skip flags (mlx-swift's
`CudaBuild` plugin and its packages' macros). They disable trust checks, so
`scripts/release-plugin.sh` and the `local-ai-helper` CI job also pass the resolved-file
options above, bound to the plugin's own `Package.resolved`:

```bash
xcodebuild test -project Plugins/LocalAI/DbloreLocalAI.xcodeproj -scheme DbloreLocalAI \
  -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation
```

Models are downloaded by the app, not the plugin: each `LocalModelCatalog` entry pins a full
commit SHA (`revision`) and every file by name, size and SHA-256, checked before install.
`scripts/pin-local-model.py <repo> <revision> [...]` prints those `files:` pins without
downloading weights. Bump a revision deliberately, after reviewing the upstream repo.

`scripts/release-plugin.sh --plugin <id>` (`duckdb`, the default, or `local-ai`) builds a
plugin artifact. `duckdb` downloads the pinned official DuckDB release, checks the upstream
SHA-256, re-signs the dylib with the Developer ID (hardened runtime) and notarizes it.
`local-ai` archives the bundle, signs it inside out, notarizes and staples it, writes
`dist/plugins/local-ai/DbloreLocalAI.zip` with its source fingerprint, and prints the zip's
SHA-256 and the bundle's cdhash for the catalog.

- **Local tests:** `--install-dev` writes the signed artifact, an ad-hoc-signed copy and a
  `dev-catalog.json` into the gitignored `.plugin-dev/` (`--plugin local-ai --install-dev`:
  `.plugin-dev/local-ai/`). The app suites that load them are gated; run them as their own
  command, with `TEST_RUNNER_DUCKDB_PLUGIN_TESTS=1 DUCKDB_PLUGIN_TESTS=1` or
  `TEST_RUNNER_LOCAL_AI_PLUGIN_TESTS=1 LOCAL_AI_PLUGIN_TESTS=1` (suites
  `PluginLoaderBundleTests` and `LocalAIBundleGatedTests`, via `-only-testing:DbloreTests/<Suite>`)
  in front of the app's `xcodebuild test` command in step 1 and without
  `SKIP_INTEGRATION_TESTS=true` (that variable turns every gate off).
- **Publish (maintainer only, manual):** `--publish` creates the public GitHub release
  `plugin-<id>-v<version>` with `--latest=false`, so `releases/latest` keeps pointing at the
  app DMG. `duckdb` builds, uploads and rewrites its catalog entry (review and commit it).
  `local-ai` never rebuilds and never touches the catalog: put the printed SHA-256 and cdhash in
  its entry, test with `--install-dev`, then `--publish` uploads exactly that zip, and only
  when its SHA-256, cdhash and source fingerprint match.
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
