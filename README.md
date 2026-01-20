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
- 🔍 **Global Search & Navigation** - Search across all cells/content with match highlighting and case-sensitive options
- 💡 **Autocomplete** - Smart SQL autocomplete with keywords, table names, and column suggestions
- ▶️ **Execute Queries** - Run individual cells, multiple cells, or all cells with execution tracking
- 📊 **Result Visualization** - Interactive table view with column resizing and JSON data viewer
- 🗂️ **Database Schema Browser** - Left sidebar showing tables, columns, and row counts
- 🔌 **Multiple Database Support** - PostgreSQL and SQLite connectivity
- 💾 **Persistent Notebooks** - Save work as `.sqlnb` (Notebook mode) or `.sql` (Editor mode) files with full query history
- 🎨 **Syntax Highlighting** - SQL and JSON syntax highlighting with dark/light theme support
- ↩️ **Undo/Redo** - Context-aware history (editor-level and cell-level operations)
- ⌨️ **Keyboard Shortcuts** - Efficient navigation and execution shortcuts (Jupyter-like in Notebook, traditional in Editor)
- 📝 **Application Logging** - Built-in log system with export capabilities for debugging
- ✏️ **Inline Result Editing** - Edit result data directly in table views
- 🔀 **Drag & Drop** - Reorder cells by dragging (Notebook mode)
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

### Choosing Your Mode

When you first run SQLNotebook, you can:

1. **Create a new Notebook** (`.sqlnb` file) - Multi-cell interface with inline results (Jupyter-like experience)
2. **Create a new SQL file** (`.sql` file) - Single editor with result panel below (traditional SQL editor experience)

Each mode is optimized for different workflows:
- **Notebook Mode**: Great for interactive data exploration and documentation
- **Editor Mode**: Great for writing and executing SQL scripts

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

### Notebook Mode

#### Cell Execution
- `Ctrl+Enter` - Run current cell
- `Shift+Enter` - Run cell and move to next (Jupyter-like)
- `Option+Enter` - Run cell and insert new cell below
- `Cmd+Shift+Enter` - Run all cells

#### Cell Management
- `Cmd+B` - Add new cell
- `Cmd+D` - Duplicate cell
- `Cmd+Delete` - Delete cell

#### Navigation
- `↑` / `↓` - Navigate between cells (when not in editor)
- `Enter` - Focus editor
- `Esc` - Exit editor

### Editor Mode

#### Query Execution
- `Cmd+Enter` - Execute query (window-specific)
- `Ctrl+Enter` - Execute query
- Select text + `Cmd+Enter` - Execute selected query

#### Editing
- `Cmd+L` - Copy current line
- `Cmd+V` - Paste current line

### Both Modes

#### Editing
- `Cmd+Z` - Undo (context-aware)
- `Cmd+Shift+Z` - Redo
- `Cmd+F` - Open search panel

#### View
- `Cmd+B` - Toggle left sidebar (schema browser)
- `Cmd+,` - Toggle right sidebar (connection info)

See [docs/keyboard_shortcuts.md](docs/keyboard_shortcuts.md) for complete reference.

## File Format

### Notebook Mode (`.sqlnb`)
JSON format containing:
- SQL cells with execution history
- Query results and metadata
- Database connection configuration
- Execution counts and timestamps
- Full notebook structure with multiple cells

### Editor Mode (`.sql`)
Plain SQL text format:
- Single SQL query or script
- Clean SQL file format compatible with standard SQL editors
- Results stored separately in execution environment (not persisted to file)

## Documentation

- [Project Architecture](docs/project.md) - Technical overview and design decisions
- [Keyboard Shortcuts](docs/keyboard_shortcuts.md) - Complete shortcuts reference
- [Testing Plan](docs/testing_plan.md) - Testing strategy and setup
- [Dependencies](docs/dependencies.md) - SPM packages and version information
- [Task Tracking](docs/TODO.md) - Roadmap and pending features
- [Implementation Details](docs/implementation/) - Feature documentation and solutions

## License

GPL-3.0 License - see LICENSE file for details
