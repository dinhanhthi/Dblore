# TODO.md - SQL Notebook Implementation Tasks

This document outlines the implementation phases and specific tasks for building the SQL Notebook application. Reference the main **[project.md](./project.md)** for detailed specifications.

## 📊 Current Status

- ✅ **Phase 1: Core Structure** - COMPLETE
- ✅ **Phase 2: Cell Editor** - COMPLETE
- ✅ **Phase 3: Database Integration** - **COMPLETE!** 🎉
- ✅ **Phase 4: Polish** - MOSTLY COMPLETE (minor features pending)
- ⏳ **Phase 5: Advanced Features** - NOT STARTED (Features planned: Schema Visualizer 5.7, AI Query 5.6, Tabs 5.5)
- 🔒 **Phase 6: Security & Safety** - **IN PROGRESS** ⚠️ (Credentials security ✅, Connection security ⚠️, Query execution security ⚠️)
- 🚨 **Phase 7: Testing Suite** - **IN PROGRESS** ⭐ (Test targets setup ✅, Data Models tests ✅, Utilities tests ✅, ViewModel tests ✅)
- 🎯 **Phase 8: Editor Mode** - **NOT STARTED** (LAST PHASE - Implement after all other features)

### 🎉 Latest Achievement: SSL Connection Support Enhanced!
**BUILD STATUS: SUCCESS ✅**

App bây giờ có thể:
- Connect đến PostgreSQL databases (local & remote)
- Execute real SQL queries
- Parse và display results với full type information
- Handle errors gracefully
- **NEW: Full SSL/TLS support với connection string mode**
- **NEW: Smart cloud database detection (Supabase, AWS, Azure, GCP)**
- **NEW: SSL mode picker với 6 modes (disable, allow, prefer, require, verify-ca, verify-full)**

See `docs/IMPLEMENTATION_COMPLETE.md` for full details!

---

## Phase 1: Core Structure ✅

### 1.1 Project Setup
- [x] Create new macOS app project in Xcode
- [x] Set minimum deployment target to macOS 14.0
- [x] Configure app as document-based application
- [x] Add PostgresNIO package dependency via Swift Package Manager (managed via Xcode)
- [x] Define custom UTType for `.sqlnb` files in Info.plist

### 1.2 Data Models
- [x] Implement `SQLNotebook` struct with Codable conformance
- [x] Implement `NotebookCell` struct
- [x] Implement `CellType` enum
- [x] Implement `CellResult` struct
- [x] Implement `ColumnInfo` struct
- [x] Implement `CellValue` enum with all type cases
- [x] Implement `ConnectionConfig` struct
- [x] Implement `NotebookMetadata` struct
- [ ] Write unit tests for model serialization/deserialization

### 1.3 Document Architecture
- [x] Implement `SQLNotebookDocument` conforming to `FileDocument`
- [x] Implement `read` and `write` methods for document persistence
- [x] Register `.sqlnb` file type with the system
- [x] Test document creation, saving, and loading

### 1.4 Basic Layout
- [x] Create `ContentView` with main layout structure
- [x] Implement `HeaderView` with placeholder buttons
- [x] Implement `MainContentView` with ScrollView container
- [x] Implement `FooterView` with placeholder content
- [x] Implement `RightSidebarView` (hidden by default)
- [x] Set up layout constraints and spacing

---

## Phase 2: Cell Editor ✅

### 2.1 Cell List Management
- [x] Implement `NotebookViewModel` with `@Observable`
- [x] Implement `addCell(type:after:)` method
- [x] Implement `deleteCell(id:)` method
- [x] Implement `moveCell(from:to:)` method
- [x] Implement cell selection state management
- [x] Add LazyVStack for cell rendering

### 2.2 Cell View Component
- [x] Create `CellView` component with left sidebar and editor area
- [x] Implement play button with different states (default, running)
- [x] Implement execution count display
- [x] Add cell selection border styling
- [x] Implement cell hover states

### 2.3 SQL Editor
- [x] Create `SQLEditorView` using TextEditor
- [x] Implement `SQLSyntaxHighlighter` class
- [x] Define keyword lists (DDL, DML, functions, types)
- [x] Implement tokenizer for SQL syntax
- [x] Apply AttributedString styling based on token types
- [x] Set monospace font (SF Mono)
- [x] Implement auto-expanding height based on content
- [x] Add minimum height constraint (3 lines)

### 2.4 Cell Keyboard Navigation
- [x] Implement `Cmd+Enter` to run cell
- [x] Implement `Shift+Enter` to run and move next
- [x] Implement `Cmd+D` to duplicate cell
- [x] Implement `Backspace` to delete empty cell
- [x] Implement `Up/Down` arrow navigation between cells
- [x] Implement `Escape` to deselect

---

## Phase 3: Database Integration ✅ **COMPLETE!**

### 3.1 Connection Manager
- [x] Implement `DatabaseConnectionManager` actor
- [x] Implement `connect(config:)` async method
- [x] Implement `disconnect()` method
- [x] Implement `execute(query:)` async method
- [x] Implement `testConnection()` method
- [x] Handle connection errors gracefully
- [x] Implement connection state enum

### 3.2 Connection UI
- [x] Create `ConnectionSheet` view for entering connection details
- [x] Add form fields: host, port, database, username, password
- [x] Add SSL mode picker (all 6 PostgreSQL modes)
- [x] Add connection string mode with auto-parsing
- [x] Add SSL mode picker for connection string mode
- [x] Smart cloud database detection (auto-set SSL require)
- [x] Fix SSL certificate verification for cloud databases
- [x] Add "Test Connection" button
- [x] Add "Connect" and "Cancel" buttons
- [x] Show connection errors inline
- [x] Update header button state based on connection status

### 3.3 Query Execution
- [x] Wire up cell play button to execute query
- [x] Show loading spinner during execution
- [x] Parse PostgresNIO response into `CellResult`
- [x] Map PostgreSQL types to `CellValue` cases
- [x] Calculate and store execution time
- [x] Increment execution count on each run
- [x] Handle query errors and display inline

### 3.4 Result Table
- [x] Create `ResultTableView` component
- [x] Implement sticky header row with column names and types
- [x] Implement body rows with alternating colors
- [x] Format cell values based on type (NULL, numbers, strings, JSON preview)
- [x] Implement max-height with vertical scrolling
- [x] Implement column resizing (drag handles)
- [x] Implement text selection for copying
- [x] Add click handler to open cell details in sidebar

### 3.5 Result Metadata
- [x] Create `ResultMetadataView` below table
- [x] Display row count
- [x] Display execution time
- [x] Display timestamp

---

## Phase 4: Polish ✅

### 4.1 Right Sidebar
- [x] Implement sidebar show/hide animation
- [x] Implement `SidebarContent` enum for different modes
- [x] Create `JSONViewerView` with collapsible tree
- [x] Add JSON syntax highlighting
- [x] Add copy button for JSON
- [x] Add pretty-print toggle
- [x] Create `CellDetailView` for non-JSON values
- [x] Create `ConnectionInfoView` for connection details
- [x] Add close button to sidebar header
- [x] Create Settings view in right sidebar

### 4.2 Header Actions
- [x] Wire up "+ Code" button
- [x] Implement "Run All" functionality (sequential execution)
- [ ] Implement cell execution queue system
  - [ ] Add queue management to execute multiple cells one after another
  - [ ] Add visual indicator (icon) to show when cell is in queue
  - [ ] Implement queue state for cells (pending, queued, running, completed)
  - [ ] Add queue position indicator (e.g., "3/5" in queue)
  - [ ] Allow adding individual cells to queue (not just "Run All")
  - [ ] Add ability to cancel queued cells
- [x] Implement "Clear All Outputs" functionality
- [x] Add button icons using SF Symbols
- [x] Style buttons according to design system

### 4.3 Footer
- [x] Display connection status with icon
- [x] Display notebook statistics (cell count, executed count)
- [x] Display last saved time
- [x] Update "Unsaved changes" indicator

### 4.4 Drag and Drop
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
- [ ] Add "Copy" menu item
- [x] Add "Clear Output" menu item

### 4.6 Global Keyboard Shortcuts
- [x] Implement `Cmd+N` for new notebook
- [x] Implement `Cmd+O` for open notebook
- [x] Implement `Cmd+S` for save notebook
- [x] Implement `Cmd+Shift+Enter` for run all
- [x] Implement `Cmd+B` for add code cell
- [x] Implement `Cmd+Backspace` for delete cell
- [x] Implement `Cmd+Shift+R` for toggle sidebar
- [ ] Implement `Cmd+/` for comment/uncomment SQL line
- [x] Add Settings panel with keyboard shortcuts customization (basic structure)

### 4.7 Auto-save & Document State
- [x] Implement auto-save on changes (debounced)
- [x] Track document dirty state
- [x] Show unsaved indicator in footer
- [ ] Prompt to save on close if unsaved

### 4.8 Result Display Controls
- [ ] Add show/hide toggle button in cell sidebar for results
- [ ] Implement collapse/expand animation for result area
- [ ] Persist result visibility state per cell
- [ ] Add visual indicator (chevron icon) for collapsed state

### 4.11 File Optimization
- [ ] Optimize .sqlnb file when it's large
  - [ ] Detect large file size (e.g., > 10MB)
  - [ ] Implement compression option (gzip/deflate)
  - [ ] Add option to remove old results automatically
  - [ ] Use compact JSON format (no pretty printing) for large files
  - [ ] Add file size indicator in footer
  - [ ] Add "Optimize File" menu option

### 4.12 Logging System
- [ ] Implement centralized logging system throughout the app
  - [ ] Create `AppLogger` utility class using `swift-log`
  - [ ] Replace all `print()` statements with proper logging calls
  - [ ] Add log levels (debug, info, warning, error)
  - [ ] Implement log capture system (store logs in memory/file)
  - [ ] Add log rotation (limit log file size, keep last N files)
  - [ ] Add log filtering by level and component
- [ ] Add menu option to send logs to developers
  - [ ] Create "Send Logs" menu item in Help menu
  - [ ] Implement log export functionality (format as text/JSON)
  - [ ] Add option to include/exclude sensitive data (passwords, connection strings)
  - [ ] Add option to attach system info (OS version, app version)
  - [ ] Implement log sending mechanism (email, webhook, or file export)
  - [ ] Show confirmation dialog before sending
  - [ ] Add privacy notice about what data is included

### 4.9 Left Sidebar - Database Structure ✅
- [x] Create `LeftSidebarView` component
- [x] Add `isLeftSidebarVisible` state to `NotebookViewModel`
- [x] Implement database schema query methods in `DatabaseConnectionManager`
  - [x] Query list of tables from `information_schema.tables`
  - [x] Query columns for each table from `information_schema.columns`
  - [x] Query row count for each table
- [x] Create tree view component for tables and columns
  - [x] Collapsible table nodes
  - [x] Expandable column list under each table
  - [x] Display column name and type
  - [x] Show table/column icons using SF Symbols
- [x] Add refresh button to reload schema
- [x] Add toggle button in header to show/hide left sidebar
- [x] Implement keyboard shortcut (`Cmd+Shift+L`) to toggle
- [x] Auto-load schema when connection is established
- [x] Handle schema loading errors gracefully
- [x] Add click handler to insert table/column names into selected cell
- [x] Style sidebar according to design system (matching right sidebar)
- [ ] Persist left sidebar open state (restore visibility when app reopens)

### 4.10 Settings Panel ✅
- [x] Create `NotebookSettings` model to store notebook preferences
- [x] Add settings to `SQLNotebook` model
- [x] Create `SettingsContent` view component for right sidebar
- [x] Add settings case to `SidebarContent` enum
- [x] Implement max height configuration for result table view
- [x] Implement include/exclude results when saving option
- [x] Add basic keyboard shortcuts customization structure
- [x] Update document save/load to respect settings
- [x] Add Settings button to header or menu

### 4.13 Theme Toggle (Dark/Light Mode)
- [ ] Add theme preference to `AppSettings` (dark, light, system)
- [ ] Store theme preference in UserDefaults
- [ ] Update `DesignSystem.swift` to support both light and dark color schemes
  - [ ] Create light mode color variants for all semantic colors
  - [ ] Use `@Environment(\.colorScheme)` to adapt colors dynamically
- [ ] Remove hardcoded `.preferredColorScheme(.dark)` from `SQLNotebookApp.swift`
- [ ] Apply theme preference to app using `.preferredColorScheme()` modifier
- [ ] Add theme toggle control to Settings panel
  - [ ] Radio buttons or picker for: Dark, Light, System
  - [ ] Show preview of current theme
- [ ] Update all views to use semantic colors from DesignSystem (not hardcoded)
- [ ] Test all UI components in both light and dark modes
- [ ] Ensure proper contrast ratios for accessibility

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
- [ ] Add SQLite support using native Swift APIs
- [ ] Add MySQL support (optional)
- [ ] Add database type selector to connection sheet
- [ ] Handle type mapping differences between databases

### 5.4 Query Autocomplete (Optional)
- [ ] Parse schema information from connected database
- [ ] Implement autocomplete popup for table/column names
- [ ] Implement SQL keyword autocomplete
- [ ] Handle popup positioning and selection

### 5.5 Tabs Support - Multiple Database Connections
- [ ] Create tab management system (similar to VSCode)
- [ ] Implement tab model to store multiple database connections per notebook
- [ ] Add tab bar UI component above main content area
- [ ] Each tab maintains its own:
  - [ ] `DatabaseConnectionManager` instance
  - [ ] Connection state and config
  - [ ] Database schema (tables/columns)
  - [ ] Query execution context
- [ ] Add "New Tab" button to create additional database connections
- [ ] Implement tab switching functionality
- [ ] Add close button (X) on each tab
- [ ] Show active tab indicator (highlighted background)
- [ ] Display connection status icon on each tab (connected/disconnected)
- [ ] Show database name and host in tab label
- [ ] Handle tab reordering (drag and drop)
- [ ] Persist tab configurations in notebook document
- [ ] Update left sidebar to show schema for active tab's database
- [ ] Update query execution to use active tab's connection
- [ ] Add keyboard shortcuts:
  - [ ] `Cmd+T` to create new tab
  - [ ] `Cmd+W` to close current tab
  - [ ] `Cmd+1-9` to switch to tab by number
  - [ ] `Cmd+Shift+]` / `Cmd+Shift+[` to navigate between tabs
- [ ] Handle connection errors per tab (don't affect other tabs)
- [ ] Add context menu on tabs (Connect, Disconnect, Close, Close Others, etc.)

### 5.6 AI-Powered Natural Language Query (Local Model Only)
- [ ] Research và select local LLM framework (e.g., llama.cpp, CoreML, or Swift-native solution)
- [ ] Integrate local model vào app (download/load model files)
- [ ] Create `AIService` actor để handle natural language processing
- [ ] Implement prompt engineering để convert natural language → SQL queries
  - [ ] Include database schema context (tables, columns, types)
  - [ ] Include recent query history for context
  - [ ] Add validation để ensure generated SQL is safe
- [ ] Create UI component cho AI query input
  - [ ] Add AI button/icon trong cell editor hoặc header
  - [ ] Create input field cho natural language query
  - [ ] Show loading state khi AI đang process
  - [ ] Display generated SQL trước khi execute (allow user to review/edit)
  - [ ] Add "Insert SQL" button để insert vào cell
- [ ] Implement error handling cho AI failures
- [ ] Add settings để configure AI model path/options
- [ ] Ensure all processing happens locally (no network calls)
- [ ] Add privacy notice về local-only processing
- [ ] Test với various natural language queries
- [ ] Optimize model size/performance cho macOS

### 5.7 Schema Visualizer
- [ ] Query foreign key relationships từ `information_schema`
  - [ ] Query `information_schema.table_constraints` để get foreign keys
  - [ ] Query `information_schema.key_column_usage` để get column mappings
  - [ ] Query `information_schema.constraint_column_usage` để get referenced tables
  - [ ] Build relationship graph với tables as nodes và foreign keys as edges
- [ ] Create visual graph component
  - [ ] Use SwiftUI Canvas hoặc third-party graph library
  - [ ] Render tables as nodes (boxes) với table name
  - [ ] Render relationships as edges (lines/arrows) between tables
  - [ ] Show relationship type (one-to-one, one-to-many, many-to-many)
  - [ ] Display foreign key column names on edges
- [ ] Implement interactive features
  - [ ] Pan và zoom functionality cho large schemas
  - [ ] Click table node để highlight related tables
  - [ ] Click edge để show relationship details (columns, constraint name)
  - [ ] Drag nodes để rearrange layout
  - [ ] Auto-layout algorithm (force-directed, hierarchical, etc.)
- [ ] Add schema visualizer view
  - [ ] Create new view component `SchemaVisualizerView`
  - [ ] Add button trong left sidebar hoặc header để open visualizer
  - [ ] Show visualizer trong modal window hoặc dedicated panel
  - [ ] Add refresh button để reload relationships
  - [ ] Add filter options (show only specific tables, hide certain relationships)
- [ ] Enhance with additional information
  - [ ] Show primary keys on table nodes
  - [ ] Color-code tables by schema
  - [ ] Show table row counts
  - [ ] Display column count per table
  - [ ] Add search/filter để find specific tables
- [ ] Handle edge cases
  - [ ] Empty database (no tables)
  - [ ] Tables without relationships
  - [ ] Circular references
  - [ ] Large schemas (performance optimization)
  - [ ] Error handling khi query fails

---

## Phase 6: Security & Safety Features 🔒 **HIGH PRIORITY**

### Overview
Implement comprehensive security features để protect database credentials, prevent accidental data loss, và ensure safe database operations.

### 6.0.1 Credentials Security ✅
- [x] Store passwords in macOS Keychain (not in UserDefaults)
- [x] Don't save passwords in notebook files (.sqlnb)
- [x] Don't include passwords in ConnectionConfig encoding
- [x] Use SessionManager to handle credential persistence securely

### 6.0.2 Connection Security ⚠️
- [x] Support SSL/TLS connection modes (disable, allow, prefer, require, verify-ca, verify-full)
- [x] Smart cloud database detection (auto-set SSL require)
- [ ] **TODO: Fix certificate verification for `.require` mode**
  - [ ] Current issue: `.require` mode sets `certificateVerification = .none` to allow self-signed certs
  - [ ] Add warning dialog when using `.require` with `.none` verification
  - [ ] Consider adding option to use `.fullVerification` even for `.require` mode
  - [ ] Document security implications in connection UI
- [ ] Add connection timeout configuration
- [ ] Add connection retry logic with exponential backoff
- [ ] Validate connection string format before attempting connection

### 6.0.3 Query Execution Security ⚠️
- [x] Enforce row limits to prevent memory exhaustion
- [x] Detect modification queries (UPDATE, DELETE, INSERT)
- [ ] **TODO: Add confirmation dialogs for destructive operations**
  - [ ] Detect DROP, TRUNCATE, ALTER TABLE, DELETE without WHERE clause
  - [ ] Show confirmation dialog với query preview
  - [ ] Add "Don't ask again" option (stored in settings)
  - [ ] Show affected rows estimate (if possible) before confirmation
- [ ] **TODO: Add read-only mode option**
  - [ ] Add "Read-only" checkbox in connection form
  - [ ] Block all modification queries (UPDATE, DELETE, INSERT, DROP, etc.) in read-only mode
  - [ ] Show clear error message when attempting modification in read-only mode
  - [ ] Store read-only preference in ConnectionConfig
- [ ] **TODO: Add transaction management**
  - [ ] Wrap modification queries in transactions
  - [ ] Auto-rollback on error
  - [ ] Add "Commit" / "Rollback" buttons for manual transaction control
  - [ ] Show transaction status indicator
- [ ] **TODO: Improve SQL injection protection**
  - [ ] Review `cellValueToSQL` function - ensure all value types are properly escaped
  - [ ] Add validation for table/column names (prevent injection via identifiers)
  - [ ] Consider using parameterized queries where possible (PostgresNIO supports this)
  - [ ] Add query sanitization warnings for suspicious patterns

### 6.0.4 Data Modification Safety ⚠️
- [x] Use primary key columns for UPDATE WHERE clause (most reliable)
- [x] Use ctid (PostgreSQL) for row identification when PK not available
- [x] Escape string values in UPDATE queries (single quotes doubled)
- [ ] **TODO: Add confirmation for inline cell editing (UPDATE operations)**
  - [ ] Show confirmation dialog before executing UPDATE
  - [ ] Display: table name, column name, old value, new value
  - [ ] Show affected rows estimate
  - [ ] Add "Don't ask again" option
- [ ] **TODO: Add transaction support for inline edits**
  - [ ] Wrap UPDATE in transaction
  - [ ] Auto-rollback if UPDATE affects unexpected number of rows (e.g., 0 or >1)
  - [ ] Show transaction status during edit
- [ ] **TODO: Add validation for UPDATE operations**
  - [ ] Verify row still exists before updating
  - [ ] Check data type compatibility
  - [ ] Validate constraints (NOT NULL, CHECK, etc.) before executing
  - [ ] Show clear error messages for constraint violations

### 6.0.5 Audit & Logging Security
- [ ] **TODO: Add query execution logging (with security considerations)**
  - [ ] Log all queries executed (for debugging)
  - [ ] **CRITICAL: Never log passwords or sensitive data**
  - [ ] Mask sensitive values in logs (e.g., credit card numbers, SSNs)
  - [ ] Add option to disable query logging
  - [ ] Store logs securely (encrypted if containing sensitive data)
- [ ] **TODO: Add connection audit trail**
  - [ ] Log connection attempts (success/failure)
  - [ ] Log disconnections
  - [ ] Don't log credentials, only connection metadata (host, database, username)
- [ ] **TODO: Add error reporting with privacy**
  - [ ] Sanitize error messages before logging (remove sensitive data)
  - [ ] Add option to send error reports (with user consent)
  - [ ] Ensure error reports don't contain credentials or sensitive data

### 6.0.6 User Education & Warnings
- [ ] **TODO: Add security warnings in UI**
  - [ ] Show warning when connecting without SSL
  - [ ] Show warning when using `.require` mode with `.none` certificate verification
  - [ ] Show warning when executing destructive operations
  - [ ] Add "Security Tips" section in Settings or Help menu
- [ ] **TODO: Add connection security indicator**
  - [ ] Show SSL/TLS status icon in footer
  - [ ] Color code: Green (secure), Yellow (insecure), Red (no encryption)
  - [ ] Show certificate information on click

### 6.0.7 Testing Security Features
- [ ] **TODO: Add security-focused tests**
  - [ ] Test password not saved in UserDefaults
  - [ ] Test password not included in notebook file encoding
  - [ ] Test SQL injection attempts are blocked/escaped
  - [ ] Test read-only mode blocks modifications
  - [ ] Test confirmation dialogs appear for destructive operations
  - [ ] Test transaction rollback on errors
  - [ ] Test sensitive data masking in logs

---

## Phase 7: Testing Suite 🚨 **CURRENT TOP PRIORITY**

### Overview
Thêm comprehensive testing suite cho SQLNotebook app sử dụng XCTest framework (built-in trong Xcode). Testing sẽ bao gồm Unit Tests, Integration Tests, và UI Tests.

### 7.1 Test Target Setup
- [x] Create new Unit Test target trong Xcode (`SQLNotebookTests`)
- [x] Create new UI Test target trong Xcode (`SQLNotebookUITests`)
- [x] Configure test targets với proper dependencies (PostgresNIO, etc.)
- [x] Set up test schemes và build configurations
- [x] Add test helper utilities và mock objects

**📖 Detailed Setup Guide:** See [TESTING_SETUP_GUIDE.md](./TESTING_SETUP_GUIDE.md) for step-by-step instructions.

### 7.2 Unit Tests - Data Models
- [x] `SQLNotebook` encoding/decoding (JSON serialization) ✅
- [x] `NotebookCell` encoding/decoding với all properties ✅
- [ ] `CellResult` encoding/decoding với error cases
- [x] `CellValue` enum encoding/decoding cho all cases ✅
  - [x] Test string, int, double, bool, null, json, date, data ✅
- [x] `ConnectionConfig` encoding/decoding (không lưu password) ✅
- [x] `NotebookMetadata` encoding/decoding ✅
- [x] `NotebookSettings` encoding/decoding ✅
- [ ] `DatabaseSchema` models encoding/decoding

### 7.3 Unit Tests - Utilities
- [x] `SQLSyntaxHighlighter` tokenizer correctness ✅
  - [x] Test keyword detection (case-insensitive) ✅
  - [x] Test function detection với parentheses ✅
  - [x] Test string highlighting (single-quote, dollar-quote) ✅
  - [x] Test comment highlighting (single-line, multi-line) ✅
  - [x] Test number highlighting ✅
  - [x] Test operator highlighting ✅
- [ ] `JSONSyntaxHighlighter` (nếu có)
- [x] `CellValue` type conversions ✅
  - [x] Test `displayString` property cho all types ✅
  - [x] Test `fullString` property cho all types ✅
  - [x] Test `isNull` và `isJSON` computed properties ✅

### 7.4 Unit Tests - Document Operations
- [ ] `SQLNotebookDocument.read()` với valid JSON
- [ ] `SQLNotebookDocument.read()` với invalid JSON (error handling)
- [ ] `SQLNotebookDocument.write()` tạo valid JSON
- [ ] Document round-trip (write → read → verify)
- [ ] Document với empty cells
- [ ] Document với cells có results
- [ ] Document với connection config (không lưu password)

### 7.5 Unit Tests - ViewModel Logic
- [x] `NotebookViewModel.addCell()` - add cell ở different positions ✅
- [x] `NotebookViewModel.deleteCell()` - delete existing cell ✅
- [x] `NotebookViewModel.moveCell()` - reorder cells ✅
- [x] `NotebookViewModel.selectCell()` - selection state management ✅
- [x] `NotebookViewModel.clearAllOutputs()` - clear all results ✅
- [ ] Cell execution count increment
- [x] Cell running state management ✅

### 7.6 Integration Tests - Database Connection
- [ ] `DatabaseConnectionManager.connect()` với valid config
- [ ] `DatabaseConnectionManager.connect()` với invalid config (error handling)
- [ ] `DatabaseConnectionManager.testConnection()` success case
- [ ] `DatabaseConnectionManager.testConnection()` failure case
- [ ] `DatabaseConnectionManager.disconnect()` cleanup
- [ ] Connection state transitions (disconnected → connecting → connected)
- [ ] SSL/TLS connection modes (require, verify-ca, etc.)
- [ ] Connection string parsing và validation

### 7.7 Integration Tests - Query Execution
- [ ] Execute SELECT query và parse results
- [ ] Execute INSERT/UPDATE/DELETE và verify affected rows
- [ ] Execute DDL statements (CREATE TABLE, etc.)
- [ ] Execute multiple statements sequentially
- [ ] Error handling cho invalid SQL syntax
- [ ] Error handling cho database errors (table not found, etc.)
- [ ] Type mapping từ PostgreSQL types → CellValue
  - [ ] Test VARCHAR, INTEGER, BIGINT, DECIMAL, BOOLEAN
  - [ ] Test JSON/JSONB types
  - [ ] Test DATE, TIMESTAMP types
  - [ ] Test NULL values
- [x] Result row limiting (max fetch rows) ✅ (DatabaseQueryExecutionTests.swift - LIMIT handling tests)
- [ ] Execution time measurement accuracy

### 7.8 Integration Tests - Schema Loading
- [ ] `fetchTables()` returns correct table list
- [ ] `fetchColumns()` returns correct column info
- [ ] Schema loading với empty database
- [ ] Schema loading error handling
- [ ] Table row count calculation

### 7.9 UI Tests - Basic Flows
- [ ] Create new notebook (`Cmd+N`)
- [ ] Open existing notebook (`Cmd+O`)
- [ ] Save notebook (`Cmd+S`)
- [ ] Add code cell (`Cmd+B`)
- [ ] Delete cell (`Cmd+Backspace`)
- [ ] Duplicate cell (`Cmd+D`)
- [ ] Run cell (`Cmd+Enter`)
- [ ] Run all cells (`Cmd+Shift+Enter`)
- [ ] Toggle sidebars (`Cmd+Shift+R`, `Cmd+Shift+L`)

### 7.10 UI Tests - Query Execution Flow
- [ ] Enter SQL query trong cell
- [ ] Execute query và verify results display
- [ ] Verify result table columns và rows
- [ ] Verify execution time display
- [ ] Verify error display cho invalid queries
- [ ] Test với empty result set
- [ ] Test với large result set (scrolling)

### 7.11 UI Tests - Connection Flow
- [ ] Open connection sheet
- [ ] Enter connection details
- [ ] Test connection button
- [ ] Connect to database
- [ ] Verify connection status in footer
- [ ] Verify schema loads in left sidebar
- [ ] Disconnect from database

### 7.12 UI Tests - Document Persistence
- [ ] Save notebook với cells và results
- [ ] Close và reopen notebook
- [ ] Verify cells content preserved
- [ ] Verify results preserved (nếu settings allow)
- [ ] Verify connection config preserved (không có password)

### Test Infrastructure
- [ ] Create mock `DatabaseConnectionManager` cho unit tests
- [ ] Create test database setup/teardown helpers
- [ ] Create sample notebook files cho testing
- [ ] **Setup Dedicated PostgreSQL Test Database** 🗄️
  - [ ] Create Docker Compose file for test PostgreSQL instance on port 5435
  - [ ] Create SQL script to initialize test database schema and sample data
    - [ ] Create tables with NUMERIC, VARCHAR, TIMESTAMP columns
    - [ ] Add sample test data for various data types
    - [ ] Create relationships (foreign keys) for schema testing
  - [ ] Update `DatabaseIntegrationTests` configuration to point to test database
  - [ ] Remove `SKIP_INTEGRATION_TESTS` flag and run all integration tests against real database
  - [ ] Add README/documentation for setting up test database locally
    - [ ] Instructions for Docker setup
    - [ ] Manual PostgreSQL setup instructions (alternative)
    - [ ] How to run test database
    - [ ] Connection details (host: localhost, port: 5435, database: sqlnotebook_test)
  - [ ] Run all integration tests and verify they pass
  - [ ] Consider adding test database setup to GitHub Actions CI workflow
    - [ ] Use Docker service or PostgreSQL action in CI
    - [ ] Initialize test database before running tests
- [ ] **Set up GitHub Actions CI/CD workflow** ⭐ **NEXT PRIORITY**
  - [ ] Create `.github/workflows/ci.yml` file
  - [ ] Configure workflow to run on push và pull requests
  - [ ] Set up macOS runner (required for Swift/macOS app)
  - [ ] Install Xcode và dependencies
  - [ ] Run all unit tests (`SQLNotebookTests` target)
  - [ ] Run all UI tests (`SQLNotebookUITests` target) - optional (can be slow)
  - [ ] Build app để verify compilation succeeds
  - [ ] Add test coverage reporting (optional)
  - [ ] Configure workflow to fail nếu any test fails
  - [ ] Add status badge to README.md
- [ ] Document test coverage goals (aim for 70%+)

### 7.13 GitHub Actions CI/CD Workflow ⭐ **IMMEDIATE NEXT STEP**

**Overview:**
Set up automated CI/CD pipeline sử dụng GitHub Actions để ensure code quality và prevent regressions. Workflow sẽ automatically run all tests mỗi khi có push hoặc pull request.

**Requirements:**
1. **Workflow File:** `.github/workflows/ci.yml`
   - Trigger: `on: [push, pull_request]`
   - Platform: `macos-latest` (required cho macOS app)
   - Xcode version: Latest stable (hoặc specific version nếu cần)

2. **Build Steps:**
   - Checkout code
   - Setup Xcode (install dependencies, select Xcode version)
   - Build app target để verify compilation
   - Run unit tests (`SQLNotebookTests` target)
   - Optionally run UI tests (`SQLNotebookUITests` target) - có thể skip nếu quá slow

3. **Test Execution:**
   - Run all tests trong `SQLNotebookTests` target
   - Ensure all tests pass (workflow fails nếu any test fails)
   - Display test results summary

4. **Optional Enhancements:**
   - Test coverage reporting (sử dụng Xcode's built-in coverage)
   - Artifact upload (test results, coverage reports)
   - Matrix testing (multiple Xcode versions nếu cần)
   - Caching Swift packages để speed up builds

5. **Status Badge:**
   - Add workflow status badge to README.md
   - Format: `![CI](https://github.com/USERNAME/SQLNotebook/workflows/CI/badge.svg)`

**Implementation Notes:**
- macOS runners có thể slower và more expensive than Linux runners
- UI tests có thể skip trong CI nếu quá slow (focus on unit tests)
- Ensure PostgresNIO dependency resolves correctly trong CI environment
- Consider using `xcodebuild test` command với proper scheme và destination

**Expected Outcome:**
- Every push/PR automatically triggers test execution
- PRs cannot be merged nếu tests fail
- Build status visible trong GitHub UI
- Confidence khi merging code changes

---

## Phase 8: Editor Mode (Traditional SQL Editor) 🎯 **LAST PHASE**

### Overview
Implement traditional SQL editor mode với single editor và result panel, cho phép user switch giữa notebook mode và editor mode. Editor mode giống các SQL editor thông thường (như DBeaver, DataGrip) với khả năng run whole file hoặc chỉ selection.

### 8.1 Core Editor Mode Implementation
- [ ] Add `ViewMode` enum (`.notebook`, `.editor`) to `NotebookViewModel`
- [ ] Add `viewMode` state property to `NotebookViewModel` (default: `.notebook`)
- [ ] Create `EditorModeView` component với single editor và result panel
  - [ ] Single SQL editor (full-width, no cells)
  - [ ] Single result panel below editor
  - [ ] Editor supports text selection
  - [ ] Result panel shows last execution result
- [ ] Update `ContentView` để conditionally render based on `viewMode`
  - [ ] If `.notebook`: show current cell-based layout
  - [ ] If `.editor`: show `EditorModeView`

### 8.2 Execution Features
- [ ] Implement "Run Selection" functionality
  - [ ] Detect selected text trong editor
  - [ ] Execute only selected SQL text (nếu có selection)
  - [ ] Show visual indicator khi có selection
- [ ] Implement "Run All" functionality trong editor mode
  - [ ] Execute entire .sql file content (all text trong editor)
  - [ ] Handle multiple statements (split by semicolon or execute as batch)
- [ ] Add execution buttons trong editor mode
  - [ ] "Run Selection" button (enabled khi có selection)
  - [ ] "Run All" button (always enabled)
  - [ ] Keyboard shortcuts: `Cmd+Enter` (run selection/all), `Cmd+Shift+Enter` (run all)

### 8.3 Mode Switching UI
- [ ] Add mode toggle button trong header
  - [ ] Icon: `square.split.2x1` (notebook) / `doc.text` (editor)
  - [ ] Tooltip: "Switch to Editor Mode" / "Switch to Notebook Mode"
- [ ] Add visual indicator trong header showing current mode
- [ ] Add keyboard shortcut để toggle mode (e.g., `Cmd+Shift+E`)
- [ ] Persist view mode preference trong `NotebookSettings`

### 8.4 Sidebar Integration
- [ ] Preserve left sidebar functionality trong editor mode
  - [ ] Table list vẫn hoạt động
  - [ ] Click table/column name inserts vào editor tại cursor position
  - [ ] Cell value editing vẫn available (nếu có result selected)
- [ ] Preserve right sidebar functionality trong editor mode
  - [ ] Cell info viewer (khi click vào result cell)
  - [ ] Connection details
  - [ ] Settings panel

### 8.5 Data Conversion
- [ ] Handle file content loading vào editor mode
  - [ ] Khi switch từ notebook → editor: concatenate all cells content
  - [ ] Join cells với newline hoặc separator
  - [ ] Preserve cell order
- [ ] Handle saving từ editor mode back to notebook mode
  - [ ] Option 1: Split by SQL statements (semicolon-separated)
  - [ ] Option 2: Preserve as single cell
  - [ ] Let user choose strategy hoặc auto-detect
- [ ] Preserve document state khi switching modes
- [ ] Handle unsaved changes warning khi switching modes

### 8.6 Testing & Polish
- [ ] Ensure editor mode works với existing connection system
- [ ] Test mode switching preserves connection state
- [ ] Test mode switching preserves document state
- [ ] Test "Run Selection" với various SQL statements
- [ ] Test "Run All" với multiple statements
- [ ] Test sidebar interactions trong editor mode
- [ ] Test keyboard shortcuts trong editor mode
- [ ] Test data conversion (notebook ↔ editor)
- [ ] Ensure editor mode works với all existing features

---

## Recent Completions (Dec 2025)

### Left Sidebar - Database Structure ✅
- ✅ Implemented `LeftSidebarView` with tree view for tables and columns
- ✅ Added expand/collapse functionality for tables
- ✅ Click to insert table/column names into SQL editor
- ✅ Auto-load schema when connection is established
- ✅ Refresh button to reload schema
- ✅ Toggle button in header with `Cmd+Shift+L` shortcut
- ✅ Empty states and loading states
- ✅ Row count display for each table
- ✅ Primary key indicators on columns

### SSL Connection Enhancement ✅
- ✅ Added connection string input mode with auto-parsing
- ✅ Added SSL mode picker for connection string mode
- ✅ Implemented smart cloud database detection (Supabase, AWS, Azure, GCP)
- ✅ Fixed SSL mode mapping (.require now properly uses .require TLS config)
- ✅ Fixed certificate verification for cloud databases (.none for .require mode)
- ✅ Tested successfully with Supabase pooler connections

---

## Implementation Plan: Left Sidebar - Database Structure

### Overview
Thêm left sidebar để hiển thị database structure dưới dạng tree view, giúp user dễ dàng xem tables và columns, và có thể click để insert tên vào SQL editor.

### Technical Approach

#### 1. Database Schema Models
```swift
struct DatabaseTable: Identifiable {
  let id = UUID()
  let schema: String
  let name: String
  var columns: [DatabaseColumn] = []
  var isExpanded: Bool = false
}

struct DatabaseColumn: Identifiable {
  let id = UUID()
  let name: String
  let type: String
  let isNullable: Bool
  let isPrimaryKey: Bool
}
```

#### 2. DatabaseConnectionManager Extensions
- `func fetchTables() async throws -> [DatabaseTable]`
  - Query: `SELECT table_schema, table_name FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema') ORDER BY table_schema, table_name`
- `func fetchColumns(tableSchema: String, tableName: String) async throws -> [DatabaseColumn]`
  - Query: `SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2 ORDER BY ordinal_position`

#### 3. NotebookViewModel Updates
- Add `var isLeftSidebarVisible: Bool = false`
- Add `var databaseTables: [DatabaseTable] = []`
- Add `var isLoadingSchema: Bool = false`
- Add `func loadDatabaseSchema() async`
- Add `func toggleLeftSidebar()`
- Auto-call `loadDatabaseSchema()` when connection state changes to `.connected`

#### 4. LeftSidebarView Component
- Similar structure to `RightSidebarView`
- Header với title "Database" và close button
- ScrollView chứa tree view
- Empty state khi chưa connected
- Loading state khi đang fetch schema
- Tree view với:
  - Table rows (collapsible)
  - Column rows (nested under tables)
  - Icons: `tablecells` for tables, `textformat.123` for columns
  - Click handler để insert name vào selected cell

#### 5. ContentView Updates
- Add left sidebar vào HStack layout:
  ```
  HStack {
    if viewModel.isLeftSidebarVisible {
      LeftSidebarView(viewModel: viewModel)
    }
    mainContent
    if viewModel.isRightSidebarVisible {
      RightSidebarView(viewModel: viewModel)
    }
  }
  ```

#### 6. HeaderView Updates
- Add toggle button cho left sidebar (icon: `sidebar.left`)
- Add keyboard shortcut `Cmd+Shift+L` để toggle

### SQL Queries for Schema

**Tables Query:**
```sql
SELECT 
  table_schema,
  table_name
FROM information_schema.tables
WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND table_type = 'BASE TABLE'
ORDER BY table_schema, table_name;
```

**Columns Query:**
```sql
SELECT 
  column_name,
  data_type,
  is_nullable,
  column_default
FROM information_schema.columns
WHERE table_schema = $1
  AND table_name = $2
ORDER BY ordinal_position;
```

### User Experience Flow
1. User connects to database
2. Schema tự động load và hiển thị trong left sidebar
3. User có thể expand/collapse tables để xem columns
4. Click vào table/column name sẽ insert vào selected cell tại cursor position
5. User có thể refresh schema bằng button trong sidebar header
6. Sidebar có thể toggle on/off bằng button hoặc keyboard shortcut

---

## Next Priorities

### 🔒 HIGH PRIORITY: Phase 6 - Security & Safety Features
**Status:** IN PROGRESS ⚠️
**Priority:** HIGH (Critical for production use, prevent data loss and credential leaks)

**COMPLETED SO FAR:**
- ✅ Credentials security (6.0.1) - Passwords stored in Keychain, not in files/UserDefaults

**CRITICAL ISSUES TO ADDRESS:**
1. **Query Execution Security (6.0.3)** - Add confirmation dialogs for destructive operations (DROP, TRUNCATE, DELETE without WHERE)
2. **Read-only Mode (6.0.3)** - Add option to prevent accidental modifications
3. **Transaction Management (6.0.3, 6.0.4)** - Wrap modifications in transactions with auto-rollback
4. **SQL Injection Protection (6.0.3)** - Review and improve query sanitization
5. **Connection Security (6.0.2)** - Fix certificate verification warning for `.require` mode
6. **Inline Edit Safety (6.0.4)** - Add confirmation for UPDATE operations

**IMMEDIATE NEXT STEP:**
Implement **6.0.3 - Confirmation dialogs for destructive operations** to prevent accidental data loss.

Xem chi tiết implementation plan ở "Phase 6: Security & Safety Features" section bên dưới.

---

### ⭐ CURRENT TOP PRIORITY: Phase 7 - Testing Suite
**Status:** IN PROGRESS ✅
**Priority:** CRITICAL (Foundation for quality assurance and preventing regressions)

**COMPLETED SO FAR:**
- ✅ Test targets setup (7.1) - Unit Test & UI Test targets created
- ✅ Data Models tests (7.2) - SQLNotebook, NotebookCell, CellValue, ConnectionConfig, NotebookMetadata, NotebookSettings
- ✅ Utilities tests (7.3) - SQLSyntaxHighlighter comprehensive tests, CellValue conversions
- ✅ ViewModel tests (7.5) - Cell management, selection, sidebar toggles, clear outputs
- ✅ Query LIMIT handling tests (7.7) - DatabaseQueryExecutionTests.swift với comprehensive LIMIT logic tests

**REMAINING TASKS:**
1. **GitHub Actions CI/CD Setup (Test Infrastructure)** ⭐ **IMMEDIATE NEXT STEP**
   - Set up automated test execution on every push/PR
   - Ensure all tests pass before merging
   - Build verification
2. **Document Operations tests (7.4)** - SQLNotebookDocument read/write operations
3. **Integration Tests (7.6, 7.7, 7.8)** - Database connection, query execution, schema loading
4. **UI Tests (7.9, 7.10, 7.11, 7.12)** - Basic flows, query execution, connection flow, document persistence
5. **Test Infrastructure (remaining)** - Mock DatabaseConnectionManager, test helpers, sample data

**IMMEDIATE NEXT STEP:**
Set up **GitHub Actions CI/CD workflow** để automatically run all tests trên mỗi push và pull request, đảm bảo tất cả test cases pass trước khi merge code.

Xem chi tiết implementation plan ở "Phase 7: Testing Suite" section bên dưới.

---

### After Testing: Phase 4 Completion
1. **Theme Toggle** (4.13) - Toggle dark/light theme for the app
2. **Result Show/Hide** (4.8) - Toggle button to collapse/expand query results
3. **Context Menu Copy** (4.5) - Add "Copy" menu item for cell content
4. **Comment/Uncomment** (4.6) - `Cmd+/` for SQL line commenting
5. **Drag and Drop** (4.4) - Cell reordering with drag handles
6. **Save Prompt** (4.7) - Prompt to save on close if unsaved
7. **File Optimization** (4.11) - Optimize .sqlnb file when it's large
8. **Logging System** (4.12) - Centralized logging with send-to-developer option

### Then: Phase 5 Advanced Features
1. **Schema Visualizer** (5.7) - Visual graph of tables and relationships ⭐ NEW
2. **AI-Powered Natural Language Query** (5.6) - Using local model only
3. **Tabs Support** (5.5) - Multiple database connections per notebook (like VSCode)
4. **Query History** (5.1) - Store and re-run past queries
5. **Export Results** (5.2) - CSV export functionality
6. **Multiple Database Support** (5.3) - SQLite, MySQL

### Finally: Phase 8 - Editor Mode 🎯
**Status:** NOT STARTED
**Priority:** LAST PHASE (Implement after all other features are complete)

**OVERVIEW:**
Traditional SQL editor mode với single editor và result panel, cho phép user switch giữa notebook mode và editor mode. Editor mode giống các SQL editor thông thường với khả năng run whole file hoặc chỉ selection.

**TASKS:**
- Core implementation (7.1) - ViewMode enum, EditorModeView component
- Execution features (7.2) - Run Selection, Run All
- Mode switching UI (7.3) - Toggle button, keyboard shortcuts
- Sidebar integration (7.4) - Preserve left/right sidebar functionality
- Data conversion (7.5) - Notebook ↔ Editor content conversion
- Testing & polish (7.6) - Comprehensive testing và integration

Xem chi tiết ở "Phase 8: Editor Mode" section bên dưới.

---

## Definition of Done

Each task is considered complete when:
1. Feature is implemented according to PROMPT.md specifications
2. Code follows Swift/SwiftUI best practices
3. Relevant tests are written and passing
4. Feature works in both light and dark mode
5. No compiler warnings or runtime errors
6. Code is reviewed and committed