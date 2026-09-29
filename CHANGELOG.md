# Changelog

All notable user-visible changes to SQLNotebook, newest first. Each release is a section headed `## vX.Y.Z (YYYY-MM-DD)` with `### Added`, `### Improved` and `### Fixed` subsections (empty ones omitted); every entry ends with links to its commits. Sections are written by `/cf-ship`, and the release workflow publishes the matching section as the GitHub Release notes.

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
