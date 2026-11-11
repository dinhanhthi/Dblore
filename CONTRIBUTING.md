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
     `swift-format -i -r Dblore/ DbloreTests/ DbloreCLI/ Plugins/LocalAI/ Plugins/Engines/`). Check the files you changed
     with `swift-format lint --strict <files>`. In tests, wait for async work with
     `boundedWait("named step") { … }` (`DbloreTests/Support/BoundedWait.swift`), never an
     unbounded `while … { await Task.yield() }` loop: a timeout then fails with the step's name
     instead of hanging the suite. A loop that already gives up after N tries records an `Issue`.
  3. Keep pull requests focused, and describe what changed and why.

## Full test runs

Run the whole unit suite under a no-output watchdog, with a result bundle, and sample the test
host when it goes quiet:

```bash
SKIP_INTEGRATION_TESTS=true xcodebuild test -scheme Dblore \
  -destination 'platform=macOS,arch=arm64' -enableCodeCoverage NO \
  -resultBundlePath /tmp/run1.xcresult > run1.txt 2>&1 &
# no new result line in run1.txt for 20 s: sample the test host once per stall
sample "$(pgrep -f 'DerivedData/.*/Dblore.app/Contents/MacOS/Dblore' | head -1)" 10 -file stall-1.txt
# no output at all for 10 min: sample once more and kill the run (a hang, not a slow test)
xcrun xcresulttool get test-results tests --path /tmp/run1.xcresult   # per-test durations
```

A stall shows as many tests of unrelated suites finishing within the same second after 30 s or
more. The cause found so far: one `@MainActor` test kept the main thread busy, so every other
main-actor test waited, and cooperative pool threads parked behind it (a NotificationCenter post
from off the main thread to a `queue: .main` observer waits until the main thread runs it, and
a `DispatchSemaphore.wait` in a test gate blocks its pool thread). So keep heavy CPU work in
tests `nonisolated`, never block a pool thread on the main thread or a semaphore, and post to
main-queue observers asynchronously (`LocalDataNotifications.post` hops to the main queue).
Durations of 30–35 s in a parallel run that finishes in 80–90 s are queue time, not a stall.
Wall-clock assertions (`MCPJSONRPCTests`, `MongoshSplitterTests`) can fail above a load average
of about 40; rerun them alone. `LocalDataNotificationGate` records an issue naming its holder
and waiter after 45 s instead of wedging the run.

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

## Large catalogs

`LargeCatalogPerformanceTests` (trait `.requiresLargeCatalog`, off by default) builds a SQLite
file with 50,000 tables, 1,000 views and 5,000 foreign keys
(`DbloreTests/Support/LargeCatalogFixture.swift`, about 2 minutes per run) and times the schema
load, the sidebar filter, the command palette, autocomplete, the AI table pick, the diagram
layout of 300 tables and the sheets that list every table. Run it on its own, never with
`SKIP_INTEGRATION_TESTS` (that variable turns every gate off):

```bash
TEST_RUNNER_LARGE_CATALOG_TESTS=1 LARGE_CATALOG_TESTS=1 xcodebuild test -scheme Dblore \
  -destination 'platform=macOS,arch=arm64' -enableCodeCoverage NO \
  -only-testing:DbloreTests/LargeCatalogPerformanceTests
```

Each budget is 1.25x the median of three Debug runs on the maintainer's Mac (a 25 ms floor for
stages under 20 ms, 60 ms for sheet layouts), and every stage keeps the main actor's longest gap
at 100 ms or less. `PERF` lines land in
`~/Library/Containers/ace.thi.Dblore/Data/tmp/perf-results.txt`. Change a budget only with three
new runs written in its comment.

`MainThreadStallMonitor` logs every main run-loop turn of 50 ms or more to the unified log
(subsystem `ace.thi.dblore.app`, category `stall`). It is on in Debug builds; launch a Release
build with `-DbloreStallMonitor YES` to turn it on. Read it with
`log show --last 5m --predicate 'subsystem == "ace.thi.dblore.app" AND category == "stall"'`.

## Command-line tool

`dblore` is its own target (`DbloreCLI/`: Swift 6, nonisolated by default, hardened runtime, no
sandbox, no entitlements), built as a dependency of the app and copied to
`Dblore.app/Contents/Helpers/dblore` with Code Sign On Copy. The target sets
`PRODUCT_MODULE_NAME = DbloreCLI`: a module named `dblore` would overwrite
`Dblore.swiftmodule` on a case-insensitive disk. `DbloreCLI/Core` is compiled into both the tool
and `DbloreTests`, so `CLIContractTests` checks that the app's pairing and `/mcp` answers decode
with the tool's decoders, the five output formats, the flags, the exit codes (0 ok, 1 usage,
2 Dblore not running or its MCP server off or busy, 3 refused, 4 query error) and the hello proof. Change the app's
answers and the tool together.

Cells follow `MCPResultEncoder`: a date is `CellValue.outputString(wallClock:)` (naive columns
`yyyy-MM-dd HH:mm:ss[.ffffff]`, zoned ISO 8601 UTC with the fraction), and a decimal is a JSON
number only with at most 15 significant digits, else its exact text; the tool prints a decoded
`Decimal` as plain digits. A refusal exits 3 when its text is in `CLIClient.refusalTexts`, ends with "Nothing was sent to the database." or starts with "Missing or invalid argument: " (`CLIClient.isRefusal`).

- The tool talks only to Dblore's MCP server on `127.0.0.1`. Before it sends its token it posts a
  fresh nonce to `/cli/hello` and checks
  `HMAC-SHA256(proofKey, "dblore-cli-hello-v1" || nonce || port)` against the port it dialed.
- Its credentials are a 0600 file in `~/Library/Application Support/Dblore CLI/` (0700), not the
  login Keychain: each update re-signs the tool with a new CDHash, and the Keychain then prompts
  for and refuses the items the old binary wrote.
- The tool, the MCP server and Shortcuts open connections through `MCPConnectionPool`, whose
  `refuseUnattended` refuses password-command, Ask on connect and Vault rows and missing
  secrets. Their managers never get a typed password, a timed write unlock or a Replace Pin
  action.
- `scripts/build-release.sh` fails unless the exported helper has the Developer ID authority, the
  Team ID, the hardened runtime and a timestamp. Check a local build with
  `codesign -dv --verbose=4 <app>/Contents/Helpers/dblore`.

## Result values, cut cells and keyless rows

Producers set `ColumnInfo.wallClock` once on naive timestamp columns (PostgreSQL `timestamp`,
MySQL `DATETIME`, DuckDB `TIMESTAMP`), and every rebuild of a `ColumnInfo` keeps it; a missing
flag means zoned. Exact NUMERIC and DECIMAL values are `CellValue.decimal(String)`, never a
`Double`; a SQL literal writes one unquoted only when `DecimalText.isPlain` holds. Notebook files
add keys older builds ignore: `wallClock` on a column, `micros` on a date cell (`value` keeps
whole seconds) and `decimal: true` on a string cell (read back only for valid decimal text).

A PostgreSQL or SQLite table without a primary key is edited by `RowLocatorKind`: PostgreSQL
`tableoid`, `ctid` and `xmin`, SQLite `rowid` plus every loaded non-binary column compared with
`IS`. The data viewer reads them under `dblore_*` aliases, strips them before the grid and
indexes them by page row, never by values; an UPDATE or DELETE that matches no row is a conflict.
MySQL/MariaDB introspection returns no locator, so those tables still need a primary key.

Reads are whole unless a caller opts in. `execute` / `executeDetailed` take
`readLimits: CappedReadLimits? = nil`; only `NotebookViewModel.resultReadLimits` passes
`CappedReadLimits.app` (1,048,576 characters per cell, binary the same bytes, 256 MiB per
result, `marksCutCells`), from notebook cell runs (`runTask`) and `executeEditorQuery` when it
has no `pageState` and the tab no `dataViewer`, and never for mongosh (the document editor could
write a cut value back). Every other read stays nil and whole: data viewer pages (they read
text as a 16,384-character prefix plus its UTF-8 byte length, and `LazyCellLoader` loads the
full value), full-value loads, Data Rewind capture, foreign-key lookups, import and Generate
Rows reads, catalog reads, the SQL dump and the all-rows export. MCP read managers keep their
own `readLimits`. A cut cell is kept at exactly the limit and listed in `cutCells`, which every
place that builds or copies a `QueryResult` / `CellResult` carries with `stoppedAtByteBudget`
(grep `truncated =` when you add one) and notebook files persist as optional keys; a cut cell
under a partial mask style gets the full mask, and copy, export, pin and edit refuse it through
the `LazyCellLoader` helpers. A byte-budget stop sets `truncated`, so outside a transaction
`resetSessionIfCapped` resets the session as for a row-cap stop (session settings, temporary
tables and advisory locks are lost; MySQL gets KILL QUERY) and skips the rest of the script.

**All rows export.** `ResultExportRunner` runs the result's one read (`ReadOnlyQueryGuard`, no
`:name` parameters) again in `withDumpSnapshot(purpose: .resultExport)` on its own manager
(DuckDB: the tab's manager, refused with a transaction open), masks each row with the grid's
`maskPlan(for:)` (fail closed) and streams it through `StreamedResultWriter` to a 0600
temporary file. It carries the tab session's PostgreSQL `search_path`, `TimeZone` and `DateStyle`
(`set_config(..., true)` after BEGIN) and MySQL/MariaDB database, `time_zone`, `sql_mode`,
`group_concat_max_len` and `div_precision_increment`. It refuses open or staged changes,
temporary tables (PostgreSQL, MySQL, SQLite), a PostgreSQL `SET ROLE`, MySQL `@name` variables,
an `ANSI_QUOTES` / `NO_BACKSLASH_ESCAPES` sql_mode, unreadable state and other column names.
Not carried or refused: `SET SESSION AUTHORIZATION`, custom settings read by row-level
security, other PostgreSQL output settings, MySQL `character_set_results` and SQLite attached
files; a Vault connection connects without the tab's lease, as the SQL dump does.

## SQL text and PostgreSQL qualification

Swift compares `Character`s (grapheme clusters): a quote or backslash followed by a combining
mark is one `Character` that is not equal to the bare symbol. Never escape or scan SQL with
`replacingOccurrences(of: "'", …)` or `contains("\\")`; quote with `SQLDialect.quoteIdentifier`
and `literal`, escape with `SQLDialect.escapingScalars`, and make scanners walk
`unicodeScalars`. `SQLDialectTests` pins names and values with combining marks on every dialect.

PostgreSQL catalog reads run on the user's session, under the user's `search_path`, where a
planted function or operator can win over the built-in one. Every catalog statement names
`pg_catalog` for each relation, function, operator (`a OPERATOR(pg_catalog.=) b`), cast
(`::pg_catalog.int8`) and regclass literal (`'pg_catalog.pg_class'::pg_catalog.regclass`), and
reads `pg_catalog` directly instead of SQL-language helpers such as `obj_description` or
`information_schema` (on PostgreSQL 13 and older they parse under the caller's path).
`pg_catalog.to_regclass($1)` on a bound user-typed name is the only carve-out.
`PostgresCatalogQualificationTests` lints every introspector statement (pinning how many each
entry point sends), the manager's own catalog reads and the static catalog SQL, so add a new
entry point or statement there.

SQL the app builds on user data (edits, row locators, Data Rewind, the data viewer and filters,
foreign-key lookups, Find a Value, cascade preview, import, Copy Objects) runs under the same
path. Write its operators, functions and casts with the `SQLDialect` helpers (`comparison`,
`inList`, `like`, `cast`, `function`, `concatenation`), never by hand: on PostgreSQL they name
`pg_catalog`, and every other dialect's text stays byte-identical. A comparison on a column
passes the column's `PostgresColumnType` (`DatabaseColumn.postgresType`,
`TableStructure.Column.postgresType`), which the server classifies in the two column reads
(`PostgresColumnTypeSQL`): a type owned by an allowlisted extension (through `pg_depend`), or a
domain over one, is written `OPERATOR(<extension schema>.<op>)`, with both sides cast to the
base type for a domain; anything else, and missing type data, gets `pg_catalog`. Never write a
bare operator or match a type by its name. `qualified(schema:name:)` keeps the schema on
PostgreSQL, `public` included. `PostgresUserDataQualificationTests` runs every such
builder's PostgreSQL output through `DbloreTests/Support/PostgresQualificationLint.swift` (an
extension operator passes only with matching type data), so add a new builder there. A
PostgreSQL restore pins `search_path = pg_catalog, pg_temp` around the dump
(`SQLRestoreSearchPathPinTests`). `PostgresSearchPathIntegrationTests` (`.requiresPostgres`)
checks planted objects against a real server.

## SQL dump format and restore

A dump starts with `-- Dblore SQL dump 1 engine=<engine> created=<date>`. A dump that writes a
DROP is version 2 (`-- Dblore SQL dump 2 ...`), so older builds refuse it at the header and never
meet the DROP; a dump without one stays version 1, byte for byte. Restore
(`Dblore/Database/DatabaseConnectionManager+Restore.swift`) accepts only
`DROP VIEW / TABLE / SEQUENCE / DOMAIN / TYPE IF EXISTS` under version 2, only for objects the
same script creates, and never CASCADE; on SQLite it first refuses when a table outside the dump
cascades from a dropped one. A new statement kind that older builds must not run needs a new
version. `SQLDumpWriterTests`, `SQLRestoreGateTests` and `SQLDumpRoundTripTests` pin both sides.

A restore reads the file twice and never holds it whole. Pass 1 (`SQLRestorePlan(file:)`)
reads it through `SQLStatementStream` (1 MiB chunks, incremental UTF-8,
`SQLTokenizer.splitStatements(scalars:isFinal:state:)`, which must give the whole-text split
for any chunk boundary) into `SQLRestorePlanner`, and keeps per statement only its SHA-256
digest, kind and gate classification, plus the Safe Mode confirmation rows of non-data
statements (up to `maxConfirmationBytes`, 16 MiB). There is no file cap; a statement over
`maxStatementBytes` (64 MiB) is refused. Pass 2 (`RestoreStatementSource`) reads the file
again and yields statement N only when its digest, kind and classification equal pass 1's; a
changed, missing or appended statement throws `fileChanged(index:)` before it is sent
(PostgreSQL, SQLite and DuckDB roll back; MySQL has run the statements before it). The
security-scoped access stays open across both passes. Under Protected mode the pending list
gets one line per statement kind (operation `RESTORE`, text "N data statements"), not one per
statement.
`SQLStatementStreamTests`, `SQLRestoreStreamTests` and `SQLRestoreFilePlanTests` pin it.

## Streamed import

The one-file import sheet streams CSV, TSV and NDJSON (a `.json` file whose first
non-whitespace character after a BOM is `{`) into a new or existing table; keyed imports, JSON
arrays and multi-file imports (`MultiFileImportModel` never passes `allowsStreaming`) keep the
in-memory path and its 256 MiB / 100,000-row limits. `ImportFileStream` reads 1 MiB chunks in
the preview's encoding into `DelimitedTextReader.RecordStream` or
`JSONRowsReader.LineStream`, which bound a record by the header's column count and
`maxRecordBytes` (64 MiB). Pass 1 checks the header (NDJSON: the union of keys over the whole
file, else `columnsChanged`), counts rows, applies the field limit, takes the DuckDB decimal
digits over every row and keeps one SHA-256 per block of 1,000 rows. Pass 2 is a
`StreamedBatch`: `nextChunk` reads the next block, compares its digest before building any SQL
(`fileChanged`, nothing of it is sent) and returns its INSERTs. CREATE TABLE is the prelude on
PostgreSQL, SQLite and DuckDB; MySQL/MariaDB send it first on its own (it commits), so the
empty table stays if the rows fail. `TableImportStreamTests` and `ImportFileStreamTests` pin
it.

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

A new feature ships as a plugin by default when its dependency adds 5 MB or more, or it holds a
lot of memory or runs a process; it sits behind a narrow interface and needs no private copy of
the shared networking stack. A new database engine is always an engine plugin, whatever its
size, so the app does not grow per engine. Plugins load into Dblore's own process: a
sandboxed app cannot run a helper executable it downloaded (the sandbox quarantines the files
it writes and macOS refuses to execute them).

The catalog `Dblore/Utilities/Plugins/PluginCatalog.json` is `schemaVersion` 3 with a
`plugins` array. Every entry has `id`, `kind`, `version`, `url`, `sha256` and `maxSize`:

- `library` (`duckdb`): a signed, notarized `.dylib` named by `libraryFileName`.
  `PluginLoader` opens it without following symlinks and checks its size, SHA-256 and Team ID
  before `dlopen`.
- `bundle` (`local-ai`, `sqlserver`, `clickhouse`): a signed, notarized, stapled `.bundle`
  (`bundleName`, `bundleIdentifier`) shipped as `<Name>.zip`; the zip's SHA-256 is checked
  before it is unpacked, then `PluginLoader` checks the Team ID, the pinned `cdhash` and every
  sealed resource before `Bundle.load`.

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

**Database engines** are bundles too, built from `Plugins/Engines` (`project.yml`, regenerate
`DbloreEngines.xcodeproj` with `xcodegen generate`): `Shared/` holds the entry points and the
request handler every engine compiles, `ClickHouse/` and `SQLServer/` one driver each, and
`Tests/` host-less unit tests. Engine protocol v1 lives in
`Dblore/Database/EnginePlugin/EnginePluginProtocol.swift` (Foundation only, compiled into each
bundle by path); the app side is `EnginePluginSession`, `EnginePluginIntrospector` and the
runtime loader next to it. A bundle exports exactly two C symbols:
`dblore_engine_protocol()` returns `1`, and `dblore_engine_request(json, context, emit)` takes
one request JSON object and answers through `emit` with event JSON objects. Requests map to
`DatabaseSession` and `SchemaIntrospector` calls; rows come in batches of about 512 KiB under a
1 MiB event cap, at most two ahead of the app's `more` credit, and a larger cell goes as
`chunk` events up to 256 MiB.
New features are additive and advertised in `hello.features`, so the version stays 1. The
password appears only in `open` and is never logged or echoed. For an SSH tunnel the app opens
the tunnel and hands the plugin `127.0.0.1:<port>` plus the TLS server name. Every event is
untrusted input to the app.

ClickHouse uses only Foundation and Security (its HTTP interface). SQL Server links FreeTDS
(db-lib, LGPL-2.1) and OpenSSL (Apache-2.0) statically: run
`Plugins/Engines/SQLServer/deps/build-deps.sh` once before building it. The script pins FreeTDS
1.5.21 and OpenSSL 3.5.9 by source URL and SHA-256 and builds arm64 static libraries into the
gitignored `dist/deps/sqlserver/`; with the public plugin source, the pinned tarball lets the
bundle be relinked against a modified FreeTDS. To bump FreeTDS, change the pin and also the FreeTDS version in the source link of
`PluginDisplayInfo` (`Dblore/Views/Settings/PluginsSettingsSection.swift`). Both schemes run the
same unit tests; `DbloreSQLServer` also builds the SQL Server bundle, so it needs the libraries:

```bash
xcodebuild test -project Plugins/Engines/DbloreEngines.xcodeproj -scheme DbloreClickHouse \
  -destination 'platform=macOS,arch=arm64'
```

Models are downloaded by the app, not the plugin: each `LocalModelCatalog` entry pins a full
commit SHA (`revision`) and every file by name, size and SHA-256, checked before install.
`scripts/pin-local-model.py <repo> <revision> [...]` prints those `files:` pins without
downloading weights. Bump a revision deliberately, after reviewing the upstream repo.

`scripts/release-plugin.sh --plugin <id>` (`duckdb`, the default, `local-ai`, `sqlserver` or
`clickhouse`) builds a plugin artifact. `duckdb` downloads the pinned official DuckDB release,
checks the upstream SHA-256, re-signs the dylib with the Developer ID (hardened runtime) and notarizes it.
`local-ai` archives the bundle, signs it inside out, notarizes and staples it, writes
`dist/plugins/local-ai/DbloreLocalAI.zip` with its source fingerprint, and prints the zip's
SHA-256 and the bundle's cdhash for the catalog. `sqlserver` and `clickhouse` do the same into
`dist/plugins/<id>/` (SQL Server runs `build-deps.sh` first) with a source fingerprint per
engine; the version is the archived bundle's.

- **Local tests:** `--install-dev` writes the signed artifact, an ad-hoc-signed copy and a
  `dev-catalog.json` into the gitignored `.plugin-dev/` (`--plugin local-ai --install-dev`:
  `.plugin-dev/local-ai/`). The app suites that load them are gated; run them as their own
  command, with `TEST_RUNNER_DUCKDB_PLUGIN_TESTS=1 DUCKDB_PLUGIN_TESTS=1` or
  `TEST_RUNNER_LOCAL_AI_PLUGIN_TESTS=1 LOCAL_AI_PLUGIN_TESTS=1` (suites
  `PluginLoaderBundleTests` and `LocalAIBundleGatedTests`, via `-only-testing:DbloreTests/<Suite>`)
  in front of the app's `xcodebuild test` command in step 1 and without
  `SKIP_INTEGRATION_TESTS=true` (that variable turns every gate off). Engine bundles go to
  `.plugin-dev/<id>/`. Live engine suites get the traits `requiresEnginePlugin`,
  `requiresSQLServer` and `requiresClickHouse` (`TEST_RUNNER_ENGINE_PLUGIN_TESTS`,
  `TEST_RUNNER_SQLSERVER_TESTS`, `TEST_RUNNER_CLICKHOUSE_TESTS`); no suite uses them yet.
- **Publish (maintainer only, manual):** `--publish` creates the public GitHub release
  `plugin-<id>-v<version>` with `--latest=false`, so `releases/latest` keeps pointing at the
  app DMG. `duckdb` builds, uploads and rewrites its catalog entry (review and commit it).
  `local-ai`, `sqlserver` and `clickhouse` never rebuild and never touch the catalog: put the
  printed SHA-256 and cdhash in the entry, test with `--install-dev`, then `--publish` uploads
  exactly that zip, and only when its SHA-256, cdhash and source fingerprint match (for an
  engine, also the bundle's version).
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
