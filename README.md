<div align="center">

<img src="assets/logo_256.png" alt="Dblore" width="120" />

# Dblore

A native macOS database client: query in Jupyter-style **notebooks** or a classic
**SQL editor**, browse and edit results and tables, explore the schema, guard production
with Safe Mode, and get help from an AI assistant that works with your own key or a local
model. Supports PostgreSQL, SQLite (beta) and DuckDB (as a plugin); more engines (such
as MongoDB) are planned.

[Download](https://github.com/dinhanhthi/Dblore/releases/latest) &nbsp;·&nbsp; [Website](https://dblore.dinhanhthi.com)
&nbsp;·&nbsp; macOS 14+ &nbsp;·&nbsp; signed &amp; notarized

</div>

> [!NOTE]
> Dblore is built around my own day-to-day needs, so many features are still missing.
> Need something? [Suggest a feature](https://github.com/dinhanhthi/Dblore/issues/new?template=feature_request.md&title=New%20feature%3A%20&labels=enhancement)
> and I'll consider adding it.

![Screenshot](assets/poster.png)

## Features

- **Connections**: PostgreSQL with SSL, client certificates and SSH tunnels; import
  connections from DBeaver, TablePlus, DataGrip, `.pgpass` or a URI
- **Notebooks**: `.dblore` notebooks that mix SQL cells with inline results, like Jupyter
  for your databases; or plain `.sql` files in a classic editor
- **Markdown notes**: jot a quick `.md` note in the workspace without saving it first
  (written to disk only on Cmd+S), and toggle between the source and an editable preview
- **SQL editor and execution**: syntax highlighting and table- and column-aware
  autocompletion; run a cell, the query at the cursor or all cells, cancel running
  queries, and see row count and execution time per result; bind named `:name`
  parameters; find any command with `Cmd+K`
- **Results grid**: sort, resize and search columns, paginate, edit values inline, inspect
  a cell with a JSON viewer, follow foreign keys, pin a result to compare re-runs, and
  export to Excel, CSV, JSON, Markdown, PDF, TSV or SQL `INSERT`
- **Import data**: CSV, TSV and JSON into a new or existing table, with a preview,
  column mapping and type overrides
- **Table data viewer**: open any table or view from the sidebar to browse and edit its
  data without writing a query
- **Schema browser and visualizer**: tables, columns and types in the sidebar, and a
  canvas of tables with foreign-key lines; view the source of functions and triggers
- **Safe Mode**: protection levels, confirmation before destructive statements, and a
  Commit / Rollback banner for pending transactions, with Touch ID to unlock, and a
  commit style (Immediate, Confirm, Review or Password)
- **AI assistant**: chat panel (`Cmd+L`) that writes SQL from plain-language questions
  and explains or fixes queries. Works with Anthropic, OpenAI, OpenRouter, Ollama,
  LM Studio, `mlx_lm.server` or any OpenAI-compatible endpoint (bring your own API key).
  Only schema metadata is sent automatically; query text and errors are sent only when
  you confirm, row data is never sent on its own, and generated SQL is never run
  automatically. Point it at a local model for fully local use. Detach it into a
  floating, draggable bubble at the bottom of the window, or pick the default in
  Settings > AI > Panel

## Plugins

Optional engines that are not bundled with the app. Install them from
**Settings > Plugins**: Dblore downloads a signed, notarized library, checks its SHA-256
before every load, and **Remove** deletes it again.

| Plugin | Version | What it adds |
| ------ | ------- | ------------ |
| **DuckDB** | 1.5.6 | Open a `.duckdb` file (read-only by default, also from Finder), create one or use an in-memory database, browse its schema and query Parquet or CSV files |

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
