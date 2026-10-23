# Changelog

All notable user-visible changes to Dblore, newest first. Each release is a section headed `## vX.Y.Z (YYYY-MM-DD)` with `### Added`, `### Improved`, `### Fixed` and `### Upgrade notes` subsections (empty ones omitted); every entry ends with links to its commits. Sections are written by `/cf-ship`, and the release workflow publishes the matching section as the GitHub Release notes.

## v0.8.3 (2026-10-23)

### Added

- **Related rows before a delete.** When staged changes delete rows, Preview SQL and the Safe Mode dialog list what else the delete touches: rows deleted by cascade, rows set to NULL or to their default, and rows that still refer to the deleted ones. A foreign key that would block the delete disables Commit and names the constraint; Commit Anyway lets the database decide. The counts run on a separate read-only connection within 5 seconds, and are skipped while a transaction is open. [#d62df711](https://github.com/dinhanhthi/Dblore/commit/d62df711)
- **Set several cells at once.** Select rows, then right-click a column: Set Value… writes the same text, NULL or DEFAULT (PostgreSQL and MySQL) into every selected cell, and Generate UUID / Generate UUIDv7 writes a different UUID into each one (uuid, text and long enough character columns). It is one change to stage and one Undo. [#2bb7d3a5](https://github.com/dinhanhthi/Dblore/commit/2bb7d3a5)
- **PostgreSQL sequences and types.** The sidebar has Sequences and Types sections (enums, domains and composite types), loaded when opened, with Show DDL and Copy Name. [#21544615](https://github.com/dinhanhthi/Dblore/commit/21544615)
- **Data Dictionary.** File > Export Data Dictionary… writes the columns, indexes and foreign keys of every table as a Markdown or a standalone HTML file (no scripts, no remote content). [#bad7cc6f](https://github.com/dinhanhthi/Dblore/commit/bad7cc6f)
- **ER diagram as text.** The schema diagram can copy or save the tables shown as Mermaid or Graphviz DOT. [#bad7cc6f](https://github.com/dinhanhthi/Dblore/commit/bad7cc6f)
- **Compare Schemas.** File > Compare Schemas… compares two schemas of the same engine (PostgreSQL, MySQL/MariaDB, SQLite): another schema of this connection or a saved connection. It lists tables, columns, indexes and foreign keys to add, change or drop, shows the exact script, and runs it on this tab's connection only, through Safe Mode. Drops are unticked by default, lossy type changes are flagged, and changes that cannot be scripted are listed instead of run. [#48e8c53d](https://github.com/dinhanhthi/Dblore/commit/48e8c53d) [#856d3c3a](https://github.com/dinhanhthi/Dblore/commit/856d3c3a)
- **Copy formats.** Copy as Markdown in the grid menu, and Settings > Result Table > "Copy rows as" chooses what Cmd+C copies: TSV (the default), TSV or CSV with headers, CSV, JSON or Markdown. JSON keeps the column order and suffixes a repeated column name (`id_2`); NaN and infinite numbers are written as text. Markdown copies and exports turn line breaks into `<br>` and escape `\`, `|`, `&`, `<` and `>`.
- **Invisible characters.** Control characters, zero-width characters, special spaces and direction controls in a cell are shown as visible marks, with their code points in the tooltip; joiners inside emoji and words stay as they are. Copy, export and search still use the real text. Settings > Result Table turns it off.
- **Query Insights.** The History tab's chart button groups the queries you ran by shape (values replaced by `?`, `IN` lists folded) over 24 hours, 7 or 30 days, per connection: runs, average, p95 and slowest time, error rate and last run, sortable, with Open in Editor. [#b0599d57](https://github.com/dinhanhthi/Dblore/commit/b0599d57)
- **Find a value in every table.** A button next to the schema filter (and the command palette) searches the text of every column in up to 500 tables, one at a time on a separate read-only connection, with Contains or Equals, 50 rows and 10 seconds per table, and Cancel. Clicking a match opens the table filtered to it. PostgreSQL, MySQL/MariaDB and SQLite. [#b0599d57](https://github.com/dinhanhthi/Dblore/commit/b0599d57)
- **SQL snippets.** Settings > Editor > Snippets: a trigger word expands to a template with tab stops (`${1:default}`, `${1}`, `$0`), offered in autocomplete; Tab and Shift-Tab move between the stops. [#c08d72e1](https://github.com/dinhanhthi/Dblore/commit/c08d72e1)
- **Sidebar folders and hidden schemas.** Group tables and views into folders per connection (Move to Folder, drag, rename, delete), and hide schemas you do not use from the sidebar with the eye menu; hidden schemas stay available to SQL, autocomplete and search. [#93f666e7](https://github.com/dinhanhthi/Dblore/commit/93f666e7)
- **Export and import connections.** The welcome screen's Connections tab exports chosen connections, and optionally an open workspace's favorites, to a Dblore file; File > Import Connections… reads it back. Passwords, SSH secrets, keys, certificates and file databases are never exported; on import, connections already saved are skipped, a connection string pointing at other hosts is dropped, SSH tunnels and weaker settings are flagged, and favorites go into one folder without duplicates. [#78b70a1a](https://github.com/dinhanhthi/Dblore/commit/78b70a1a)
- **Connection scripts.** A connection can run your own scripts from `~/Library/Application Scripts/ace.thi.Dblore`: one before connecting (a failure stops the connect), one after disconnecting, and a password command whose first output line is used as the password for that connect only, never saved. Scripts get the host, port, user and database as arguments; a script that times out keeps running, since macOS gives Dblore no way to stop it. Quitting Dblore runs the after-disconnect scripts. Imported connections never bring scripts with them: choose them in the connection form. [#7ba4bac7](https://github.com/dinhanhthi/Dblore/commit/7ba4bac7)
- **xAI and Requesty.** Two more AI providers in Settings > AI, each with its own API key; the model list comes from the provider. Requests to Requesty go through its router to the model vendor. [#5c9e4e72](https://github.com/dinhanhthi/Dblore/commit/5c9e4e72)
- **Split a chart by a column.** The chart's Split by menu draws one small chart per value of a column (up to 12), with shared axes and one legend, and the PNG export includes the whole grid. [#5c9e4e72](https://github.com/dinhanhthi/Dblore/commit/5c9e4e72)
- **Geometry and vector viewers.** Cell Value draws PostGIS geometry and geography and MySQL GEOMETRY values (points, lines, polygons with holes, multi-part shapes and collections). It shows the shape type, point count and SRID, with the WKT and Copy WKT. Very large shapes are thinned, or drawn in part with a "Partial preview" note. pgvector `vector`, `halfvec` and `sparsevec` values show their dimension, norm, minimum and maximum, and their first values. PostgreSQL result columns of these types are named GEOMETRY, GEOGRAPHY, VECTOR and so on instead of USER-DEFINED. [#df6418b6](https://github.com/dinhanhthi/Dblore/commit/df6418b6)
- **MCP write tools.** Settings > MCP > Allow write tools (off by default) lets an agent ask to run one change through a new `execute_write` tool. It works only on allowlisted connections you give a write scope: data changes, or data and schema changes. Schema changes cover tables, indexes, views, sequences, schemas, types and domains, and on MongoDB creating, renaming and dropping collections and creating and dropping indexes (`collMod`, hidden indexes, views and `dropDatabase` are refused); agents cannot create, change or drop functions, procedures or triggers, and MongoDB system collections and pipelines that name another database are refused. Every call opens a Dblore panel that shows the exact statement. It runs only after you click Approve once: there are no standing grants, Return never approves, at most three requests wait, and an unanswered request is denied 2 minutes after it shows. Statements with hidden characters, privilege or account changes, extensions, foreign data, file access or more than one statement are refused before anything is asked. Connections whose commit style is Review or Password refuse agent changes. [#dc65bef3](https://github.com/dinhanhthi/Dblore/commit/dc65bef3) [#c12214bb](https://github.com/dinhanhthi/Dblore/commit/c12214bb)
- **Outside MCP servers.** Settings > MCP > Outside MCP servers adds an MCP server by URL and an optional token. The URL must be https, or plain http to 127.0.0.1, ::1 or localhost, and redirects are never followed. The token is kept in the Keychain and is listed and deleted with the other secrets in Settings > Data. Test connects to the server and lists its tools; you tick the ones the AI chat may use. A new server starts turned off with no tools allowed. If a server later changes a tool's description or schema, the tool shows "Changed" and is unticked until you review it again. Text from the server is shown with hidden and direction characters removed. [#d7539949](https://github.com/dinhanhthi/Dblore/commit/d7539949)
- **AI chat uses outside MCP tools.** On a connection whose AI access allows it, the chat can offer the tools you allowed on enabled outside MCP servers. It never does this with an on-device model. Each call shows a card with the server, the tool and the exact arguments. Nothing is sent until you press Run once; it accepts clicks only after the card has been shown for a moment, and every call asks again. The tool's result goes back to the assistant marked as data from a third party, never as instructions, and nothing in it can run SQL. Arguments the card cannot show exactly (hidden characters, or longer than the card) are refused. A server that does not answer within 10 seconds is left out of that turn, with a note in the chat. [#291851a8](https://github.com/dinhanhthi/Dblore/commit/291851a8)

### Improved

- **Copied rows are safe to paste into a spreadsheet.** Copying rows or cells as text puts an apostrophe before a text value that starts like a formula (`=`, `+`, `-`, `@`, tab or a line break), the same rule CSV and TSV exports use. Numbers, dates and Copy Value / Copy as INSERT / Copy as IN list stay raw. Settings > Result Table turns it off. [#0a6e014c](https://github.com/dinhanhthi/Dblore/commit/0a6e014c)
- **Large cell values open at once.** Cell Value shows a value over 256 KiB as plain text in a view that lays out only what is on screen, and Format JSON runs in the background with Cancel. [#1d82e730](https://github.com/dinhanhthi/Dblore/commit/1d82e730)
- **MongoDB schema** labels string values in quotes, so `"5"` and `5` are told apart, and stops at 5,000 fields on collections with very many keys. The selected aggregation stage is kept when you switch sections. [#bad04b51](https://github.com/dinhanhthi/Dblore/commit/bad04b51)
- **Matching controls.** Tab groups (Contains / Equals, 24 h / 7 d / 30 d, Cell / Row and similar) use the same capsule tabs as Grid / Chart, and dropdowns use the capsule style of the Download menu instead of the system pop-up. [#8d6f7881](https://github.com/dinhanhthi/Dblore/commit/8d6f7881) [#f5a6991e](https://github.com/dinhanhthi/Dblore/commit/f5a6991e) [#27d08f43](https://github.com/dinhanhthi/Dblore/commit/27d08f43) [#f4b42297](https://github.com/dinhanhthi/Dblore/commit/f4b42297)

### Fixed

- **Rows of a table without a primary key** are no longer dropped silently from an update or delete: the change is refused and names the table. [#d62df711](https://github.com/dinhanhthi/Dblore/commit/d62df711)
- **MySQL no longer sends the full password over an unverified remote connection.** When the server asks for the full password (caching_sha2_password) and the connection does not verify the server's TLS certificate, Dblore stops and says to choose Verify CA or Verify Full; a direct connection to 127.0.0.1, ::1 or localhost is exempt. Over SSH, a rejected tunnel channel is reported as such. [#f20a02aa](https://github.com/dinhanhthi/Dblore/commit/f20a02aa)
- **CSV and TSV exports neutralize formulas** in every line of a value, in values starting with a combining mark or a line break, and in headers; saving an export file no longer blocks the app. [#0a6e014c](https://github.com/dinhanhthi/Dblore/commit/0a6e014c)
- **Cancelling a query in a transaction** reports what really happened on SQLite and DuckDB (the pending changes were rolled back, or the transaction was kept), and a deadlock that rolls back a MySQL transaction clears its pending changes. [#9c1cd35d](https://github.com/dinhanhthi/Dblore/commit/9c1cd35d)
- **Read-only SQLite files** show rows still in the WAL file. MongoDB asks for the password instead of signing in with an empty one. PostgreSQL over SSH refuses Verify Full with an IP address host up front, and a timed-out test connection no longer leaves work running. [#769bd5bb](https://github.com/dinhanhthi/Dblore/commit/769bd5bb)
- **MongoDB** index statistics only hide on a permission error (a timeout now shows), closing a collection stops its aggregation run and previews, and an inline edit on a query result in a script tab refreshes that result. [#bad04b51](https://github.com/dinhanhthi/Dblore/commit/bad04b51) [#1d82e730](https://github.com/dinhanhthi/Dblore/commit/1d82e730)
- **MariaDB dumps** write a view after the views it reads, so the dump restores. [#1d82e730](https://github.com/dinhanhthi/Dblore/commit/1d82e730)
- **Structure editor** index rows keep their own state when one is dropped or removed, and Beautify JSON no longer crashes on a single value such as `123`. Copy Database File can no longer hang. [#1d82e730](https://github.com/dinhanhthi/Dblore/commit/1d82e730)
- **Menu commands work in every workspace window**, including windows opened with New Workspace: the File menu items, the Query menu and Cmd+Return.
- Keypad Enter accepts an autocomplete suggestion like Return, and a PostgreSQL SQL dump keeps a text value that starts with a combining mark intact. [#242fd5f6](https://github.com/dinhanhthi/Dblore/commit/242fd5f6)
- **Enum values** whose text is 4, 8 or 12 bytes long (such as `refunded`) are no longer shown as a pgvector number list. [#760bf557](https://github.com/dinhanhthi/Dblore/commit/760bf557)

### Upgrade notes

- AI: with xAI or Requesty as the active provider, Dblore 0.8.2 and older read the AI settings as empty, and saving any AI setting there replaces them. Switch to another provider before opening an older build.
- MySQL: a connection with TLS set to Disable, Allow, Prefer or Require to a server that needs full password authentication (caching_sha2_password with no cached login) now fails with a message instead of sending the password. Choose Verify CA or Verify Full, or connect once from a client that verifies TLS so the server caches the login.
- Copying rows or cells as text now puts an apostrophe before a text value that starts like a formula (`=`, `+`, `-`, `@`, tab or a line break), so it pastes with a leading apostrophe; turn it off in Settings > Result Table.
- Connections saved by this version can carry `hiddenSchemas` and the connection script fields (before-connect, after-disconnect, password command and timeout); an older build drops them when it saves the connection again.
- A chart saved with Split by carries `facetColumn`; an older build draws it unsplit and drops the key when it saves the notebook.
- MCP write tools are off by default; turn on Settings > MCP > Allow write tools and give a connection a write scope before an agent can ask to change data.

## v0.8.2 (2026-10-21)

### Added

- **AI access per connection.** Each connection has an AI access setting (use the default, Always, Ask once per session, or Never) and its own rules that are sent with every request. Never sends no schema, query, error or rows; Ask shows Allow / Not now before anything leaves the Mac. Settings > AI sets the default and whether result rows may be sent. The MCP server follows the same setting. [#007e1348](https://github.com/dinhanhthi/Dblore/commit/007e1348) [#a83891ba](https://github.com/dinhanhthi/Dblore/commit/a83891ba) [#aba54711](https://github.com/dinhanhthi/Dblore/commit/aba54711)
- **Review and Optimize.** The AI panel reviews or optimizes the current SQL query using table structure and the EXPLAIN plan shape (never literals or rows), shows the steps and a local diff, and Apply replaces the query as one undo step. [#68318f66](https://github.com/dinhanhthi/Dblore/commit/68318f66)
- **AI tools with approval cards.** On remote providers the assistant can list and describe tables, run one read-only query when "Run read-only queries" is on (the rows are shown to you; they reach the model only with "Send result rows to AI"), and propose SQL as a card with its kind. Nothing runs on its own: Run goes through the tab's normal path with Safe Mode, and DROP or TRUNCATE need the object name typed first. [#c167a5b8](https://github.com/dinhanhthi/Dblore/commit/c167a5b8) [#52500436](https://github.com/dinhanhthi/Dblore/commit/52500436)
- **Google Gemini** as an AI provider, with its API key kept in the Keychain. [#a76472cc](https://github.com/dinhanhthi/Dblore/commit/a76472cc)
- **Inline suggestions.** Optional gray text after the caret in SQL query tabs and notebook cells (off by default; Tab accepts, Esc dismisses). On-device keeps your SQL on this Mac. [#dbc5cbb8](https://github.com/dinhanhthi/Dblore/commit/dbc5cbb8) [#29c30197](https://github.com/dinhanhthi/Dblore/commit/29c30197)
- **Slash commands and @mentions** in the AI panel: `/explain`, `/fix`, `/review`, `/optimize` and your own commands with `{{query}}`, `{{selection}}`, `{{schema}}` and `{{error}}` placeholders; `@table:`, `@query`, `@results` and `@favorite:` attach context, following the connection's AI access setting. [#0618a499](https://github.com/dinhanhthi/Dblore/commit/0618a499)
- **Selection summary.** Selecting cells in a result shows Count, Sum and Avg in the status bar; the popover adds Non-null, Min and Max and copies the summary. [#fa2f06e3](https://github.com/dinhanhthi/Dblore/commit/fa2f06e3)
- **Find and Replace** in SQL editors and notebook cells (Cmd+Opt+F), with match case and whole word; Replace All is one undo step. [#fa2f06e3](https://github.com/dinhanhthi/Dblore/commit/fa2f06e3)
- **Connection color and group.** Give a connection a color and a group in its form; the Connections list on the welcome screen and the Recent connections menu group them, and the footer shows the connection's color. [#2554f09b](https://github.com/dinhanhthi/Dblore/commit/2554f09b)
- **Several highlight rules at once.** Highlight cells or rows with as many rules as you need (a cell rule wins over a row rule), switch each one on or off, and mark saved rules Active to apply them whenever the table opens. [#2554f09b](https://github.com/dinhanhthi/Dblore/commit/2554f09b)
- **SQLite and DuckDB plan trees.** Explain on SQLite (EXPLAIN QUERY PLAN) and DuckDB (JSON plans, with timings for Explain Analyze) opens the same plan tree as PostgreSQL and MySQL. [#9825e825](https://github.com/dinhanhthi/Dblore/commit/9825e825)
- **Create tables.** New Table… on the sidebar's Tables header (PostgreSQL, MySQL, SQLite) builds columns, a primary key, unique and foreign keys and a table comment (PostgreSQL, MySQL), shows the exact SQL and runs it through Safe Mode; under Review it waits for Commit on PostgreSQL and SQLite (MySQL asks you to switch off Review first). [#0369eeaf](https://github.com/dinhanhthi/Dblore/commit/0369eeaf)
- **Rename, comment and drop tables** from the structure editor, or with Rename… and Drop Table… on a table in the sidebar. Drop asks for the table name and shows the exact statement first; under Review the change waits for Commit on PostgreSQL and SQLite, and open tabs follow a rename or close after a drop. Table comments are read and edited on PostgreSQL and MySQL. [#c73bd2d1](https://github.com/dinhanhthi/Dblore/commit/c73bd2d1)
- **Parquet export.** Export a SQL result as a `.parquet` file from the export sheet or the copy bar's format menu, with progress and Cancel. Integer, floating-point, boolean, timestamp, binary and JSON columns keep their type; other columns are written as text. It needs the DuckDB plugin; without it the format links to Settings > Plugins. [#d25dc0d2](https://github.com/dinhanhthi/Dblore/commit/d25dc0d2)
- **Plugins list.** Settings > Plugins shows each available plugin on its own row, with its own Install, Remove, progress and Cancel. [#d25dc0d2](https://github.com/dinhanhthi/Dblore/commit/d25dc0d2)
- **Data Rewind.** Edits made in the data viewer on PostgreSQL, MySQL and SQLite (cell edits, Row Details and staged changes) keep a copy of each row before and after the change. View > Data Rewind… lists them for the connection, shows the exact SQL that puts the rows back and runs it as one batch after the usual Safe Mode confirmation; if a row changed since the edit, nothing is rewound and the row is named. The copies stay in a separate file on this Mac, are never included in backups, and are kept 30 days by default (7 to 365, up to 100 MB); Settings > Data turns recording off or deletes them. Imported rows are not recorded. [#43aa6176](https://github.com/dinhanhthi/Dblore/commit/43aa6176) [#870c05b7](https://github.com/dinhanhthi/Dblore/commit/870c05b7) [#56d66e10](https://github.com/dinhanhthi/Dblore/commit/56d66e10)
- **DuckDB SQL dump and restore.** Export SQL Dump and Restore SQL Dump now work on DuckDB connections, in memory or from a file: schemas, ENUM types, sequences, tables, indexes, views and every row (including binary values) are written to a plain SQL file and read back in one transaction. Restore only accepts the statements a Dblore DuckDB dump contains (views that read files or run SQL from text are refused), needs a writable connection and runs with Protected mode off. Macros, other user types and comments are not dumped. [#a5c6c4e5](https://github.com/dinhanhthi/Dblore/commit/a5c6c4e5)
- **MongoDB administration.** Admin commands join the mongosh subset (`createIndex`, `dropIndex`, `hideIndex`/`unhideIndex`, `createCollection`, `createView`, `drop`, `renameCollection` and `collMod`), so they also run from a `.js` tab. Indexes are created, hidden and dropped from the Indexes section, collections and views are created, renamed, dropped and edited from the sidebar, and a Validation section reads, generates from a sample and applies a collection's validator. Drops ask for the typed name first, and every action goes through Safe Mode. [#96d7ed97](https://github.com/dinhanhthi/Dblore/commit/96d7ed97) [#0454bb83](https://github.com/dinhanhthi/Dblore/commit/0454bb83) [#0598b573](https://github.com/dinhanhthi/Dblore/commit/0598b573) [#3f74eb9d](https://github.com/dinhanhthi/Dblore/commit/3f74eb9d)
- **MongoDB bulk update and delete.** "Bulk Update / Delete…" in the Documents header runs one update or delete on every document that matches the filter, with a count preview first; an empty filter or 1,000 or more documents needs the collection name typed. [#9e0ee0cd](https://github.com/dinhanhthi/Dblore/commit/9e0ee0cd)
- **MongoDB databases.** The sidebar's Databases button opens an overview of the server's databases and their collections, where you can create a database, drop one (typed name) or switch to it; the workspace reconnects to the chosen database. `db.getSiblingDB(...)` create and drop commands work in `.js` tabs. [#ec38c084](https://github.com/dinhanhthi/Dblore/commit/ec38c084) [#8e6a4c0a](https://github.com/dinhanhthi/Dblore/commit/8e6a4c0a) [#d587eb1b](https://github.com/dinhanhthi/Dblore/commit/d587eb1b)
- **MongoDB JSON view.** A MongoDB result can be shown as JSON next to Grid and Documents, and the view mode and page size are remembered per collection. [#6b2540d0](https://github.com/dinhanhthi/Dblore/commit/6b2540d0)
- **MongoDB export and import.** Export a collection, a query or an aggregation as Extended JSON or CSV. Import Documents… reads a JSON, NDJSON or CSV file into a new or existing collection after a preview; a conversion error stops the import before anything is sent. [#f199d5fd](https://github.com/dinhanhthi/Dblore/commit/f199d5fd) [#ba146fa3](https://github.com/dinhanhthi/Dblore/commit/ba146fa3) [#87ca6e17](https://github.com/dinhanhthi/Dblore/commit/87ca6e17)
- **MongoDB backup and restore.** Back Up Database and Restore Backup (File menu) write the chosen collections and views, with their indexes and validators, to one `.ndjson` file and read it back after checking the whole file; Restore can drop colliding collections after the typed database name. [#119d223b](https://github.com/dinhanhthi/Dblore/commit/119d223b)
- **Aggregation `$out` and `$merge` runs.** A pipeline that ends in `$out` or `$merge` runs from the Aggregations section behind Safe Mode, and the aggregation options set how many documents a stage preview shows (10, 20, 50 or 100). [#ffbed3a4](https://github.com/dinhanhthi/Dblore/commit/ffbed3a4)

### Improved

- **Menus** show a native checkmark on the selected item in dropdowns and in the AI assistant's model and context menus. [#d93bda0f](https://github.com/dinhanhthi/Dblore/commit/d93bda0f) [#a7164afa](https://github.com/dinhanhthi/Dblore/commit/a7164afa)
- **Ghost buttons** have a stronger hover fill in light mode. [#964bad85](https://github.com/dinhanhthi/Dblore/commit/964bad85)
- **AI assistant** empty state is centered without example prompts, and the floating card has a stronger border. [#c860085e](https://github.com/dinhanhthi/Dblore/commit/c860085e) [#39ec401a](https://github.com/dinhanhthi/Dblore/commit/39ec401a) [#43272b60](https://github.com/dinhanhthi/Dblore/commit/43272b60)

### Fixed

- **AI schema context** puts each table, column and index on one line, so a catalog name cannot add lines to the prompt. [#a52dbf02](https://github.com/dinhanhthi/Dblore/commit/a52dbf02)
- **PostgreSQL connection strings** with raw reserved characters in the password (such as `@`, `/` or `#`) are parsed. [#28433f4d](https://github.com/dinhanhthi/Dblore/commit/28433f4d)

### Upgrade notes

- Connections saved by this version carry AI access and rules fields; an older build drops them when it saves the connection again.
- With Google Gemini as the active AI provider, an older build shows AI as not configured.
- An older build drops custom slash commands and the inline suggestion settings when it saves the AI settings.
- An older build drops a connection's color and group when it saves the connection again.
- Saved highlights that use the Pink, Cyan or Gray color cannot be read by an older build: it shows no saved highlights and replaces them all on its next save.
- The DuckDB plugin installed by an earlier version keeps working; there is nothing to reinstall.
- History rows from a rewind read as Editor in an older build.
- A MongoDB workspace saved after a database switch carries the saved connection's database; an older build ignores it and may ask for the password again.
- The Data Rewind store (`Application Support/Dblore/Rewind/rewind.sqlite`) holds copies of edited rows on this Mac. It is excluded from backups and never exported; Settings > Data deletes it.

## v0.8.1 (2026-10-17)

### Added

- **MongoDB collection screen.** A collection opened from the sidebar has Documents, Aggregations, Schema and Indexes sections next to the title. Indexes lists each index with its type, size, usage, properties and status. Schema analyzes the sampled documents, and a value can be clicked to filter by it or the schema exported. [#2ce9350a](https://github.com/dinhanhthi/Dblore/commit/2ce9350a) [#aa502481](https://github.com/dinhanhthi/Dblore/commit/aa502481) [#38da82b0](https://github.com/dinhanhthi/Dblore/commit/38da82b0) [#6b8bd1b3](https://github.com/dinhanhthi/Dblore/commit/6b8bd1b3)
- **MongoDB filter bar.** The filter is a multi-line field that pairs brackets and quotes, wraps a selection in quotes and completes field names. A query options panel adds projection, sort, collation, hint, skip, limit and `maxTimeMS`, queries can be saved and reused, Explain shows the plan as a tree, Export Code writes the query as Node.js, Python, Java, Go or C# driver code, and Expand All / Collapse All opens every document. [#479c8dab](https://github.com/dinhanhthi/Dblore/commit/479c8dab) [#aa4a8375](https://github.com/dinhanhthi/Dblore/commit/aa4a8375) [#42555a67](https://github.com/dinhanhthi/Dblore/commit/42555a67) [#bde5e56c](https://github.com/dinhanhthi/Dblore/commit/bde5e56c) [#6b8bd1b3](https://github.com/dinhanhthi/Dblore/commit/6b8bd1b3) [#1f72a8aa](https://github.com/dinhanhthi/Dblore/commit/1f72a8aa) [#e2e82d6a](https://github.com/dinhanhthi/Dblore/commit/e2e82d6a)
- **MongoDB aggregations.** The Aggregations section runs a pipeline built stage by stage or typed as highlighted, formattable text. A toolbar offers collation, hint and `maxTimeMS` options, Wizard templates (group and count, lookup, top N, unwind, match, bucket), saved pipelines, Explain and Export Code or Export Data. Clicking a stage opens the common operators and a double-click types any operator, and autocomplete suggests accumulators, expression operators and stage options. [#56e30ece](https://github.com/dinhanhthi/Dblore/commit/56e30ece) [#348734a4](https://github.com/dinhanhthi/Dblore/commit/348734a4) [#cfbe982b](https://github.com/dinhanhthi/Dblore/commit/cfbe982b) [#84e50cb6](https://github.com/dinhanhthi/Dblore/commit/84e50cb6) [#b26fe6d6](https://github.com/dinhanhthi/Dblore/commit/b26fe6d6) [#710f79d9](https://github.com/dinhanhthi/Dblore/commit/710f79d9) [#835995d9](https://github.com/dinhanhthi/Dblore/commit/835995d9) [#8c39aaa4](https://github.com/dinhanhthi/Dblore/commit/8c39aaa4)
- **AI buttons on MongoDB.** The filter bar, the Aggregations section and the aggregation builder have an AI button that writes the filter or pipeline from a prompt, with Stop and Apply. [#334acd5e](https://github.com/dinhanhthi/Dblore/commit/334acd5e) [#24a52c24](https://github.com/dinhanhthi/Dblore/commit/24a52c24) [#46d7c3ca](https://github.com/dinhanhthi/Dblore/commit/46d7c3ca)
- **mongosh options.** `find` and `countDocuments` take projection, collation, hint and `maxTimeMS` options, and Explain works on `find` and `aggregate` cells. [#ce7c22b7](https://github.com/dinhanhthi/Dblore/commit/ce7c22b7) [#bde5e56c](https://github.com/dinhanhthi/Dblore/commit/bde5e56c)
- **Query scripts as `.js`.** In a MongoDB workspace a new query file is `Untitled.js`, and a `.sql` file is refused there (and a `.js` file elsewhere). [#05b94e2a](https://github.com/dinhanhthi/Dblore/commit/05b94e2a)
- **Expand or collapse every nested field** of a document card from its menu. [#54f20676](https://github.com/dinhanhthi/Dblore/commit/54f20676)

### Improved

- **Welcome window** shows workspaces as plain folders with a badge for their database type. [#c941167f](https://github.com/dinhanhthi/Dblore/commit/c941167f)
- **Saved secrets** (passwords, SSH credentials, AI keys, MCP token) now live in the data protection keychain, shared by Debug and Release builds; older items are copied over when read. [#c17bc881](https://github.com/dinhanhthi/Dblore/commit/c17bc881)
- **Motion polish.** The copy icon swaps with a symbol animation, the test connection result fades in and buttons ease on press. [#b9b45a06](https://github.com/dinhanhthi/Dblore/commit/b9b45a06) [#904f4380](https://github.com/dinhanhthi/Dblore/commit/904f4380) [#1c6ee1d1](https://github.com/dinhanhthi/Dblore/commit/1c6ee1d1)
- **MongoDB layout.** Larger collection and footer tabs, compact filter bar buttons, a stronger border on document cards and clearer popover inputs. [#5728fe0e](https://github.com/dinhanhthi/Dblore/commit/5728fe0e) [#3e221858](https://github.com/dinhanhthi/Dblore/commit/3e221858) [#37b492c8](https://github.com/dinhanhthi/Dblore/commit/37b492c8) [#56af441b](https://github.com/dinhanhthi/Dblore/commit/56af441b)

### Fixed

- **Left sidebar** collapses when a right sidebar opens or the window shrinks and there is no room for both, so only one side stays open. [#3ab60713](https://github.com/dinhanhthi/Dblore/commit/3ab60713) [#5af8dd6f](https://github.com/dinhanhthi/Dblore/commit/5af8dd6f) [#00a9e43a](https://github.com/dinhanhthi/Dblore/commit/00a9e43a)
- **Cmd+F** searches the loaded page of a MongoDB collection and is disabled outside Documents. [#b9c7296d](https://github.com/dinhanhthi/Dblore/commit/b9c7296d)
- **AI on MongoDB** drops a filter or pipeline reply that finishes after Stop, and the prompt field keeps three lines visible. [#61cd0f80](https://github.com/dinhanhthi/Dblore/commit/61cd0f80) [#400e1d72](https://github.com/dinhanhthi/Dblore/commit/400e1d72)
- **Editors** with a fixed height fill their frame, so a click below the text focuses them. [#ace4242a](https://github.com/dinhanhthi/Dblore/commit/ace4242a)
- **Document type badge** stays rightmost on a MongoDB card, with the hover actions to its left. [#08935c9d](https://github.com/dinhanhthi/Dblore/commit/08935c9d)
- **Index statistics** no longer trap on overflow when summed. [#61215c4a](https://github.com/dinhanhthi/Dblore/commit/61215c4a)

## v0.8.0 (2026-10-16)

### Added

- **MongoDB.** Connect with a `mongodb://` or `mongodb+srv://` connection string or the form. Logins use SCRAM-SHA-256 or SCRAM-SHA-1 (users created in `admin` need Auth Source `admin`), and TLS is either off or Verify Full, with an optional custom CA. Notebook cells and SQL files take a subset of the mongosh syntax, which Dblore parses itself and never runs as JavaScript: `find` with `sort`, `skip` and `limit`, `aggregate`, `countDocuments`, `distinct`, `insertOne`/`insertMany`, `updateOne`/`updateMany`, `replaceOne`, `deleteOne`/`deleteMany` and `show collections`, with highlighting and autocomplete of collections, sampled fields, operators and stages. Results show as a grid or as document cards (Copy Value, Copy Path, Copy Document as Extended JSON), reads are capped like SQL reads, and Cancel stops the command on the server ("Query cancelled. The connection was kept."). The sidebar lists collections, views and sampled fields, and the AI assistant writes mongosh commands on MongoDB tabs. [#cca5347f](https://github.com/dinhanhthi/Dblore/commit/cca5347f) [#73cc3da7](https://github.com/dinhanhthi/Dblore/commit/73cc3da7)
- **MongoDB data viewer and aggregation builder.** A collection opened from the sidebar has a filter bar that takes a filter document (for example `{status: "active"}`) and runs it on the server. "Build Aggregation..." in the collection menu, or on a cell's `aggregate` command, builds a pipeline stage by stage: reorder, turn stages on and off, preview the documents each stage returns (read-only; a `$out` or `$merge` stage and the stages after it are not previewed), then insert the pipeline as a cell or copy it. [#73cc3da7](https://github.com/dinhanhthi/Dblore/commit/73cc3da7)
- **MongoDB document edits.** In the data viewer, edit fields inline, add, duplicate or delete documents, or edit a whole document in mongosh notation. Changes are staged by `_id`, previewed as the exact `updateOne`, `insertOne` and `deleteOne` commands, and sent one by one after Safe Mode confirmation; a failure reports how many were applied. Results whose `_id` mixes types are read-only. [#73cc3da7](https://github.com/dinhanhthi/Dblore/commit/73cc3da7)
- **Document cards.** Choose Documents under a MongoDB result to see one card per document, with its top-level fields shown and nested objects and arrays that expand and collapse with a click. Double-click a value to edit it where it is, at any depth: Return sends one `$set` of its dotted path after the usual Safe Mode confirmation and Esc cancels; a double-click on an object, array or other type opens the field editor instead. The card header and each field line open Row Details and Cell Value in the right sidebar, and in the data viewer a card can be duplicated, deleted and reverted, with staged inserts shown as "New" cards. [#dbfcafbc](https://github.com/dinhanhthi/Dblore/commit/dbfcafbc) [#7d24741e](https://github.com/dinhanhthi/Dblore/commit/7d24741e) [#451709d3](https://github.com/dinhanhthi/Dblore/commit/451709d3) [#ce8c405d](https://github.com/dinhanhthi/Dblore/commit/ce8c405d)
- **Document counts in the sidebar.** MongoDB collections show their approximate document count next to the name. [#1ab4f65d](https://github.com/dinhanhthi/Dblore/commit/1ab4f65d)
- **Safe Mode on MongoDB.** MongoDB has no transactions, so Protected mode cannot hold writes for a later Commit and the Review commit style acts as Confirm (the form does not offer Review): writes ask before they run, with a warning when a command affects every document of a collection. Schema-only blocks only `$out`. [#cca5347f](https://github.com/dinhanhthi/Dblore/commit/cca5347f)
- **MCP server on MongoDB.** Agents can use MongoDB connections with the same tools: `describe_table` returns sampled field paths with their BSON types, and `run_query` takes exactly one read command in the mongosh subset (`$out`, `$merge` and server-side JavaScript such as `$where`, `$function` and `$accumulator` are refused), with the usual row, cell and 30-second limits. MongoDB has no server-side read-only mode, so give the connection a user with a read-only role. [#73cc3da7](https://github.com/dinhanhthi/Dblore/commit/73cc3da7)
- **SSH tunnels for MySQL and MongoDB.** MySQL, MariaDB and MongoDB connections can go through an SSH tunnel, as PostgreSQL already could: the same password and ed25519/ECDSA key logins and the same host-key trust prompt. MySQL and MariaDB traffic passes through a private forwarder on `127.0.0.1`; MongoDB runs directly over the SSH channel, with no local port. MongoDB over SSH supports a single host only (no `mongodb+srv://` or multi-host strings; the form says so). Verify Full with an IP address as the MySQL host is refused over SSH. Cancel sends `KILL QUERY` or `killOp` through the same tunnel and never opens a connection outside it, also after the tunnel has closed. [#1f5f624b](https://github.com/dinhanhthi/Dblore/commit/1f5f624b)
- **MySQL EXPLAIN plan tree.** On MySQL, Explain reads `EXPLAIN FORMAT=JSON` and shows the plan as a tree with costs, a Raw JSON view and node details, and two plans can be pinned and compared. MariaDB keeps the tabular EXPLAIN, and Explain Analyze stays a text tree. UNION and subquery plans are shown shallow. [#1f5f624b](https://github.com/dinhanhthi/Dblore/commit/1f5f624b)
- **SQL dump.** File > Export SQL Dump... writes a PostgreSQL, MySQL/MariaDB or SQLite database to a `.sql` file: all tables or a chosen few, with or without data, read in one snapshot on a connection of its own, with progress and Cancel. Not included: functions, procedures, PostgreSQL and MySQL triggers, MySQL events, extensions, roles, ownership and grants, and on PostgreSQL also row security policies (a restored table has none, so check who can read it), materialized views, comments, non-default column collations and types other than enums and domains (a table with a composite or range column does not restore); SQLite virtual tables are created empty. A dump holds your data in clear text: a new dump file is readable only by your user account, but keep it somewhere safe. [#63e32bd0](https://github.com/dinhanhthi/Dblore/commit/63e32bd0)
- **Restore SQL Dump.** File > Restore SQL Dump... restores a Dblore dump of the same engine, up to 64 MiB, into the open database. Every statement is checked before anything runs: only the statements a Dblore dump writes are accepted (tables, indexes, views, types, sequences, and INSERT rows that hold only literal values), and any other statement refuses the whole file. Restoring still runs the file's SQL as written (column defaults, checks, views and triggers), so restore only dumps you trust. Under the Confirm and Password commit styles the confirmation lists every statement except the rows, with its full text one click away. PostgreSQL and SQLite restore in one transaction (under Protected mode it waits for Commit). MySQL restores one statement at a time, so it is refused while Protected mode is on or a transaction is open; afterwards Dblore resets the session settings the dump changed and closes the connection if that fails. A PostgreSQL dump with backslashes in strings in its schema needs `standard_conforming_strings = on` (the default). MySQL tables using the FEDERATED, CONNECT or SPIDER engines, or DATA/INDEX DIRECTORY, are refused. Known limit: on MariaDB a view built on another view whose name sorts after it does not restore. [#63e32bd0](https://github.com/dinhanhthi/Dblore/commit/63e32bd0)
- **Copy Database File.** File > Copy Database File... saves an open SQLite database, including changes still in its WAL file, as one checked file. [#63e32bd0](https://github.com/dinhanhthi/Dblore/commit/63e32bd0)
- **Dumps and restores in History.** Each dump and restore is recorded as one History row with a Dump or Restore badge, when History is on. [#63e32bd0](https://github.com/dinhanhthi/Dblore/commit/63e32bd0)

### Improved

- **Row Details** uses smaller field labels and inputs, so more fields fit in the sidebar. [#38eb7593](https://github.com/dinhanhthi/Dblore/commit/38eb7593)
- **Button polish.** The AI assistant button icon is colored, the schema visualizer button is gray when closed and accented when open, the expanded AI bubble logo sits on a light border with an accent gradient, and button labels stay on one line. [#a33e4db7](https://github.com/dinhanhthi/Dblore/commit/a33e4db7) [#e117c274](https://github.com/dinhanhthi/Dblore/commit/e117c274) [#d38ac01b](https://github.com/dinhanhthi/Dblore/commit/d38ac01b) [#230556df](https://github.com/dinhanhthi/Dblore/commit/230556df)

### Fixed

- **Cancel on MySQL** now says "Query cancelled. The connection was kept." instead of reporting a reset connection, since `KILL QUERY` keeps the session and its transaction. Stopping a MySQL or MongoDB query no longer warns that pending changes will be rolled back. [#2614c5dc](https://github.com/dinhanhthi/Dblore/commit/2614c5dc) [#674f40cb](https://github.com/dinhanhthi/Dblore/commit/674f40cb)
- **Safe Mode confirmation lists the statements.** The Confirm dialog showed only its first line; it now lists every statement it will run, under the warning. [#674f40cb](https://github.com/dinhanhthi/Dblore/commit/674f40cb)
- **First row of a result.** A result long enough to scroll no longer opens with its first row half under the column header. [#674f40cb](https://github.com/dinhanhthi/Dblore/commit/674f40cb)
- **Row count after Commit.** The data viewer counts the rows again after committed inserts or deletes, so the paging bar no longer shows the old total. [#674f40cb](https://github.com/dinhanhthi/Dblore/commit/674f40cb)
- **MySQL values of 16 MiB or more** are sent and read in full: the mysql-nio fork's tag `1.9.1-dblore.3` splits and reassembles large packets (capped at 1 GiB) and adds a login over an already open channel. [#cca5347f](https://github.com/dinhanhthi/Dblore/commit/cca5347f)
- **SQLite triggers in a cell.** A `CREATE TRIGGER … BEGIN … END` typed in a cell now runs as one statement instead of failing in pieces, and a `--` comment ends only at a line feed, as in SQLite, so Safe Mode no longer misreads a statement after a comment that ends with a bare carriage return. [#63e32bd0](https://github.com/dinhanhthi/Dblore/commit/63e32bd0)
- **Structure editor on MySQL and MariaDB.** MariaDB refuses NOT NULL on a generated column up front, and MySQL CHECK and index expressions are shown without escape characters. [#2614c5dc](https://github.com/dinhanhthi/Dblore/commit/2614c5dc)

### Upgrade notes

- **Downgrading:** older builds cannot open a workspace or notebook whose connection is MongoDB. History rows of dumps and restores show as Editor in 0.7.x, and 0.6.x refuses JSON history backups that contain them. [#cca5347f](https://github.com/dinhanhthi/Dblore/commit/cca5347f) [#63e32bd0](https://github.com/dinhanhthi/Dblore/commit/63e32bd0)

## v0.7.2 (2026-10-15)

### Added

- **Markdown File as the new tab default.** The "New Tab" default in Settings > General can now be "Markdown File", so `Cmd+T` opens a new Markdown file. [#2bd558bc](https://github.com/dinhanhthi/Dblore/commit/2bd558bc)

### Improved

- **Hairline borders.** Panels, modals, popups and the right sidebar use thinner, more consistent borders, and the details header picker and tab bar spacing are tidier. [#66e82982](https://github.com/dinhanhthi/Dblore/commit/66e82982)

## v0.7.1 (2026-10-14)

### Added

- **Row Details.** Hover the "#" cell of a result row and click its details button, or choose "Show Row Details" in the right-click menu of a cell or of the "#" column, to open the whole row in the right sidebar: the table, the row number and key, then one field per column. In an editable result you change values there; edits stay drafts (a dot marks each one) until Apply, and Cancel drops them. Key, generated and read-only columns are shown but not editable, and a row you staged as an insert in the data viewer opens too. [#cc5c0368](https://github.com/dinhanhthi/Dblore/commit/cc5c0368) [#ee611092](https://github.com/dinhanhthi/Dblore/commit/ee611092)

### Improved

- **Typing and tabs.** Typing in a notebook cell or SQL editor no longer re-renders the tab bar and every view that reads the tabs on each keystroke. [#386ed125](https://github.com/dinhanhthi/Dblore/commit/386ed125)
- **Search stays responsive.** Searching a large result (10,000 rows by 30 columns) no longer freezes the window while it scans; the scan runs off the main thread. [#a1d0ae43](https://github.com/dinhanhthi/Dblore/commit/a1d0ae43)
- **JSON viewer.** The right sidebar no longer pretty-prints and highlights a large JSON value again each time the sidebar re-renders, so it opens and animates without stalling on big cells. [#923e8f98](https://github.com/dinhanhthi/Dblore/commit/923e8f98)

### Fixed

- **Schema visualizer idle CPU.** Closing the schema visualizer with column connections on left its dash animation timer running; it now stops with the view. [#7589025f](https://github.com/dinhanhthi/Dblore/commit/7589025f)

## v0.7.0 (2026-10-14)

### Added

- **MySQL and MariaDB.** Connect over TCP with TLS and client certificates (mTLS, certificate in the Keychain); there is no SSH tunnel for MySQL. Users with `caching_sha2_password` or `mysql_native_password` can log in; `sha256_password` and MariaDB ed25519 fail with a clear error. The database field is required and the sidebar shows only that database. Close to PostgreSQL parity: queries with `DELIMITER` support, schema tree, autocomplete and highlighting, Safe Mode and Protected mode, history, export, capped reads, cancel through `KILL QUERY` on a short control connection, staged and inline edits by primary key (tables without a primary key are not editable), foreign-key lookup, CSV/TSV/JSON import, routine and trigger source, and EXPLAIN as a table (Explain Analyze on MySQL 8.0.18 or later; no plan tree). Session timeouts apply too, but on MySQL the statement timeout stops only `SELECT`, and the idle timeout (`wait_timeout`) closes any idle connection, not only one with an open transaction. [#9fbbd498](https://github.com/dinhanhthi/Dblore/commit/9fbbd498)
- **MySQL SSL modes.** Allow, Prefer and Require encrypt the connection without verifying the server certificate (unlike the app's PostgreSQL Require, which verifies it), because stock MySQL 8 and MariaDB servers use self-signed certificates. Only Verify CA and Verify Full authenticate the server; on an untrusted network an active attacker could otherwise read the traffic and the password. Allow and Prefer also fall back to plain text when the server offers no SSL. The footer shows "Unverified SSL" or "No SSL" for these cases, and the connection form explains the modes. [#9fbbd498](https://github.com/dinhanhthi/Dblore/commit/9fbbd498)
- **MySQL driver from a patched fork.** mysql-nio comes from the [dinhanhthi/mysql-nio](https://github.com/dinhanhthi/mysql-nio) fork, which refuses a TLS downgrade before sending credentials, uses the correct 20-byte scramble, and never retrieves the server's public key over plain text. A login that needs full authentication over an unencrypted connection is therefore refused; connect once over SSL so the server caches the login. [#9fbbd498](https://github.com/dinhanhthi/Dblore/commit/9fbbd498)
- **Import MySQL and MariaDB connections** from `mysql://` and `mariadb://` URIs, DBeaver, TablePlus and DataGrip; the SSL mode is kept from URIs, DBeaver and TablePlus. [#9fbbd498](https://github.com/dinhanhthi/Dblore/commit/9fbbd498)
- **MCP server.** Let AI agents such as Claude Code and Cursor read your databases through a read-only MCP server at `http://127.0.0.1:<port>/mcp` (default port 41730). It is off by default; turn it on in the new Settings > MCP tab, choose which saved connections agents may use (DuckDB is not available), and copy the Claude Code command or the Cursor JSON with the Bearer token. The token is kept in the Keychain and can be regenerated. Tools: `list_connections`, `list_tables`, `describe_table` and `run_query`. A query must be exactly one read statement, passes the gate with a read-only policy and runs in a read-only transaction that is rolled back (SQLite opens read-only); it returns 200 rows by default (at most 1000), cuts cells at 2000 characters and stops after 30 seconds. Agent queries are recorded in History when History is on. Use a least-privilege database user, and treat results as untrusted data. [#bbc87ae2](https://github.com/dinhanhthi/Dblore/commit/bbc87ae2)
- **Structure editor.** "Edit Structure..." in a table's sidebar menu opens a sheet to add, alter, rename and drop columns (type, default, nullable), create and drop indexes, and add or drop primary, foreign, unique and check constraints on PostgreSQL and MySQL. SQLite gets only the changes it supports directly: add a column, rename a column (SQLite 3.25+), drop a column (3.35+, refused for a key, indexed or generated column), create and drop indexes; the table is never rebuilt. DuckDB tables open read-only with "View Structure...". Every change is previewed as the exact SQL that runs, goes through Safe Mode confirmation, and is recorded in History. [#830569ff](https://github.com/dinhanhthi/Dblore/commit/830569ff)
- **AI assistant runs read-only queries.** Turn on "Run read-only queries" in Settings > AI > Privacy (off by default) and the assistant writes a query, Dblore runs it and shows you the rows. Row values and error messages are never sent to the model. Only a single read-only statement runs, inside a read-only transaction (SQLite opens the file read-only); on DuckDB only a `SELECT` that reads no files runs. Anything else is refused and shown as SQL for you to run yourself. [#07866936](https://github.com/dinhanhthi/Dblore/commit/07866936)
- **Add Row form.** "Add Row" in the results grid menu opens a form in the right sidebar with one field per column, typed inputs, a NULL button and validation against the column type. An empty field is left out of the `INSERT`, so the database default applies; Add stages the row. [#c49f420a](https://github.com/dinhanhthi/Dblore/commit/c49f420a)
- **Color Values by Type.** Show numbers, text, dates, booleans and JSON in their own soft colors in the results grid (Settings > Results). NULL keeps its faint style. [#c49f420a](https://github.com/dinhanhthi/Dblore/commit/c49f420a)
- **Format SQL in notebook cells.** The floating toolbar of a notebook cell has a Format SQL button. [#c49f420a](https://github.com/dinhanhthi/Dblore/commit/c49f420a)
- **Confirm before quitting.** "Confirm before quitting with Cmd+Q" in Settings > General asks before Dblore quits from the keyboard shortcut; quitting from the Dock or the menu bar never asks. [#c49f420a](https://github.com/dinhanhthi/Dblore/commit/c49f420a)
- **Animations setting.** Toasts, modals, tabs and panels animate. Turn animations on or off in Settings > Appearance; System follows the macOS Reduce Motion setting. [#526d5679](https://github.com/dinhanhthi/Dblore/commit/526d5679)
- **Unused model files.** Settings > AI shows how much disk space files of on-device models that are no longer offered, and unfinished downloads, take, and removes them after you confirm. [#78e8419a](https://github.com/dinhanhthi/Dblore/commit/78e8419a) [#c92087a6](https://github.com/dinhanhthi/Dblore/commit/c92087a6)

### Improved

- **MySQL implicit commits in Protected mode.** MySQL commits implicitly before DDL, `TRUNCATE`, `LOCK TABLES`, user and grant statements, `ANALYZE`/`OPTIMIZE TABLE`, `FLUSH` and similar statements, so Protected mode refuses them with a MySQL-specific message instead of silently committing the pending changes. With Protected mode off, such a statement also ends the transaction Dblore tracks, and after statements that may or may not commit (such as `CALL`) Dblore asks the server. [#9fbbd498](https://github.com/dinhanhthi/Dblore/commit/9fbbd498)
- **Structure changes are atomic where the engine allows it.** On PostgreSQL and SQLite all changes of one Apply run together and join the pending transaction in Protected mode. On MySQL, where each statement commits, the editor is disabled in Protected (Review) mode, while changes are pending or with your own transaction open, and a failure reports how many statements were applied. [#830569ff](https://github.com/dinhanhthi/Dblore/commit/830569ff)
- **DuckDB read-only PRAGMAs** that only read the catalog or the version run as reads under Safe Mode; other PRAGMAs are still treated as utility commands. [#9fbbd498](https://github.com/dinhanhthi/Dblore/commit/9fbbd498)
- **History backups from newer versions.** Importing a JSON history backup accepts unknown sources and kinds written by a future version instead of refusing the file. [#bbc87ae2](https://github.com/dinhanhthi/Dblore/commit/bbc87ae2)
- **Grid / Chart slider** sits at the far right of the SQL editor result footer. [#9fbbd498](https://github.com/dinhanhthi/Dblore/commit/9fbbd498)
- **On-device models.** The on-device AI models are now Qwen3.5 2B, 4B and 9B and Gemma 4 12B (all 4-bit). They get a shorter prompt and greedy decoding, so the same question gives the same SQL. Models that are no longer offered can be removed with Unused model files. [#d53845c0](https://github.com/dinhanhthi/Dblore/commit/d53845c0) [#51142816](https://github.com/dinhanhthi/Dblore/commit/51142816)
- **Export and backup progress.** Exporting local data in Settings > Data shows the step it is on, can be cancelled, and ends with a toast; importing a backup ends with a toast too. [#5bdf4a77](https://github.com/dinhanhthi/Dblore/commit/5bdf4a77)
- **History search by badge.** Searching History for a source or kind badge such as "AI Assistant" finds those rows. [#5bdf4a77](https://github.com/dinhanhthi/Dblore/commit/5bdf4a77)
- **Pending transaction details.** "View Details" on the pending transaction banner shows every pending statement in full. [#c49f420a](https://github.com/dinhanhthi/Dblore/commit/c49f420a)
- **Welcome window.** A sidebar with the logo, version and the start actions sits next to a filterable list of recent workspaces and connections. Welcome windows keep one small fixed size, workspace windows open at least 1000 x 600, and tabs in one window share its size. [#59ccb1a0](https://github.com/dinhanhthi/Dblore/commit/59ccb1a0)
- **Resizable AI card.** Drag an edge of the floating AI assistant card to resize it. [#07866936](https://github.com/dinhanhthi/Dblore/commit/07866936)
- **Custom CA on its own.** The connection form accepts a custom CA (PEM) without a client certificate; it needs Require, Verify CA or Verify Full TLS mode. [#e4df4d1b](https://github.com/dinhanhthi/Dblore/commit/e4df4d1b)
- **Interface polish.** Hairline borders, right side panels, outlined red danger buttons, a bolt icon on the read-only queries switch and mini-sized switches, in light and dark. [#51e27274](https://github.com/dinhanhthi/Dblore/commit/51e27274) [#7d83229e](https://github.com/dinhanhthi/Dblore/commit/7d83229e) [#1d9122e0](https://github.com/dinhanhthi/Dblore/commit/1d9122e0) [#1632444f](https://github.com/dinhanhthi/Dblore/commit/1632444f)

### Fixed

- **Compare view** shows columns that exist on only one side first, so the added-column tint is visible instead of off-screen. [#6ca3e647](https://github.com/dinhanhthi/Dblore/commit/6ca3e647)
- **SQLite statements** are no longer split at a `;` inside a bracketed identifier such as `[a;b]`. [#9fbbd498](https://github.com/dinhanhthi/Dblore/commit/9fbbd498)
- **SQL INSERT export and copy** from notebook cells and the SQL editor use the connection's SQL dialect, so SQLite and DuckDB get the right quoting. [#9fbbd498](https://github.com/dinhanhthi/Dblore/commit/9fbbd498)
- **Not a PostgreSQL server.** Connecting to a port that does not speak the PostgreSQL protocol now says so and points at the database type, instead of an unrelated error. [#e4df4d1b](https://github.com/dinhanhthi/Dblore/commit/e4df4d1b)
- **SQLite and DuckDB connects.** A SQLite file in a folder Dblore cannot write to is reported when you connect instead of failing at the first write, and a DuckDB workspace that connects at launch no longer reports the plugin as missing while Dblore is still checking it. [#e4df4d1b](https://github.com/dinhanhthi/Dblore/commit/e4df4d1b)
- **Set as active button** no longer wraps onto two lines in the AI provider row. [#c22c260f](https://github.com/dinhanhthi/Dblore/commit/c22c260f)

### Upgrade notes

- **Downgrading to 0.6.x:** 0.6.x cannot open a workspace or notebook whose connection is MySQL; the connection history keeps the entry. JSON history backups that contain MCP or Structure entries are refused by 0.6.x, and such rows show as Editor there. [#9fbbd498](https://github.com/dinhanhthi/Dblore/commit/9fbbd498) [#bbc87ae2](https://github.com/dinhanhthi/Dblore/commit/bbc87ae2)

## v0.6.1 (2026-10-09)

### Added

- **Connection name in the footer.** The connected status now shows the name of the connection. [#07901169](https://github.com/dinhanhthi/Dblore/commit/07901169)

### Improved

- **Readable colors in both appearances.** Color tokens are retuned for WCAG contrast in light and dark, labels on accent and destructive fills are readable, state fills, borders and the search highlight are calmer, and the toast is less intrusive. [#68c95602](https://github.com/dinhanhthi/Dblore/commit/68c95602) [#463f1147](https://github.com/dinhanhthi/Dblore/commit/463f1147) [#ba5f963b](https://github.com/dinhanhthi/Dblore/commit/ba5f963b)
- **Tab pickers and settings controls.** Tab pickers use readable on-accent labels, and controls stand off the settings panels. [#6db9acb8](https://github.com/dinhanhthi/Dblore/commit/6db9acb8) [#a159597e](https://github.com/dinhanhthi/Dblore/commit/a159597e)
- **Plugin buttons.** Install, Retry and Cancel in Settings > Plugins use the regular size. [#b055cbad](https://github.com/dinhanhthi/Dblore/commit/b055cbad)

## v0.6.0 (2026-10-09)

### Added

- **DuckDB, as an optional plugin.** Install DuckDB from Settings > Plugins; it downloads a signed, notarized `libduckdb.dylib` and checks its SHA-256 before every load, and Remove deletes it. Open a `.duckdb` file (read-only by default, also from Finder), create one or use an in-memory database, browse its schema tree, and query Parquet or CSV files with the "Query Parquet/CSV File..." palette action. Safe Mode guards DuckDB writes such as `INSTALL`, `ATTACH`, `COPY ... TO` and `CREATE TABLE`; row edits, data import and foreign-key lookup are not available for DuckDB. A saved DuckDB connection without the plugin offers an Install button. [#0b537ef1](https://github.com/dinhanhthi/Dblore/commit/0b537ef1) [#34364049](https://github.com/dinhanhthi/Dblore/commit/34364049) [#ad27f360](https://github.com/dinhanhthi/Dblore/commit/ad27f360) [#5b95427d](https://github.com/dinhanhthi/Dblore/commit/5b95427d)
- **PostgreSQL over SSH.** Connect through an SSH tunnel with a password or an ed25519/ECDSA private key, including passphrase-protected keys (the passphrase is never stored). The first connection asks you to trust the server's host-key fingerprint, and a changed host key blocks the connection. RSA keys are not supported. Saved SSH passwords, keys and trusted host keys can be deleted in Settings > Data. [#2ebd7fb5](https://github.com/dinhanhthi/Dblore/commit/2ebd7fb5) [#bcc8755a](https://github.com/dinhanhthi/Dblore/commit/bcc8755a) [#581bb704](https://github.com/dinhanhthi/Dblore/commit/581bb704)
- **Import connections** from `.pgpass`, a PostgreSQL URI, DBeaver (including saved passwords), TablePlus and DataGrip. Preview and pick the connections first; duplicates and connections without a password are flagged. Available from the welcome screen, the saved connections list and the File menu. [#dbce5881](https://github.com/dinhanhthi/Dblore/commit/dbce5881) [#6cd3f1b5](https://github.com/dinhanhthi/Dblore/commit/6cd3f1b5)
- **Pin and compare results.** Pin a cell or SQL editor result, re-run, and compare both side by side with added, removed and changed rows highlighted; two `EXPLAIN` JSON plans compare node by node. A notebook cell's pin is saved in the file when results are saved. [#fa317b83](https://github.com/dinhanhthi/Dblore/commit/fa317b83)
- **Long-query notifications.** Get a macOS notification when a query runs longer than a threshold (default 10 seconds, by default only while Dblore is in the background). It shows the tab, duration and row count, never the SQL or data; clicking it opens the tab. Off by default, in General settings. [#95adb329](https://github.com/dinhanhthi/Dblore/commit/95adb329)
- **Routine and trigger source.** The schema sidebar lists triggers, and View Source opens a function, procedure or trigger definition in a read-only tab, with Copy and "Open as editable copy". [#95f19c7a](https://github.com/dinhanhthi/Dblore/commit/95f19c7a) [#9d0963bd](https://github.com/dinhanhthi/Dblore/commit/9d0963bd)
- **Markdown notes.** Open a `.md` file or start a new note in the workspace; it is written to disk only on `Cmd+S`. Switch between the source (code mode) and an editable WYSIWYG preview. [#8da64483](https://github.com/dinhanhthi/Dblore/commit/8da64483) [#ec0af407](https://github.com/dinhanhthi/Dblore/commit/ec0af407) [#8f730574](https://github.com/dinhanhthi/Dblore/commit/8f730574) [#4ef38485](https://github.com/dinhanhthi/Dblore/commit/4ef38485)
- **AI assistant as a floating bubble.** Detach the AI panel into a draggable bubble at the bottom of the window; choose the default presentation in Settings > AI > Panel. [#eff78a21](https://github.com/dinhanhthi/Dblore/commit/eff78a21) [#d646ae28](https://github.com/dinhanhthi/Dblore/commit/d646ae28) [#f495f618](https://github.com/dinhanhthi/Dblore/commit/f495f618)
- **Light/dark toggle** button in the header, between AI and Settings. [#d3b118df](https://github.com/dinhanhthi/Dblore/commit/d3b118df)
- **Settings search.** Fuzzy-search the sections of the settings modal from its sidebar. [#f86add0b](https://github.com/dinhanhthi/Dblore/commit/f86add0b)

### Improved

- **Safety cues in the footer.** The Safe Mode and protection cues moved to the footer, with a "No SSL" badge when the connection is not encrypted. [#f4e4625a](https://github.com/dinhanhthi/Dblore/commit/f4e4625a)
- **Schema sidebar and cell value sidebar.** The Public tab groups tables by schema, and the cell value sidebar is resizable. [#75cc20fc](https://github.com/dinhanhthi/Dblore/commit/75cc20fc)
- **Polished UI.** Chrome is painted with solid design tokens instead of macOS glass, and tabs, the welcome window, the command palette, modals and alerts are refined. [#acc85de2](https://github.com/dinhanhthi/Dblore/commit/acc85de2) [#36fa7bee](https://github.com/dinhanhthi/Dblore/commit/36fa7bee)
- **Result column headers.** The filter icon sits on the name line and the sort arrow on the type line, with tooltips; the filter popover header is more compact. [#a8e5297e](https://github.com/dinhanhthi/Dblore/commit/a8e5297e) [#3578139f](https://github.com/dinhanhthi/Dblore/commit/3578139f)
- **Connection history** keeps up to 50 connections (was 6), and entries written by a newer Dblore version are kept instead of emptying the history. [#53f86a0c](https://github.com/dinhanhthi/Dblore/commit/53f86a0c) [#dbce5881](https://github.com/dinhanhthi/Dblore/commit/dbce5881)

### Fixed

- **Stopping a SQLite query** now works even when Stop is pressed just as the query starts; before, such a query kept running until its statement timeout. [#9bdaec70](https://github.com/dinhanhthi/Dblore/commit/9bdaec70)
- **Log files** are created reliably: the Logs directory is created before the first log file is written. [#960bcf72](https://github.com/dinhanhthi/Dblore/commit/960bcf72)
- **History sidebar** uses the system scrollbar. [#52b1e02b](https://github.com/dinhanhthi/Dblore/commit/52b1e02b)

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

- **Column filters.** A filter sidebar with a header button builds `WHERE` conditions in card layout, and filters can be saved and reused from a popover in the header; the button shows an accent dot when a filter is applied. [#4d5bd5f](https://github.com/dinhanhthi/Dblore/commit/4d5bd5f) [#cc39d89](https://github.com/dinhanhthi/Dblore/commit/cc39d89) [#7880a78](https://github.com/dinhanhthi/Dblore/commit/7880a78) [#fcd9505](https://github.com/dinhanhthi/Dblore/commit/fcd9505)
- **Highlight cells and rows.** Highlight matching cells or rows in the results grid from the sidebar, with a softer tint and a live cell/row toggle; the button shows an accent dot when applied. [#3513bd1](https://github.com/dinhanhthi/Dblore/commit/3513bd1) [#a0ce3bd](https://github.com/dinhanhthi/Dblore/commit/a0ce3bd) [#f97bb01](https://github.com/dinhanhthi/Dblore/commit/f97bb01) [#fcd9505](https://github.com/dinhanhthi/Dblore/commit/fcd9505)
- **Favorites.** Save SQL snippets in a Favorites sidebar tab, with modals to add and edit them and insertion into the editor. [#a99a802](https://github.com/dinhanhthi/Dblore/commit/a99a802) [#835cdac](https://github.com/dinhanhthi/Dblore/commit/835cdac) [#a27b639](https://github.com/dinhanhthi/Dblore/commit/a27b639)
- **Results cell context menu** with copy, see more and highlight. [#8c0d6e3](https://github.com/dinhanhthi/Dblore/commit/8c0d6e3)
- **Sorted column tint** in the results grid. [#5a30d38](https://github.com/dinhanhthi/Dblore/commit/5a30d38)
- **Current line highlight** in the SQL editor. [#4a3dc39](https://github.com/dinhanhthi/Dblore/commit/4a3dc39)
- **Side-by-side editor layout** can be toggled and set as the default in settings, and the line number gutter fits its content. [#2d238bb](https://github.com/dinhanhthi/Dblore/commit/2d238bb)
- **Refresh button** in the cell details sidebar, which also refreshes automatically. [#ba23546](https://github.com/dinhanhthi/Dblore/commit/ba23546)
- **Rename a connection** from the connection info modal with an Apply button. [#d1382e9](https://github.com/dinhanhthi/Dblore/commit/d1382e9)
- **App version** is shown on the welcome screen. [#8a537dc](https://github.com/dinhanhthi/Dblore/commit/8a537dc)

### Improved

- **New app logo.** [#b06839a](https://github.com/dinhanhthi/Dblore/commit/b06839a)
- **Faster app**: incremental SQL syntax highlighting, quicker schema loading with a non-blocking workspace open, a cached results grid display, debounced autocomplete and a delayed Sparkle update check. [#937b92a](https://github.com/dinhanhthi/Dblore/commit/937b92a) [#3250c0b](https://github.com/dinhanhthi/Dblore/commit/3250c0b) [#2b0252e](https://github.com/dinhanhthi/Dblore/commit/2b0252e)
- **Data viewer header** now holds the footer controls, with a simpler pagination label. [#2d84bb3](https://github.com/dinhanhthi/Dblore/commit/2d84bb3)
- **Remember connection** is on by default. [#a07c9ec](https://github.com/dinhanhthi/Dblore/commit/a07c9ec)
- **Safe mode** protection icons use the app accent color. [#e856710](https://github.com/dinhanhthi/Dblore/commit/e856710)

### Fixed

- Undo and redo in editors and cells no longer interfere with each other. [#9aba555](https://github.com/dinhanhthi/Dblore/commit/9aba555)
- Tabs show the unsaved dot in the close button slot, which turns into an x on hover. [#8337c8f](https://github.com/dinhanhthi/Dblore/commit/8337c8f)
- A single flat border sits under the tab bar without a glass rim. [#1547df1](https://github.com/dinhanhthi/Dblore/commit/1547df1)

## v0.2.2 (2026-09-29)

### Added

- **Table data viewer.** Open a table's data in its own tab, with a compact header, search and an icon-only refresh button; pinned data viewer tabs are restored with the workspace. [#3cf3643](https://github.com/dinhanhthi/Dblore/commit/3cf3643) [#8d0a055](https://github.com/dinhanhthi/Dblore/commit/8d0a055) [#11d9f9a](https://github.com/dinhanhthi/Dblore/commit/11d9f9a) [#c564a5f](https://github.com/dinhanhthi/Dblore/commit/c564a5f)
- **Reopen the last closed tab** with `Cmd+Shift+T`. [#610854f](https://github.com/dinhanhthi/Dblore/commit/610854f)
- **Format SQL button** next to the syntax highlight toggle in the editor. [#2f9291e](https://github.com/dinhanhthi/Dblore/commit/2f9291e)
- **Results grid**: a row number column, double-click a column divider to fit its width to the content, column widths auto-fit when columns change, and the hovered row is highlighted. [#1017512](https://github.com/dinhanhthi/Dblore/commit/1017512) [#4feca56](https://github.com/dinhanhthi/Dblore/commit/4feca56) [#f949ef5](https://github.com/dinhanhthi/Dblore/commit/f949ef5) [#024c1e4](https://github.com/dinhanhthi/Dblore/commit/024c1e4)
- **Gray accent color** option; the default accent is now blue. [#7e5f892](https://github.com/dinhanhthi/Dblore/commit/7e5f892)
- **Tooltips** on icon-only buttons. [#5efe9ab](https://github.com/dinhanhthi/Dblore/commit/5efe9ab)

### Improved

- **Settings** now use a sidebar for navigation, and shortcuts are split into App and Editor tabs. [#04ae47a](https://github.com/dinhanhthi/Dblore/commit/04ae47a) [#fdafe53](https://github.com/dinhanhthi/Dblore/commit/fdafe53)
- **Results grid look**: vertical lines between columns, a distinct row number gutter and header background, a smaller column type font in the header and softer text color. [#e999315](https://github.com/dinhanhthi/Dblore/commit/e999315) [#4a7cac4](https://github.com/dinhanhthi/Dblore/commit/4a7cac4) [#f344b7d](https://github.com/dinhanhthi/Dblore/commit/f344b7d) [#752ca2d](https://github.com/dinhanhthi/Dblore/commit/752ca2d) [#c8f0fb3](https://github.com/dinhanhthi/Dblore/commit/c8f0fb3) [#0b7f8e5](https://github.com/dinhanhthi/Dblore/commit/0b7f8e5)
- **Cell details** now open with word wrap on and JSON auto-beautified. [#0acbd0a](https://github.com/dinhanhthi/Dblore/commit/0acbd0a)
- **Stronger hover background** for inactive tabs. [#635d44e](https://github.com/dinhanhthi/Dblore/commit/635d44e)
- **Faster UI**: smoother scrolling in large result grids and quicker tab switching. [#a8e2cb1](https://github.com/dinhanhthi/Dblore/commit/a8e2cb1) [#7a549bb](https://github.com/dinhanhthi/Dblore/commit/7a549bb)
- **Large reads inside transactions** are now capped with a server-side cursor. [#a2876aa](https://github.com/dinhanhthi/Dblore/commit/a2876aa)

### Fixed

- Closing a window no longer crashes the app. [#318f601](https://github.com/dinhanhthi/Dblore/commit/318f601)
- Dragging tabs to reorder no longer moves the window. [#7ca0bdc](https://github.com/dinhanhthi/Dblore/commit/7ca0bdc)
- Autocomplete suggests tables and columns in every editor. [#2a70af8](https://github.com/dinhanhthi/Dblore/commit/2a70af8)
- The SQL formatter keeps clause contents inline and aligns the `SELECT` list. [#6994523](https://github.com/dinhanhthi/Dblore/commit/6994523)
- Connecting uses the active tab's configuration and is blocked on an invalid connection string. [#020b13b](https://github.com/dinhanhthi/Dblore/commit/020b13b)
- The Save Workspace commands show in the File menu. [#7e3228a](https://github.com/dinhanhthi/Dblore/commit/7e3228a)
- Navigation arrows keep their spacing when the left sidebar is collapsed. [#f06c717](https://github.com/dinhanhthi/Dblore/commit/f06c717)

## v0.2.1 (2026-09-28)

### Improved

- **Lowered the minimum macOS to 14.** SQLNotebook now runs on macOS 14 and later (previously 26); the Liquid Glass look and the pointing-hand cursor still show on the macOS versions that support them. [#a51ce77](https://github.com/dinhanhthi/Dblore/commit/a51ce77)
- **The installer DMG now includes a shortcut to the Applications folder**, so you can drag SQLNotebook straight in. [#b668e5b](https://github.com/dinhanhthi/Dblore/commit/b668e5b)

## v0.2.0 (2026-09-28)

### Added

- **Automatic updates.** SQLNotebook now checks for new versions in the background and lets you install them with one click; check anytime from the **SQLNotebook > Check for Updates…** menu, or toggle background checks in **Settings > Updates**. [#d5ce6bf](https://github.com/dinhanhthi/Dblore/commit/d5ce6bf)

## v0.1.0 (2026-09-27)

### Added

- **SQL notebooks (`.sqlnb`) and standalone `.sql` editor tabs**, both in a multi-tab, multi-window workspace with drag-to-reorder tabs, middle-click close, recent files, auto-save, and window state (size/position) restored per window. [#9ebc09c](https://github.com/dinhanhthi/Dblore/commit/9ebc09c) [#4018865](https://github.com/dinhanhthi/Dblore/commit/4018865) [#045362e](https://github.com/dinhanhthi/Dblore/commit/045362e) [#1603d7c](https://github.com/dinhanhthi/Dblore/commit/1603d7c)
- **Cell-based query execution**: run a single cell, run the query at the cursor (Simple Mode), or run all cells, with an execution queue, cancellable in-flight queries, per-cell row/execution-time metadata, and a confirmation before destructive "run all" queries. [#7024e1b](https://github.com/dinhanhthi/Dblore/commit/7024e1b) [#5fafc02](https://github.com/dinhanhthi/Dblore/commit/5fafc02) [#c1c6a7a](https://github.com/dinhanhthi/Dblore/commit/c1c6a7a) [#4154cf2](https://github.com/dinhanhthi/Dblore/commit/4154cf2)
- **Query editor**: SQL syntax highlighting, line numbers, autocompletion (table/column aware), word-wrap toggle, current-line highlight, comment/uncomment (`cmd+/`), undo/redo, and keyboard shortcuts for running the query or selection. [#86ebce8](https://github.com/dinhanhthi/Dblore/commit/86ebce8) [#dcc1c28](https://github.com/dinhanhthi/Dblore/commit/dcc1c28) [#7bfcfca](https://github.com/dinhanhthi/Dblore/commit/7bfcfca) [#e5f123f](https://github.com/dinhanhthi/Dblore/commit/e5f123f)
- **Results grid**: sortable, resizable and auto-fitting columns, primary key and type icons, pagination with a configurable row cap, in-grid search with match highlighting, and a cell-detail view with a JSON viewer and string beautifier. [#c2509ff](https://github.com/dinhanhthi/Dblore/commit/c2509ff) [#a7acbaa](https://github.com/dinhanhthi/Dblore/commit/a7acbaa) [#138f2c2](https://github.com/dinhanhthi/Dblore/commit/138f2c2) [#e147c78](https://github.com/dinhanhthi/Dblore/commit/e147c78)
- **Export results** to Excel, CSV, JSON, Markdown, PDF or TSV. [#deb7361](https://github.com/dinhanhthi/Dblore/commit/deb7361)
- **Inline data editing** directly in the results grid (using `ctid` for PostgreSQL), staged or auto-committed depending on Safe Mode. [#c990840](https://github.com/dinhanhthi/Dblore/commit/c990840) [#ce0c960](https://github.com/dinhanhthi/Dblore/commit/ce0c960) [#4e8162f](https://github.com/dinhanhthi/Dblore/commit/4e8162f)
- **Safe Mode**: five protection levels, confirmation before `DROP`/`TRUNCATE`/`ALTER`/`CREATE`, a warning on `DELETE`/`UPDATE` without a `WHERE` clause, a Protected mode with a pending-transaction Commit/Rollback banner, and Touch ID (with system-password fallback) to unlock changes. [#b725879](https://github.com/dinhanhthi/Dblore/commit/b725879) [#74e4dc6](https://github.com/dinhanhthi/Dblore/commit/74e4dc6) [#05dff6b](https://github.com/dinhanhthi/Dblore/commit/05dff6b) [#47a597e](https://github.com/dinhanhthi/Dblore/commit/47a597e)
- **Connections**: a connection form with saved history, configurable timeouts, SSL/certificate verification, retry on failure, and a read-only mode. [#3de7a6f](https://github.com/dinhanhthi/Dblore/commit/3de7a6f) [#c5f35e4](https://github.com/dinhanhthi/Dblore/commit/c5f35e4) [#aa0ab36](https://github.com/dinhanhthi/Dblore/commit/aa0ab36) [#d1254e3](https://github.com/dinhanhthi/Dblore/commit/d1254e3)
- **Schema visualizer**: a searchable, force-directed canvas of tables with resizable cards and toggleable foreign-key connection lines. [#6f0d668](https://github.com/dinhanhthi/Dblore/commit/6f0d668) [#11875ef](https://github.com/dinhanhthi/Dblore/commit/11875ef) [#c0f0c66](https://github.com/dinhanhthi/Dblore/commit/c0f0c66) [#112f845](https://github.com/dinhanhthi/Dblore/commit/112f845)
- **Workspace-level left sidebar** with the connected schema (tables, columns, row counts, types) and a per-tab right sidebar with cell/query details, both resizable and animated. [#7b90a18](https://github.com/dinhanhthi/Dblore/commit/7b90a18) [#2766886](https://github.com/dinhanhthi/Dblore/commit/2766886) [#cc7033f](https://github.com/dinhanhthi/Dblore/commit/cc7033f)
- **Global and in-editor search**, and a "View Query"/"Run with query" bar that shows the exact SQL sent to the database, including the applied row limit. [#1dfe23f](https://github.com/dinhanhthi/Dblore/commit/1dfe23f) [#0dfa64a](https://github.com/dinhanhthi/Dblore/commit/0dfa64a) [#2872df4](https://github.com/dinhanhthi/Dblore/commit/2872df4)
- **Sandboxed file access** via security-scoped bookmarks for workspaces, tabs and recent files, with a Developer ID–signed, notarized build. [#37236af](https://github.com/dinhanhthi/Dblore/commit/37236af) [#c263b6f](https://github.com/dinhanhthi/Dblore/commit/c263b6f) [#efc83a1](https://github.com/dinhanhthi/Dblore/commit/efc83a1)
- **Liquid Glass design system**, dark/light theme with a selectable accent color, and a redesigned settings modal with one section per tab. [#d0bfecb](https://github.com/dinhanhthi/Dblore/commit/d0bfecb) [#32a9b2c](https://github.com/dinhanhthi/Dblore/commit/32a9b2c) [#ea2896d](https://github.com/dinhanhthi/Dblore/commit/ea2896d) [#9a32f10](https://github.com/dinhanhthi/Dblore/commit/9a32f10)

### Improved

- Query execution, search rendering and result-grid drawing moved off the main actor, and the left sidebar builds its entity rows lazily, keeping the UI responsive on large schemas and result sets. [#06fa6f1](https://github.com/dinhanhthi/Dblore/commit/06fa6f1) [#36e7afd](https://github.com/dinhanhthi/Dblore/commit/36e7afd) [#f0f126d](https://github.com/dinhanhthi/Dblore/commit/f0f126d)
- The results grid was rewritten on `NSTableView` for smoother scrolling, sorting and inline editing. [#c2509ff](https://github.com/dinhanhthi/Dblore/commit/c2509ff) [#613490e](https://github.com/dinhanhthi/Dblore/commit/613490e)
