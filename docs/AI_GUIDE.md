# AI Assistant Guide for SQLNotebook

This document provides comprehensive guidance for AI assistants working with the SQLNotebook codebase.

**Main Documentation Reference:**
- Technical specifications: [project.md](./project.md)
- Task breakdown: [TODO.md](./TODO.md)

---

## 📋 Project Overview

**SQLNotebook** is a native macOS application built with Swift and SwiftUI, functioning as an interactive SQL notebook (similar to Jupyter Notebook but specialized for SQL queries). The app allows users to write, execute, and store SQL queries in a cell-based interface with persistent results.

### Key Features
- Cell-based interface with SQL cells
- Execute SQL queries with syntax highlighting
- Save notebooks as `.sqlnb` files (JSON format)
- Display query results in table format
- Integrated JSON viewer for JSON/JSONB data
- Database connectivity: PostgreSQL (via PostgresNIO) and SQLite (native)

---

## 🏗️ Architecture & Structure

### Tech Stack
- **Language:** Swift 6+ with strict concurrency checking
- **UI Framework:** SwiftUI (latest)
- **Target:** macOS 15.0+ (Sequoia)
- **Architecture:** MVVM with Observable macro (@Observable, not ObservableObject)
- **Database Connectivity:** PostgresNIO (PostgreSQL) with SSL/TLS support
- **Persistence:** Codable documents saved as `.sqlnb` JSON files

### Project Structure

```
SQLNotebook/
├── Database/
│   ├── DatabaseConnectionManager.swift           # Actor managing database connections
│   ├── DatabaseConnectionManager+QueryExecution.swift
│   └── DatabaseConnectionManager+Schema.swift
├── Models/
│   ├── ConnectionConfig.swift                   # Database connection configuration
│   ├── NotebookCell.swift                       # Cell model (SQL only)
│   ├── SQLNotebook.swift                        # Main notebook model
│   ├── SQLNotebookDocument.swift                # FileDocument implementation
│   └── AppSettings.swift                        # Global app preferences
├── ViewModels/
│   ├── NotebookViewModel.swift                  # @Observable ViewModel (main)
│   ├── NotebookViewModel+Connection.swift       # Connection management
│   ├── NotebookViewModel+Execution.swift        # Query execution
│   ├── NotebookViewModel+CellManagement.swift   # Cell CRUD operations
│   └── NotebookViewModel+Sidebar.swift          # Sidebar state management
├── Views/
│   ├── Components/
│   │   ├── CellView.swift                       # Individual cell rendering
│   │   ├── ResultTableView.swift                # Query result table
│   │   └── ToastView.swift                      # Toast notifications
│   ├── Sidebars/
│   │   ├── LeftSidebarView.swift                # Database schema browser
│   │   ├── RightSidebarView.swift               # Multi-purpose sidebar
│   │   ├── ConnectionFormContent.swift          # Connection configuration
│   │   ├── SettingsContent.swift                # App settings
│   │   └── CellInfoContent.swift                # Cell detail with inline editing
│   ├── HeaderView.swift                         # Header toolbar
│   ├── FooterView.swift                         # Footer bar
│   └── ContentView.swift                        # Main view container
├── Utilities/
│   ├── DesignSystem.swift                       # Shadcn-inspired design tokens
│   ├── SQLSyntaxHighlighter.swift               # SQL syntax highlighting
│   └── CellValueValidator.swift                 # Value format validation
└── SQLNotebookApp.swift                         # App entry point
```

---

## 💾 Data Models

### Core Models
- **SQLNotebook**: Main document model with cells, metadata, connection config
- **NotebookCell**: Individual SQL cell with content and results
- **CellResult**: Execution results with columns, rows, timing info, primary keys
- **ConnectionConfig**: Database connection parameters with SSL/TLS support
- **CellValue**: Enum for data types (string, int, double, bool, null, json, date, data)

### State Management
- **NotebookViewModel**: @Observable class managing notebook state (organized in extensions)
- **ConnectionState**: Enum tracking connection status
- **SidebarContent**: Enum for right sidebar content modes
- **AppSettings**: Global preferences (UserDefaults-backed, @Observable)

---

## 🎨 UI Layout & Design System

### Layout Structure
```
┌─────────────────────────────────────────────────────────────────────────┐
│ HEADER (44pt)                                                           │
├──────────────┬──────────────────────────────────────┬───────────────────┤
│              │                                      │                   │
│ LEFT SIDEBAR │                                      │  RIGHT SIDEBAR    │
│ (collapsible)│         MAIN CONTENT                 │  (collapsible)    │
│ 240pt width  │         (scrollable)                 │  320pt width      │
│              │                                      │                   │
│ Database     │                                      │ Connection/       │
│ Schema       │                                      │ Settings/         │
│ Tree View    │                                      │ JSON Viewer/      │
│              │                                      │ Cell Info         │
├──────────────┴──────────────────────────────────────┴───────────────────┤
│ FOOTER (24pt)                                                           │
└─────────────────────────────────────────────────────────────────────────┘
```

### Design System (Shadcn-inspired)
- **Colors**: Semantic colors adapting to light/dark mode via `DesignSystem.swift`
- **Typography**: SF Mono/Menlo for code, system fonts for UI
- **Components**: Buttons, Cards, Inputs, Tables with consistent styling
- **Spacing**: 8pt grid system
- **Border Radius**: 6-8pt for cards and inputs

### SQL Syntax Highlighting
Token categories in `SQLSyntaxHighlighter.swift`:
- Keywords (SELECT, FROM, WHERE) - Blue
- Functions (COUNT, SUM) - Purple
- Strings ('text') - Green
- Numbers (123, 45.67) - Orange
- Comments (-- comment) - Gray

---

## 🔧 Development Guidelines

### Code Conventions
1. **Swift 6 Concurrency**: Use async/await, actors for database operations
2. **Observable Macro**: Use @Observable instead of ObservableObject
3. **Type Safety**: Leverage Swift's strong type system, avoid force unwrapping
4. **Error Handling**: Proper error propagation with try/catch and Result types
5. **SwiftUI Best Practices**:
   - Prefer composition over inheritance
   - Keep views small and focused
   - Extract reusable components into `Views/Components/`

### Key Implementation Notes
1. **Performance**:
   - Use LazyVStack for cell list
   - Row limit enforcement (1-200 rows configurable)
   - Debounce user inputs
2. **Memory Management**:
   - Actor-based connection manager for thread safety
   - Configurable max rows to prevent memory exhaustion
3. **Security**:
   - ⚠️ **TODO:** Store passwords in Keychain (NOT in `.sqlnb` files)
   - SSL/TLS support with 6 PostgreSQL modes
   - Value format validation before UPDATE queries
4. **Persistence**:
   - Document-based app architecture
   - Auto-save with undo/redo support
5. **Database**:
   - Actor-based connection manager (`DatabaseConnectionManager`)
   - Connection retry logic with exponential backoff
   - Proper query cancellation

### MVVM + Actors Pattern
- **ViewModels**: `NotebookViewModel` (marked `@MainActor @Observable`) is the single source of truth, organized into focused extensions
- **Database Layer**: `DatabaseConnectionManager` is an `actor` for thread-safe PostgreSQL operations
- **Models**: Use `Sendable` protocol for concurrency safety

---

## 🔌 Database Connectivity

### DatabaseConnectionManager (Actor)
- Manages PostgreSQL connections via PostgresNIO
- Thread-safe operations with actor isolation
- Methods: `connect`, `disconnect`, `execute`, `testConnection`, `loadSchema`, `updateCellValue`

### SSL/TLS Support
**Supported SSL Modes (PostgreSQL):**
- `disable`: No SSL encryption
- `allow`: Try non-SSL first, then SSL if server requires it
- `prefer`: Try SSL first, fallback to non-SSL
- `require`: Require SSL (full certificate verification)
- `verifyCa`: Require SSL and verify CA certificate
- `verifyFull`: Require SSL and verify hostname matches certificate

**Smart Cloud Database Detection:**
- Auto-detects Supabase, AWS RDS, Azure, Google Cloud SQL
- Automatically suggests `require` mode for cloud databases
- Connection string parsing with auto-fill

### Supported Operations
- SELECT queries → return result sets with column metadata
- INSERT/UPDATE/DELETE → return affected row counts
- DDL statements → success/failure status
- Multiple statements → execute sequentially
- Row limit enforcement (configurable 1-200 rows)
- Query modification detection

### Error Handling
Display SQL errors inline below cells:
- Error message from database (formatted PostgreSQL errors)
- Query execution time before error
- User-friendly error display
- Toast notification for critical errors

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action | Status |
|----------|--------|--------|
| `Cmd+N` | New notebook | ✅ |
| `Cmd+O` | Open notebook | ✅ |
| `Cmd+S` | Save notebook | ✅ |
| `Cmd+Enter` | Run selected cell | ✅ |
| `Shift+Enter` | Run cell and move to next | ✅ |
| `Option+Enter` | Run cell and add new cell below | ✅ |
| `Cmd+Shift+Enter` | Run all cells | ✅ |
| `Cmd+B` | Add code cell below | ✅ |
| `Cmd+Delete` | Delete selected cell | ✅ |
| `Cmd+D` | Duplicate cell | ✅ |
| `Cmd+,` | Toggle right sidebar | ✅ |
| `Cmd+/` | Comment/uncomment line in SQL | ⏳ TODO |
| `Escape` | Deselect cell / Close sidebar | ✅ |
| `Up/Down` | Navigate between cells | ✅ |
| `Cmd+Z` | Undo | ✅ |
| `Cmd+Shift+Z` | Redo | ✅ |

Defined in `NotebookViewModel+Execution.swift` and `KeyboardShortcutModifier`.

---

## 📄 File Format

`.sqlnb` files are JSON with structure:
```json
{
  "version": "1.0",
  "id": "uuid",
  "metadata": {
    "title": "My Queries",
    "createdAt": "2024-01-15T10:00:00Z",
    "modifiedAt": "2024-01-15T14:30:00Z"
  },
  "connectionConfig": {
    "host": "localhost",
    "port": 5432,
    "database": "mydb",
    "username": "user",
    "sslMode": "prefer",
    "databaseType": "postgresql"
  },
  "cells": [
    {
      "id": "uuid",
      "type": "sql",
      "content": "SELECT * FROM users LIMIT 10;",
      "executionCount": 1,
      "isResultVisible": true,
      "result": {
        "columns": [
          {"name": "id", "type": "INTEGER"},
          {"name": "name", "type": "VARCHAR"}
        ],
        "rows": [
          [{"int": 1}, {"string": "Alice"}],
          [{"int": 2}, {"string": "Bob"}]
        ],
        "executionTime": 0.034,
        "rowCount": 2,
        "timestamp": "2024-01-15T14:32:00Z",
        "tableName": "users",
        "primaryKeyColumns": ["id"]
      }
    }
  ]
}
```

**⚠️ Security Note**: Passwords should NOT be stored in files, only in Keychain (TODO: Phase 6).

---

## 🧪 Testing Strategy

### Test Organization
- **Unit**: Model serialization (`DataModelTests`), syntax highlighting (`SQLSyntaxHighlighterTests`), value validation (`CellValueValidatorTests`)
- **Integration**: Database operations with Docker PostgreSQL (`DatabaseIntegrationTests`, `DatabaseQueryExecutionTests`)
- **UI**: Critical user flows (`SQLNotebookUITests`)

### Running Tests
```bash
# All tests with Docker database
xcodebuild test -scheme SQLNotebook

# Specific test class
xcodebuild test -scheme SQLNotebook -only-testing SQLNotebookTests/DatabaseIntegrationTests

# Setup: Docker PostgreSQL in docker/postgresql/
cd docker/postgresql && docker compose up -d
```

### Docker Test Database
PostgreSQL setup at `docker/postgresql/docker-compose.test.yml`. Migrations auto-run on startup. Data persists in named volume.

---

## 🎯 Implementation Status

### Completed Features ✅

**Core Functionality (Phase 1-3):**
- Cell-based SQL notebook with syntax highlighting
- PostgreSQL database connectivity with SSL/TLS support
- Query execution with result display
- Document persistence as `.sqlnb` JSON files
- Undo/Redo support

**Polish Features (Phase 4 - Mostly Complete):**
- Header actions: Add cell, Run all, Clear outputs
- Confirmation dialog for Run All
- Keyboard shortcuts (all except Cmd+/)
- Auto-save with debounce
- Footer with connection status and stats
- Theme Toggle: System/Light/Dark mode preference
- Result Display Controls: Show/Hide results per cell or all

**Security Features (Phase 6 - Partial):**
- SSL/TLS connection modes (all 6 PostgreSQL modes)
- Smart cloud database detection
- Connection retry logic with exponential backoff
- Certificate verification fix for `.require` mode
- Row limit enforcement (1-200 rows)
- Query modification detection
- Primary key tracking for UPDATE operations
- Value format validation (integer, uuid, jsonb, date, timestamp)
- Boolean toggle UI for value editing
- Toast notifications for user feedback

**Advanced UI Features:**
- **Left Sidebar:** Database schema tree view with click-to-insert
- **Right Sidebar:** Connection form, Settings, JSON viewer, Cell info with inline editing
- **Toast Notifications:** Auto-dismissing notifications with hover support
- **Inline Editing:** Edit result cell values directly, execute UPDATE queries

### In Progress / TODO ⏳

**Phase 4 Remaining:**
- Cell execution queue system
- Drag and drop reordering
- Comment/uncomment (Cmd+/)
- Result table search & filter
- Save prompt on close
- File optimization for large files
- Logging system

**Phase 6 Remaining:**
- Keychain storage for passwords (SECURITY PRIORITY)
- Connection timeout configuration
- Confirmation dialogs for destructive operations
- Read-only mode
- Transaction support for inline edits

**Phase 7 Remaining:**
- Integration tests for database operations
- UI workflow tests

**Phase 5 (Advanced Features - Not Started):**
- Query history
- Export to CSV
- Multiple database support (SQLite, MySQL)
- Query autocomplete
- Tabs support for multiple connections
- AI-powered natural language queries (local model)
- Schema visualizer

**Phase 8 (Editor Mode - Not Started):**
- Traditional SQL editor mode with single editor
- Run selection functionality
- Mode switching UI

---

## 📚 Common Development Tasks

### Adding a New Feature
1. Update data model in `Models/` (ensure `Sendable` + `nonisolated init`)
2. Add ViewModel methods in appropriate `NotebookViewModel+*.swift` extension
3. Create/update Views in `Views/` (extract reusable components to `Views/Components/`)
4. Add tests in `SQLNotebookTests/` for new logic
5. Format with `swift-format` before committing

### Debugging Database Issues
- Check `DatabaseConnectionManager` logs (uses `Logging` framework)
- Verify Docker container: `docker compose -f docker/postgresql/docker-compose.test.yml ps`
- Test manual queries: `docker exec postgres-sqlnotebook psql -U postgres`

### Modifying Cell Execution
All execution logic in `NotebookViewModel+Execution.swift`:
- `runCell(_:)` — executes single cell
- `runAllCells()` — executes all cells sequentially
- `cancelCell(_:)` — stops running cell (cancellation token support TBD)

---

## 🔑 Key Files Worth Understanding

- [DatabaseConnectionManager.swift](../SQLNotebook/Database/DatabaseConnectionManager.swift) — Actor managing all DB operations
- [NotebookViewModel.swift](../SQLNotebook/ViewModels/NotebookViewModel.swift) — State management core
- [DesignSystem.swift](../SQLNotebook/Utilities/DesignSystem.swift) — UI token definitions
- [project.md](./project.md) — Full technical specification
- [TODO.md](./TODO.md) — Task breakdown and verification

---

## ⚠️ Important Gotchas

- **Password Security**: Connection passwords NEVER saved in `.sqlnb` files; must use Keychain (TODO)
- **Result Limits**: Default max rows = 50 (configurable 1-200). Prevents memory spikes on large queries
- **MainActor Dispatch**: When updating UI from background tasks, wrap in `Task { @MainActor in ... }`
- **Sidebar Enum**: Right sidebar content is a single-value enum; only one view shown at a time
- **Document State**: UndoManager tracks changes; changes sync to disk automatically (debounced)
- **Row Identification**: PostgreSQL uses `ctid` (physical row ID), SQLite uses `rowid` for inline editing
- **Primary Key Detection**: Currently hardcoded to false in schema loading (TODO: fix in Phase 6)

---

## 📦 Dependencies

### Swift Package Manager
- **PostgresNIO**: Async PostgreSQL client (imported in `DatabaseConnectionManager`)
- **SwiftUI**: Latest (Observable macro, not ObservableObject)
- **Logging**: Standard Swift logging framework
- **Codable**: For `.sqlnb` file serialization

---

## 🏁 Definition of Done

Each task is complete when:
1. Feature is implemented according to specifications
2. Code follows Swift/SwiftUI best practices
3. Relevant tests are written and passing
4. Feature works in both light and dark mode
5. No compiler warnings or runtime errors
6. Code is reviewed and committed
