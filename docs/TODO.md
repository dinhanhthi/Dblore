# TODO.md - SQL Notebook Implementation Tasks

## Current Status Overview

- ✅ **Phase 1: Core Structure** - COMPLETE
- ✅ **Phase 2: Cell Editor** - COMPLETE
- ✅ **Phase 3: Database Integration** - COMPLETE
- ⏳ **Phase 4: Polish** - MOSTLY COMPLETE (11 of 14 sections - Result Display, Theme Toggle, Search & Filter added)
- ⏳ **Phase 5: Advanced Features** - NOT STARTED
- 🔒 **Phase 6: Security & Safety** - MOSTLY COMPLETE (6.0.4 Data Modification Safety complete including Value Format Validation)
- ✅ **Phase 7: Testing Suite** - MOSTLY COMPLETE (CI/CD setup done, test coverage partial)
- 🎯 **Phase 8: Editor Mode** - NOT STARTED (Last phase)

---

## Phase 4: Polish (MOSTLY COMPLETE - 11 of 13 sections)

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

### 4.8 Result Display Controls - COMPLETE
- [x] Add show/hide toggle button in cell sidebar
- [x] Implement collapse/expand animation
- [x] Persist result visibility state per cell (isResultVisible in NotebookCell.swift)
- [x] Visual indicator (chevron icon) for collapsed state
- [x] Header menu: "Show All Results" and "Hide All Results" buttons
- [x] View model methods: toggleResultVisibility, hideAllResults, showAllResults

### 4.9 Result Table Search & Filter - NOT STARTED
- [ ] Add toolbar to ResultTableView with search input field
- [ ] Implement global search across all columns (search in all cell values)
- [ ] Add column-specific filter dropdowns for each column header
- [ ] Filter rows based on column value matches
- [ ] Show filtered row count vs total row count
- [ ] Clear search/filter button

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

## Phase 4: Polish (MOSTLY COMPLETE - 11 of 13 sections)

**Note:** Section 4.9 (Result Table Search & Filter) added as new feature request.

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

### 8.4-8.6 Sidebar Integration, Data Conversion & Testing
- [ ] Preserve sidebars in editor mode
- [ ] Handle data conversion between modes
- [ ] Test mode switching and keyboard shortcuts

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

## Recent Completions

### User Notifications for Value Editing ✅ (Phase 6.0.4) - NEWLY VERIFIED
Toast notifications for JSON edit validation (error), JSON edit success, database update success/error, and clipboard copy (info). Implemented with ToastView.swift (ToastMessage enum), NotebookViewModel.showToast() method with 4-second auto-dismiss timer. Shows in bottom-right with colored icons (checkmark=success, xmark=error, info=info circle) and borders.

### Boolean Toggle UI for Value Editing ✅ (Phase 6.0.4)
Toggle slider for boolean value editing in right sidebar. User clicks toggle instead of typing "true"/"false". Implemented in [CellInfoContent.swift](SQLNotebook/Views/Sidebars/CellInfoContent.swift).

### Left Sidebar - Database Structure ✅
Tree view showing database tables, columns, row counts, and primary keys. Click to insert table/column names into editor. Auto-loads schema on connection.

### SSL Connection Enhancement ✅
Connection string input mode with auto-parsing. Smart cloud database detection (Supabase, AWS, Azure, GCP). SSL mode picker and fixed certificate verification.

---

## Next Priorities

### CURRENT: Complete Phase 6 Security (High Priority)
Security and data safety enhancements (completing Phase 6.0.4):

1. **Confirmation Dialogs (6.0.3)** - Add confirmation before DELETE/UPDATE/INSERT
   - Modal dialog showing query and row count affected
   - Warn users of destructive operations
   - Effort: MEDIUM (UI + state management)

3. **Read-Only Mode (6.0.3)** - Prevent accidental modifications
   - Add read-only toggle in connection settings
   - Disable edit/delete functionality in read-only mode
   - Effort: MEDIUM (requires permission checks across views)

4. **Connection Retry Logic (6.0.2)** - Exponential backoff for failed connections
   - Auto-retry with delays (1s, 2s, 4s, 8s, 16s max)
   - User notification on retry attempts
   - Effort: SMALL (connection manager enhancement)

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
Schema visualizer, AI queries, tabs, query history, export to CSV, multiple DB support.

---

## Verification Report (Latest Scan)

**Date:** 2026-01-04
**Verified By:** Claude Code - TODO Manager Agent
**Key Changes:**
- ✅ **Phase 6.0.4 Value Format Validation VERIFIED COMPLETE**
  - CellValueValidator.swift implements full validation for all types (int, double, json, date, boolean, null, binary data)
  - Integrated in CellInfoContent.swift:288 with `CellValueValidator.validate(input, for: value)`
  - Validation error displayed in UI (CellInfoContent.swift:159-171) with red border and error message
  - Save button disabled when validation fails (CellInfoContent.swift:77)
  - Status updated from incomplete to COMPLETE ✅

- ✅ Phase 6.0.4 User Notifications remains COMPLETE (ToastView.swift, NotebookViewModel.showToast())
- ✅ Phase 4.8 Result Display Controls confirmed COMPLETE (isResultVisible property, menu buttons)
- ✅ Phase 4.13 Theme Toggle remains COMPLETE

- 📝 **NEW FEATURE REQUEST ADDED: Phase 4.9 Result Table Search & Filter**
  - User requested: toolbar with search feature and column-based filters for ResultTableView
  - Added to Phase 4 Polish section
  - Status: NOT STARTED
  - Requirements: global search, column filters, filtered row count display

- ❌ Verified incomplete items remain accurate:
  - Cmd+/ comment/uncomment: Not implemented
  - Drag and drop: Not implemented (only column resize drag exists)
  - Save on close prompt: Not implemented
  - Cell execution queue: Not implemented (runAllCells is sequential, no queue UI)
  - Confirmation dialogs for destructive operations: Not implemented
  - Read-only mode: Not implemented

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
- Theme Toggle: System/Light/Dark mode preference (AppSettings.swift:82-86, AppearanceModifier.swift)
- Result Display Controls: isResultVisible property in NotebookCell, Show/Hide All menu buttons (HeaderView.swift:59-70), toggle/show/hide methods in NotebookViewModel+CellManagement.swift

**Phase 6 Completed Tasks**
- SSL/TLS connection modes (all 6 PostgreSQL modes supported)
- Smart cloud database detection (Supabase, AWS, Azure, GCP)
- Row limit enforcement to prevent memory exhaustion
- Query modification detection (SELECT vs UPDATE/DELETE/INSERT)
- Primary key column tracking for UPDATE operations
- PostgreSQL ctid row identification
- Boolean toggle UI for value editing (CellInfoContent.swift)
- User Notifications for Value Editing (ToastView.swift with error/success/info types)
- Database schema loading with column info
- Toast notification system: JSON edit validation alerts, database update feedback (ToastMessage enum, NotebookViewModel.showToast() method)
- Value Format Validation (CellValueValidator.swift with validation for integer, double, json, date, boolean, null, binary data types; integrated in CellInfoContent.swift:288 with error display and save button disable)

**Phase 7 Completed Tasks**
- Unit test infrastructure
- UI test infrastructure
- GitHub Actions CI/CD workflow
- Docker PostgreSQL test database setup
- Data model serialization tests
- SQL syntax highlighter tests
- ViewModel logic tests

### Verified Incomplete Features

**Phase 4 - Not Started/In Progress** (5 of 7 remaining)
- Result Table Search & Filter (4.9): Not implemented (new feature request)
- Drag and drop reordering: Not implemented (moveCell exists but no UI for drag handles)
- Comment/uncomment (Cmd+/): Not implemented
- Save on close prompt: Not implemented
- Cell execution queue system: Not implemented (no visual queue UI)
- File optimization (compression, large file handling): Not implemented
- Logging system (AppLogger): Not implemented

**Phase 6 - Incomplete**
- Confirmation dialogs for destructive operations: Not implemented
- Read-only mode: Not implemented
- Connection retry logic: Not implemented
- Certificate verification fix for `.require` mode: Not completed
- Connection timeout configuration: Not implemented
- Confirmation for inline cell editing: Not implemented
- Transaction support for inline edits: Not implemented

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
