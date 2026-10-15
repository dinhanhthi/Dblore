<div align="center">

<img src="assets/logo_256.png" alt="Dblore" width="120" />

# Dblore

A native macOS database client: query in Jupyter-style **notebooks** or a classic
**SQL editor**, browse and edit results and tables, explore the schema, guard production
with Safe Mode, and get help from an AI assistant that works with your own key or a local
model. Supports PostgreSQL, MySQL/MariaDB, MongoDB, SQLite and DuckDB (as a plugin).

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
- **MySQL and MariaDB**: TCP with TLS and client certificates, or through an SSH tunnel;
  queries, schema tree, autocomplete, Safe Mode and Protected mode, history, export, staged
  edits by primary key, foreign-key lookup, CSV import, routine and trigger source, EXPLAIN
  (a plan tree on MySQL, a table on MariaDB) and cancel. Only the Verify CA and Verify Full
  SSL modes check the server certificate
- **MongoDB**: connect with a `mongodb://` or `mongodb+srv://` string or the form (SCRAM
  login, TLS, SSH tunnel to a single host); write commands in a subset of the mongosh
  syntax (find, aggregate, count, distinct, insert, update, replace and delete) with
  highlighting and autocomplete; browse results as a grid or a document tree; filter a
  collection in the data viewer, build an aggregation stage by stage with a preview of each
  stage, and stage document edits by `_id` that run one by one after Safe Mode confirmation
- **Notebooks**: `.dblore` notebooks that mix SQL cells with inline results, like Jupyter
  for your databases; or plain `.sql` files in a classic editor
- **Markdown notes**: jot a quick `.md` note in the workspace without saving it first
  (written to disk only on Cmd+S), and toggle between the source and an editable preview
- **SQL editor and execution**: syntax highlighting and table- and column-aware
  autocompletion; run a cell, the query at the cursor or all cells, cancel running
  queries, and see row count and execution time per result; bind named `:name`
  parameters; find any command with `Cmd+K`
- **SQL dump and restore**: export a PostgreSQL, MySQL/MariaDB or SQLite database (all
  tables or some, with or without data) as a `.sql` file read in one snapshot, restore a
  Dblore dump of up to 64 MiB after every statement is checked, or copy an open SQLite
  database into one file
- **Results grid**: sort, resize and search columns, paginate, edit values inline, inspect
  a cell with a JSON viewer, follow foreign keys, add a row from a form, color values by
  type, pin a result to compare re-runs, and export to Excel, CSV, JSON, Markdown, PDF,
  TSV or SQL `INSERT`
- **Import data**: CSV, TSV and JSON into a new or existing table, with a preview,
  column mapping and type overrides
- **Table data viewer**: open any table or view from the sidebar to browse and edit its
  data without writing a query
- **Schema browser and visualizer**: tables, columns and types in the sidebar, and a
  canvas of tables with foreign-key lines; view the source of functions and triggers
- **Structure editor**: "Edit Structure..." on a table adds, alters, renames and drops
  columns, indexes and keys on PostgreSQL and MySQL, with a preview of the exact SQL that
  runs. SQLite gets only the ALTERs it supports (add column; rename and drop column on newer
  SQLite versions; create and drop index); DuckDB is view-only
- **Safe Mode**: protection levels, confirmation before destructive statements, and a
  Commit / Rollback banner for pending transactions, with Touch ID to unlock, and a
  commit style (Immediate, Confirm, Review or Password)
- **AI assistant**: chat panel (`Cmd+L`) that writes SQL (mongosh commands on MongoDB)
  from plain-language questions and explains or fixes queries. Works with Anthropic,
  OpenAI, OpenRouter, Ollama, LM Studio, `mlx_lm.server` or any OpenAI-compatible endpoint
  (bring your own API key).
  Only schema metadata is sent automatically; query text and errors are sent only when
  you confirm, row data is never sent on its own, and generated SQL does not run unless
  you turn on "Run read-only queries" (off by default): then a single read-only statement
  runs and only you see the rows. Point it at a local model (Qwen3.5 or Gemma 4 on-device,
  Ollama, LM Studio) for fully local use. Detach it into a floating, resizable bubble at
  the bottom of the window, or pick the default in Settings > AI > Panel
- **MCP server**: let AI agents such as Claude Code or Cursor read your databases through a
  read-only server on `127.0.0.1`. Off by default; only the connections you allow in
  Settings > MCP are exposed, every query is checked and run read-only, and queries are
  recorded in History. On MongoDB agents run single read commands in the mongosh subset;
  MongoDB has no read-only session, so give that connection a user with a read-only role

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
- A PostgreSQL, MySQL/MariaDB or MongoDB server, or a SQLite or DuckDB file, to connect to

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

[`docker/`](docker/README.md) has ready-made PostgreSQL, MySQL/MariaDB and MongoDB
containers. PostgreSQL:

- a development database with sample data, on port `5433`
  (`postgresql://dblore:dblore123@localhost:5433/dblore`);
- a separate database for the opt-in PostgreSQL test suites (`TEST_RUNNER_POSTGRES_TESTS=1`),
  on port `5435`.

```sh
cd docker/postgresql
cp .env.example .env
docker compose up -d
```

[`docker/mysql`](docker/mysql/docker-compose.test.yml) runs MySQL 8.4 on port `3307` and
MariaDB 11.4 on port `3308` for the opt-in MySQL test suites (`TEST_RUNNER_MYSQL_TESTS=1`):

```sh
docker compose -f docker/mysql/docker-compose.test.yml up -d
```

[`docker/mongodb`](docker/mongodb/docker-compose.test.yml) runs MongoDB 8.0 on port `27018`
for the opt-in MongoDB test suites (`TEST_RUNNER_MONGO_TESTS=1`), plus a TLS-only server on
port `27019` behind the `tls` profile (`TEST_RUNNER_MONGO_TLS_TESTS=1`, certificates from
`docker/mongodb/scripts/gen-mongo-tls.sh`):

```sh
docker compose -f docker/mongodb/docker-compose.test.yml up -d --wait
```

CI runs the integration suites against live PostgreSQL, MySQL, MariaDB and MongoDB
containers, which [`scripts/ci-live-databases.sh`](scripts/ci-live-databases.sh) starts and
removes again (see [docker/README.md](docker/README.md#ci-live-databases-scriptsci-live-databasessh)).

## Contributing

Contributions are welcome: open an issue to discuss a change, or send a pull request.
See **[CONTRIBUTING.md](CONTRIBUTING.md)** for guidelines.

## License

Copyright (C) 2025-2026 Anh-Thi Dinh.

Dblore is open source under the
[GNU Affero General Public License v3.0](https://www.gnu.org/licenses/agpl-3.0.html).
You may use, modify, and distribute it under its terms. See [LICENSE](LICENSE) for the
full license text.
