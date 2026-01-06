# Gemini Guide for SQLNotebook

**Common Documentation:** See [docs/AI_GUIDE.md](docs/AI_GUIDE.md) for complete project overview, architecture, and development guidelines.

---

## Gemini-Specific Instructions

This document provides Gemini-specific guidance for working with the SQLNotebook codebase.

---

## Project Quick Overview

**SQLNotebook** is a native macOS application for writing and executing SQL queries in a cell-based interface, similar to Jupyter Notebook. It supports PostgreSQL and SQLite, offering persistent query results and a rich user interface built with SwiftUI.

**Key Technologies:**
- **Language:** Swift 6.0+
- **UI Framework:** SwiftUI
- **Architecture:** MVVM (Model-View-ViewModel) with `@Observable`
- **Database:** PostgresNIO (SwiftNIO based driver)
- **Persistence:** Codable structs serialized to JSON (`.sqlnb` files)
- **Target Platform:** macOS 16.0+

---

## Key Files & Structure

**Entry Point:**
- `SQLNotebookApp.swift` — The main entry point of the application

**Database Layer:**
- `Database/DatabaseConnectionManager.swift` — An actor responsible for managing database connections (PostgreSQL via PostgresNIO) and executing queries
- Handles connection lifecycle, SSL/TLS, and type mapping

**Data Models:**
- `Models/NotebookCell.swift` — Defines the data model for a single notebook cell (`NotebookCell`), including its type (SQL/Markdown), content, and execution results (`CellResult`)
- `Models/SQLNotebookDocument.swift` — Manages the document-based application logic for `.sqlnb` files
- `Models/ConnectionConfig.swift` — Database connection configuration
- `Models/SQLNotebook.swift` — Main notebook model

**ViewModels:**
- `ViewModels/NotebookViewModel.swift` — The main ViewModel driving the notebook UI
- `ViewModels/NotebookViewModel+Connection.swift` — Database connection logic
- `ViewModels/NotebookViewModel+Execution.swift` — Query execution logic
- `ViewModels/NotebookViewModel+CellManagement.swift` — Cell CRUD operations
- `ViewModels/NotebookViewModel+Sidebar.swift` — Sidebar state management

**Views:**
- `Views/ContentView.swift` — Main view container
- `Views/Components/CellView.swift` — Individual cell rendering
- `Views/Components/ResultTableView.swift` — Query result table
- `Views/Sidebars/LeftSidebarView.swift` — Database schema browser
- `Views/Sidebars/RightSidebarView.swift` — Connection/settings/JSON viewer sidebar

---

## Development Requirements

**System Requirements:**
- macOS 16.0+
- Xcode 16.0+
- Swift 6.0+

**Building & Running:**
1. Open `SQLNotebook.xcodeproj` in Xcode
2. Wait for Swift Package Manager to resolve dependencies (e.g., `PostgresNIO`)
3. Build and Run (Cmd+R)

---

## Code Conventions

**Concurrency:**
- Heavy usage of Swift Concurrency (`async`/`await`, `actor` for database management)
- All database operations are asynchronous
- `@MainActor` is used for ViewModels to ensure UI updates happen on the main thread

**UI:**
- SwiftUI views using `@Observable` objects for state (not `ObservableObject`)
- MVVM architecture with clear separation of concerns

**Error Handling:**
- Custom `DatabaseError` enum for standardized error reporting in database operations
- Proper error propagation with `try`/`catch` blocks

**Type Safety:**
- Strong typing for SQL results using `CellValue` enum to handle various database types:
  - `String`, `Int`, `Double`, `Bool`, `null`, `json`, `date`, `data`

---

## Important Implementation Details

**Database Connection:**
- Actor-based `DatabaseConnectionManager` for thread-safe operations
- SSL/TLS support with 6 different PostgreSQL modes
- Connection retry logic with exponential backoff
- Smart cloud database detection (Supabase, AWS, Azure, GCP)

**Query Execution:**
- SELECT queries return result sets with column metadata
- INSERT/UPDATE/DELETE return affected row counts
- Row limit enforcement (configurable 1-200 rows) to prevent memory issues
- Query modification detection for safety

**UI Features:**
- Cell-based interface with SQL syntax highlighting
- Collapsible left sidebar for database schema browsing
- Collapsible right sidebar for connection details, settings, JSON viewer, and cell info
- Inline result editing with UPDATE query execution
- Toast notifications for user feedback
- Theme support: System/Light/Dark mode

**Persistence:**
- Document-based app using SwiftUI's `DocumentGroup`
- `.sqlnb` files are JSON format with Codable serialization
- Auto-save with debouncing
- Undo/Redo support via `UndoManager`

**Security:**
- ⚠️ **TODO:** Passwords should be stored in Keychain (currently in document files - NOT SECURE)
- SSL/TLS support for secure connections
- Value format validation before UPDATE queries

---

## Testing

**Test Targets:**
- `SQLNotebookTests` — Unit tests for data models, syntax highlighting, ViewModels
- `SQLNotebookUITests` — UI tests for critical user flows

**Running Tests:**
```bash
# All tests
xcodebuild test -scheme SQLNotebook

# Specific test class
xcodebuild test -scheme SQLNotebook -only-testing SQLNotebookTests/DataModelTests
```

**Docker Test Database:**
- PostgreSQL test database in `docker/postgresql/`
- Run: `cd docker/postgresql && docker compose up -d`

---

## Current Status

**Completed:**
- ✅ Core notebook functionality (Phases 1-3)
- ✅ Most polish features (Phase 4): keyboard shortcuts, auto-save, theme toggle, result controls
- ✅ Partial security features (Phase 6): SSL/TLS, connection retry, value validation, inline editing

**In Progress:**
- ⏳ Phase 4 remaining: Cell execution queue, drag-and-drop, comment/uncomment, result search/filter
- ⏳ Phase 6 remaining: Keychain password storage, connection timeout, confirmation dialogs, read-only mode
- ⏳ Phase 7: Integration tests and UI tests

**Not Started:**
- Phase 5: Advanced features (query history, CSV export, multiple DB support, autocomplete, tabs, AI queries, schema visualizer)
- Phase 8: Editor mode (traditional SQL editor with single panel)

---

## Quick Reference Links

- 📖 [Complete AI Guide](docs/AI_GUIDE.md) — Full documentation for all AI assistants
- 📋 [Project Spec](docs/project.md) — Detailed technical specifications
- ✅ [TODO](docs/TODO.md) — Task breakdown and verification