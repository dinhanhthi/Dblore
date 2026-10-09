# Changelog

All notable user-visible changes to Dblore, newest first. Each release is a section headed `## vX.Y.Z (YYYY-MM-DD)` with `### Added`, `### Improved`, `### Fixed` and `### Upgrade notes` subsections (empty ones omitted); every entry ends with links to its commits. Sections are written by `/cf-ship`, and the release workflow publishes the matching section as the GitHub Release notes.

## Unreleased

### Added

- **DuckDB, as an optional plugin.** Install DuckDB from Settings > Plugins; it downloads a signed, notarized `libduckdb.dylib` and checks its SHA-256 before every load, and Remove deletes it. Open a `.duckdb` file (read-only by default, also from Finder), create one or use an in-memory database, browse its schema tree, and query Parquet or CSV files with the "Query Parquet/CSV File..." palette action. Safe Mode guards DuckDB writes such as `INSTALL`, `ATTACH`, `COPY ... TO` and `CREATE TABLE`; row edits, data import and foreign-key lookup are not available for DuckDB. A saved DuckDB connection without the plugin offers an Install button. [#0b537ef1](https://github.com/dinhanhthi/Dblore/commit/0b537ef1) [#34364049](https://github.com/dinhanhthi/Dblore/commit/34364049) [#ad27f360](https://github.com/dinhanhthi/Dblore/commit/ad27f360) [#5b95427d](https://github.com/dinhanhthi/Dblore/commit/5b95427d)
- **PostgreSQL over SSH.** Connect through an SSH tunnel with a password or an ed25519/ECDSA private key, including passphrase-protected keys (the passphrase is never stored). The first connection asks you to trust the server's host-key fingerprint, and a changed host key blocks the connection. RSA keys are not supported. Saved SSH passwords, keys and trusted host keys can be deleted in Settings > Data. [#2ebd7fb5](https://github.com/dinhanhthi/Dblore/commit/2ebd7fb5) [#bcc8755a](https://github.com/dinhanhthi/Dblore/commit/bcc8755a) [#581bb704](https://github.com/dinhanhthi/Dblore/commit/581bb704)
- **Import connections** from `.pgpass`, a PostgreSQL URI, DBeaver (including saved passwords), TablePlus and DataGrip. Preview and pick the connections first; duplicates and connections without a password are flagged. Available from the welcome screen, the saved connections list and the File menu. [#dbce5881](https://github.com/dinhanhthi/Dblore/commit/dbce5881) [#6cd3f1b5](https://github.com/dinhanhthi/Dblore/commit/6cd3f1b5)
- **Pin and compare results.** Pin a cell or SQL editor result, re-run, and compare both side by side with added, removed and changed rows highlighted; two `EXPLAIN` JSON plans compare node by node. A notebook cell's pin is saved in the file when results are saved. [#fa317b83](https://github.com/dinhanhthi/Dblore/commit/fa317b83)
- **Long-query notifications.** Get a macOS notification when a query runs longer than a threshold (default 10 seconds, by default only while Dblore is in the background). It shows the tab, duration and row count, never the SQL or data; clicking it opens the tab. Off by default, in General settings. [#95adb329](https://github.com/dinhanhthi/Dblore/commit/95adb329)
- **Routine and trigger source.** The schema sidebar lists triggers, and View Source opens a function, procedure or trigger definition in a read-only tab, with Copy and "Open as editable copy". [#95f19c7a](https://github.com/dinhanhthi/Dblore/commit/95f19c7a) [#9d0963bd](https://github.com/dinhanhthi/Dblore/commit/9d0963bd)

### Improved

- **Connection history** keeps up to 50 connections (was 6), and entries written by a newer Dblore version are kept instead of emptying the history. [#53f86a0c](https://github.com/dinhanhthi/Dblore/commit/53f86a0c) [#dbce5881](https://github.com/dinhanhthi/Dblore/commit/dbce5881)

### Upgrade notes

- **Client certificates** saved before v0.5.0 and never opened since must be re-imported: the fallback that read their old Keychain entry is removed. The orphaned entries (service `ace.thi.dblore.client-certificate`) can be deleted in Keychain Access. [#53f86a0c](https://github.com/dinhanhthi/Dblore/commit/53f86a0c)
- **Downgrading to v0.5.0:** v0.5.0 cannot read a saved DuckDB connection, so its whole connection history shows as empty, and re-saving a connection there drops its SSH tunnel settings. [#53f86a0c](https://github.com/dinhanhthi/Dblore/commit/53f86a0c) [#34364049](https://github.com/dinhanhthi/Dblore/commit/34364049)

## v0.5.0 (2026-10-06)

### Added

- **Command palette.** Find and run commands with `Cmd+K`. The first match is highlighted as results arrive, and Escape closes the palette and restores focus. [#140da3a8](https://github.com/dinhanhthi/Dblore/commit/140da3a8) [#5ab3cbcd](https://github.com/dinhanhthi/Dblore/commit/5ab3cbcd) [#1825db9d](https://github.com/dinhanhthi/Dblore/commit/1825db9d)
- **Audit history.** Query history can show only writes, and double-clicking a non-replayable entry opens its details. [#9c19abc0](https://github.com/dinhanhthi/Dblore/commit/9c19abc0) [#3d07c372](https://github.com/dinhanhthi/Dblore/commit/3d07c372)
- **Undo staged grid edits** from the Edit menu. [#f1de6b71](https://github.com/dinhanhthi/Dblore/commit/f1de6b71) [#9c452aba](https://github.com/dinhanhthi/Dblore/commit/9c452aba)
- **Named SQL parameters.** Bind `:name` values in the SQL editor sidebar and in an inline form on each notebook cell, and choose whether those values are saved in the file. The form hides when the cell no longer has a named parameter, and SQLite `@name` or `$name` mixed with `:name` is refused. [#84a1fef2](https://github.com/dinhanhthi/Dblore/commit/84a1fef2) [#01ef1402](https://github.com/dinhanhthi/Dblore/commit/01ef1402) [#adcb5872](https://github.com/dinhanhthi/Dblore/commit/adcb5872) [#77b0890c](https://github.com/dinhanhthi/Dblore/commit/77b0890c) [#b6606b24](https://github.com/dinhanhthi/Dblore/commit/b6606b24) [#f2d1535d](https://github.com/dinhanhthi/Dblore/commit/f2d1535d) [#9d860244](https://github.com/dinhanhthi/Dblore/commit/9d860244)
- **Foreign-key lookup.** Look up a referenced row while editing, jump to it, and follow foreign keys on aliased single-table results. Declining the jump keeps the draft, and partition foreign keys are skipped. [#c76c5372](https://github.com/dinhanhthi/Dblore/commit/c76c5372) [#c555f34f](https://github.com/dinhanhthi/Dblore/commit/c555f34f) [#0fb4920b](https://github.com/dinhanhthi/Dblore/commit/0fb4920b)
- **Import data.** Import CSV, TSV, JSON and newline-delimited JSON from the File menu or a table menu. Preview rows and `NULL` values, map columns, override inferred types, review the generated SQL and cancel a running import. [#a04dce9b](https://github.com/dinhanhthi/Dblore/commit/a04dce9b) [#d216e8fb](https://github.com/dinhanhthi/Dblore/commit/d216e8fb) [#542bb8b8](https://github.com/dinhanhthi/Dblore/commit/542bb8b8) [#fffdcec4](https://github.com/dinhanhthi/Dblore/commit/fffdcec4) [#6d6d247d](https://github.com/dinhanhthi/Dblore/commit/6d6d247d)
- **PostgreSQL client certificates.** Authenticate with a client certificate, store the private-key passphrase in the Keychain, and choose a custom certificate authority. The connection form shows the certificate in a highlighted box. [#ba1c2bdf](https://github.com/dinhanhthi/Dblore/commit/ba1c2bdf) [#8c73bce0](https://github.com/dinhanhthi/Dblore/commit/8c73bce0) [#538e90cb](https://github.com/dinhanhthi/Dblore/commit/538e90cb) [#6b486b3e](https://github.com/dinhanhthi/Dblore/commit/6b486b3e)
- **Commit style.** Choose Immediate, Confirm, Review or Password for dialogs, unlock and inline cell edits, from the footer and Settings. View mode uses the same style. [#380ae74a](https://github.com/dinhanhthi/Dblore/commit/380ae74a) [#57cfb4c5](https://github.com/dinhanhthi/Dblore/commit/57cfb4c5) [#c2afa8d8](https://github.com/dinhanhthi/Dblore/commit/c2afa8d8) [#96d25349](https://github.com/dinhanhthi/Dblore/commit/96d25349) [#c895db63](https://github.com/dinhanhthi/Dblore/commit/c895db63) [#b5c73de2](https://github.com/dinhanhthi/Dblore/commit/b5c73de2)
- **Restore the last session.** General settings choose whether startup shows the welcome screen or reopens the last session. [#d35a3163](https://github.com/dinhanhthi/Dblore/commit/d35a3163) [#3d2cc3b2](https://github.com/dinhanhthi/Dblore/commit/3d2cc3b2)
- **Session timeouts.** Set global PostgreSQL statement, lock and idle-transaction timeouts, and override them on a connection. [#296985cc](https://github.com/dinhanhthi/Dblore/commit/296985cc)
- **Edit or retry an AI message.** Try again on a user message, or edit that message and resend it. [#903a2c2b](https://github.com/dinhanhthi/Dblore/commit/903a2c2b) [#1114426b](https://github.com/dinhanhthi/Dblore/commit/1114426b)

### Improved

- **Query errors** show a server hint, or a cast hint when a bound parameter has no PostgreSQL type. [#05d8f0ca](https://github.com/dinhanhthi/Dblore/commit/05d8f0ca) [#538c0779](https://github.com/dinhanhthi/Dblore/commit/538c0779)
- **Connection status** stays on one short line, and recent connection names stay on one line. [#e5429626](https://github.com/dinhanhthi/Dblore/commit/e5429626) [#2f0b88a2](https://github.com/dinhanhthi/Dblore/commit/2f0b88a2) [#9db8ee4e](https://github.com/dinhanhthi/Dblore/commit/9db8ee4e)
- **Settings and safety copy.** Settings rows use switches and tabs, Safe Mode actions use filled buttons, and safety help explains the protection level. [#7424b92f](https://github.com/dinhanhthi/Dblore/commit/7424b92f) [#fee89f17](https://github.com/dinhanhthi/Dblore/commit/fee89f17) [#bccbb070](https://github.com/dinhanhthi/Dblore/commit/bccbb070) [#d0a7f2e9](https://github.com/dinhanhthi/Dblore/commit/d0a7f2e9)

### Fixed

- **PostgreSQL arrays** show their values instead of `NULL`. [#50559330](https://github.com/dinhanhthi/Dblore/commit/50559330)
- **Generated columns** stay read-only, including on PostgreSQL before 12. [#9af38b4e](https://github.com/dinhanhthi/Dblore/commit/9af38b4e) [#721e7933](https://github.com/dinhanhthi/Dblore/commit/721e7933)
- **Dates** keep microsecond precision for edits and foreign-key lookups. [#6c8b0981](https://github.com/dinhanhthi/Dblore/commit/6c8b0981)
- **NULL cells** in the right sidebar can be edited with the column type, through the notebook connection. [#ecdb358c](https://github.com/dinhanhthi/Dblore/commit/ecdb358c) [#0f6a6162](https://github.com/dinhanhthi/Dblore/commit/0f6a6162)
- **Schema** reloads after writes, and the paused notice sits in the sidebar footer. [#b4bdb28c](https://github.com/dinhanhthi/Dblore/commit/b4bdb28c) [#9072550f](https://github.com/dinhanhthi/Dblore/commit/9072550f)
- **Clearing recent connections** asks before removing saved passwords and certificates. [#d13ab4fd](https://github.com/dinhanhthi/Dblore/commit/d13ab4fd)
- **AI replies** that are not SQL stay out of SQL code blocks, and requests to `api.openai.com` are not token-capped. [#976ba510](https://github.com/dinhanhthi/Dblore/commit/976ba510) [#b716cc83](https://github.com/dinhanhthi/Dblore/commit/b716cc83)
- **SQLite result columns** map back to the table with `table_xinfo` ordinals, so edits and foreign keys use the right column. [#5f6f15a6](https://github.com/dinhanhthi/Dblore/commit/5f6f15a6)
- **Selected NULL text** stays readable, and the collapsed sidebar keeps its top border under the native tab bar. [#8aad8b01](https://github.com/dinhanhthi/Dblore/commit/8aad8b01) [#d901b2f7](https://github.com/dinhanhthi/Dblore/commit/d901b2f7)

## v0.4.2 (2026-10-03)

### Added

- **Native window tabs.** Group workspace windows with macOS tabs, open a new window tab with `Cmd+Shift+N`, and drag a document tab into a new window. General settings control whether new windows join a tab group and whether `Cmd+T` creates a notebook or SQL file. [#640939a](https://github.com/dinhanhthi/Dblore/commit/640939a) [#a4d0e39](https://github.com/dinhanhthi/Dblore/commit/a4d0e39) [#628c0d2](https://github.com/dinhanhthi/Dblore/commit/628c0d2) [#68cb839](https://github.com/dinhanhthi/Dblore/commit/68cb839) [#38460d1](https://github.com/dinhanhthi/Dblore/commit/38460d1)
- **Query history status filter.** Show only succeeded, failed or cancelled queries alongside the existing scope and search filters. [#d34632e](https://github.com/dinhanhthi/Dblore/commit/d34632e)

### Improved

- **Save an unsaved workspace.** The workspace info dialog offers Save with its edited name; Save Workspace As is available after the workspace has been saved. [#4e65b63](https://github.com/dinhanhthi/Dblore/commit/4e65b63)
- **Settings navigation.** The modal title shows the selected settings tab. [#7c1237d](https://github.com/dinhanhthi/Dblore/commit/7c1237d)

### Fixed

- **Stable history rows.** Row actions appear without shifting the history list. [#e7c0f96](https://github.com/dinhanhthi/Dblore/commit/e7c0f96)

## v0.4.1 (2026-10-03)

### Added

- **Pinned tabs and tab context menu.** Right-click a tab to pin it, close the tabs to its right or open it in a new window; pinned tabs survive `Cmd+W`. [#d8cb3ce](https://github.com/dinhanhthi/Dblore/commit/d8cb3ce) [#0819c04](https://github.com/dinhanhthi/Dblore/commit/0819c04) [#ed7529a](https://github.com/dinhanhthi/Dblore/commit/ed7529a) [#170572e](https://github.com/dinhanhthi/Dblore/commit/170572e)
- **Workspace and connection details.** The info button opens one modal with both the workspace and the connection details. [#7113227](https://github.com/dinhanhthi/Dblore/commit/7113227)
- **Editable recent cards.** Edit a recent workspace from the welcome screen. [#33beece](https://github.com/dinhanhthi/Dblore/commit/33beece)
- **AI assistant.** A settings button in the assistant header; replies are SQL only unless you ask for an explanation; headings and lists render in replies. [#3b34ba3](https://github.com/dinhanhthi/Dblore/commit/3b34ba3) [#e90370f](https://github.com/dinhanhthi/Dblore/commit/e90370f) [#efc5d21](https://github.com/dinhanhthi/Dblore/commit/efc5d21)

### Improved

- **Interface polish.** Notebook toolbar buttons match the Results buttons, Run uses the accent color, and every settings tab is a card like Data. [#1a3b225](https://github.com/dinhanhthi/Dblore/commit/1a3b225) [#4ee7d32](https://github.com/dinhanhthi/Dblore/commit/4ee7d32) [#661f10b](https://github.com/dinhanhthi/Dblore/commit/661f10b) [#f4bf124](https://github.com/dinhanhthi/Dblore/commit/f4bf124)

### Fixed

- **AI composer.** The message box scrolls and adapts its corner radius as it grows. [#3f0ee00](https://github.com/dinhanhthi/Dblore/commit/3f0ee00)

## v0.4.0 (2026-10-02)

### Added

- **SQLite files (beta).** Open a SQLite file from the connect modal and work with it like a server connection: SQL parsing, staged edits through the session, auto-connect and a read-only banner. Features the engine cannot support are hidden. [#c845590](https://github.com/dinhanhthi/Dblore/commit/c845590) [#602173c](https://github.com/dinhanhthi/Dblore/commit/602173c) [#644f16a](https://github.com/dinhanhthi/Dblore/commit/644f16a) [#87084cd](https://github.com/dinhanhthi/Dblore/commit/87084cd) [#c15ba6a](https://github.com/dinhanhthi/Dblore/commit/c15ba6a)
- **AI assistant.** A chat sidebar (toggle with `Cmd+L`) with cloud providers, ChatGPT sign-in and local MLX models, chats saved per workspace with a history, `Shift+Return` for a new line, and the table open in the data viewer attached as context. [#58b81f6](https://github.com/dinhanhthi/Dblore/commit/58b81f6) [#28eca04](https://github.com/dinhanhthi/Dblore/commit/28eca04) [#f4dfd6c](https://github.com/dinhanhthi/Dblore/commit/f4dfd6c) [#f4d36e2](https://github.com/dinhanhthi/Dblore/commit/f4d36e2) [#539f8d8](https://github.com/dinhanhthi/Dblore/commit/539f8d8) [#a4f28a6](https://github.com/dinhanhthi/Dblore/commit/a4f28a6) [#54c84f8](https://github.com/dinhanhthi/Dblore/commit/54c84f8) [#7a5d9e6](https://github.com/dinhanhthi/Dblore/commit/7a5d9e6) [#cb74895](https://github.com/dinhanhthi/Dblore/commit/cb74895)
- **Query history.** Every query is recorded locally and browsable from a history sidebar tab with detail and paging. [#5d0634b](https://github.com/dinhanhthi/Dblore/commit/5d0634b) [#67d49b9](https://github.com/dinhanhthi/Dblore/commit/67d49b9) [#932e789](https://github.com/dinhanhthi/Dblore/commit/932e789)
- **Result charts** with a grid/chart switch beside the results actions. [#67d49b9](https://github.com/dinhanhthi/Dblore/commit/67d49b9) [#25d9fe1](https://github.com/dinhanhthi/Dblore/commit/25d9fe1)
- **EXPLAIN plans** with a gate on `ANALYZE`. [#f5c422f](https://github.com/dinhanhthi/Dblore/commit/f5c422f)
- **Staged row edits.** Edit rows in the data viewer, review them as staged changes and commit them as one batch from the toolbar. [#292caa6](https://github.com/dinhanhthi/Dblore/commit/292caa6) [#82a0d11](https://github.com/dinhanhthi/Dblore/commit/82a0d11)
- **Export.** A download sheet with PDF and SQL `INSERT` formats, per-format options with reset, redaction, wrapping and a size check; SQL `INSERT` / `IN` list copy. [#4ea21a3](https://github.com/dinhanhthi/Dblore/commit/4ea21a3) [#a0b1633](https://github.com/dinhanhthi/Dblore/commit/a0b1633) [#7bf1e88](https://github.com/dinhanhthi/Dblore/commit/7bf1e88)
- **Local data backup.** A Data tab in settings to export, import and clear local data without secrets. [#9e820b4](https://github.com/dinhanhthi/Dblore/commit/9e820b4) [#d720571](https://github.com/dinhanhthi/Dblore/commit/d720571)
- **Column value filter** from the results grid header. [#168f036](https://github.com/dinhanhthi/Dblore/commit/168f036)
- **Sidebar name filter** with loose fuzzy match in each left tab. [#25baf2d](https://github.com/dinhanhthi/Dblore/commit/25baf2d)
- **Data viewer header** shows the open table and highlights it in the sidebar. [#a5e05f4](https://github.com/dinhanhthi/Dblore/commit/a5e05f4)
- **Welcome screen.** A save button for unsaved workspaces, inline rename of the workspace title and icon, and a hover remove button on recent cards. [#88bb137](https://github.com/dinhanhthi/Dblore/commit/88bb137) [#926d3fe](https://github.com/dinhanhthi/Dblore/commit/926d3fe) [#4cc2c2f](https://github.com/dinhanhthi/Dblore/commit/4cc2c2f)
- **Toasts** have a close button. [#301c9cb](https://github.com/dinhanhthi/Dblore/commit/301c9cb)

### Improved

- **Interface polish.** Dark backgrounds are lifted toward VS Code Dark, modals close with `Escape`, editor font sizes are configurable, and settings, history, tabs, buttons and tooltips got consistent spacing and hover states. [#c3d356c](https://github.com/dinhanhthi/Dblore/commit/c3d356c) [#932e789](https://github.com/dinhanhthi/Dblore/commit/932e789) [#65abd9d](https://github.com/dinhanhthi/Dblore/commit/65abd9d) [#58f8658](https://github.com/dinhanhthi/Dblore/commit/58f8658)
- **Faster tab switching.** Tabs switch on mouse-down. [#ecd44ec](https://github.com/dinhanhthi/Dblore/commit/ecd44ec)
- **Transactions.** The grid reloads after a rollback, and the transaction banner has a settings gear. [#95ebed9](https://github.com/dinhanhthi/Dblore/commit/95ebed9)

### Fixed

- Local model downloads finish despite a `swift-huggingface` cache error. [#3470d62](https://github.com/dinhanhthi/Dblore/commit/3470d62)
- Filtered search no longer matches hidden rows or re-enters highlights across cells. [#947ada7](https://github.com/dinhanhthi/Dblore/commit/947ada7) [#0171fb1](https://github.com/dinhanhthi/Dblore/commit/0171fb1)
- Right sidebars slide out the same way they slide in, and the traffic light background matches the open sidebar. [#6d46d08](https://github.com/dinhanhthi/Dblore/commit/6d46d08) [#0b06a06](https://github.com/dinhanhthi/Dblore/commit/0b06a06)
- A new welcome window opens when the last document window closes, and `.sqlws` files claimed by the legacy UTI can be selected in the open panel. [#d79b8e7](https://github.com/dinhanhthi/Dblore/commit/d79b8e7) [#9ac0b91](https://github.com/dinhanhthi/Dblore/commit/9ac0b91)
- The password eye toggle is clickable, and the SQLite name refills while a stale recent connection is cleared. [#d9b94cc](https://github.com/dinhanhthi/Dblore/commit/d9b94cc) [#e1e0f3f](https://github.com/dinhanhthi/Dblore/commit/e1e0f3f)

## v0.3.2 (2026-09-29)

### Improved

- **SQLNotebook is now Dblore.** The app has a new name, a new bundle identifier (`ace.thi.Dblore`) and a new update feed, and notebooks use the `.dblore` extension. Rename existing `.sqlnb` files to `.dblore` (the content is unchanged) to open them. Saved connections, passwords and settings from SQLNotebook are not carried over, and SQLNotebook 0.3.1 does not update itself: download Dblore from the releases page. [#4039647](https://github.com/dinhanhthi/Dblore/commit/4039647) [#e548ddf](https://github.com/dinhanhthi/Dblore/commit/e548ddf)
- **Wording no longer assumes SQL only.** Welcome screens, the "Run all" confirmation, the cell placeholder and the settings group title now speak about queries and notebooks in general; the `.sql` editor, Format SQL and SQL keyword highlighting keep their names. [#b0dbdcf](https://github.com/dinhanhthi/Dblore/commit/b0dbdcf)

## v0.3.1 (2026-09-29)

### Added

- **Column filters.** A filter sidebar with a header button builds `WHERE` conditions in card layout, and filters can be saved and reused from a popover in the header; the button shows an accent dot when a filter is applied. [#4d5bd5f](https://github.com/dinhanhthi/SQLNotebook/commit/4d5bd5f) [#cc39d89](https://github.com/dinhanhthi/SQLNotebook/commit/cc39d89) [#7880a78](https://github.com/dinhanhthi/SQLNotebook/commit/7880a78) [#fcd9505](https://github.com/dinhanhthi/SQLNotebook/commit/fcd9505)
- **Highlight cells and rows.** Highlight matching cells or rows in the results grid from the sidebar, with a softer tint and a live cell/row toggle; the button shows an accent dot when applied. [#3513bd1](https://github.com/dinhanhthi/SQLNotebook/commit/3513bd1) [#a0ce3bd](https://github.com/dinhanhthi/SQLNotebook/commit/a0ce3bd) [#f97bb01](https://github.com/dinhanhthi/SQLNotebook/commit/f97bb01) [#fcd9505](https://github.com/dinhanhthi/SQLNotebook/commit/fcd9505)
- **Favorites.** Save SQL snippets in a Favorites sidebar tab, with modals to add and edit them and insertion into the editor. [#a99a802](https://github.com/dinhanhthi/SQLNotebook/commit/a99a802) [#835cdac](https://github.com/dinhanhthi/SQLNotebook/commit/835cdac) [#a27b639](https://github.com/dinhanhthi/SQLNotebook/commit/a27b639)
- **Results cell context menu** with copy, see more and highlight. [#8c0d6e3](https://github.com/dinhanhthi/SQLNotebook/commit/8c0d6e3)
- **Sorted column tint** in the results grid. [#5a30d38](https://github.com/dinhanhthi/SQLNotebook/commit/5a30d38)
- **Current line highlight** in the SQL editor. [#4a3dc39](https://github.com/dinhanhthi/SQLNotebook/commit/4a3dc39)
- **Side-by-side editor layout** can be toggled and set as the default in settings, and the line number gutter fits its content. [#2d238bb](https://github.com/dinhanhthi/SQLNotebook/commit/2d238bb)
- **Refresh button** in the cell details sidebar, which also refreshes automatically. [#ba23546](https://github.com/dinhanhthi/SQLNotebook/commit/ba23546)
- **Rename a connection** from the connection info modal with an Apply button. [#d1382e9](https://github.com/dinhanhthi/SQLNotebook/commit/d1382e9)
- **App version** is shown on the welcome screen. [#8a537dc](https://github.com/dinhanhthi/SQLNotebook/commit/8a537dc)

### Improved

- **New app logo.** [#b06839a](https://github.com/dinhanhthi/SQLNotebook/commit/b06839a)
- **Faster app**: incremental SQL syntax highlighting, quicker schema loading with a non-blocking workspace open, a cached results grid display, debounced autocomplete and a delayed Sparkle update check. [#937b92a](https://github.com/dinhanhthi/SQLNotebook/commit/937b92a) [#3250c0b](https://github.com/dinhanhthi/SQLNotebook/commit/3250c0b) [#2b0252e](https://github.com/dinhanhthi/SQLNotebook/commit/2b0252e)
- **Data viewer header** now holds the footer controls, with a simpler pagination label. [#2d84bb3](https://github.com/dinhanhthi/SQLNotebook/commit/2d84bb3)
- **Remember connection** is on by default. [#a07c9ec](https://github.com/dinhanhthi/SQLNotebook/commit/a07c9ec)
- **Safe mode** protection icons use the app accent color. [#e856710](https://github.com/dinhanhthi/SQLNotebook/commit/e856710)

### Fixed

- Undo and redo in editors and cells no longer interfere with each other. [#9aba555](https://github.com/dinhanhthi/SQLNotebook/commit/9aba555)
- Tabs show the unsaved dot in the close button slot, which turns into an x on hover. [#8337c8f](https://github.com/dinhanhthi/SQLNotebook/commit/8337c8f)
- A single flat border sits under the tab bar without a glass rim. [#1547df1](https://github.com/dinhanhthi/SQLNotebook/commit/1547df1)

## v0.2.2 (2026-09-29)

### Added

- **Table data viewer.** Open a table's data in its own tab, with a compact header, search and an icon-only refresh button; pinned data viewer tabs are restored with the workspace. [#3cf3643](https://github.com/dinhanhthi/SQLNotebook/commit/3cf3643) [#8d0a055](https://github.com/dinhanhthi/SQLNotebook/commit/8d0a055) [#11d9f9a](https://github.com/dinhanhthi/SQLNotebook/commit/11d9f9a) [#c564a5f](https://github.com/dinhanhthi/SQLNotebook/commit/c564a5f)
- **Reopen the last closed tab** with `Cmd+Shift+T`. [#610854f](https://github.com/dinhanhthi/SQLNotebook/commit/610854f)
- **Format SQL button** next to the syntax highlight toggle in the editor. [#2f9291e](https://github.com/dinhanhthi/SQLNotebook/commit/2f9291e)
- **Results grid**: a row number column, double-click a column divider to fit its width to the content, column widths auto-fit when columns change, and the hovered row is highlighted. [#1017512](https://github.com/dinhanhthi/SQLNotebook/commit/1017512) [#4feca56](https://github.com/dinhanhthi/SQLNotebook/commit/4feca56) [#f949ef5](https://github.com/dinhanhthi/SQLNotebook/commit/f949ef5) [#024c1e4](https://github.com/dinhanhthi/SQLNotebook/commit/024c1e4)
- **Gray accent color** option; the default accent is now blue. [#7e5f892](https://github.com/dinhanhthi/SQLNotebook/commit/7e5f892)
- **Tooltips** on icon-only buttons. [#5efe9ab](https://github.com/dinhanhthi/SQLNotebook/commit/5efe9ab)

### Improved

- **Settings** now use a sidebar for navigation, and shortcuts are split into App and Editor tabs. [#04ae47a](https://github.com/dinhanhthi/SQLNotebook/commit/04ae47a) [#fdafe53](https://github.com/dinhanhthi/SQLNotebook/commit/fdafe53)
- **Results grid look**: vertical lines between columns, a distinct row number gutter and header background, a smaller column type font in the header and softer text color. [#e999315](https://github.com/dinhanhthi/SQLNotebook/commit/e999315) [#4a7cac4](https://github.com/dinhanhthi/SQLNotebook/commit/4a7cac4) [#f344b7d](https://github.com/dinhanhthi/SQLNotebook/commit/f344b7d) [#752ca2d](https://github.com/dinhanhthi/SQLNotebook/commit/752ca2d) [#c8f0fb3](https://github.com/dinhanhthi/SQLNotebook/commit/c8f0fb3) [#0b7f8e5](https://github.com/dinhanhthi/SQLNotebook/commit/0b7f8e5)
- **Cell details** now open with word wrap on and JSON auto-beautified. [#0acbd0a](https://github.com/dinhanhthi/SQLNotebook/commit/0acbd0a)
- **Stronger hover background** for inactive tabs. [#635d44e](https://github.com/dinhanhthi/SQLNotebook/commit/635d44e)
- **Faster UI**: smoother scrolling in large result grids and quicker tab switching. [#a8e2cb1](https://github.com/dinhanhthi/SQLNotebook/commit/a8e2cb1) [#7a549bb](https://github.com/dinhanhthi/SQLNotebook/commit/7a549bb)
- **Large reads inside transactions** are now capped with a server-side cursor. [#a2876aa](https://github.com/dinhanhthi/SQLNotebook/commit/a2876aa)

### Fixed

- Closing a window no longer crashes the app. [#318f601](https://github.com/dinhanhthi/SQLNotebook/commit/318f601)
- Dragging tabs to reorder no longer moves the window. [#7ca0bdc](https://github.com/dinhanhthi/SQLNotebook/commit/7ca0bdc)
- Autocomplete suggests tables and columns in every editor. [#2a70af8](https://github.com/dinhanhthi/SQLNotebook/commit/2a70af8)
- The SQL formatter keeps clause contents inline and aligns the `SELECT` list. [#6994523](https://github.com/dinhanhthi/SQLNotebook/commit/6994523)
- Connecting uses the active tab's configuration and is blocked on an invalid connection string. [#020b13b](https://github.com/dinhanhthi/SQLNotebook/commit/020b13b)
- The Save Workspace commands show in the File menu. [#7e3228a](https://github.com/dinhanhthi/SQLNotebook/commit/7e3228a)
- Navigation arrows keep their spacing when the left sidebar is collapsed. [#f06c717](https://github.com/dinhanhthi/SQLNotebook/commit/f06c717)

## v0.2.1 (2026-09-28)

### Improved

- **Lowered the minimum macOS to 14.** SQLNotebook now runs on macOS 14 and later (previously 26); the Liquid Glass look and the pointing-hand cursor still show on the macOS versions that support them. [#a51ce77](https://github.com/dinhanhthi/SQLNotebook/commit/a51ce77)
- **The installer DMG now includes a shortcut to the Applications folder**, so you can drag SQLNotebook straight in. [#b668e5b](https://github.com/dinhanhthi/SQLNotebook/commit/b668e5b)

## v0.2.0 (2026-09-28)

### Added

- **Automatic updates.** SQLNotebook now checks for new versions in the background and lets you install them with one click; check anytime from the **SQLNotebook > Check for Updates…** menu, or toggle background checks in **Settings > Updates**. [#d5ce6bf](https://github.com/dinhanhthi/SQLNotebook/commit/d5ce6bf)

## v0.1.0 (2026-09-27)

### Added

- **SQL notebooks (`.sqlnb`) and standalone `.sql` editor tabs**, both in a multi-tab, multi-window workspace with drag-to-reorder tabs, middle-click close, recent files, auto-save, and window state (size/position) restored per window. [#9ebc09c](https://github.com/dinhanhthi/SQLNotebook/commit/9ebc09c) [#4018865](https://github.com/dinhanhthi/SQLNotebook/commit/4018865) [#045362e](https://github.com/dinhanhthi/SQLNotebook/commit/045362e) [#1603d7c](https://github.com/dinhanhthi/SQLNotebook/commit/1603d7c)
- **Cell-based query execution**: run a single cell, run the query at the cursor (Simple Mode), or run all cells, with an execution queue, cancellable in-flight queries, per-cell row/execution-time metadata, and a confirmation before destructive "run all" queries. [#7024e1b](https://github.com/dinhanhthi/SQLNotebook/commit/7024e1b) [#5fafc02](https://github.com/dinhanhthi/SQLNotebook/commit/5fafc02) [#c1c6a7a](https://github.com/dinhanhthi/SQLNotebook/commit/c1c6a7a) [#4154cf2](https://github.com/dinhanhthi/SQLNotebook/commit/4154cf2)
- **Query editor**: SQL syntax highlighting, line numbers, autocompletion (table/column aware), word-wrap toggle, current-line highlight, comment/uncomment (`cmd+/`), undo/redo, and keyboard shortcuts for running the query or selection. [#86ebce8](https://github.com/dinhanhthi/SQLNotebook/commit/86ebce8) [#dcc1c28](https://github.com/dinhanhthi/SQLNotebook/commit/dcc1c28) [#7bfcfca](https://github.com/dinhanhthi/SQLNotebook/commit/7bfcfca) [#e5f123f](https://github.com/dinhanhthi/SQLNotebook/commit/e5f123f)
- **Results grid**: sortable, resizable and auto-fitting columns, primary key and type icons, pagination with a configurable row cap, in-grid search with match highlighting, and a cell-detail view with a JSON viewer and string beautifier. [#c2509ff](https://github.com/dinhanhthi/SQLNotebook/commit/c2509ff) [#a7acbaa](https://github.com/dinhanhthi/SQLNotebook/commit/a7acbaa) [#138f2c2](https://github.com/dinhanhthi/SQLNotebook/commit/138f2c2) [#e147c78](https://github.com/dinhanhthi/SQLNotebook/commit/e147c78)
- **Export results** to Excel, CSV, JSON, Markdown, PDF or TSV. [#deb7361](https://github.com/dinhanhthi/SQLNotebook/commit/deb7361)
- **Inline data editing** directly in the results grid (using `ctid` for PostgreSQL), staged or auto-committed depending on Safe Mode. [#c990840](https://github.com/dinhanhthi/SQLNotebook/commit/c990840) [#ce0c960](https://github.com/dinhanhthi/SQLNotebook/commit/ce0c960) [#4e8162f](https://github.com/dinhanhthi/SQLNotebook/commit/4e8162f)
- **Safe Mode**: five protection levels (à la TablePlus), confirmation before `DROP`/`TRUNCATE`/`ALTER`/`CREATE`, a warning on `DELETE`/`UPDATE` without a `WHERE` clause, a Protected mode with a pending-transaction Commit/Rollback banner, and Touch ID (with system-password fallback) to unlock changes. [#b725879](https://github.com/dinhanhthi/SQLNotebook/commit/b725879) [#74e4dc6](https://github.com/dinhanhthi/SQLNotebook/commit/74e4dc6) [#05dff6b](https://github.com/dinhanhthi/SQLNotebook/commit/05dff6b) [#47a597e](https://github.com/dinhanhthi/SQLNotebook/commit/47a597e)
- **Connections**: a connection form with saved history, configurable timeouts, SSL/certificate verification, retry on failure, and a read-only mode. [#3de7a6f](https://github.com/dinhanhthi/SQLNotebook/commit/3de7a6f) [#c5f35e4](https://github.com/dinhanhthi/SQLNotebook/commit/c5f35e4) [#aa0ab36](https://github.com/dinhanhthi/SQLNotebook/commit/aa0ab36) [#d1254e3](https://github.com/dinhanhthi/SQLNotebook/commit/d1254e3)
- **Schema visualizer**: a searchable, force-directed canvas of tables with resizable cards and toggleable foreign-key connection lines. [#6f0d668](https://github.com/dinhanhthi/SQLNotebook/commit/6f0d668) [#11875ef](https://github.com/dinhanhthi/SQLNotebook/commit/11875ef) [#c0f0c66](https://github.com/dinhanhthi/SQLNotebook/commit/c0f0c66) [#112f845](https://github.com/dinhanhthi/SQLNotebook/commit/112f845)
- **Workspace-level left sidebar** with the connected schema (tables, columns, row counts, types) and a per-tab right sidebar with cell/query details, both resizable and animated. [#7b90a18](https://github.com/dinhanhthi/SQLNotebook/commit/7b90a18) [#2766886](https://github.com/dinhanhthi/SQLNotebook/commit/2766886) [#cc7033f](https://github.com/dinhanhthi/SQLNotebook/commit/cc7033f)
- **Global and in-editor search**, and a "View Query"/"Run with query" bar that shows the exact SQL sent to the database, including the applied row limit. [#1dfe23f](https://github.com/dinhanhthi/SQLNotebook/commit/1dfe23f) [#0dfa64a](https://github.com/dinhanhthi/SQLNotebook/commit/0dfa64a) [#2872df4](https://github.com/dinhanhthi/SQLNotebook/commit/2872df4)
- **Sandboxed file access** via security-scoped bookmarks for workspaces, tabs and recent files, with a Developer ID–signed, notarized build. [#37236af](https://github.com/dinhanhthi/SQLNotebook/commit/37236af) [#c263b6f](https://github.com/dinhanhthi/SQLNotebook/commit/c263b6f) [#efc83a1](https://github.com/dinhanhthi/SQLNotebook/commit/efc83a1)
- **Liquid Glass design system**, dark/light theme with a selectable accent color, and a redesigned settings modal with one section per tab. [#d0bfecb](https://github.com/dinhanhthi/SQLNotebook/commit/d0bfecb) [#32a9b2c](https://github.com/dinhanhthi/SQLNotebook/commit/32a9b2c) [#ea2896d](https://github.com/dinhanhthi/SQLNotebook/commit/ea2896d) [#9a32f10](https://github.com/dinhanhthi/SQLNotebook/commit/9a32f10)

### Improved

- Query execution, search rendering and result-grid drawing moved off the main actor, and the left sidebar builds its entity rows lazily, keeping the UI responsive on large schemas and result sets. [#06fa6f1](https://github.com/dinhanhthi/SQLNotebook/commit/06fa6f1) [#36e7afd](https://github.com/dinhanhthi/SQLNotebook/commit/36e7afd) [#f0f126d](https://github.com/dinhanhthi/SQLNotebook/commit/f0f126d)
- The results grid was rewritten on `NSTableView` for smoother scrolling, sorting and inline editing. [#c2509ff](https://github.com/dinhanhthi/SQLNotebook/commit/c2509ff) [#613490e](https://github.com/dinhanhthi/SQLNotebook/commit/613490e)
