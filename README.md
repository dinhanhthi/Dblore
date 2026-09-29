<div align="center">

<img src="assets/logo_256.png" alt="SQLNotebook" width="120" />

# SQLNotebook

A native macOS app for working with SQL: write and run queries in **notebooks** (like
Jupyter, but for SQL) or in a classic **SQL editor**, against PostgreSQL.

**[Download for macOS](https://github.com/dinhanhthi/SQLNotebook/releases/latest)**
&nbsp;·&nbsp; macOS 14+ &nbsp;·&nbsp; signed &amp; notarized

</div>

![Screenshot](assets/poster.png)

## Features

- **Notebooks and editor tabs**: `.sqlnb` notebooks with inline results per cell, and
  standalone `.sql` files, in a multi-tab, multi-window workspace
- **Query execution**: run a cell, the query at the cursor, or all cells; cancel running
  queries; row count and execution time per result
- **Editor**: syntax highlighting, line numbers, table- and column-aware autocompletion,
  word wrap, comment toggle
- **Results grid**: sort, resize and search columns, paginate, and inspect a cell in a
  detail view with a JSON viewer
- **Export**: Excel, CSV, JSON, Markdown, PDF or TSV
- **Inline editing**: edit values directly in the results grid
- **Table data viewer**: click a table/view in the sidebar to browse its data in a preview
  tab (pagination, column toggles, inline edit)
- **Safe Mode**: protection levels, confirmation before destructive statements, and a
  Commit / Rollback banner for pending transactions, with Touch ID to unlock
- **Schema browser and visualizer**: tables, columns and types in the sidebar, and a
  canvas of tables with foreign-key lines
- **Connections**: saved connections with passwords in the Keychain, SSL, timeouts and a
  read-only mode
- **Automatic updates**: checks for new versions and installs them from the app

## Install

- **Download the app:** get the latest signed &amp; notarized DMG from the
  [Releases page](https://github.com/dinhanhthi/SQLNotebook/releases/latest), open it and
  drag SQLNotebook to Applications. From v0.2.0 on, it updates itself
  (**SQLNotebook > Check for Updates…**).
- **Or build from source:** see below.

## Requirements

- macOS 14 or later
- Xcode 27 on macOS 26 (only to build from source)
- A PostgreSQL server to connect to

## Build from source

```sh
git clone https://github.com/dinhanhthi/SQLNotebook.git
cd SQLNotebook
open SQLNotebook.xcodeproj      # press Run
```

Headless build / test:

```sh
xcodebuild build -scheme SQLNotebook -destination 'platform=macOS,arch=arm64'
SKIP_INTEGRATION_TESTS=true xcodebuild test -scheme SQLNotebook \
  -destination 'platform=macOS,arch=arm64' -enableCodeCoverage NO
```

`-enableCodeCoverage NO` is required: without it `xcodebuild test` hangs after the tests
finish.

### Local databases

[`docker/`](docker/README.md) has ready-made PostgreSQL containers:

- a development database with sample data, on port `5433`
  (`postgresql://sqlnotebook:sqlnotebook123@localhost:5433/sqlnotebook`);
- a separate database for the integration tests, on port `5435`.

```sh
cd docker/postgresql
cp .env.example .env
docker compose up -d
```

## Contributing

Contributions are welcome: open an issue to discuss a change, or send a pull request.
See **[CONTRIBUTING.md](CONTRIBUTING.md)** for guidelines.

## License

Copyright (C) 2025-2026 Anh-Thi Dinh.

SQLNotebook is open source under the
[GNU Affero General Public License v3.0](https://www.gnu.org/licenses/agpl-3.0.html).
You may use, modify, and distribute it under its terms. See [LICENSE](LICENSE) for the
full license text.
