<div align="center">

<img src="assets/logo_256.png" alt="Dblore" width="120" />

# Dblore

A native macOS database client: query in Jupyter-style **notebooks** or a classic
**SQL editor**, browse and edit results and tables, explore the schema, guard production
with Safe Mode, and get help from an AI assistant that works with your own key or a local
model.

[Download](https://github.com/dinhanhthi/Dblore/releases/latest) &nbsp;·&nbsp; [Website](https://dblore.dinhanhthi.com)
&nbsp;·&nbsp; macOS 14+ &nbsp;·&nbsp; signed &amp; notarized

</div>

> [!NOTE]
> Dblore is built around my own day-to-day needs, so many features are still missing.
> Need something? [Suggest a feature](https://github.com/dinhanhthi/Dblore/issues/new?template=feature_request.md&title=New%20feature%3A%20&labels=enhancement) and I'll consider adding it.

![Screenshot](assets/poster.png)

## Features

- **Notebooks and SQL editor** with autocomplete, formatting and inline results
- **Schema browser**, structure editor, join query builder and schema compare
- **Results grid** with inline editing, charts, import and export
- **Safe Mode** and **Lock** to protect production data
- **AI assistant** with your own key or a local model, plus an MCP server and a command-line tool

See everything Dblore can do, and search for a specific feature, on the
**[features page](https://dblore.dinhanhthi.com/features.html)**.

## Databases

PostgreSQL, MySQL/MariaDB, MongoDB and SQLite are built in. DuckDB, SQL Server, ClickHouse
and Redis are plugins. CockroachDB, Redshift, YugabyteDB, TiDB and SingleStore connect as
presets. Per-engine details are on the [features page](https://dblore.dinhanhthi.com/features.html).

## Plugins

DuckDB, SQL Server, ClickHouse, Redis and On-device AI are optional plugins. Install them from
**Settings > Plugins**: each is a signed, notarized download, checked before it loads.
Which features ship as plugins is decided in [CONTRIBUTING](CONTRIBUTING.md#plugins).

## Install

- **Download the app:** get the latest signed &amp; notarized DMG from the
  [Releases page](https://github.com/dinhanhthi/Dblore/releases/latest), open it and
  drag Dblore to Applications. It updates itself (**Dblore > Check for Updates…**).
- **Or build from source:** see below.

## Requirements

- macOS 14 or later
- Xcode 27 on macOS 26 (only to build from source)
- A database server or file to connect to (DuckDB, SQL Server, ClickHouse and Redis need their
  plugin; Redis 6.0 or later)

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

Ready-made Docker servers (PostgreSQL, MySQL/MariaDB, MongoDB and an SSH tunnel stack) to
connect the app to and run the integration tests against. Ports, logins and setup:
[docker/README.md](docker/README.md).

## Contributing

Contributions are welcome: open an issue to discuss a change, or send a pull request.
See **[CONTRIBUTING.md](CONTRIBUTING.md)** for guidelines.

## License

Copyright (C) 2025-2026 Anh-Thi Dinh.

Dblore is open source under the
[GNU Affero General Public License v3.0](https://www.gnu.org/licenses/agpl-3.0.html).
You may use, modify, and distribute it under its terms. See [LICENSE](LICENSE) for the
full license text.
