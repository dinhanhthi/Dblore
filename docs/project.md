# macOS SQL Notebook Application - Development Prompt

## Project Overview

Build a native macOS application using Swift and SwiftUI that functions as an interactive SQL notebook, similar to Jupyter Notebook but specifically designed for SQL queries. The app should allow users to write, execute, and document SQL queries in a cell-based interface with persistent results.

**Current Status:** The application is functional with core features complete (Phases 1-3), most polish features implemented (Phase 4), and partial security features (Phase 6). The app supports PostgreSQL with SSL/TLS, includes a database schema browser, inline result editing, and dark/light theme support.

For implementation phases and task breakdown, see **[TODO.md](./TODO.md)**.

---

## Technical Stack

- **Language:** Swift 6+ with strict concurrency checking
- **UI Framework:** SwiftUI (latest version)
- **Target:** macOS 15.0+ (Sequoia)
- **Architecture:** MVVM with Observable macro (@Observable, not ObservableObject)
- **Database Connectivity:** PostgreSQL via [PostgresNIO](https://github.com/vapor/postgres-nio) with SSL/TLS support
- **Persistence:** Codable documents saved as `.sqlnb` JSON files
- **State Management:** AppSettings (UserDefaults) for global preferences, UndoManager for document history

---

## Application Architecture

### Data Models
````swift
// Core document model
struct SQLNotebook: Codable, Identifiable {
   let id: UUID
   var cells: [NotebookCell]
   var metadata: NotebookMetadata
   var connectionConfig: ConnectionConfig?
}

struct NotebookCell: Codable, Identifiable {
   let id: UUID
   var cellType: CellType // .sql only
   var content: String
   var executionCount: Int? // nil if never run
   var result: CellResult?
   var isRunning: Bool = false
}

enum CellType: String, Codable {
   case sql
}

struct CellResult: Codable {
   let columns: [ColumnInfo]
   let rows: [[CellValue]]
   let executionTime: TimeInterval
   let rowCount: Int
   let timestamp: Date
}

struct ColumnInfo: Codable {
   let name: String
   let type: String // e.g., "VARCHAR", "INTEGER", "JSONB"
}

enum CellValue: Codable {
   case string(String)
   case int(Int)
   case double(Double)
   case bool(Bool)
   case null
   case json(String) // Store JSON as string for display
   case date(Date)
   case data(Data) // For binary types
}

struct ConnectionConfig: Codable {
   var host: String
   var port: Int
   var database: String
   var username: String
   var password: String // NOTE: Should use Keychain for production (TODO)
   var sslMode: SSLMode // Supports: disable, allow, prefer, require, verifyCa, verifyFull
   var databaseType: DatabaseType // Currently: .postgresql only

   // Smart cloud database detection
   var isCloudDatabase: Bool // Auto-detected from host (Supabase, AWS, Azure, GCP)
}

struct NotebookMetadata: Codable {
   var createdAt: Date
   var modifiedAt: Date
   var title: String
}
````

### View Models
````swift
@MainActor
@Observable
class NotebookViewModel {
   var notebook: SQLNotebook
   var connectionState: ConnectionState = .disconnected
   var selectedCellId: UUID?
   var rightSidebarContent: SidebarContent?
   var isRightSidebarVisible: Bool = false
   var executionCounter: Int = 0

   // Left sidebar (database schema)
   var isLeftSidebarVisible: Bool = false
   var databaseTables: [DatabaseTable] = []
   var isLoadingSchema: Bool = false

   // Toast notifications
   var currentToast: ToastMessage?

   // Database connection manager (actor)
   let connectionManager = DatabaseConnectionManager()

   // Undo/Redo support
   let undoManager = UndoManager()

   // Methods
   func addCell(type: CellType, after cellId: UUID?)
   func deleteCell(id: UUID)
   func runCell(id: UUID) async
   func runAllCells() async
   func clearAllOutputs()
   func connect() async throws
   func disconnect()
   func moveCell(from: IndexSet, to: Int)
   func showToast(_ message: String, type: ToastMessage.ToastType)
   func loadDatabaseSchema() async
   func updateCellValue(...) async throws // Inline editing
}

enum ConnectionState {
   case disconnected
   case connecting
   case connected(DatabaseConnection)
   case error(String)
}

enum SidebarContent: Equatable {
   case jsonViewer(json: String, path: String)
   case cellInfo(columnName: String, columnType: String, value: CellValue,
                 tableName: String?, rowData: [String: CellValue]?,
                 primaryKeyColumns: [String], rowIdentifier: CellValue?, cellId: UUID?)
   case connectionDetails
   case connectionForm
   case settings
}

@MainActor
@Observable
class AppSettings {
   static let shared = AppSettings()

   var maxResultHeight: CGFloat = 500.0
   var includeResultsOnSave: Bool = true
   var maxRowLimit: Int = 50 // Max 200, prevents memory issues
   var isLeftSidebarVisible: Bool = false
   var themePreference: ThemePreference = .dark // .system, .light, .dark
}
```

---

## UI Layout Specification

### Overall Structure
```
┌─────────────────────────────────────────────────────────────────────────┐
│ HEADER (44pt)                                                           │
├──────────────┬──────────────────────────────────────┬───────────────────┤
│              │                                      │                   │
│ LEFT SIDEBAR │                                      │  RIGHT SIDEBAR    │
│ (collapsible)│         MAIN CONTENT                 │  (collapsible)    │
│ 240pt width  │         (scrollable)                 │  320pt width      │
│              │                                      │                   │
│ Database     │                                      │ Connection/       │
│ Schema       │                                      │ Settings/         │
│ Tree View    │                                      │ JSON Viewer/      │
│              │                                      │ Cell Info         │
├──────────────┴──────────────────────────────────────┴───────────────────┤
│ FOOTER (24pt)                                                           │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1. Header Bar

**Layout:** Horizontal stack with leading and trailing groups

**Leading Group (left-aligned):**
- **"+ Code" Button:** Adds a new SQL cell below the currently selected cell (or at the end if none selected)
- **"Run All" Button:** Executes all SQL cells sequentially from top to bottom
- **"Clear All Outputs" Button:** Clears all cell results but keeps the code

**Trailing Group (right-aligned):**
- **Connection Button:** 
 - Shows "Connect" when disconnected → Opens connection sheet/popover
 - Shows "Connecting..." with spinner when connecting
 - Shows "Connected" with green indicator when connected → Click to disconnect or show connection info

**Styling:**
- Height: 44pt
- Background: Secondary system background
- Buttons: Borderless button style with SF Symbols icons
- Divider line at bottom

### 2. Main Content Area

**Container:** ScrollView with LazyVStack for performance with many cells

#### Cell Structure

Each cell is a distinct visual block:
```
┌──────┬─────────────────────────────────────────────────────┐
│      │  ┌─────────────────────────────────────────────────┐│
│ [▶]  │  │                                                 ││
│      │  │            CODE EDITOR                          ││
│ [1]  │  │              (SQL)                              ││
│      │  │                                                 ││
│      │  └─────────────────────────────────────────────────┘│
├──────┴─────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────┐   │
│  │              RESULT TABLE                           │   │
│  │         (max-height with scroll)                    │   │
│  └─────────────────────────────────────────────────────┘   │
│  Rows: 150 | Execution time: 0.034s | 2024-01-15 14:32    │
└────────────────────────────────────────────────────────────┘
````

**Left Sidebar of Cell (width: 48pt):**
- **Play/Run Button:** 
 - Default: Play icon (SF Symbol: `play.fill`)
 - Running: ProgressView (circular spinner)
 - Position: Top of the sidebar, vertically centered with first line of code
- **Execution Count:**
 - Display format: `[1]`, `[2]`, etc.
 - Show only if cell has been executed at least once
 - Grayed out text, smaller font
 - Position: Below the play button

**Code Editor Area:**
- **SQL Cells:**
 - Syntax highlighting for SQL keywords, strings, numbers, comments
 - Monospace font (SF Mono or Menlo)
 - Line numbers on the left edge (optional, can be toggled)
 - Minimum height: 3 lines
 - Auto-expand based on content
 - Background: Slightly darker than main background

**Result Area (only visible if result exists):**
- **Container:** 
 - Max height: 300pt (configurable)
 - Overflow: Vertical scroll
 - Border: Subtle rounded border
 - Background: Slightly different from code area

- **Result Table:**
 - **Header Row:**
   - Column names in bold
   - Column types in parentheses, smaller and grayed: `id (INTEGER)`, `name (VARCHAR)`
   - Sticky header (stays visible when scrolling)
   - Resizable columns (drag handles between headers)
 - **Body Rows:**
   - Alternating row colors for readability
   - Cell values formatted by type:
     - NULL: Italic gray "NULL"
     - Strings: Regular text, truncate with ellipsis if too long
     - Numbers: Right-aligned
     - JSON/JSONB: Show `{...}` or `[...]` preview, clickable to open in sidebar
     - Dates: Formatted according to locale
   - Clickable cells: Clicking opens detailed view in right sidebar
   - Text selection enabled for copying values

- **Result Metadata Bar:**
 - Position: Below the table
 - Content: `Rows: {count} | Execution time: {time}s | {timestamp}`
 - Smaller font, muted color

**Cell Interactions:**
- Click to select (shows selection border)
- Drag handle on left for reordering
- Right-click context menu: Run, Delete, Duplicate, Move Up, Move Down, Copy, Clear Output
- Keyboard shortcuts when selected:
 - `Cmd+Enter`: Run cell
 - `Shift+Enter`: Run cell and select next
 - `Cmd+D`: Duplicate cell
 - `Backspace` (when empty): Delete cell

### 3. Left Sidebar (Database Schema) ✅ IMPLEMENTED

**Behavior:**
- Hidden by default
- Slides in from left when toggled
- Width when visible: 240pt
- Toggle with toolbar button
- State persists in AppSettings

**Features:**
- **Database Tree View:**
  - Shows all tables in connected database
  - Each table shows: name, row count, icon
  - Expandable to show columns
  - Column details: name, type, primary key indicator
- **Click to Insert:**
  - Click table name → inserts table name into focused cell
  - Click column name → inserts column name into focused cell
- **Auto-load:**
  - Schema loads automatically on successful connection
  - Refresh button to reload schema
- **Search/Filter:** (Future enhancement)

### 4. Right Sidebar

**Behavior:**
- Hidden by default (width: 0)
- Slides in from right when activated
- Width when visible: 320pt
- Can be manually toggled with a button or keyboard shortcut (`Cmd+Shift+R`)

**Auto-shows when:**
- User clicks on a result table cell
- User clicks connection button
- User clicks settings button
- User explicitly toggles it

**Content Modes:**

**a) JSON Viewer Mode:** ✅ IMPLEMENTED
- Triggered when clicking a JSON/JSONB cell in results
- Header: "JSON Viewer" with path info (e.g., "Row 5, Column 'metadata'")
- Features:
 - Collapsible tree view
 - Syntax highlighting
 - Copy button
 - Pretty-print toggle
 - Search within JSON

**b) Cell Value Detail Mode with Inline Editing:** ✅ IMPLEMENTED
- Triggered when clicking any result cell
- Shows:
 - Full value (not truncated)
 - Data type
 - Column name and table name
 - Row identifier (ctid for PostgreSQL)
 - **Editable value field:**
   - Text input for most types
   - Boolean toggle for boolean values
   - Save/Cancel buttons
 - **UPDATE query execution:**
   - Uses primary keys or ctid for WHERE clause
   - Re-runs cell query after successful update
 - Copy button
 - Format options (for dates, numbers)

**c) Connection Details Mode:** ✅ IMPLEMENTED
- Shows connection configuration
- Host, port, database, username
- SSL mode indicator
- Database type (PostgreSQL/SQLite)
- Disconnect button

**d) Connection Form Mode:** ✅ IMPLEMENTED
- Database connection configuration form
- Connection string input with auto-parsing
- Smart cloud database detection (Supabase, AWS RDS, Azure, GCP)
- SSL mode picker (6 modes)
- Test connection button
- Save and connect

**e) Settings Mode:** ✅ IMPLEMENTED
- **Appearance:**
  - Theme preference (System/Light/Dark)
- **Result Table:**
  - Max result height (200-1000pt)
  - Max row limit (1-200 rows)
  - Include results on save toggle
- **Keyboard Shortcuts:**
  - Reference list of all shortcuts
- **About:**
  - App version
  - PostgreSQL client version
  - Links to documentation
- Reset to defaults button

**Close Button:** Top-right corner of sidebar

### 5. Footer Bar ✅ IMPLEMENTED

**Layout:** Horizontal stack with sections

**Content:**
- **Connection Status:** Icon + "Connected to {database}@{host}" or "Not connected"
- **Spacer**
- **Notebook Stats:** "12 cells | 8 executed"
- **App Version:** "v1.0.0"
- **Last Saved:** "Saved 2 minutes ago" or "Unsaved changes"

**Styling:**
- Height: 24pt
- Background: Same as header
- Smaller font size
- Muted colors
- Divider line at top

### 6. Toast Notifications ✅ IMPLEMENTED

**Behavior:**
- Appears at top-center of window
- Auto-dismisses after 4 seconds
- Hover to prevent auto-dismiss
- Types: info, success, error
- Used for:
  - Connection success/failure
  - Query execution feedback
  - Value update confirmation
  - Schema reload status

---

## Design System (shadcn-inspired)

### Color Palette

Use semantic colors that adapt to light/dark mode:
````swift
extension Color {
   static let background = Color(nsColor: .windowBackgroundColor)
   static let foreground = Color(nsColor: .labelColor)
   static let muted = Color(nsColor: .secondaryLabelColor)
   static let mutedForeground = Color(nsColor: .tertiaryLabelColor)
   static let border = Color(nsColor: .separatorColor)
   static let input = Color(nsColor: .controlBackgroundColor)
   static let ring = Color.accentColor.opacity(0.5)
   
   // Semantic colors
   static let success = Color.green
   static let warning = Color.orange
   static let destructive = Color.red
}
````

### Typography
````swift
extension Font {
   static let mono = Font.system(.body, design: .monospaced)
   static let monoSmall = Font.system(.caption, design: .monospaced)
}
````

### Component Styling

**Buttons:**
- Primary: Filled background, rounded corners (8pt radius)
- Secondary: Border only, transparent background
- Ghost: No border, no background, hover shows subtle background
- All buttons: 32pt height for toolbar, subtle hover state

**Cards/Cells:**
- Background: Slightly elevated from main background
- Border: 1pt, border color
- Border radius: 8pt
- Shadow: None or very subtle

**Inputs:**
- Border: 1pt, border color
- Border radius: 6pt
- Focus ring: 2pt ring color
- Height: 36pt for standard inputs

**Tables:**
- Header: Bold, sticky, subtle background
- Rows: Alternating subtle backgrounds
- Borders: Only horizontal lines between rows
- Hover: Subtle highlight on row hover

---

## SQL Syntax Highlighting

Implement a custom `AttributedString` builder or use a library.

**Token Categories and Colors:**
````swift
enum SQLTokenType {
   case keyword    // SELECT, FROM, WHERE, etc. - Blue
   case function   // COUNT, SUM, etc. - Purple
   case string     // 'text' - Green
   case number     // 123, 45.67 - Orange
   case comment    // -- comment, /* */ - Gray
   case operator   // =, <>, AND, OR - Default
   case identifier // table/column names - Default
}
````

**Keywords to Highlight:**
- DDL: CREATE, ALTER, DROP, TABLE, INDEX, VIEW, DATABASE, SCHEMA
- DML: SELECT, INSERT, UPDATE, DELETE, FROM, WHERE, JOIN, ON, AND, OR, NOT, IN, BETWEEN, LIKE, IS, NULL, AS, ORDER, BY, GROUP, HAVING, LIMIT, OFFSET, UNION, INTERSECT, EXCEPT
- Functions: COUNT, SUM, AVG, MIN, MAX, COALESCE, NULLIF, CAST, EXTRACT, etc.
- Types: INTEGER, VARCHAR, TEXT, BOOLEAN, DATE, TIMESTAMP, JSON, JSONB, etc.

---

## Document Persistence

### File Format

Save notebooks as `.sqlnb` files (JSON format):
````json
{
 "version": "1.0",
 "id": "uuid",
 "metadata": {
   "title": "My Queries",
   "createdAt": "2024-01-15T10:00:00Z",
   "modifiedAt": "2024-01-15T14:30:00Z"
 },
 "connectionConfig": {
   "host": "localhost",
   "port": 5432,
   "database": "mydb",
   "username": "user"
 },
 "cells": [
   {
     "id": "uuid",
     "type": "sql",
     "content": "SELECT * FROM users LIMIT 10;",
     "executionCount": 1,
     "result": {
       "columns": [
         {"name": "id", "type": "INTEGER"},
         {"name": "name", "type": "VARCHAR"}
       ],
       "rows": [
         [{"int": 1}, {"string": "Alice"}],
         [{"int": 2}, {"string": "Bob"}]
       ],
       "executionTime": 0.034,
       "rowCount": 2,
       "timestamp": "2024-01-15T14:32:00Z"
     }
   }
 ]
}
````

### Document-Based App

Implement using SwiftUI's document-based app architecture:
````swift
@main
struct SQLNotebookApp: App {
   var body: some Scene {
       DocumentGroup(newDocument: SQLNotebookDocument()) { file in
           ContentView(document: file.$document)
       }
   }
}

struct SQLNotebookDocument: FileDocument {
   static var readableContentTypes: [UTType] = [.sqlNotebook]
   // Implementation...
}

extension UTType {
   static var sqlNotebook: UTType {
       UTType(exportedAs: "com.yourapp.sqlnotebook")
   }
}
````

---

## Database Connectivity

### Connection Manager ✅ IMPLEMENTED
````swift
actor DatabaseConnectionManager {
   private var connection: PostgresConnection?
   private var eventLoopGroup: EventLoopGroup?
   private var config: ConnectionConfig?

   static let defaultMaxFetchRows = 100

   // Connection Management
   func connect(config: ConnectionConfig) async throws
   func disconnect() async
   func testConnection(config: ConnectionConfig) async throws -> Bool

   // Query Execution
   func execute(query: String, maxRows: Int) async throws -> QueryResult
   func executeModifyingQuery(query: String) async throws -> ModifyQueryResult

   // Schema Operations
   func loadSchema() async throws -> [DatabaseTable]
   func getTableRowCount(tableName: String) async throws -> Int

   // Inline Editing
   func updateCellValue(
      tableName: String,
      columnName: String,
      newValue: CellValue,
      primaryKeyColumns: [String],
      rowData: [String: CellValue],
      rowIdentifier: CellValue?
   ) async throws
}

struct QueryResult {
   let columns: [ColumnInfo]
   let rows: [[CellValue]]
   let executionTime: TimeInterval
   let rowCount: Int
   let tableName: String?  // For inline editing
}

struct DatabaseTable {
   let name: String
   let rowCount: Int
   var columns: [ColumnMetadata]
}

struct ColumnMetadata {
   let name: String
   let dataType: String
   let isPrimaryKey: Bool
}
````

### SSL/TLS Support ✅ IMPLEMENTED

**Supported SSL Modes (PostgreSQL):**
- `disable`: No SSL encryption
- `allow`: Try non-SSL first, then SSL if server requires it
- `prefer`: Try SSL first, fallback to non-SSL if server doesn't support it
- `require`: Require SSL, but don't verify certificates (for cloud databases)
- `verifyCa`: Require SSL and verify CA certificate
- `verifyFull`: Require SSL and verify hostname matches certificate

**Smart Cloud Database Detection:**
- Auto-detects Supabase, AWS RDS, Azure, Google Cloud SQL
- Automatically suggests `require` mode for cloud databases
- Connection string parsing with auto-fill

**NOTE:** Certificate verification for `.require` mode currently uses `.none` to support cloud providers with custom certificates. Full verification needs improvement.

### Supported Operations ✅ IMPLEMENTED

- **SELECT queries:** Return result set with column metadata and rows
- **INSERT/UPDATE/DELETE:** Return affected row count
- **DDL statements:** Return success/failure
- **Multiple statements:** Execute sequentially, return last result
- **Row Limit Enforcement:** Configurable max rows (1-200) to prevent memory exhaustion
- **Query Modification Detection:** Automatically detects UPDATE/DELETE/INSERT queries

### Error Handling ✅ IMPLEMENTED

Display SQL errors inline below the cell:
- Error message from database (formatted PostgreSQL errors)
- Query execution time before error
- User-friendly error display
- Toast notification for critical errors

---

## Keyboard Shortcuts ✅ IMPLEMENTED

| Shortcut | Action | Status |
|----------|--------|--------|
| `Cmd+N` | New notebook | ✅ |
| `Cmd+O` | Open notebook | ✅ |
| `Cmd+S` | Save notebook | ✅ |
| `Cmd+Enter` | Run selected cell | ✅ |
| `Shift+Enter` | Run cell and move to next | ✅ |
| `Option+Enter` | Run cell and add new cell below | ✅ |
| `Cmd+Shift+Enter` | Run all cells | ✅ |
| `Cmd+B` | Add code cell below | ✅ |
| `Cmd+Delete` | Delete selected cell | ✅ |
| `Cmd+D` | Duplicate cell | ✅ |
| `Cmd+Shift+J` | New SQL file | ✅ |
| `Cmd+Shift+S` | Save As | ✅ |
| `Cmd+,` | Toggle right sidebar | ✅ |
| `Cmd+/` | Comment/uncomment line in SQL | ⏳ TODO |
| `Escape` | Deselect cell / Close sidebar | ✅ |
| `Up/Down` | Navigate between cells | ✅ |
| `Cmd+Z` | Undo | ✅ |
| `Cmd+Shift+Z` | Redo | ✅ |

---

## Testing Considerations ✅ MOSTLY IMPLEMENTED

### Test Infrastructure ✅
- **Unit Test target:** SQLNotebookTests
- **UI Test target:** SQLNotebookUITests
- **CI/CD:** GitHub Actions workflow configured
- **Test Database:** Docker PostgreSQL setup for integration tests
- **Test Data:** Initialization scripts with sample data

### Implemented Tests ✅
- **Data Models:** Serialization/deserialization tests for `SQLNotebook`, `NotebookCell`, `CellValue`
- **SQL Syntax Highlighter:** Token parsing and highlighting tests
- **ViewModel Logic:** Basic functionality tests

### Pending Tests ⏳
- **Document Operations:** Round-trip save/load tests
- **Database Integration:** Connection, query execution, schema loading tests
- **Type Mapping:** JSON/JSONB, DATE, TIMESTAMP type tests
- **UI Workflows:** End-to-end user flow tests

---

## Implementation Notes & Current Status

### Completed Features ✅

1. **Core Functionality (Phase 1-3):**
   - Cell-based SQL notebook with syntax highlighting
   - PostgreSQL database connectivity with SSL/TLS support
   - Query execution with result display
   - Document persistence as `.sqlnb` JSON files
   - Undo/Redo support

2. **Polish Features (Phase 4 - Mostly Complete):**
   - Header actions: Add cell, Run all, Clear outputs
   - Confirmation dialog for Run All
   - Keyboard shortcuts (all except Cmd+/)
   - Auto-save with debounce
   - Footer with connection status and stats
   - **Theme Toggle:** System/Light/Dark mode preference ✅

3. **Security Features (Phase 6 - Partial):**
   - SSL/TLS connection modes (all 6 PostgreSQL modes)
   - Smart cloud database detection
   - Row limit enforcement (1-200 rows)
   - Query modification detection
   - Primary key tracking for UPDATE operations
   - Boolean toggle UI for value editing

4. **Advanced UI Features:**
   - **Left Sidebar:** Database schema tree view with click-to-insert
   - **Right Sidebar:** Connection form, Settings, JSON viewer, Cell info with inline editing
   - **Toast Notifications:** Auto-dismissing notifications with hover support
   - **Inline Editing:** Edit result cell values directly, execute UPDATE queries

### In Progress / TODO ⏳

1. **Phase 4 Remaining:**
   - Cell execution queue system
   - Drag and drop reordering
   - Comment/uncomment (Cmd+/)
   - Result show/hide toggle
   - Save prompt on close
   - File optimization for large files
   - Logging system

2. **Phase 6 Remaining:**
   - Value format validation (integer, uuid, jsonb, date, timestamp)
   - Confirmation dialogs for destructive operations
   - Read-only mode
   - Connection retry logic with exponential backoff
   - Certificate verification fix for `.require` mode

3. **Phase 7 Remaining:**
   - Integration tests for database operations
   - UI workflow tests

4. **Phase 5 (Advanced Features - Not Started):**
   - Query history
   - Export to CSV
   - Multiple database support (SQLite, MySQL)
   - Query autocomplete
   - Tabs support for multiple connections
   - AI-powered natural language queries (local model)
   - Schema visualizer

5. **Phase 8 (Editor Mode - Not Started):**
   - Traditional SQL editor mode with single editor
   - Run selection functionality
   - Mode switching UI

### Technical Implementation Details

1. **Performance:**
   - ✅ `LazyVStack` used for cell list
   - ✅ Row limit enforcement (configurable 1-200)
   - ⏳ Pagination for very large result sets (future)

2. **Memory Management:**
   - ✅ Configurable max rows to prevent memory exhaustion
   - ✅ Actor-based connection manager for thread safety
   - ⏳ Virtual scrolling for large result sets (future)

3. **Security:**
   - ⏳ **TODO:** Store passwords in Keychain (currently in document files - NOT SECURE)
   - ✅ SSL/TLS support with multiple modes
   - ⏳ Value format validation before UPDATE queries

4. **Undo/Redo:**
   - ✅ UndoManager integrated for cell operations
   - ✅ Document dirty state tracking

5. **Accessibility:**
   - ✅ Proper labels for most interactive elements
   - ⏳ Full accessibility audit needed

### Known Issues & TODOs from Code

1. **Keychain Storage** (`DataModelTests.swift:301`): Passwords should use Keychain, not JSON files
2. **Primary Key Detection** (`DatabaseConnectionManager+Schema.swift:101`): Currently hardcoded to false, needs proper detection
3. **User Notifications** (`NotebookViewModel+Sidebar.swift`): Add alerts for value editing success/failure
4. **CommandTag from PostgresNIO** (`DatabaseConnectionManager+QueryExecution.swift`): Waiting for library to expose commandTag
5. **Certificate Verification** (`DatabaseConnectionManager.swift:52`): `.require` mode uses `.none` verification, needs improvement

### Architecture Highlights

- **Swift 6 Concurrency:** async/await, actors for database operations
- **@Observable Macro:** Modern state management (not ObservableObject)
- **Actor-Based Database Manager:** Thread-safe connection handling
- **Document-Based App:** Native macOS document architecture
- **AppSettings:** Global preferences via UserDefaults
- **MVVM Pattern:** Clear separation of concerns
- **Design System:** Shadcn-inspired, adaptive to light/dark mode