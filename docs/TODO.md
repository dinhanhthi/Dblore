# TODO.md - SQL Notebook Implementation Tasks

## Current Status Overview

- ✅ **Phase 1: Core Structure** - COMPLETE
- ✅ **Phase 2: Cell Editor** - COMPLETE
- ✅ **Phase 3: Database Integration** - COMPLETE
- ⏳ **Phase 4: Polish** - MOSTLY COMPLETE (10 of 13 sections - Theme Toggle now complete)
- ⏳ **Phase 5: Advanced Features** - NOT STARTED
- 🔒 **Phase 6: Security & Safety** - PARTIAL (Some key features complete, some in-progress)
- ✅ **Phase 7: Testing Suite** - MOSTLY COMPLETE (CI/CD setup done, test coverage partial)
- 🎯 **Phase 8: Editor Mode** - NOT STARTED (Last phase)

---

## Phase 4: Polish (MOSTLY COMPLETE - 10 of 13 sections)

### 4.2 Header Actions - PARTIAL
- [x] Wire up "+ Code" button
- [x] Implement "Run All" functionality
- [x] Implement "Clear All Outputs"
- [x] Button icons using SF Symbols
- [x] Add confirmation dialog for Run All
- [ ] **Implement cell execution queue system**
  - [ ] Queue management for multiple cells
  - [ ] Visual indicator for queued cells
  - [ ] Queue state for cells
  - [ ] Queue position indicator
  - [ ] Add individual cells to queue
  - [ ] Cancel queued cells

### 4.4 Drag and Drop - NOT STARTED
- [ ] Add drag handle to cell left sidebar
- [ ] Implement `onMove` modifier for cell reordering
- [ ] Add visual feedback during drag
- [ ] Update cell order in notebook model

### 4.6 Global Keyboard Shortcuts - PARTIAL
- [x] All basic shortcuts implemented (`Cmd+N`, `Cmd+O`, `Cmd+S`, `Cmd+Shift+Enter`, etc.)
- [x] Settings panel with keyboard shortcuts
- [ ] `Cmd+/` for comment/uncomment SQL line

### 4.7 Auto-save & Document State - PARTIAL
- [x] Implement auto-save on changes (debounced)
- [x] Track document dirty state
- [x] Show unsaved indicator in footer
- [ ] Prompt to save on close if unsaved

### 4.8 Result Display Controls - NOT STARTED
- [ ] Add show/hide toggle button in cell sidebar
- [ ] Implement collapse/expand animation
- [ ] Persist result visibility state per cell
- [ ] Visual indicator (chevron icon) for collapsed state

### 4.11 File Optimization - NOT STARTED
- [ ] Detect large file size (> 10MB)
- [ ] Implement compression option
- [ ] Add option to remove old results automatically
- [ ] Use compact JSON format for large files
- [ ] Add file size indicator in footer

### 4.12 Logging System - NOT STARTED
- [ ] Create `AppLogger` utility class
- [ ] Replace `print()` statements with logging calls
- [ ] Add log levels (debug, info, warning, error)
- [ ] Implement log capture and export system

### 4.13 Theme Toggle (Dark/Light Mode) - COMPLETE
- [x] Add theme preference to `AppSettings` (ThemePreference enum with System/Light/Dark options)
- [x] Store theme preference in UserDefaults (AppSettings.swift:42-86)
- [x] Update `DesignSystem.swift` for light/dark modes (color system supports both schemes)
- [x] Create light mode color variants (SwiftUI .light/.dark ColorScheme support)
- [x] Use `@Environment(\.colorScheme)` for dynamic colors via AppearanceModifier
- [x] Add theme toggle control to Settings panel (SettingsContent.swift:14-51 with radio buttons)

---

## Phase 5: Advanced Features (NOT STARTED)

### 5.1 Query History
- [ ] Store executed queries with timestamps
- [ ] Create query history view/panel
- [ ] Allow re-running queries from history

### 5.2 Export Results
- [ ] Implement "Export to CSV" for result tables
- [ ] Add export button to result metadata bar

### 5.3 Multiple Database Support
- [ ] Abstract database connection interface
- [ ] Add SQLite support
- [ ] Add MySQL support (optional)

### 5.4 Query Autocomplete (Optional)
- [ ] Implement autocomplete popup for table/column names
- [ ] Implement SQL keyword autocomplete

### 5.5 Tabs Support - Multiple Database Connections
- [ ] Create tab management system
- [ ] Implement tab bar UI component
- [ ] Add "New Tab" button
- [ ] Handle tab switching and persistence
- [ ] Add keyboard shortcuts: `Cmd+T`, `Cmd+W`, `Cmd+1-9`

### 5.6 AI-Powered Natural Language Query (Local Model Only)
- [ ] Select local LLM framework
- [ ] Integrate local model into app
- [ ] Implement prompt engineering for natural language → SQL
- [ ] Create UI component for AI query input

### 5.7 Schema Visualizer
- [ ] Query foreign key relationships
- [ ] Build relationship graph
- [ ] Create visual graph component
- [ ] Implement pan and zoom functionality

---

## Phase 6: Security & Safety Features (PARTIAL)

### 6.0.2 Connection Security - PARTIAL
- [x] Support SSL/TLS connection modes (all 6 PostgreSQL modes)
- [x] Smart cloud database detection
- [ ] Fix certificate verification for `.require` mode
- [ ] Add connection timeout configuration
- [ ] Add connection retry logic with exponential backoff

### 6.0.3 Query Execution Security - PARTIAL
- [x] Enforce row limits to prevent memory exhaustion
- [x] Detect modification queries
- [ ] Add confirmation dialogs for destructive operations
- [ ] Add read-only mode option
- [ ] Add transaction management

### 6.0.4 Data Modification Safety - MOSTLY COMPLETE
- [x] Use primary key columns for UPDATE WHERE clause
- [x] Use ctid (PostgreSQL) for row identification
- [x] Boolean toggle UI for value editing ✅
- [ ] **Value Format Validation** - Validate integer, uuid, jsonb, date, timestamp types
  - [ ] Check modified value format matches cell type when in edit mode
  - [ ] Display validation error/warning in footer sidebar
  - [ ] Disable "save" button when validation fails
- [ ] Add confirmation for inline cell editing
- [ ] Add transaction support for inline edits

### 6.0.5 & 6.0.6 Audit & User Education - NOT STARTED
- [ ] Query execution logging and audit trail
- [ ] Security warnings and tips in UI
- [ ] Connection security indicator

---

## Phase 7: Testing Suite (MOSTLY COMPLETE)

### Test Infrastructure - MOSTLY COMPLETE
- [x] Unit Test target setup
- [x] UI Test target setup
- [x] GitHub Actions CI/CD workflow configured
- [x] Docker PostgreSQL test database setup
- [x] Test database initialization script
- [x] CI/CD workflow for automated testing

### Unit Tests - MOSTLY COMPLETE
- [x] Data model serialization tests (`SQLNotebook`, `NotebookCell`, `CellValue`, etc.)
- [x] SQL syntax highlighter tests
- [x] ViewModel logic tests
- [ ] Document operations tests (round-trip)
- [ ] `CellResult` and `DatabaseSchema` model tests

### Integration Tests - PARTIAL
- [ ] `DatabaseConnectionManager` connection tests
- [ ] Query execution tests (SELECT, INSERT/UPDATE/DELETE)
- [ ] Schema loading tests
- [ ] Type mapping tests (JSON/JSONB, DATE, TIMESTAMP)

### UI Tests - NOT STARTED
- [ ] Basic workflow tests (create, open, save notebook)
- [ ] Query execution flow tests
- [ ] Connection flow tests
- [ ] Document persistence tests

---

## Phase 8: Editor Mode (NOT STARTED - LAST PHASE)

A traditional SQL editor mode with single editor and result panel below.

### 8.1 Core Editor Mode Implementation
- [ ] Add `ViewMode` enum (`.notebook`, `.editor`)
- [ ] Create `EditorModeView` component
- [ ] Single SQL editor with syntax highlighting
- [ ] Single result panel below editor

### 8.2 Execution Features
- [ ] Implement "Run Selection" functionality
- [ ] Implement "Run All" functionality
- [ ] Add execution buttons

### 8.3 Mode Switching UI
- [ ] Add mode toggle button in header
- [ ] Add keyboard shortcut to toggle mode
- [ ] Persist view mode preference

### 8.4-8.6 Sidebar Integration, Data Conversion & Testing
- [ ] Preserve sidebars in editor mode
- [ ] Handle data conversion between modes
- [ ] Test mode switching and keyboard shortcuts

---

## Code-Level TODOs Found

Items marked as `// TODO:` or `// NOTE:` in the codebase that should be tracked:

### To Implement
1. **Keychain Storage for Passwords** (`DataModelTests.swift:301`)
   - Passwords should not be stored in .sqlnb JSON files
   - Should use Keychain for secure storage

2. **Schema Primary Key Detection** (`DatabaseConnectionManager+Schema.swift:101`)
   - Currently sets primary keys to false
   - Should detect primary keys from database constraints

3. **User Notifications for Value Editing** (`NotebookViewModel+Sidebar.swift:157, 169, 287, 290`)
   - Show alert when cell value editing succeeds
   - Show error alert when cell value editing fails
   - Show success notification after value update

4. **CommandTag from PostgresNIO** (`DatabaseConnectionManager+QueryExecution.swift:39, 350`)
   - Waiting for PostgresNIO to expose commandTag via onMetadata callback
   - Currently not exposed in version 1.30.1

---

## Recent Completions

### Boolean Toggle UI for Value Editing ✅ (Phase 6.0.4)
Toggle slider for boolean value editing in right sidebar. User clicks toggle instead of typing "true"/"false". Implemented in [CellInfoContent.swift](SQLNotebook/Views/Sidebars/CellInfoContent.swift).

### Left Sidebar - Database Structure ✅
Tree view showing database tables, columns, row counts, and primary keys. Click to insert table/column names into editor. Auto-loads schema on connection.

### SSL Connection Enhancement ✅
Connection string input mode with auto-parsing. Smart cloud database detection (Supabase, AWS, Azure, GCP). SSL mode picker and fixed certificate verification.

---

## Next Priorities

### CURRENT: Complete Phase 4 Polish (Medium Effort)
Priority UI enhancements (5 of 6 remaining):

1. **Result Show/Hide (4.8)** - Collapse/expand results per cell
2. **Comment/Uncomment (4.6)** - `Cmd+/` shortcut
3. **Drag and Drop (4.4)** - Reorder cells
4. **Save Prompt (4.7)** - Warn before closing unsaved
5. **Cell Execution Queue (4.2)** - Visual queue for batch execution

### COMPLETED: Phase 4.13 Theme Toggle
- Dark/Light/System mode preference now fully implemented and working

### THEN: Complete Phase 6 Security (High Priority)
1. **Value Format Validation (6.0.4)** - Validate integer, uuid, jsonb, etc.
2. **Confirmation Dialogs (6.0.3)** - Warn before DELETE/UPDATE
3. **Read-Only Mode** - Prevent accidental modifications
4. **Connection Retry Logic (6.0.2)** - Exponential backoff

### THEN: Phase 7 Integration Tests & Phase 8 Editor Mode
Complete test coverage and implement the final editor mode phase.

### LATER: Phase 5 Advanced Features
Schema visualizer, AI queries, tabs, query history, export to CSV, multiple DB support.

---

## Verification Report (Latest Scan)

**Date:** 2026-01-03
**Verified By:** Claude Code - TODO Manager Agent
**Key Change:** Phase 4.13 Theme Toggle confirmed complete

### Verified Complete Features

**Phase 1-3 (Core Structure, Cell Editor, Database Integration)**
- Cell-based SQL editor with syntax highlighting
- Database connection management for PostgreSQL
- SQL query execution with result table display
- Schema browser in left sidebar
- Connection management UI
- Auto-save with debounce
- Undo/redo support

**Phase 4 Completed Tasks**
- Header actions: "+ Code", "Run All", "Clear All Outputs" with icons
- Confirmation dialog for "Run All"
- Global keyboard shortcuts: Cmd+Enter, Shift+Enter, Option+Enter, Cmd+Shift+Enter, Cmd+D, Cmd+Delete, Cmd+B, Cmd+Shift+R
- Settings panel with keyboard shortcut reference
- Auto-save functionality (tracks unsaved state with `lastSaved` indicator)
- Footer showing connection status, version, and save time
- Theme Toggle: System/Light/Dark mode preference with NSAppearance application

**Phase 6 Completed Tasks**
- SSL/TLS connection modes (all 6 PostgreSQL modes supported)
- Smart cloud database detection (Supabase, AWS, Azure, GCP)
- Row limit enforcement to prevent memory exhaustion
- Query modification detection (SELECT vs UPDATE/DELETE/INSERT)
- Primary key column tracking for UPDATE operations
- PostgreSQL ctid row identification
- Boolean toggle UI for value editing
- Database schema loading with column info

**Phase 7 Completed Tasks**
- Unit test infrastructure
- UI test infrastructure
- GitHub Actions CI/CD workflow
- Docker PostgreSQL test database setup
- Data model serialization tests
- SQL syntax highlighter tests
- ViewModel logic tests

### Verified Incomplete Features

**Phase 4 - Not Started/In Progress**
- Cell execution queue system: Not implemented
- Drag and drop reordering: Not implemented
- Comment/uncomment (Cmd+/): Not implemented
- Result show/hide toggle: Not implemented
- Save on close prompt: Not implemented
- File optimization (compression, large file handling): Not implemented
- Logging system (AppLogger): Not implemented

**Phase 6 - Incomplete**
- Value format validation: Not implemented
- Confirmation dialogs for destructive operations: Not implemented
- Read-only mode: Not implemented
- Connection retry logic: Not implemented
- Certificate verification fix for `.require` mode: Not completed
- Connection timeout configuration: Not implemented

**Phase 7 - Incomplete**
- Document operations tests (round-trip): Not implemented
- CellResult and DatabaseSchema model tests: Not implemented
- DatabaseConnectionManager connection tests: Not implemented
- Query execution integration tests: Not implemented
- Schema loading tests: Not implemented
- Type mapping tests: Not implemented
- UI workflow tests: Not implemented

**Phase 8 - Not Started**
- Editor mode (non-notebook SQL editor view): Not started

### Key Implementation Details Verified

- Swift 6 concurrency with async/await
- @Observable macro for state management (not ObservableObject)
- Actor-based DatabaseConnectionManager for thread safety
- AppSettings for global preferences stored in UserDefaults
- Left sidebar: Database schema tree view
- Right sidebar: Connection details, settings, JSON viewer, cell info
- Cell execution: Individual cell run or run all
- Value editing: Boolean toggle, text editing for other types
- Results: Paginated display with row limit enforcement
- Syntax highlighting: SQL and JSON support
- Dark mode: Forced app-wide (`.preferredColorScheme(.dark)`)

### Architecture Observations

- Layout: Header → Main (left sidebar + center content + right sidebar) → Footer
- Result display: Integrated below each cell with full result table
- Connection management: Form-based UI with connection testing
- Error handling: Inline error display below cells
- Notifications: Toast notifications for user feedback
- File format: .sqlnb files as JSON (Codable-based)

---

## Definition of Done

Each task is complete when:
1. Feature is implemented according to specifications
2. Code follows Swift/SwiftUI best practices
3. Relevant tests are written and passing
4. Feature works in both light and dark mode
5. No compiler warnings or runtime errors
6. Code is reviewed and committed
