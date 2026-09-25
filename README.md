# SQLNotebook

<p align="center">
  <img src="assets/sqlnb.png" alt="SQLNotebook Logo" width="100" />
</p>

A native macOS application for interactive SQL development. Write, execute, and save SQL queries in a notebook-style interface, similar to Jupyter Notebook but designed specifically for SQL workflows. It also supports traditional editor mode for writing SQL queries.

![Screenshot](./assets/screenshot.png)

## ✨ Features

### Core Functionality
- 📓 **Dual Mode System**
  - **Notebook Mode** (`.sqlnb` files): Cell-based interface with inline results, similar to Jupyter Notebook
  - **Editor Mode** (`.sql` files): Single SQL editor with result panel below, optimized for traditional SQL development
  - Seamless switching between modes with dedicated file types
- 💡 **Autocomplete** - Smart SQL autocomplete with keywords, table names, and column suggestions
- 📊 **Result Visualization** - Interactive table view with column resizing and JSON data viewer
- 🗂️ **Database Schema Browser** - Left sidebar showing tables, columns, and row counts
- 🔌 **Multiple Database Support** - PostgreSQL and SQLite connectivity
- 💾 **Persistent Notebooks** - Save work as `.sqlnb` (Notebook mode) or `.sql` (Editor mode) files with full query history
- 🎨 **Syntax Highlighting** - SQL and JSON syntax highlighting with dark/light theme support
- ⌨️ **Keyboard Shortcuts** - Efficient navigation and execution shortcuts (Jupyter-like in Notebook, traditional in Editor)
- 📝 **Application Logging** - Built-in log system with export capabilities for debugging
- ✏️ **Inline Result Editing** - Edit result data directly in table views

## 🛠️ Tech Stack

- 🚀 **Language:** Swift 6+ with strict concurrency checking
- 🎨 **UI Framework:** SwiftUI with native macOS integration
- 🗄️ **Database Clients:**
  - PostgreSQL: [PostgresNIO](https://github.com/vapor/postgres-nio) with SSL/TLS support
  - SQLite: Native SQLite3 library

## Getting Started

### Requirements

- macOS 16.0 or later
- Xcode 16.0 or later
- Swift 6.0 or later

### Installation

```bash
# Clone repository
git clone https://github.com/yourusername/SQLNotebook.git
cd SQLNotebook

# Open in Xcode
open SQLNotebook.xcodeproj

# Build and run (Cmd+R)
```

### Build Settings

**Important:** Enable strict concurrency checking to match CI/CD:

1. Select project → Target "SQLNotebook" → Build Settings
2. Search for "Strict Concurrency Checking"
3. Set to `Complete`

Or build via command line:
```bash
xcodebuild -scheme SQLNotebook build SWIFT_STRICT_CONCURRENCY=complete
```

## Development

### Code Formatting

Format code with `swift-format`:

```bash
# Install
brew install swift-format

# Format entire project
swift-format -i -r SQLNotebook/

# Check formatting (lint mode)
swift-format lint -r SQLNotebook/
```

### Testing

Run tests with Swift Testing framework:

```bash
# Run all tests
xcodebuild test -scheme SQLNotebook

# Skip integration tests (no database required)
SKIP_INTEGRATION_TESTS=true xcodebuild test -scheme SQLNotebook
```

### Database Setup

For development and testing, use Docker:

```bash
cd docker/postgresql
cp .env.example .env
docker compose up -d
```

**Connection Details:**
- Host: `localhost`
- Port: `5432`
- Database: `sqlnotebook`
- User: `sqlnotebook`
- Password: `sqlnotebook123`

Connection string: `postgresql://sqlnotebook:sqlnotebook123@localhost:5433/sqlnotebook`

The database includes sample tables (customers, products, orders, employees, analytics) with realistic data for testing.

**Database for testing**: `postgresql://sqlnotebook_test:sqlnotebook123@localhost:5435/sqlnotebook_test`

## Documentation

- [Project Architecture](docs/project.md) - Technical overview and design decisions
- [Keyboard Shortcuts](docs/keyboard_shortcuts.md) - Complete shortcuts reference
- [Testing Plan](docs/testing_plan.md) - Testing strategy and setup
- [Dependencies](docs/dependencies.md) - SPM packages and version information
- [Task Tracking](docs/TODO.md) - Roadmap and pending features
- [Implementation Details](docs/implementation/) - Feature documentation and solutions

## License

SQLNotebook is licensed under [AGPL-3.0-or-later](LICENSE).
