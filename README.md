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

- **Notebooks**: `.dblore` notebooks that mix SQL cells with inline results, like Jupyter
  for your databases; or plain `.sql` files in a classic editor
- **SQL editor and execution**: syntax highlighting and table- and column-aware
  autocompletion; run a cell, the query at the cursor or all cells, cancel running
  queries, and see row count and execution time per result
- **Results grid**: sort, resize and search columns, paginate, edit values inline, inspect
  a cell with a JSON viewer, and export to Excel, CSV, JSON, Markdown, PDF or TSV
- **Table data viewer**: open any table or view from the sidebar to browse and edit its
  data without writing a query
- **Schema browser and visualizer**: tables, columns and types in the sidebar, and a
  canvas of tables with foreign-key lines
- **Safe Mode**: protection levels, confirmation before destructive statements, and a
  Commit / Rollback banner for pending transactions, with Touch ID to unlock
- **AI assistant**: chat panel (`Cmd+L`) that writes SQL from plain-language questions
  and explains or fixes queries. Works with Anthropic, OpenAI, OpenRouter, Ollama,
  LM Studio, `mlx_lm.server` or any OpenAI-compatible endpoint (bring your own API key).
  Only schema metadata is sent automatically; query text and errors are sent only when
  you confirm, row data is never sent on its own, and generated SQL is never run
  automatically. Point it at a local model for fully local use

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
