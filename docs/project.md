# macOS SQL Notebook Application - Development Prompt

## Project Overview

Build a native macOS application using Swift and SwiftUI that functions as an interactive SQL notebook, similar to Jupyter Notebook but specifically designed for SQL queries. The app should allow users to write, execute, and document SQL queries in a cell-based interface with persistent results.

For implementation phases and task breakdown, see **[TODO.md](./TODO.md)**.

---

## Technical Stack

- **Language:** Swift 6+ (latest version)
- **UI Framework:** SwiftUI Latest version.
- **Target:** macOS 16.0+
- **Architecture:** MVVM with Observable macro
- **Database Connectivity:** PostgreSQL via [PostgresNIO](https://github.com/vapor/postgres-nio) or SQLite via native Swift APIs
- **Persistence:** Codable documents saved as `.sqlnb` JSON files

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
   var cellType: CellType // .sql or .markdown
   var content: String
   var executionCount: Int? // nil if never run
   var result: CellResult?
   var isRunning: Bool = false
}

enum CellType: String, Codable {
   case sql
   case markdown
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
   var password: String // Consider using Keychain for production
   var sslMode: SSLMode
}

struct NotebookMetadata: Codable {
   var createdAt: Date
   var modifiedAt: Date
   var title: String
}
````

### View Models
````swift
@Observable
class NotebookViewModel {
   var notebook: SQLNotebook
   var connectionState: ConnectionState = .disconnected
   var selectedCellId: UUID?
   var rightSidebarContent: SidebarContent?
   var isRightSidebarVisible: Bool = false
   
   // Methods
   func addCell(type: CellType, after cellId: UUID?)
   func deleteCell(id: UUID)
   func runCell(id: UUID) async
   func runAllCells() async
   func clearAllOutputs()
   func connect() async throws
   func disconnect()
   func moveCell(from: IndexSet, to: Int)
}

enum ConnectionState {
   case disconnected
   case connecting
   case connected(DatabaseConnection)
   case error(String)
}

enum SidebarContent {
   case jsonViewer(json: String, path: String)
   case cellInfo(CellResult)
   case connectionDetails(ConnectionConfig)
}
```

---

## UI Layout Specification

### Overall Structure
```
┌─────────────────────────────────────────────────────────────────┐
│ HEADER                                                          │
├───────────────────────────────────────────┬─────────────────────┤
│                                           │                     │
│                                           │   RIGHT SIDEBAR     │
│              MAIN CONTENT                 │   (collapsible)     │
│              (scrollable)                 │                     │
│                                           │                     │
├───────────────────────────────────────────┴─────────────────────┤
│ FOOTER                                                          │
└─────────────────────────────────────────────────────────────────┘
```

### 1. Header Bar

**Layout:** Horizontal stack with leading and trailing groups

**Leading Group (left-aligned):**
- **"+ Code" Button:** Adds a new SQL cell below the currently selected cell (or at the end if none selected)
- **"+ Markdown" Button:** Adds a new Markdown cell
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
│ [1]  │  │         (SQL or Markdown)                       ││
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
- **Markdown Cells:**
 - When editing: Plain text editor with markdown syntax
 - When not editing: Rendered markdown view
 - Double-click to edit, click outside or Cmd+Enter to render

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

### 3. Right Sidebar

**Behavior:**
- Hidden by default (width: 0)
- Slides in from right when activated
- Width when visible: 320pt
- Can be manually toggled with a button or keyboard shortcut (`Cmd+Shift+R`)

**Auto-shows when:**
- User clicks on a result table cell
- User clicks on specific elements that have detailed info
- User explicitly toggles it

**Content Modes:**

**a) JSON Viewer Mode:**
- Triggered when clicking a JSON/JSONB cell in results
- Header: "JSON Viewer" with path info (e.g., "Row 5, Column 'metadata'")
- Features:
 - Collapsible tree view
 - Syntax highlighting
 - Copy button
 - Pretty-print toggle
 - Search within JSON

**b) Cell Value Detail Mode:**
- Triggered when clicking any result cell
- Shows:
 - Full value (not truncated)
 - Data type
 - Byte size (if relevant)
 - Copy button
 - Format options (for dates, numbers)

**c) Connection Info Mode:**
- Triggered when clicking connection status
- Shows all connection details (except password)
- Connection statistics if available

**Close Button:** Top-right corner of sidebar

### 4. Footer Bar

**Layout:** Horizontal stack with sections

**Content:**
- **Connection Status:** Icon + "Connected to {database}@{host}" or "Not connected"
- **Spacer**
- **Notebook Stats:** "12 cells | 8 executed"
- **Last Saved:** "Saved 2 minutes ago" or "Unsaved changes"

**Styling:**
- Height: 24pt
- Background: Same as header
- Smaller font size
- Muted colors
- Divider line at top

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

### Connection Manager
````swift
actor DatabaseConnectionManager {
   private var connection: PostgresConnection?
   
   func connect(config: ConnectionConfig) async throws
   func disconnect() async
   func execute(query: String) async throws -> QueryResult
   func testConnection() async throws -> Bool
}

struct QueryResult {
   let columns: [ColumnInfo]
   let rows: [[CellValue]]
   let executionTime: TimeInterval
   let affectedRows: Int?
}
````

### Supported Operations

- SELECT queries: Return result set
- INSERT/UPDATE/DELETE: Return affected row count
- DDL statements: Return success/failure
- Multiple statements: Execute sequentially, return last result (or all results)

### Error Handling

Display SQL errors inline below the cell:
- Error message from database
- Position in query if available
- Suggestion for common errors (optional)

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+N` | New notebook |
| `Cmd+O` | Open notebook |
| `Cmd+S` | Save notebook |
| `Cmd+Enter` | Run selected cell |
| `Shift+Enter` | Run cell and move to next |
| `Cmd+Shift+Enter` | Run all cells |
| `Cmd+B` | Add code cell below |
| `Cmd+M` | Add markdown cell below |
| `Cmd+Backspace` | Delete selected cell |
| `Cmd+D` | Duplicate cell |
| `Cmd+Shift+R` | Toggle right sidebar |
| `Cmd+/` | Comment/uncomment line in SQL |
| `Escape` | Deselect cell / Close sidebar |
| `Up/Down` | Navigate between cells |

---

## Testing Considerations

- Unit tests for data models and serialization
- Unit tests for SQL syntax tokenizer
- Integration tests for database operations
- UI tests for critical user flows

---

## Notes for Implementation

1. **Performance:** Use `LazyVStack` for cell list to handle notebooks with many cells
2. **Memory:** For large result sets, consider pagination or virtual scrolling
3. **Security:** Store passwords in Keychain, not in document files
4. **Undo/Redo:** Leverage SwiftUI's built-in undo manager for document changes
5. **Accessibility:** Ensure all interactive elements have proper labels