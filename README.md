# SQLNotebook

<p align="center">
  <img src="assets/sqlnb.png" alt="SQLNotebook Logo" width="100" />
</p>

A native macOS application for interactive SQL development. Write, execute, and save SQL queries in a notebook-style interface, similar to Jupyter Notebook but designed specifically for SQL workflows. It also supports traditional editor mode for writing SQL queries.

![Screenshot](./assets/screenshot.png)

## ✨ Features

### Core Functionality
- 📓 **Dual Mode System** - Notebook mode (cell-based) and Editor mode (traditional editor)
- 🔍 **Global Search & Navigation** - Search across all cells/content with match highlighting and case-sensitive options
- 💡 **Autocomplete** - Smart SQL autocomplete with keywords, table names, and column suggestions
- ▶️ **Execute Queries** - Run individual cells, multiple cells, or all cells with execution tracking
- 📊 **Result Visualization** - Interactive table view with column resizing and JSON data viewer
- 🗂️ **Database Schema Browser** - Left sidebar showing tables, columns, and row counts
- 🔌 **Multiple Database Support** - PostgreSQL and SQLite connectivity
- 💾 **Persistent Notebooks** - Save work as `.sqlnb` files (JSON format) with full query history
- 🎨 **Syntax Highlighting** - SQL and JSON syntax highlighting with dark/light theme support
- ↩️ **Undo/Redo** - Context-aware history (editor-level and cell-level operations)
- ⌨️ **Keyboard Shortcuts** - Efficient navigation and execution shortcuts (Jupyter-like workflow)
- 📝 **Application Logging** - Built-in log system with export capabilities for debugging
- ✏️ **Inline Result Editing** - Edit result data directly in table views
- 🔀 **Drag & Drop** - Reorder cells by dragging
- 🚦 **Row Limits** - Automatic row limiting to prevent memory issues with large result sets
- 📈 **Affected Rows Tracking** - Display row counts for INSERT, UPDATE, DELETE operations

## 🛠️ Tech Stack

- 🚀 **Language:** Swift 6+ with strict concurrency checking
- 🎨 **UI Framework:** SwiftUI with native macOS integration
- 🗄️ **Database Clients:**
  - PostgreSQL: [PostgresNIO](https://github.com/vapor/postgres-nio) with SSL/TLS support
  - SQLite: Native SQLite3 library
- 🏗️ **Architecture:** MVVM with `@Observable` macro
- 🔒 **State Management:** Observable pattern with Actor-based thread safety
- 💾 **Persistence:** Codable models with JSON-based `.sqlnb` file format
- ⚡ **Execution:** Swift async/await with queued execution model

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

## Keyboard Shortcuts

### Cell Execution
- `Ctrl+Enter` - Run current cell
- `Shift+Enter` - Run cell and move to next (Jupyter-like)
- `Option+Enter` - Run cell and insert new cell below
- `Cmd+Shift+Enter` - Run all cells

### Cell Management
- `Cmd+B` - Add new cell
- `Cmd+D` - Duplicate cell
- `Cmd+Delete` - Delete cell

### Navigation
- `↑` / `↓` - Navigate between cells (when not in editor)
- `Enter` - Focus editor
- `Esc` - Exit editor

### Editing
- `Cmd+Z` - Undo (context-aware)
- `Cmd+Shift+Z` - Redo
- `Cmd+F` - Open search panel

### View
- `Cmd+B` - Toggle left sidebar (schema browser)
- `Cmd+,` - Toggle right sidebar (connection info)
- `Cmd+M` - Switch between notebook and editor modes

See [docs/keyboard_shortcuts.md](docs/keyboard_shortcuts.md) for complete reference.

## File Format

Notebooks are saved as `.sqlnb` JSON files containing:
- SQL cells with execution history
- Query results and metadata
- Database connection configuration
- Execution counts and timestamps

## Documentation

- [Project Architecture](docs/project.md) - Technical overview and design decisions
- [Keyboard Shortcuts](docs/keyboard_shortcuts.md) - Complete shortcuts reference
- [Testing Plan](docs/testing_plan.md) - Testing strategy and setup
- [Dependencies](docs/dependencies.md) - SPM packages and version information
- [Task Tracking](docs/TODO.md) - Roadmap and pending features
- [Implementation Details](docs/implementation/) - Feature documentation and solutions

## License

MIT License - see LICENSE file for details
