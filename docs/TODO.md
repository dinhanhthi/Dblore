# TODO.md - SQL Notebook Implementation Tasks

## Current Status Overview

- ✅ **Phase 1: Core Structure** - COMPLETE
- ✅ **Phase 2: Cell Editor** - COMPLETE
- ✅ **Phase 3: Database Integration** - COMPLETE
- ✅ **Phase 4: Polish** - COMPLETE (14 of 14 sections - All subsections now complete including Global Search 4.14)
- 🟡 **Phase 5: Advanced Features** - PARTIAL (5.4 Autocomplete complete; 5.6-5.8 pending)
- ✅ **Phase 6: Security & Safety** - COMPLETE (6.0.2, 6.0.3, 6.0.4 all implemented; 6.0.5-6.0.6 future)
- 🟡 **Phase 7: Testing Suite** - MOSTLY COMPLETE (CI/CD setup done, integration tests partial)
- ✅ **Phase 8: Editor Mode** - COMPLETE (8.1-8.5 complete including Run Selection; 8.6-8.8 future enhancements)
- 🟡 **Phase 10: Performance Optimization** - PENDING (see [TODO_OPTIMIZE.md](TODO_OPTIMIZE.md))

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

## Phase 8: Editor Mode (COMPLETE ✅)

A traditional SQL editor mode with single editor and result panel below.

### 8.1 Core Editor Mode Implementation - COMPLETE ✅
- [x] Add `ViewMode` enum (`.notebook`, `.editor`) - [ViewMode.swift](SQLNotebook/Models/ViewMode.swift)
- [x] Create `EditorModeView` component - [EditorModeView.swift](SQLNotebook/Views/EditorModeView.swift)
- [x] Single SQL editor with syntax highlighting - SQLEditorView in EditorModeView.swift:22-29
- [x] Single result panel below editor - ResultTableView in EditorModeView.swift:43-48

### 8.2 Execution Features - COMPLETE ✅
- [x] Implement "Run Query" functionality - runEditorQuery() in NotebookViewModel+EditorMode.swift:28-46
- [x] Add execution buttons - Run button with Cmd+Shift+Enter shortcut
- [x] Implement "Run Selection" functionality - getEditorQueryText() in NotebookViewModel+EditorMode.swift:12-25 (returns selected text if any, otherwise full content)
- [ ] Implement "Run All" functionality - Future enhancement

### 8.3 Mode Switching UI - COMPLETE ✅
- [x] Add mode toggle button in header - HeaderView.swift:101-127 (Notebook/Editor buttons)
- [x] Add keyboard shortcut to toggle mode - toggleViewMode() in NotebookViewModel+EditorMode.swift:87-106
- [x] Persist view mode preference - viewMode property in NotebookViewModel.swift:93 (persisted via AppSettings)

### 8.4 Sidebar Integration, Data Conversion & Testing - COMPLETE ✅
- [x] Preserve sidebars in editor mode - Both left and right sidebars visible in editor mode
- [x] Handle data conversion between modes - Smart content transfer in toggleViewMode() (NotebookViewModel+EditorMode.swift:87-106)
- [x] Support keyboard shortcuts - Cmd+Shift+Enter to run in editor mode

### 8.5 Result Display & Error Handling - COMPLETE ✅
- [x] Display result table for SELECT queries - ResultTableView integration (EditorModeView.swift:43-48)
- [x] Display error messages - errorView() function (EditorModeView.swift:164-180)
- [x] Show row count and execution time - resultPanelHeader() (EditorModeView.swift:120-162)
- [x] Affected rows display for modification queries - Dynamic display in NotebookViewModel+EditorMode.swift:69-72
- [x] Toast notifications for success/error - showToast() calls in executeEditorQuery() (NotebookViewModel+EditorMode.swift:68-83)

### 8.6 Export Results - PENDING
- [ ] Implement "Export to CSV" for result tables

### 8.7 Multiple Database Support - PENDING
- [ ] Abstract database connection interface
- [ ] Add SQLite support
- [ ] Add MySQL support (optional)

### 8.8 Executed Query Viewer - PENDING
- [ ] Add button next to execution metadata ("30 rows • 0.01s")
  - [ ] Add button in EditorModeView.resultPanelHeader (line 91-133)
  - [ ] Add button in ResultMetadataView for notebook mode (CellResultViews.swift:158-187)
  - [ ] Use icon "doc.text" or "chevron.right.square"
- [ ] Create ExecutedQuerySidebarContent view component
  - [ ] Display query with syntax highlighting
  - [ ] Add copy button
  - [ ] Reuse ExecutedQueryDisplayView component
- [ ] Add `.executedQuery(query: String, cellId: UUID?)` case to SidebarContent enum
- [ ] Wire up button action to show query in right sidebar
  - [ ] Set `viewModel.rightSidebarContent = .executedQuery(...)`
  - [ ] Set `viewModel.isRightSidebarVisible = true`
- [ ] Support both Editor mode and Notebook mode

**Note:** Infrastructure is 70% ready:
- ✅ sourceQuery field exists in CellResult model
- ✅ ExecutedQueryDisplayView component exists
- ✅ Right sidebar system exists
- ❌ Button not implemented
- ❌ SidebarContent case not added
- ❌ Sidebar view component not created

**Effort:** LOW-MEDIUM (2-3 hours)

---

## Phase 9: Schema Visualizer (PENDING)
- [ ] Query foreign key relationships
- [ ] Build relationship graph
- [ ] Create visual graph component
- [ ] Implement pan and zoom functionality

## Code-Level TODOs Found

Items marked as `// TODO:` or `// FIXME:` in the codebase (verified 2026-01-22):

### Active Code TODOs (3 items found)

1. **Future JSON Value Update** - LOW PRIORITY (Future Enhancement)
   - [NotebookViewModel+Sidebar.swift:181](SQLNotebook/ViewModels/NotebookViewModel+Sidebar.swift#L181)
   - Currently only copies JSON edits to clipboard
   - In the future could update actual database value
   - Status: Low priority, user feedback suggests clipboard copy is sufficient

2. **Keychain Storage for Passwords** - SECURITY ISSUE (Future Enhancement)
   - [DataModelTests.swift:304](SQLNotebookTests/DataModelTests.swift#L304)
   - Passwords should not be stored in .sqlnb JSON files
   - Should use Keychain for secure storage (macOS Keychain API)
   - Status: Part of Phase 6 Security (deferred to future)
   - Effort: LOW - macOS Keychain integration

3. **Integration Tests Schema Loading** - TESTING (Blocked)
   - [DatabaseIntegrationTests.swift:284](SQLNotebookTests/DatabaseIntegrationTests.swift#L284)
   - Note: "Add schema loading tests when public API is available"
   - Status: Waiting for public API availability

### Completed Code TODOs (Verified 2026-01-22)

**Editor Mode: Run Selection** - COMPLETE ✅
   - [NotebookViewModel+EditorMode.swift:12-25](SQLNotebook/ViewModels/NotebookViewModel+EditorMode.swift#L12)
   - Implementation: getEditorQueryText() returns selected text if any, otherwise full content
   - runEditorQuery() calls getEditorQueryText() to support both selection and full query execution
   - Status: VERIFIED COMPLETE

**User Notifications for Value Editing** - COMPLETE ✅
   - [NotebookViewModel+Sidebar.swift:156](SQLNotebook/ViewModels/NotebookViewModel+Sidebar.swift#L156) - JSON edit validation alert
   - [NotebookViewModel+Sidebar.swift:168](SQLNotebook/ViewModels/NotebookViewModel+Sidebar.swift#L168) - JSON edit success toast
   - Implementation: ToastView.swift with success/error/info/warning types
   - Status: VERIFIED COMPLETE - Part of Phase 6.0.4

**Schema Primary Key Detection** - COMPLETE ✅
   - [DatabaseConnectionManager+Schema.swift:202-250](SQLNotebook/Database/DatabaseConnectionManager+Schema.swift#L202)
   - Implementation: fetchPrimaryKeyColumns() queries pg_index and pg_attribute system catalogs
   - Called in fetchColumns() to set isPrimaryKey correctly for each column
   - Status: VERIFIED COMPLETE

---

## Recent Completions (Major Features)

### Phase 8: Editor Mode ✅ (Verified Jan 22, 2026)
- ViewMode enum with .notebook and .editor cases
- EditorModeView component with VSplitView layout (editor top, results bottom)
- Single SQL editor with syntax highlighting and autocomplete
- Result panel showing table/error with row count and execution time
- Toolbar with Run button (Cmd+Shift+Enter), connection status
- **Run Selection fully implemented** - getEditorQueryText() in NotebookViewModel+EditorMode.swift:12-25
- Mode toggle in header (Notebook/Editor buttons with visual indicators)
- Smart content transfer between modes (preserves cell content when switching)
- Error display with selectable error messages
- Toast notifications for success/error feedback
- Affected rows display for INSERT/UPDATE/DELETE queries
- Sidebar integration (both left schema sidebar and right details sidebar visible)
- Tested with read-only connections and destructive query confirmation

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

### CURRENT: Phase 7 Integration Tests & Phase 8 Enhancements (HIGH PRIORITY)

**Phase 8 Editor Mode is COMPLETE ✅** - Core functionality (8.1-8.5) including Run Selection is fully implemented.

**Immediate Next Steps (in priority order):**

1. **Phase 7 Integration Tests** (Medium Effort - HIGH PRIORITY)
   - [x] Test infrastructure complete (Docker, CI/CD)
   - [ ] DatabaseConnectionManager connection tests
   - [ ] Query execution tests (SELECT, INSERT/UPDATE/DELETE)
   - [ ] Schema loading tests (blocked on public API availability)
   - [ ] Type mapping tests (JSON/JSONB, DATE, TIMESTAMP)
   - [ ] Document operations tests (round-trip serialization)
   - [ ] Editor mode functional tests
   - Effort: MEDIUM (tests mostly structured, need database setup in CI)

2. **Phase 8.8 Executed Query Viewer** (Low Effort - NICE TO HAVE)
   - [ ] Add button next to execution metadata ("30 rows • 0.01s")
   - [ ] Create ExecutedQuerySidebarContent view component
   - [ ] Add `.executedQuery` case to SidebarContent enum
   - [ ] Wire up button to show query in right sidebar
   - Effort: LOW-MEDIUM (infrastructure 70% ready, 2-3 hours)

3. **Phase 8.6 Export to CSV** (Medium Effort - NICE TO HAVE)
   - [ ] Implement CSV export from ResultTableView
   - [ ] Add "Export" button to result panel header
   - [ ] Handle special characters, quoted fields
   - [ ] Save to file with date-stamped name
   - Effort: LOW-MEDIUM (basic CSV formatting)

### FUTURE: Phase 5 Advanced Features & Phase 8.7 Multiple Databases (NICE TO HAVE)

1. **Multi-SQL Command Execution (5.8)** - Feature Request
   - Execute multiple SQL commands separated by semicolons or line breaks
   - Display result of LAST query in table view
   - Previous commands (CREATE, INSERT, UPDATE, DELETE) execute silently
   - Show execution status for each command
   - Similar behavior to pgAdmin/DBeaver editors
   - Effort: MEDIUM (requires query parsing, sequential execution, multi-result storage)

2. **Schema Visualizer (5.7)** - Nice to Have
   - Query foreign key relationships, build relationship graph
   - Visual graph component with pan and zoom
   - Effort: LARGE (requires graph layout algorithm)

3. **Multiple Database Support (8.7)** - Future Enhancement
   - Abstract database connection interface
   - Add SQLite support
   - Add MySQL support (optional)
   - Effort: LARGE (requires adapter pattern, testing per DB)

4. **Future Security Enhancements**
   - Keychain storage for passwords (low effort, deferred)
   - Query audit trail (6.0.5) - future enhancement
   - User security education (6.0.6) - future enhancement

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

**Date:** 2026-01-22
**Git HEAD:** main branch (a031fae - fix(notebook): line number height)
**Recent Commits:**
- a031fae: fix(notebook): line number height isn't reflexible to the change of window size
- 54cea72: feat: toggle word-wrap for the query editor
- f0d8aa5: feat: both options create new notebook/sql file are added to File menu
- 62c1dac: fix: cannot type double quotes as normal in json format for cell value editor
- 8fdc947: doc: update TODO & TODO_OPTIMIZE

**Verification Summary:**

### Verified Complete (Jan 22, 2026)
- ✅ Phase 1-4: Core structure, cell editor, database integration, polish (27,000+ lines)
- ✅ Phase 5.4: Query autocomplete with 95+ SQL keywords and context awareness
- ✅ Phase 6: Security & safety features (timeout, retry, TLS, confirmation, read-only, validation)
- ✅ Phase 8: Editor Mode - COMPLETE
  - 8.1 Core implementation: complete (306 lines)
  - 8.2 Execution features: **Run Query & Run Selection BOTH complete** ✅
  - 8.3 Mode switching: complete
  - 8.4 Sidebar integration: complete
  - 8.5 Result display: complete
  - 8.6 Export CSV: pending (future enhancement)
  - 8.7 Multiple databases: pending (future enhancement)
  - 8.8 Executed Query Viewer: pending (infrastructure 70% ready)
- 🟡 Phase 7: Mostly complete (test infrastructure ready, integration tests partial)

### Key Verified Files (Phase 8 Editor Mode)
- [ViewMode.swift](SQLNotebook/Models/ViewMode.swift) - AppMode enum with .notebook and .editor cases
- [EditorModeView.swift](SQLNotebook/Views/EditorModeView.swift) - UI component (306 lines)
- [NotebookViewModel+EditorMode.swift](SQLNotebook/ViewModels/NotebookViewModel+EditorMode.swift) - Business logic (93 lines)
  - **getEditorQueryText():12-25** - Returns selected text if any, otherwise full content
  - **runEditorQuery():28-46** - Executes query (selection or full)
- [ContentView.swift](SQLNotebook/ContentView.swift) - mainContent property with mode switching
- [HeaderView.swift](SQLNotebook/Views/HeaderView.swift) - Mode toggle buttons (lines 101-127)

### Code-Level Findings (2026-01-22)
- Found 3 active TODOs in codebase:
  - NotebookViewModel+Sidebar.swift:181 - Future JSON DB update (low priority)
  - DataModelTests.swift:304 - Keychain storage (deferred security enhancement)
  - DatabaseIntegrationTests.swift:284 - Schema loading tests (blocked on public API)
- **COMPLETED since last verification:**
  - ✅ Run Selection - Fully implemented in NotebookViewModel+EditorMode.swift:12-25
  - ✅ Primary Key Detection - Implemented in DatabaseConnectionManager+Schema.swift:202-250

**Phase Status Summary (2026-01-22):**
- ✅ Phase 1-4: Complete (~27,000 lines of implementation)
- 🟡 Phase 5: Partial (5.4 complete; 5.6-5.8 pending)
- ✅ Phase 6: Complete (6.0.2, 6.0.3, 6.0.4; 6.0.5-6.0.6 future)
- 🟡 Phase 7: Partial (infrastructure complete; integration tests need work)
- ✅ Phase 8: Complete (8.1-8.5 all complete including Run Selection; 8.6-8.8 future enhancements)

**Recommended Next Actions:**
1. **HIGH PRIORITY:** Complete Phase 7 Integration Tests (medium effort)
   - DatabaseConnectionManager connection tests
   - Query execution tests (SELECT, INSERT/UPDATE/DELETE)
   - Type mapping tests (JSON/JSONB, DATE, TIMESTAMP)

2. **NICE TO HAVE:** Phase 8.8 Executed Query Viewer (low-medium effort)
   - Button wiring (infrastructure 70% ready)
   - ExecutedQuerySidebarContent view component

3. **NICE TO HAVE:** Phase 8.6 CSV Export (low-medium effort)

4. **FUTURE:** Phase 5 Advanced Features (multi-SQL, schema visualizer, AI query)

5. **OPTIMIZATION:** See [TODO_OPTIMIZE.md](TODO_OPTIMIZE.md) for Phase 10 Performance Optimization tasks