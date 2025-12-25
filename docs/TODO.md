# TODO.md - SQL Notebook Implementation Tasks

This document outlines the implementation phases and specific tasks for building the SQL Notebook application. Reference the main **[project.md](./project.md)** for detailed specifications.

## 📊 Current Status

- ✅ **Phase 1: Core Structure** - COMPLETE
- ✅ **Phase 2: Cell Editor** - COMPLETE  
- ✅ **Phase 3: Database Integration** - **COMPLETE!** 🎉
- ✅ **Phase 4: Polish** - MOSTLY COMPLETE (minor features pending)
- ⏳ **Phase 5: Advanced Features** - NOT STARTED

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

### 4.2 Header Actions
- [x] Wire up "+ Code" button
- [x] Implement "Run All" functionality (sequential execution)
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

### 4.7 Auto-save & Document State
- [x] Implement auto-save on changes (debounced)
- [x] Track document dirty state
- [x] Show unsaved indicator in footer
- [ ] Prompt to save on close if unsaved

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

---

## Testing Checklist ❌ (Not implemented yet)

### Unit Tests
- [ ] Data model encoding/decoding
- [ ] SQL tokenizer correctness
- [ ] CellValue type conversions
- [ ] Document read/write operations

### Integration Tests
- [ ] Database connection lifecycle
- [ ] Query execution and result parsing
- [ ] Error handling for invalid queries

### UI Tests
- [ ] Create new notebook flow
- [ ] Add and delete cells
- [ ] Run query and verify results display
- [ ] Save and reopen notebook with results
- [ ] Keyboard navigation

---

## Recent Completions (Dec 2025)

### SSL Connection Enhancement ✅
- ✅ Added connection string input mode with auto-parsing
- ✅ Added SSL mode picker for connection string mode
- ✅ Implemented smart cloud database detection (Supabase, AWS, Azure, GCP)
- ✅ Fixed SSL mode mapping (.require now properly uses .require TLS config)
- ✅ Fixed certificate verification for cloud databases (.none for .require mode)
- ✅ Tested successfully with Supabase pooler connections

---

## Next Priorities

### Recommended: Phase 4 Completion
1. **Drag and Drop** (4.4) - Cell reordering with drag handles
2. **Comment/Uncomment** (4.6) - `Cmd+/` for SQL line commenting
3. **Save Prompt** (4.7) - Prompt to save on close if unsaved

### Then: Phase 5 Advanced Features
1. **Query History** - Store and re-run past queries
2. **Export Results** - CSV export functionality
3. **Multiple Database Support** - SQLite, MySQL

---

## Definition of Done

Each task is considered complete when:
1. Feature is implemented according to PROMPT.md specifications
2. Code follows Swift/SwiftUI best practices
3. Relevant tests are written and passing
4. Feature works in both light and dark mode
5. No compiler warnings or runtime errors
6. Code is reviewed and committed