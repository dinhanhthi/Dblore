<div align="center">

<img src="assets/logo_256.png" alt="Dblore" width="120" />

# Dblore

A native macOS app for working with databases: write and run queries in **notebooks**
(like Jupyter, for your databases) or in a classic **SQL editor**. Supports PostgreSQL
today, and SQLite files as beta; more engines (such as MongoDB) are planned.

[Download](https://github.com/dinhanhthi/Dblore/releases/latest) &nbsp;·&nbsp; [Website](https://dblore.dinhanhthi.com)
&nbsp;·&nbsp; macOS 14+ &nbsp;·&nbsp; signed &amp; notarized

</div>

![Screenshot](assets/poster.png)

## Features

- **Notebooks and editor tabs**: `.dblore` notebooks with inline results per cell, and
  standalone `.sql` files, in a multi-tab, multi-window workspace
- **Native window tabs** (optional): Settings > General > "Open new windows as tabs" groups
  windows into the macOS tab bar. `Cmd+Shift+N` or "+" opens a new window tab, `Ctrl+Tab`
  switches, `Cmd+T` opens a new tab. Drag a window tab out (or Window > Move Tab to New
  Window) to split it into its own window
- **Drag a tab out**: drag a workspace tab outside the window to open it in a new window
  (same as "Open in New Window"; pinned and unsaved tabs stay)
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
- **AI assistant**: chat panel (`Cmd+L`) that writes SQL from plain-language questions
  and explains or fixes queries. Works with Anthropic, OpenAI, OpenRouter, Ollama,
  LM Studio, `mlx_lm.server` or any custom OpenAI-compatible endpoint (bring your own API
  key; Claude Pro/Max subscriptions are not supported). Table and column names, types
  and keys are sent automatically; query text and error messages are only sent when you
  review and press Send on Explain or Fix, and row data is never sent on its own. Generated
  SQL is never run automatically. For fully local use, point it at Ollama, LM Studio or `mlx_lm.server`
- **Connections**: saved connections with passwords in the Keychain, SSL, timeouts and a
  read-only mode
- **Automatic updates**: checks for new versions and installs them from the app

## Install

- **Download the app:** get the latest signed &amp; notarized DMG from the
  [Releases page](https://github.com/dinhanhthi/Dblore/releases/latest), open it and
  drag Dblore to Applications. From v0.2.0 on, it updates itself
  (**Dblore > Check for Updates…**).
- **Or build from source:** see below.

## Requirements

- macOS 14 or later
- Xcode 27 on macOS 26 (only to build from source)
- A PostgreSQL server to connect to

## Build from source

```sh
git clone https://github.com/dinhanhthi/Dblore.git
cd Dblore
open Dblore.xcodeproj      # press Run
```

Headless build / test:

```sh
xcodebuild build -scheme Dblore -destination 'platform=macOS,arch=arm64'
SKIP_INTEGRATION_TESTS=true xcodebuild test -scheme Dblore \
  -destination 'platform=macOS,arch=arm64' -enableCodeCoverage NO
```

`-enableCodeCoverage NO` is required: without it `xcodebuild test` hangs after the tests
finish.

### Local databases

[`docker/`](docker/README.md) has ready-made PostgreSQL containers:

- a development database with sample data, on port `5433`
  (`postgresql://dblore:dblore123@localhost:5433/dblore`);
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

Dblore is open source under the
[GNU Affero General Public License v3.0](https://www.gnu.org/licenses/agpl-3.0.html).
You may use, modify, and distribute it under its terms. See [LICENSE](LICENSE) for the
full license text.
