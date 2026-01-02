# TODO.md - SQL Notebook Implementation Tasks

## Current Status

- ✅ **Phase 1: Core Structure** - COMPLETE (All 1.1-1.4 items done)
- ✅ **Phase 2: Cell Editor** - COMPLETE (All 2.1-2.4 items done)
- ✅ **Phase 3: Database Integration** - COMPLETE (All 3.1-3.5 items done)
- ⏳ **Phase 4: Polish** - MOSTLY COMPLETE (9 of 13 sections complete, 4 pending)
- ⏳ **Phase 5: Advanced Features** - NOT STARTED
- 🔒 **Phase 6: Security & Safety** - PARTIAL (1 complete, 6 in progress/not started)
- ✅ **Phase 7: Testing Suite** - MOSTLY COMPLETE (4 complete: 7.1, 7.2, 7.3, 7.13 with CI/CD; rest partial/not started)
- 🎯 **Phase 8: Editor Mode** - NOT STARTED (LAST PHASE)

---

## Phase 1: Core Structure ✅

### 1.1 Project Setup
- [x] Create new macOS app project in Xcode
- [x] Set minimum deployment target to macOS 14.0
- [x] Configure app as document-based application
- [x] Add PostgresNIO package dependency
- [x] Define custom UTType for `.sqlnb` files

### 1.2 Data Models
- [x] Implement `SQLNotebook` struct
- [x] Implement `NotebookCell` struct
- [x] Implement `CellType` enum
- [x] Implement `CellResult` struct
- [x] Implement `ColumnInfo` struct
- [x] Implement `CellValue` enum
- [x] Implement `ConnectionConfig` struct
- [x] Implement `NotebookMetadata` struct
- [x] Write unit tests for model serialization

### 1.3 Document Architecture
- [x] Implement `SQLNotebookDocument` with `FileDocument`
- [x] Implement `read` and `write` methods
- [x] Register `.sqlnb` file type
- [x] Test document creation, saving, and loading

### 1.4 Basic Layout
- [x] Create `ContentView` with main layout
- [x] Implement `HeaderView`
- [x] Implement `MainContentView` with ScrollView
- [x] Implement `FooterView`
- [x] Implement `RightSidebarView`

---

## Phase 2: Cell Editor ✅

### 2.1 Cell List Management
- [x] Implement `NotebookViewModel` with `@Observable`
- [x] Implement `addCell()` method
- [x] Implement `deleteCell()` method
- [x] Implement `moveCell()` method
- [x] Cell selection state management
- [x] LazyVStack for cell rendering

### 2.2 Cell View Component
- [x] Create `CellView` component
- [x] Play button with different states
- [x] Execution count display
- [x] Cell selection border styling
- [x] Cell hover states

### 2.3 SQL Editor
- [x] Create `SQLEditorView` using TextEditor
- [x] Implement `SQLSyntaxHighlighter`
- [x] Keyword lists (DDL, DML, functions, types)
- [x] Tokenizer for SQL syntax
- [x] AttributedString styling for tokens
- [x] Monospace font (SF Mono)
- [x] Auto-expanding height

### 2.4 Cell Keyboard Navigation
- [x] `Cmd+Enter` to run cell
- [x] `Shift+Enter` to run and move next
- [x] `Cmd+D` to duplicate cell
- [x] `Backspace` to delete empty cell
- [x] Up/Down arrow navigation between cells
- [x] `Escape` to deselect

---

## Phase 3: Database Integration ✅

### 3.1 Connection Manager
- [x] Implement `DatabaseConnectionManager` actor
- [x] `connect()` async method
- [x] `disconnect()` method
- [x] `execute()` async method
- [x] `testConnection()` method
- [x] Handle connection errors
- [x] Connection state enum

### 3.2 Connection UI
- [x] Create `ConnectionSheet` view
- [x] Form fields: host, port, database, username, password
- [x] SSL mode picker (all 6 PostgreSQL modes)
- [x] Connection string mode with auto-parsing
- [x] Smart cloud database detection
- [x] "Test Connection" button
- [x] "Connect" and "Cancel" buttons
- [x] Display connection errors inline

### 3.3 Query Execution
- [x] Wire up cell play button
- [x] Show loading spinner
- [x] Parse PostgreSQL response
- [x] Map PostgreSQL types to `CellValue`
- [x] Calculate execution time
- [x] Increment execution count
- [x] Handle query errors inline

### 3.4 Result Table
- [x] Create `ResultTableView` component
- [x] Sticky header row with column names and types
- [x] Body rows with alternating colors
- [x] Format cell values based on type
- [x] Column resizing with drag handles
- [x] Text selection for copying
- [x] Click handler to open cell details in sidebar

### 3.5 Result Metadata
- [x] Create `ResultMetadataView`
- [x] Display row count
- [x] Display execution time
- [x] Display timestamp

---

## Phase 4: Polish ✅ (MOSTLY COMPLETE)

### 4.1 Right Sidebar
- [x] Implement sidebar show/hide animation
- [x] `SidebarContent` enum for different modes
- [x] Create `JSONViewerView` with collapsible tree
- [x] JSON syntax highlighting
- [x] Copy button for JSON
- [x] Pretty-print toggle
- [x] `CellDetailView` for non-JSON values
- [x] `ConnectionInfoView` for connection details
- [x] Close button to sidebar header
- [x] Settings view in right sidebar

### 4.2 Header Actions
- [x] Wire up "+ Code" button
- [x] Implement "Run All" functionality
- [ ] Implement cell execution queue system
  - [ ] Queue management for multiple cells
  - [ ] Visual indicator for queued cells
  - [ ] Queue state for cells
  - [ ] Queue position indicator
  - [ ] Add individual cells to queue
  - [ ] Cancel queued cells
- [x] Implement "Clear All Outputs"
- [x] Button icons using SF Symbols
- [x] Add confirmation dialog for Run All

### 4.3 Footer
- [x] Display connection status with icon
- [x] Display notebook statistics
- [x] Display last saved time
- [x] "Unsaved changes" indicator

### 4.4 Drag and Drop - NOT STARTED
- [ ] Add drag handle to cell left sidebar
- [ ] Implement `onMove` modifier for cell reordering
- [ ] Add visual feedback during drag
- [ ] Update cell order in notebook model

### 4.5 Context Menu
- [x] Implement right-click context menu on cells
- [x] Add "Run" menu item
- [x] Add "Delete" menu item
- [x] Add "Duplicate" menu item
- [x] Add "Move Up" / "Move Down" menu items
- [x] Add "Copy" menu item (implemented as floating panel button)
- [x] Add "Clear Output" menu item

### 4.6 Global Keyboard Shortcuts
- [x] `Cmd+N` for new notebook
- [x] `Cmd+O` for open notebook
- [x] `Cmd+S` for save notebook
- [x] `Cmd+Shift+Enter` for run all
- [x] `Cmd+B` for add code cell
- [x] `Cmd+Backspace` for delete cell
- [x] `Cmd+Shift+R` for toggle sidebar
- [x] `Cmd+Shift+L` for toggle left sidebar
- [ ] `Cmd+/` for comment/uncomment SQL line - NOT STARTED
- [x] Settings panel with keyboard shortcuts (basic structure)

### 4.7 Auto-save & Document State
- [x] Implement auto-save on changes (debounced)
- [x] Track document dirty state
- [x] Show unsaved indicator in footer
- [ ] Prompt to save on close if unsaved - NOT STARTED

### 4.8 Result Display Controls - NOT STARTED
- [ ] Add show/hide toggle button in cell sidebar
- [ ] Implement collapse/expand animation
- [ ] Persist result visibility state per cell
- [ ] Visual indicator (chevron icon) for collapsed state

### 4.9 Left Sidebar - Database Structure ✅
- [x] Create `LeftSidebarView` component
- [x] Add `isLeftSidebarVisible` state
- [x] Database schema query methods
- [x] Tree view for tables and columns
- [x] Collapsible table nodes
- [x] Expandable column list
- [x] Refresh button
- [x] Toggle button in header
- [x] `Cmd+Shift+L` keyboard shortcut
- [x] Auto-load schema when connected
- [x] Error handling for schema loading
- [x] Click to insert table/column names
- [x] Persist left sidebar open state

### 4.10 Settings Panel ✅
- [x] Create `NotebookSettings` model
- [x] Add settings to `SQLNotebook` model
- [x] Create `SettingsContent` view component
- [x] Add settings case to `SidebarContent` enum
- [x] Max height configuration for result table
- [x] Include/exclude results when saving option
- [x] Keyboard shortcuts customization structure
- [x] Update document save/load for settings
- [x] Add Settings button to header

### 4.11 File Optimization - NOT STARTED
- [ ] Detect large file size (> 10MB)
- [ ] Implement compression option
- [ ] Add option to remove old results automatically
- [ ] Use compact JSON format for large files
- [ ] Add file size indicator in footer
- [ ] Add "Optimize File" menu option

### 4.12 Logging System - NOT STARTED
- [ ] Create `AppLogger` utility class
- [ ] Replace `print()` statements with logging calls
- [ ] Add log levels (debug, info, warning, error)
- [ ] Implement log capture system
- [ ] Add log rotation
- [ ] Add log filtering by level and component
- [ ] Add "Send Logs" menu item
- [ ] Implement log export functionality
- [ ] Add option to exclude sensitive data
- [ ] Add system info attachment option
- [ ] Implement log sending mechanism
- [ ] Show confirmation dialog before sending

### 4.13 Theme Toggle (Dark/Light Mode) - NOT STARTED
- [ ] Add theme preference to `AppSettings`
- [ ] Store theme preference in UserDefaults
- [ ] Update `DesignSystem.swift` for light/dark modes
- [ ] Create light mode color variants
- [ ] Use `@Environment(\.colorScheme)` for dynamic colors
- [ ] Remove hardcoded `.preferredColorScheme(.dark)`
- [ ] Apply theme preference to app
- [ ] Add theme toggle control to Settings panel
- [ ] Test all UI components in both modes
- [ ] Ensure proper contrast ratios

---

## Phase 5: Advanced Features

### 5.1 Query History
- [ ] Store executed queries with timestamps
- [ ] Create query history view/panel
- [ ] Allow re-running queries from history
- [ ] Persist history per notebook or globally

### 5.2 Export Results
- [ ] Implement "Export to CSV" for result tables
- [ ] Add export button to result metadata bar
- [ ] Show save panel for file location
- [ ] Handle large result sets efficiently

### 5.3 Multiple Database Support
- [ ] Abstract database connection interface
- [ ] Add SQLite support
- [ ] Add MySQL support (optional)
- [ ] Add database type selector to connection sheet
- [ ] Handle type mapping differences

### 5.4 Query Autocomplete (Optional)
- [ ] Parse schema information from database
- [ ] Implement autocomplete popup for table/column names
- [ ] Implement SQL keyword autocomplete
- [ ] Handle popup positioning and selection

### 5.5 Tabs Support - Multiple Database Connections
- [ ] Create tab management system
- [ ] Implement tab model for multiple database connections
- [ ] Add tab bar UI component
- [ ] Each tab maintains own connection manager and state
- [ ] Add "New Tab" button
- [ ] Implement tab switching
- [ ] Add close button (X) on each tab
- [ ] Show active tab indicator
- [ ] Display connection status icon on tab
- [ ] Show database name and host in tab label
- [ ] Handle tab reordering with drag and drop
- [ ] Persist tab configurations in notebook
- [ ] Update left sidebar for active tab
- [ ] Update query execution for active tab
- [ ] Add keyboard shortcuts: `Cmd+T`, `Cmd+W`, `Cmd+1-9`, `Cmd+Shift+]`/`[`
- [ ] Handle connection errors per tab
- [ ] Add context menu on tabs

### 5.6 AI-Powered Natural Language Query (Local Model Only)
- [ ] Select local LLM framework
- [ ] Integrate local model into app
- [ ] Create `AIService` actor
- [ ] Implement prompt engineering for natural language → SQL
- [ ] Include database schema context
- [ ] Include recent query history for context
- [ ] Add validation for generated SQL safety
- [ ] Create UI component for AI query input
- [ ] Show generated SQL before execution
- [ ] Add "Insert SQL" button
- [ ] Implement error handling
- [ ] Add settings for AI model path/options
- [ ] Ensure local-only processing (no network calls)
- [ ] Add privacy notice
- [ ] Test with various natural language queries
- [ ] Optimize model size/performance for macOS

### 5.7 Schema Visualizer
- [ ] Query foreign key relationships
- [ ] Build relationship graph
- [ ] Create visual graph component
- [ ] Render tables as nodes
- [ ] Render relationships as edges
- [ ] Show relationship type information
- [ ] Display foreign key column names on edges
- [ ] Implement pan and zoom functionality
- [ ] Click table to highlight related tables
- [ ] Click edge to show relationship details
- [ ] Drag nodes to rearrange layout
- [ ] Implement auto-layout algorithm
- [ ] Create `SchemaVisualizerView` component
- [ ] Add button to open visualizer
- [ ] Show visualizer in modal or dedicated panel
- [ ] Add refresh button
- [ ] Add filter options
- [ ] Show primary keys on table nodes
- [ ] Color-code tables by schema
- [ ] Show table row counts
- [ ] Display column count per table
- [ ] Add search/filter for specific tables
- [ ] Handle empty database (no tables)
- [ ] Handle tables without relationships
- [ ] Handle circular references
- [ ] Optimize for large schemas
- [ ] Error handling for query failures

---

## Phase 6: Security & Safety Features 🔒 (PARTIAL - 2 of 7 complete, 1 in progress)

### 6.0.1 Credentials Security ✅
- [x] Store passwords in macOS Keychain
- [x] Don't save passwords in notebook files
- [x] Don't include passwords in ConnectionConfig encoding
- [x] Use SessionManager for credential persistence

### 6.0.2 Connection Security
- [x] Support SSL/TLS connection modes (all 6 PostgreSQL modes)
- [x] Smart cloud database detection
- [ ] Fix certificate verification for `.require` mode - IN PROGRESS
- [ ] Add connection timeout configuration - NOT STARTED
- [ ] Add connection retry logic with exponential backoff - NOT STARTED
- [ ] Validate connection string format - NOT STARTED

### 6.0.3 Query Execution Security - NOT STARTED
- [x] Enforce row limits to prevent memory exhaustion
- [x] Detect modification queries
- [ ] Add confirmation dialogs for destructive operations
- [ ] Add read-only mode option
- [ ] Add transaction management
- [ ] Improve SQL injection protection

### 6.0.4 Data Modification Safety - PARTIAL
- [x] Use primary key columns for UPDATE WHERE clause
- [x] Use ctid (PostgreSQL) for row identification
- [x] Escape string values in UPDATE queries
- [ ] Add confirmation for inline cell editing - NOT STARTED
- [ ] Add transaction support for inline edits - NOT STARTED
- [ ] Add validation for UPDATE operations - NOT STARTED
- [ ] **Value Format Validation in Right Sidebar** - NOT STARTED
  - [ ] Check modified value format matches cell type when in edit mode
  - [ ] Display validation error/warning in footer sidebar
  - [ ] Disable "save" button when validation fails
  - [ ] Support validation for all cell types: integer, bigint, boolean, uuid, jsonb, json, date, timestamp, etc.
- [x] **Boolean Toggle UI for Value Editing** - COMPLETE ✅
  - [x] Show toggle slider (true/false) when editing boolean values
  - [x] User clicks toggle instead of typing "true"/"false"
  - [x] Integrate with sidebar value editing flow
  - [x] Toggle is smaller (scale 0.8) matching connection sidebar pattern
  - [x] Toggle appears immediately when sidebar opens (no edit mode needed)
  - [x] Toggle positioned on LEFT of label "true"/"false"
  - [x] Save button only appears when value changes
  - [x] Save button disappears after saving
  - [x] Hide edit button for boolean values
  - [x] Added 8 comprehensive Xcode Canvas previews for all cell value types

### 6.0.5 Audit & Logging Security - NOT STARTED
- [ ] Add query execution logging
- [ ] Add connection audit trail
- [ ] Add error reporting with privacy

### 6.0.6 User Education & Warnings - NOT STARTED
- [ ] Add security warnings in UI
- [ ] Add security tips in Settings or Help menu
- [ ] Add connection security indicator

### 6.0.7 Testing Security Features - NOT STARTED
- [ ] Add security-focused tests
- [ ] Test password not saved in UserDefaults
- [ ] Test password not in notebook file encoding
- [ ] Test SQL injection attempts
- [ ] Test read-only mode
- [ ] Test confirmation dialogs
- [ ] Test transaction rollback
- [ ] Test sensitive data masking

---

## Phase 7: Testing Suite 🚨 (MOSTLY COMPLETE - 4 of 13 complete, rest partial/not started)

### 7.1 Test Target Setup ✅
- [x] Create Unit Test target (`SQLNotebookTests`)
- [x] Create UI Test target (`SQLNotebookUITests`)
- [x] Configure test targets with dependencies
- [x] Set up test schemes and build configurations
- [x] Add test helper utilities

### 7.2 Unit Tests - Data Models ✅
- [x] `SQLNotebook` encoding/decoding
- [x] `NotebookCell` encoding/decoding
- [ ] `CellResult` encoding/decoding with error cases - NOT STARTED
- [x] `CellValue` enum encoding/decoding (all cases)
- [x] `ConnectionConfig` encoding/decoding
- [x] `NotebookMetadata` encoding/decoding
- [x] `NotebookSettings` encoding/decoding
- [ ] `DatabaseSchema` models encoding/decoding - NOT STARTED

### 7.3 Unit Tests - Utilities ✅
- [x] `SQLSyntaxHighlighter` tokenizer correctness
  - [x] Keyword detection (case-insensitive)
  - [x] Function detection with parentheses
  - [x] String highlighting (single-quote, dollar-quote)
  - [x] Comment highlighting (single-line, multi-line)
  - [x] Number highlighting
  - [x] Operator highlighting
- [ ] `JSONSyntaxHighlighter` (if exists)
- [x] `CellValue` type conversions
  - [x] `displayString` property for all types
  - [x] `fullString` property for all types
  - [x] `isNull` and `isJSON` computed properties

### 7.4 Unit Tests - Document Operations - NOT STARTED
- [ ] `SQLNotebookDocument.read()` with valid JSON
- [ ] `SQLNotebookDocument.read()` with invalid JSON
- [ ] `SQLNotebookDocument.write()` creates valid JSON
- [ ] Document round-trip (write → read → verify)
- [ ] Document with empty cells
- [ ] Document with cells with results
- [ ] Document with connection config

### 7.5 Unit Tests - ViewModel Logic ✅
- [x] `NotebookViewModel.addCell()` at different positions
- [x] `NotebookViewModel.deleteCell()` existing cell
- [x] `NotebookViewModel.moveCell()` for cell reordering
- [x] `NotebookViewModel.selectCell()` selection state
- [x] `NotebookViewModel.clearAllOutputs()` clear results
- [ ] Cell execution count increment - NOT STARTED
- [x] Cell running state management

### 7.6 Integration Tests - Database Connection - NOT STARTED
- [ ] `DatabaseConnectionManager.connect()` with valid config
- [ ] `DatabaseConnectionManager.connect()` with invalid config
- [ ] `DatabaseConnectionManager.testConnection()` success
- [ ] `DatabaseConnectionManager.testConnection()` failure
- [ ] `DatabaseConnectionManager.disconnect()` cleanup
- [ ] Connection state transitions
- [ ] SSL/TLS connection modes
- [ ] Connection string parsing and validation

### 7.7 Integration Tests - Query Execution - PARTIAL
- [ ] Execute SELECT query and parse results
- [ ] Execute INSERT/UPDATE/DELETE with affected rows
- [ ] Execute DDL statements (CREATE TABLE, etc.)
- [ ] Execute multiple statements sequentially
- [ ] Error handling for invalid SQL syntax
- [ ] Error handling for database errors
- [x] Type mapping from PostgreSQL types → CellValue (NUMERIC, VARCHAR, etc. tested)
  - [x] VARCHAR, INTEGER, BIGINT, DECIMAL, BOOLEAN
  - [ ] JSON/JSONB types - NOT STARTED
  - [ ] DATE, TIMESTAMP types - NOT STARTED
  - [x] NULL values
- [x] Result row limiting (max fetch rows)
- [ ] Execution time measurement accuracy - NOT STARTED

### 7.8 Integration Tests - Schema Loading - NOT STARTED
- [ ] `fetchTables()` returns correct table list
- [ ] `fetchColumns()` returns correct column info
- [ ] Schema loading with empty database
- [ ] Schema loading error handling
- [ ] Table row count calculation

### 7.9 UI Tests - Basic Flows - NOT STARTED
- [ ] Create new notebook (`Cmd+N`)
- [ ] Open existing notebook (`Cmd+O`)
- [ ] Save notebook (`Cmd+S`)
- [ ] Add code cell (`Cmd+B`)
- [ ] Delete cell (`Cmd+Backspace`)
- [ ] Duplicate cell (`Cmd+D`)
- [ ] Run cell (`Cmd+Enter`)
- [ ] Run all cells (`Cmd+Shift+Enter`)
- [ ] Toggle sidebars (`Cmd+Shift+R`, `Cmd+Shift+L`)

### 7.10 UI Tests - Query Execution Flow - NOT STARTED
- [ ] Enter SQL query in cell
- [ ] Execute query and verify results display
- [ ] Verify result table columns and rows
- [ ] Verify execution time display
- [ ] Verify error display for invalid queries
- [ ] Test with empty result set
- [ ] Test with large result set (scrolling)

### 7.11 UI Tests - Connection Flow - NOT STARTED
- [ ] Open connection sheet
- [ ] Enter connection details
- [ ] Test connection button
- [ ] Connect to database
- [ ] Verify connection status in footer
- [ ] Verify schema loads in left sidebar
- [ ] Disconnect from database

### 7.12 UI Tests - Document Persistence - NOT STARTED
- [ ] Save notebook with cells and results
- [ ] Close and reopen notebook
- [ ] Verify cells content preserved
- [ ] Verify results preserved (if settings allow)
- [ ] Verify connection config preserved

### 7.13 Test Infrastructure - PARTIAL
- [ ] Create mock `DatabaseConnectionManager` - NOT STARTED
- [ ] Create test database setup/teardown helpers - PARTIAL (integration tests have helpers)
- [ ] Create sample notebook files - PARTIAL (some test files exist)
- [x] Setup dedicated PostgreSQL test database (Docker available)
- [x] Create Docker Compose file for test database
- [x] Create SQL script for test database initialization
- [x] Update integration tests for test database
- [x] Add documentation for setting up test database
- [x] Setup GitHub Actions CI/CD workflow - COMPLETE
  - [x] Create `.github/workflows/ci.yml` - Complete ([ci.yml](.github/workflows/ci.yml))
  - [x] Configure workflow for push and pull requests
  - [x] Set up macOS runner (macos-15)
  - [x] Resolve Xcode and dependencies
  - [x] Run unit tests with SKIP_INTEGRATION_TESTS and SKIP_UI_TESTS
  - [x] Build app verification
  - [x] Use SKIP_INTEGRATION_TESTS for CI environment
  - [x] Add workflow status badge to README (already present in README)

---

## Phase 8: Editor Mode 🎯 (NOT STARTED - LAST PHASE)

**Status:** Not yet implemented. This is the final phase for an alternative SQL editor mode.

### 8.1 Core Editor Mode Implementation
- [ ] Add `ViewMode` enum (`.notebook`, `.editor`)
- [ ] Add `viewMode` state property to `NotebookViewModel`
- [ ] Create `EditorModeView` component
- [ ] Single SQL editor (full-width, no cells)
- [ ] Single result panel below editor
- [ ] Editor supports text selection
- [ ] Update `ContentView` to conditionally render based on `viewMode`

### 8.2 Execution Features
- [ ] Implement "Run Selection" functionality
- [ ] Detect selected text in editor
- [ ] Execute only selected SQL text
- [ ] Show visual indicator for selection
- [ ] Implement "Run All" functionality
- [ ] Execute entire file content
- [ ] Add execution buttons
- [ ] "Run Selection" button (enabled when selection exists)
- [ ] "Run All" button (always enabled)

### 8.3 Mode Switching UI
- [ ] Add mode toggle button in header
- [ ] Add visual indicator showing current mode
- [ ] Add keyboard shortcut to toggle mode
- [ ] Persist view mode preference

### 8.4 Sidebar Integration
- [ ] Preserve left sidebar functionality in editor mode
- [ ] Preserve right sidebar functionality in editor mode
- [ ] Table/column click inserts at cursor position
- [ ] Cell value editing for selected result

### 8.5 Data Conversion
- [ ] Handle file content loading to editor mode
- [ ] Concatenate all cells content when switching to editor
- [ ] Preserve cell order
- [ ] Handle saving from editor mode back to notebook mode
- [ ] Split by SQL statements or preserve as single cell
- [ ] Preserve document state when switching modes
- [ ] Handle unsaved changes warning

### 8.6 Testing & Polish
- [ ] Ensure editor mode works with connection system
- [ ] Test mode switching preserves connection state
- [ ] Test mode switching preserves document state
- [ ] Test "Run Selection" with various SQL statements
- [ ] Test "Run All" with multiple statements
- [ ] Test sidebar interactions in editor mode
- [ ] Test keyboard shortcuts in editor mode
- [ ] Test data conversion (notebook ↔ editor)

---

## Recent Completions

### Boolean Toggle UI for Value Editing ✅ (Phase 6.0.4)
- ✅ Implemented toggle slider for boolean value editing in right sidebar
- ✅ User clicks toggle instead of typing "true"/"false"
- ✅ Toggle automatically appears when sidebar opens (no edit mode needed)
- ✅ Toggle scaled 0.8 to match connection sidebar pattern
- ✅ Save button only appears when value changes
- ✅ Save button disappears after saving
- ✅ Edit button hidden for boolean values
- ✅ Added 8 comprehensive Xcode Canvas previews for all cell value types
- ✅ Implementation file: [CellInfoContent.swift](SQLNotebook/Views/Sidebars/CellInfoContent.swift)

### Left Sidebar - Database Structure ✅
- ✅ Implemented `LeftSidebarView` with tree view
- ✅ Added expand/collapse functionality
- ✅ Click to insert table/column names
- ✅ Auto-load schema when connection is established
- ✅ Refresh button to reload schema
- ✅ Toggle button with `Cmd+Shift+L` shortcut
- ✅ Empty and loading states
- ✅ Row count display for each table
- ✅ Primary key indicators

### SSL Connection Enhancement ✅
- ✅ Added connection string input mode with auto-parsing
- ✅ Added SSL mode picker for connection string mode
- ✅ Smart cloud database detection (Supabase, AWS, Azure, GCP)
- ✅ Fixed SSL mode mapping
- ✅ Fixed certificate verification for cloud databases
- ✅ Tested with Supabase pooler connections

---

## Next Priorities (Last Updated: 2026-01-02)

### COMPLETED: Boolean Toggle UI for Value Editing (Phase 6.0.4) ✅
**Status:** Feature fully implemented with 8 comprehensive Canvas previews.
- [x] Toggle slider for boolean values in right sidebar
- [x] No edit mode needed - toggle always visible
- [x] Save button appears only when value changes
- [x] All previews for different cell value types
- [x] Implementation file: [CellInfoContent.swift](SQLNotebook/Views/Sidebars/CellInfoContent.swift:114-129)

**Impact:** Safe boolean data modification with improved UX

---

### NEXT PRIORITY: Complete Phase 4 Polish (Medium Effort)
These UI enhancements improve user experience:

1. **Theme Toggle (4.13)** - Allow dark/light mode preference
   - Add preference to AppSettings
   - Update DesignSystem colors for light mode
   - Toggle control in Settings panel

2. **Result Show/Hide (4.8)** - Collapse/expand result visibility per cell
   - Toggle button in cell sidebar
   - Persist per-cell visibility state

3. **Comment/Uncomment (4.6)** - `Cmd+/` keyboard shortcut
   - Parse SQL to find line start
   - Toggle SQL comment prefix

4. **Drag and Drop (4.4)** - Reorder cells with drag handle
   - Add drag handle to cell sidebar
   - Implement onMove modifier

5. **Save Prompt (4.7)** - Warn before closing unsaved document
   - AppDelegate.applicationShouldTerminateAfterLastWindowClosed

6. **File Optimization (4.11)** - Reduce file sizes
   - Detect files > 10MB
   - Option to remove old results

7. **Logging System (4.12)** - Structured logging
   - Create AppLogger utility
   - Replace print() calls

---

### THEN: Complete Phase 6 Security (High Priority - Ongoing)
Security is never "done" but critical features to add:

1. **Value Format Validation & Boolean Toggle (6.0.4)** - Safe data modification
   - Validate format of modified values before saving (integer, uuid, jsonb, etc.)
   - Show validation errors in sidebar footer
   - Boolean toggle UI instead of manual typing true/false

2. **Confirmation Dialogs (6.0.3)** - Warn before destructive operations
   - Confirmation for DELETE/UPDATE
   - Display affected row count

3. **Read-Only Mode** - Prevent accidental modifications
   - Toggle in Settings
   - Disable play button for modification queries

4. **Transaction Management (6.0.4)** - Safe inline cell editing
   - ROLLBACK on errors
   - COMMIT after success

---

### THEN: Phase 7 Integration & UI Tests (High Effort)
Complete remaining test coverage:

1. **Document Operations Tests (7.4)** - Serialization round-trip tests
2. **Database Integration Tests (7.6-7.8)** - Connection, queries, schema
3. **UI Tests (7.9-7.12)** - User flows and persistence

---

### LATER: Phase 5 Advanced Features (Lower Priority)
When core is solid and tested:

1. **Schema Visualizer (5.7)** - Graph-based view of relationships
2. **AI Natural Language Query (5.6)** - Local LLM integration
3. **Tabs Support (5.5)** - Multiple database connections
4. **Query History (5.1)** - Recent queries panel
5. **Export to CSV (5.2)** - Export results
6. **Multiple DB Support (5.3)** - Add MySQL, SQLite

---

### FINALLY: Phase 8 Editor Mode (Last Phase)
Traditional SQL editor with single editor and result panel below.

---

## Definition of Done

Each task is complete when:
1. Feature is implemented according to specifications
2. Code follows Swift/SwiftUI best practices
3. Relevant tests are written and passing
4. Feature works in both light and dark mode
5. No compiler warnings or runtime errors
6. Code is reviewed and committed
