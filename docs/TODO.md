# TODO.md - SQL Notebook Implementation Tasks

## Current Status Overview

- ✅ **Phase 1: Core Structure** - COMPLETE
- ✅ **Phase 2: Cell Editor** - COMPLETE
- ✅ **Phase 3: Database Integration** - COMPLETE
- ✅ **Phase 4: Polish** - COMPLETE (14 of 14 sections - All subsections now complete including Global Search 4.14)
- 🟡 **Phase 5: Advanced Features** - PARTIAL (5.4 Autocomplete complete; 5.6-5.8 pending)
- ✅ **Phase 6: Security & Safety** - COMPLETE (6.0.2, 6.0.3, 6.0.4 all implemented; 6.0.5-6.0.6 future)
- 🟡 **Phase 7: Testing Suite** - MOSTLY COMPLETE (CI/CD setup done, integration tests partial)
- 🎯 **Phase 8: Editor Mode** - NOT STARTED (Last phase)

---

## Phase 4: Polish (COMPLETE ✅)

**Summary:** UI polish, keyboard shortcuts, theme system, search functionality, and file optimization.

**Key Features Implemented:**
- Header actions (Run All, Clear Outputs, Add Cell) with confirmation dialogs
- Drag & drop cell reordering with visual feedback
- Global keyboard shortcuts (Cmd+Enter, Cmd+S, Cmd+D, etc.)
- Auto-save with debounce and document dirty state tracking
- Result display controls (show/hide per cell or all cells)
- File optimization system (size monitoring, compact JSON, manual cleanup)
- Logging system (AppLogger with OSLog, export functionality, thread-safe)
- Theme toggle (System/Light/Dark mode with DesignSystem color variants)
- Global search (Cmd+F, floating panel, cross-cell search, match highlighting, navigation)

**Implementation Details:**
- 14 of 14 subsections complete
- Search: Async with TaskGroup, LRU cache, debounced input (300ms)
- File optimization: 5MB/10MB thresholds, automatic compact format
- Logging: Actor-based AppLogger, daily log rotation, Settings export
- Theme: AppSettings persistence, AppearanceModifier, radio button UI

**Note:** Section 4.9 (Result Table Search & Filter) remains as future enhancement.

## Phase 5: Advanced Features (PARTIAL - Autocomplete Complete)

### 5.4 Query Autocomplete - COMPLETE ✅
- [x] Implement autocomplete popup for table/column names
  - [SQLAutocompleteProvider.swift](SQLNotebook/Utilities/SQLAutocompleteProvider.swift) - AutocompleteSuggestion with table/column type support
  - [AutocompletePopupView.swift](SQLNotebook/Views/Components/AutocompletePopupView.swift) - UI component for suggestions
  - Context-aware suggestions: tables after FROM/JOIN, columns after SELECT/WHERE
- [x] Implement SQL keyword autocomplete
  - 95+ SQL keywords database (DML, DDL, DCL, window functions, CTEs)
  - Keyboard navigation (Up/Down, Enter to select)
  - Dynamic filtering based on user input
  - Integration with schema for table/column suggestions

### 5.7 Schema Visualizer
- [ ] Query foreign key relationships
- [ ] Build relationship graph
- [ ] Create visual graph component
- [ ] Implement pan and zoom functionality

### 5.8 Multi-SQL Command Execution
- [ ] Allow multiple SQL commands in single cell editor
  - [ ] Support semicolon (`;`) as command separator
  - [ ] Support line breaks as optional separators
  - [ ] Similar behavior to pgAdmin/DBeaver editors
- [ ] Execute all commands in sequence
  - [ ] Run all commands in order (first to last)
  - [ ] Catch errors and continue with remaining commands
  - [ ] Collect execution results for each command
- [ ] Result Display
  - [ ] Display result of LAST query only in table view
  - [ ] Previous commands (CREATE, INSERT, UPDATE, DELETE) execute silently
  - [ ] Show execution status for all commands (success/error)
  - [ ] Store individual results for each command internally
- [ ] UI/UX
  - [ ] Add visual separator in editor showing command boundaries
  - [ ] Show command count indicator (e.g., "3 commands")
  - [ ] Display execution order in cell header
  - [ ] Show which command's result is being displayed
- [ ] Error Handling
  - [ ] If a command fails, continue with remaining commands
  - [ ] Show error message for failed commands
  - [ ] Allow selective re-execution of failed commands

### 5.6 AI-Powered Natural Language Query (Local Model Only)
- [ ] Select local LLM framework
- [ ] Integrate local model into app
- [ ] Implement prompt engineering for natural language → SQL
- [ ] Create UI component for AI query input

---

## Phase 6: Security & Safety Features (COMPLETE FOR 6.0.2, 6.0.3, 6.0.4)

### 6.0.2 Connection Security - COMPLETE ✅
- [x] Support SSL/TLS connection modes (all 6 PostgreSQL modes)
- [x] Smart cloud database detection
- [x] **Add connection retry logic with exponential backoff** ✅
  - [x] Retry configuration: maxRetries = 3, delays = [1s, 2s, 4s]
  - [x] Implemented attemptConnection() helper method with recursive retry logic
  - [x] Updated connect() and testConnection() methods to use retry logic
- [x] **Fix certificate verification for `.require` mode** ✅
  - [x] Created configureTLS(for:) helper method to centralize TLS configuration
  - [x] Replaced all force unwraps with proper error handling using do-catch blocks
  - [x] Fixed `.require` mode to use full certificate verification
  - [x] Added proper cleanup on TLS configuration failures
  - [x] Documented self-signed certificate handling
- [x] **Add connection timeout configuration** ✅
  - [x] Added timeoutSeconds: Int property to ConnectionConfig model (default: 30 seconds)
  - [x] Implemented withTimeout<T: Sendable>() helper function using TaskGroup
  - [x] Updated attemptConnection() to wrap PostgresConnection.connect() with timeout
  - [x] Added timeout field to ConnectionFormContent UI
  - [x] Throws DatabaseError.connectionFailed with "Connection timeout after X seconds" message

### 6.0.3 Query Execution Security - COMPLETE ✅
- [x] Enforce row limits to prevent memory exhaustion
- [x] Detect modification queries via isModificationQuery() method
- [x] **Add confirmation dialogs for destructive operations** ✅
  - [x] showQueryConfirmationDialog, pendingQueryCellId, pendingQuery state (NotebookViewModel.swift:88-90)
  - [x] confirmAndRunCell() method to trigger dialog for modification queries (NotebookViewModel.swift:183-208)
  - [x] executePendingQuery() and cancelPendingQuery() methods (NotebookViewModel.swift:219-232)
  - [x] Confirmation dialog UI in ContentView with styled alert
  - [x] All run cell actions updated to use confirmAndRunCell()
  - [x] 11 unit tests for query confirmation functionality
- [x] **Add read-only mode option** ✅
  - [x] readOnly property in ConnectionConfig model (ConnectionConfig.swift:29, 41)
  - [x] Read-only toggle UI in connection form (both Form and Connection String modes)
  - [x] Block modification queries in read-only mode (NotebookViewModel.swift:188-194)
  - [x] Disable inline cell value editing in read-only mode
  - [x] Visual indicator in connection details sidebar
  - [x] 8 unit tests for read-only mode functionality
- [ ] Add transaction management (Future enhancement)

### 6.0.4 Data Modification Safety - COMPLETE ✅
- [x] Use primary key columns for UPDATE WHERE clause
- [x] Use ctid (PostgreSQL) for row identification
- [x] Boolean toggle UI for value editing ✅
- [x] User Notifications for Value Editing ✅
  - [x] JSON edit validation alerts
  - [x] Database update feedback toast alerts
  - [x] Clipboard copy info toast
- [x] **Value Format Validation** ✅
  - [x] CellValueValidator.swift with type validation (integer, uuid, jsonb, date, timestamp)
  - [x] Validation error/warning display in UI
  - [x] Save button disabled when validation fails
- [ ] Add confirmation for inline cell editing (Future enhancement)
- [ ] Add transaction support for inline edits (Future enhancement)

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

### 8.4 Sidebar Integration, Data Conversion & Testing
- [ ] Preserve sidebars in editor mode
- [ ] Handle data conversion between modes
- [ ] Test mode switching and keyboard shortcuts

### 8.6 Export Results
- [ ] Implement "Export to CSV" for result tables

### 8.7 Multiple Database Support
- [ ] Abstract database connection interface
- [ ] Add SQLite support
- [ ] Add MySQL support (optional)

---

## Code-Level TODOs Found

Items marked as `// TODO:` or `// FIXME:` in the codebase:

### Active Code TODOs (5 items found)

1. **User Notifications for Value Editing** - COMPLETE ✅
   - [NotebookViewModel+Sidebar.swift:156](SQLNotebook/ViewModels/NotebookViewModel+Sidebar.swift#L156) - JSON edit validation alert (error)
   - [NotebookViewModel+Sidebar.swift:168](SQLNotebook/ViewModels/NotebookViewModel+Sidebar.swift#L168) - JSON edit success toast
   - [NotebookViewModel+Sidebar.swift:283-286](SQLNotebook/ViewModels/NotebookViewModel+Sidebar.swift#L283) - Cell value update success toast
   - [NotebookViewModel+Sidebar.swift:294-296](SQLNotebook/ViewModels/NotebookViewModel+Sidebar.swift#L294) - Cell value update error toast
   - [NotebookViewModel+Sidebar.swift:302](SQLNotebook/ViewModels/NotebookViewModel+Sidebar.swift#L302) - Clipboard copy info toast
   - Implementation Details: ToastView.swift (ToastMessage with success/error/info/warning types), NotebookViewModel.showToast() method with auto-dismiss timer
   - Status: VERIFIED COMPLETE - Part of Phase 6.0.4 validation and user feedback

2. **Future JSON Value Update** - LOW PRIORITY
   - `NotebookViewModel+Sidebar.swift:169` - In the future, update actual database with JSON edits
   - Status: Currently only copies to clipboard

3. **Keychain Storage for Passwords** - SECURITY ISSUE
   - `DataModelTests.swift:301`
   - Passwords should not be stored in .sqlnb JSON files
   - Should use Keychain for secure storage
   - Status: Part of Phase 6 Security

4. **Schema Primary Key Detection** - DATA ACCURACY
   - `DatabaseConnectionManager+Schema.swift:101`
   - Currently sets primary keys to false
   - Should detect primary keys from database constraints
   - Status: Related to Phase 6.0.4 row identification

---

## Recent Completions (Major Features)

### Phase 4.14 Global Search ✅
- Cmd+F keyboard shortcut opens floating search panel
- Searches SQL content, table results, error messages across all cells
- Match highlighting with navigation (Up/Down), match counter ("3 of 15")
- Async search with TaskGroup, LRU cache (max 100 items)
- Debounced input (300ms), case-sensitive toggle

### Phase 4.12 Logging System ✅
- Actor-based AppLogger with OSLog integration
- Log levels (debug, info, warning, error)
- Daily log rotation, export via Settings > Developer
- Replaces print() statements across 7 key files

### Phase 4.11 File Optimization ✅
- File size monitoring with color-coded warnings (5MB/10MB thresholds)
- Automatic compact JSON format for large files (~20-30% reduction)
- Manual cleanup button, "New Cell" disabled when size exceeded

### Phase 5.4 Query Autocomplete ✅
- SQL keyword database (95+ keywords: DML, DDL, DCL, window functions, CTEs)
- Context-aware suggestions (tables after FROM/JOIN, columns after SELECT/WHERE)
- Keyboard navigation (Up/Down, Enter to select)
- Schema integration for dynamic table/column suggestions

### Phase 6.0.2 Connection Security ✅
- SSL/TLS support (all 6 PostgreSQL modes)
- Connection retry with exponential backoff (1s, 2s, 4s delays)
- Connection timeout configuration (default 30s)
- Certificate verification fix for `.require` mode

### Phase 6.0.4 Data Modification Safety ✅
- Value format validation (integer, uuid, jsonb, date, timestamp)
- Boolean toggle UI for editing
- Toast notifications (JSON edit, database updates, clipboard)
- Primary key and ctid row identification

---

## Next Priorities

### CURRENT: Phase 7 Integration Tests & Phase 8 Editor Mode (High Priority)

**Phase 6 Security is COMPLETE ✅** - All major security features (timeout, confirmation dialogs, read-only mode, value validation) are fully implemented and tested.

**Next Focus:**
1. **Phase 7 Integration Tests** (Medium Effort)
   - [ ] DatabaseConnectionManager connection tests
   - [ ] Query execution tests (SELECT, INSERT/UPDATE/DELETE)
   - [ ] Schema loading tests
   - [ ] Type mapping tests (JSON/JSONB, DATE, TIMESTAMP)
   - [ ] Document operations tests (round-trip serialization)
   - [ ] UI Tests for basic workflow, query execution, connection flow

2. **Phase 8 Editor Mode** (Large Effort - Last Phase)
   - [ ] Add ViewMode enum (.notebook, .editor)
   - [ ] Create EditorModeView component
   - [ ] Single SQL editor with syntax highlighting
   - [ ] Result panel below editor
   - [ ] Run Selection and Run All functionality
   - [ ] Mode toggle button in header with keyboard shortcut
   - [ ] Data conversion between modes
   - [ ] Export to CSV functionality
   - [ ] Multiple database support (SQLite, MySQL optional)

### THEN: Phase 5 Advanced Features (Medium Effort - Nice to Have)

1. **Multi-SQL Command Execution (5.8)** - NEW FEATURE REQUEST
   - Execute multiple SQL commands separated by semicolons or line breaks
   - Display result of LAST query in table view
   - Previous commands (CREATE, INSERT, UPDATE, DELETE) execute silently
   - Show execution status for each command
   - Similar behavior to pgAdmin/DBeaver editors
   - Effort: MEDIUM (requires query parsing, sequential execution, multi-result storage)

2. **Schema Visualizer (5.7)**
   - Query foreign key relationships, build relationship graph
   - Visual graph component with pan and zoom

3. **Optional Advanced Features**
   - AI-Powered Natural Language Query (5.6) - requires local LLM framework
   - Result Table Search & Filter (4.9) - add toolbar to ResultTableView

---


---

## Definition of Done

Each task is complete when:
1. Feature is implemented according to specifications
2. Code follows Swift/SwiftUI best practices
3. Relevant tests are written and passing
4. Feature works in both light and dark mode
5. No compiler warnings or runtime errors
6. Code is reviewed and committed

---

## Latest Verification Report

**Date:** 2026-01-08
**Git HEAD:** main branch (f950e59)
**Recent Commits:**
- f950e59: chore
- 5dc6266: feat: read-only mode connection
- 779f424: chore: add icon to the setting headings
- f302d86: test: fix warnings in tests
- cd18868: feat: add confirmation for destructive queries

**Verification Summary:**

### Verified Complete (Jan 8, 2026)
- ✅ Phase 1-4: Core structure, cell editor, database integration, polish
- ✅ Phase 5.4: Query autocomplete (SQLAutocompleteProvider.swift with 95+ keywords)
- ✅ Phase 6.0.2: Connection security (timeout: ConnectionConfig.swift:28,40; retry logic; TLS verification)
- ✅ Phase 6.0.3: Query execution security
  - Confirmation dialogs: NotebookViewModel.swift:88-90, 183-232; ContentView.swift confirmation UI
  - Read-only mode: ConnectionConfig.swift:29,41; isModificationQuery() check; UI disable in edit mode
- ✅ Phase 6.0.4: Data modification safety (CellValueValidator.swift; boolean toggle; toast notifications)

### Verified Files
- [ConnectionConfig.swift](SQLNotebook/Models/ConnectionConfig.swift) - timeoutSeconds, readOnly properties
- [NotebookViewModel.swift](SQLNotebook/ViewModels/NotebookViewModel.swift) - isModificationQuery(), confirmAndRunCell(), readOnly check
- [DatabaseConnectionManager.swift](SQLNotebook/Database/DatabaseConnectionManager.swift) - withTimeout(), attemptConnection()
- [SQLAutocompleteProvider.swift](SQLNotebook/Utilities/SQLAutocompleteProvider.swift) - 95+ SQL keywords
- [CellValueValidator.swift](SQLNotebook/Utilities/CellValueValidator.swift) - Type validation
- [ViewModelTests.swift](SQLNotebookTests/ViewModelTests.swift) - 11 confirmation tests, 8 read-only tests

**Phase Status Summary:**
- ✅ Phase 1-4: Complete (27,000+ lines implemented)
- ✅ Phase 5.4: Complete (query autocomplete)
- ✅ Phase 6: Complete (security & safety for 6.0.2, 6.0.3, 6.0.4)
- 🟡 Phase 7: Partial (unit tests complete, integration tests pending)
- 🎯 Phase 8: Not started (editor mode)

**Recommended Next Actions:**
1. **HIGH PRIORITY:** Complete Phase 7 integration tests (database connection, query execution, schema loading)
2. **THEN:** Implement Phase 8 Editor Mode (alternative single-editor view)
3. **NICE TO HAVE:** Phase 5 advanced features (multi-SQL commands, tabs, schema visualizer)