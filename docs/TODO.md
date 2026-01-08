# TODO.md - SQL Notebook Implementation Tasks

## Current Status Overview

- ✅ **Phase 1: Core Structure** - COMPLETE
- ✅ **Phase 2: Cell Editor** - COMPLETE
- ✅ **Phase 3: Database Integration** - COMPLETE
- ✅ **Phase 4: Polish** - COMPLETE (14 of 14 sections - All subsections now complete including Global Search 4.14)
- ⏳ **Phase 5: Advanced Features** - NOT STARTED
- ✅ **Phase 6: Security & Safety** - MOSTLY COMPLETE (6.0.2 Connection Security complete; 6.0.3 & 6.0.4 partial)
- ✅ **Phase 7: Testing Suite** - MOSTLY COMPLETE (CI/CD setup done, test coverage partial)
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

## Phase 5: Advanced Features (NOT STARTED)

### 5.4 Query Autocomplete (Optional)
- [x] Implement autocomplete popup for table/column names
- [x] Implement SQL keyword autocomplete

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

## Phase 6: Security & Safety Features (PARTIAL)

### 6.0.2 Connection Security - COMPLETE
- [x] Support SSL/TLS connection modes (all 6 PostgreSQL modes)
- [x] Smart cloud database detection
- [x] **Add connection retry logic with exponential backoff** ✅
  - [x] Retry configuration: maxRetries = 3, delays = [1s, 2s, 4s] (DatabaseConnectionManager.swift:22-24)
  - [x] Implemented attemptConnection() helper method with recursive retry logic (DatabaseConnectionManager.swift:33-67)
  - [x] Updated connect() method to use retry logic (DatabaseConnectionManager.swift:111)
  - [x] Updated testConnection() method to use retry logic (DatabaseConnectionManager.swift:161)
- [x] **Fix certificate verification for `.require` mode** ✅
  - [x] Created configureTLS(for:) helper method to centralize TLS configuration (DatabaseConnectionManager.swift:205-249)
  - [x] Replaced all `try!` force unwraps with proper error handling using do-catch blocks
  - [x] Fixed `.require` mode to use full certificate verification (removed `.none` security vulnerability)
  - [x] Updated connect() and testConnection() methods to use new TLS configuration (DatabaseConnectionManager.swift:81-90, 124-131)
  - [x] Added proper cleanup (shutdown event loop group) on TLS configuration failures
  - [x] Documented self-signed certificate handling (use `.allow`/`.prefer` or add CA to system trust store)
- [x] **Add connection timeout configuration** ✅
  - [x] Added timeoutSeconds: Int property to ConnectionConfig model (default: 30 seconds) (ConnectionConfig.swift:28, 39)
  - [x] Created withTimeout<T: Sendable>() helper function using TaskGroup for timeout logic (DatabaseConnectionManager.swift:23-47)
  - [x] Updated attemptConnection() to wrap PostgresConnection.connect() with timeout (DatabaseConnectionManager.swift:79-113)
  - [x] Added timeout field to ConnectionFormContent UI (text field for timeout in seconds) (ConnectionFormContent.swift:255-263)
  - [x] Updated test connection configs to include timeoutSeconds parameter (DatabaseIntegrationTests.swift:34, DataModelTests.swift)
  - [x] When timeout occurs, throws DatabaseError.connectionFailed with clear message "Connection timeout after X seconds" (DatabaseConnectionManager.swift:99)

### 6.0.3 Query Execution Security - PARTIAL
- [x] Enforce row limits to prevent memory exhaustion
- [x] Detect modification queries
- [x] **Add confirmation dialogs for destructive operations** ✅
  - [x] Added `isModificationQuery()` method to detect UPDATE/DELETE/INSERT queries (NotebookViewModel.swift:177-180)
  - [x] Added confirmation dialog state: `showQueryConfirmationDialog`, `pendingQueryCellId`, `pendingQuery` (NotebookViewModel.swift:87-90)
  - [x] Implemented `confirmAndRunCell()` to show dialog for modification queries (NotebookViewModel.swift:183-199)
  - [x] Implemented `executePendingQuery()` to execute after confirmation (NotebookViewModel.swift:202-209)
  - [x] Implemented `cancelPendingQuery()` to cancel execution (NotebookViewModel.swift:212-216)
  - [x] Added confirmation dialog UI in ContentView (ContentView.swift:147-171)
  - [x] Updated all run cell actions to use `confirmAndRunCell()` (ContentView.swift:303-307, 586-608)
  - [x] Added 11 unit tests for query confirmation functionality (ViewModelTests.swift:434-599)
- [ ] Add read-only mode option
- [ ] Add transaction management

### 6.0.4 Data Modification Safety - MOSTLY COMPLETE
- [x] Use primary key columns for UPDATE WHERE clause
- [x] Use ctid (PostgreSQL) for row identification
- [x] Boolean toggle UI for value editing ✅
- [x] User Notifications for Value Editing ✅ - JSON edit validation alerts, database update feedback toast alerts
- [x] **Value Format Validation** ✅ - Validate integer, uuid, jsonb, date, timestamp types
  - [x] Check modified value format matches cell type when in edit mode (CellValueValidator.swift, CellInfoContent.swift:288)
  - [x] Display validation error/warning in UI (CellInfoContent.swift:159-171)
  - [x] Disable "save" button when validation fails (CellInfoContent.swift:77)
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

### CURRENT: Complete Phase 6 Security (High Priority)
Security and data safety enhancements:

1. **Connection Timeout Configuration (6.0.2)** - COMPLETE ✅
   - [x] Add timeout parameter to ConnectionConfig
   - [x] Implement timeout in attemptConnection() with TaskGroup timeout logic
   - [x] Add timeout UI field in connection form
   - Status: VERIFIED COMPLETE - Timeout configuration fully implemented with proper error handling

2. **Confirmation Dialogs (6.0.3)** - COMPLETE ✅
   - [x] Modal dialog showing query before execution
   - [x] Warn users of destructive operations (UPDATE/DELETE/INSERT)
   - [x] Detect modification queries automatically
   - [x] Execute non-destructive queries (SELECT) directly
   - Effort: MEDIUM (UI + state management)
   - Status: COMPLETE - Confirmation dialog fully implemented with comprehensive test coverage (11 unit tests)

3. **Read-Only Mode (6.0.3)** - Prevent accidental modifications (NEXT TASK)
   - [ ] Add read-only toggle in connection settings
   - [ ] Disable edit/delete functionality in read-only mode
   - Effort: MEDIUM (requires permission checks across views)
   - Status: NOT STARTED - No readOnly/isReadOnly property found in ConnectionConfig

### RECENTLY COMPLETED PHASE 6.0.4 ITEMS:
- Boolean toggle UI for value editing
- User Notifications (Toast alerts for JSON edit, database update, clipboard copy)
- Value Format Validation (CellValueValidator.swift with full type validation, error display, and save button disable)

### THEN: Complete Phase 4 Polish (Medium Effort)
Priority UI enhancements (5 of 7 remaining):

1. **Result Table Search & Filter (4.9)** - NEW FEATURE REQUEST
   - Add toolbar with search input to ResultTableView
   - Global search across all columns
   - Column-specific filter dropdowns
   - Filter rows based on column values
   - Show filtered vs total row count
   - Effort: MEDIUM (requires filtering logic and UI components)

2. **Comment/Uncomment (4.6)** - `Cmd+/` shortcut
3. **Drag and Drop (4.4)** - Reorder cells via UI
4. **Save Prompt (4.7)** - Warn before closing unsaved
5. **Cell Execution Queue (4.2)** - Visual queue for batch execution

### THEN: Phase 7 Integration Tests & Phase 8 Editor Mode
Complete test coverage and implement the final editor mode phase.

### LATER: Phase 5 Advanced Features
- **Multi-SQL Command Execution (5.8)** - NEW FEATURE REQUEST
  - Execute multiple SQL commands in single cell separated by semicolons or line breaks
  - Display result of LAST query only in table view
  - Previous commands (CREATE, INSERT, UPDATE, DELETE) execute silently
  - Show execution status for each command
  - Similar behavior to pgAdmin/DBeaver editors
  - Effort: MEDIUM (requires query parsing, sequential execution, multi-result storage)
- **Tabs Support (5.5)** - Multiple notebooks with separate connections (NEW FEATURE REQUEST)
  - Each tab = separate notebook document
  - Each tab = separate database connection
  - Tab management UI with keyboard shortcuts
  - Effort: LARGE (requires major architecture changes to support multiple notebooks/connections)
- Schema visualizer, AI queries, query history, export to CSV, multiple DB support.

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
**Git HEAD:** main branch (e495bd7)
**Recent Commits:**
- 2582087: perf: optimize search algo
- 930afd7: feat: add search feature
- 036c841: feat: app log system
- e495bd7: doc: update README

**Phase Status:**
- ✅ Phase 1-3: Core complete
- ✅ Phase 4: Polish complete (14/14)
- ⏳ Phase 5: Advanced features (autocomplete done, tabs/multi-SQL pending)
- ⚠️ Phase 6: Security partial (timeout done, dialogs/read-only pending)
- ⚠️ Phase 7: Testing partial (CI/CD done, integration tests pending)
- 🎯 Phase 8: Editor mode not started

**Recommended Next Actions:**
1. Confirmation dialogs for destructive operations (6.0.3)
2. Read-only mode (6.0.3)
3. Result table search & filter (4.9 enhancement)