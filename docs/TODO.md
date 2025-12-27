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
- [x] Create Settings view in right sidebar

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

### Recommended: Phase 4 Completion
1. **Result Show/Hide** (4.8) - Toggle button to collapse/expand query results
2. **Context Menu Copy** (4.5) - Add "Copy" menu item for cell content
3. **Comment/Uncomment** (4.6) - `Cmd+/` for SQL line commenting
4. **Drag and Drop** (4.4) - Cell reordering with drag handles
5. **Save Prompt** (4.7) - Prompt to save on close if unsaved

### Then: Phase 5 Advanced Features
1. **Tabs Support** (5.5) - Multiple database connections per notebook (like VSCode) ⭐ NEW
2. **Query History** (5.1) - Store and re-run past queries
3. **Export Results** (5.2) - CSV export functionality
4. **Multiple Database Support** (5.3) - SQLite, MySQL

---

## Definition of Done

Each task is considered complete when:
1. Feature is implemented according to PROMPT.md specifications
2. Code follows Swift/SwiftUI best practices
3. Relevant tests are written and passing
4. Feature works in both light and dark mode
5. No compiler warnings or runtime errors
6. Code is reviewed and committed