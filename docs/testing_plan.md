# Testing Plan for SQLNotebook

List of all test cases to implement for SQLNotebook project, organized by categories with todo-style checklist.

---

## Data Models

### SQLNotebook Model
- [x] Encode and decode notebook with cells — DataModelTests: `sqlNotebookEncodingDecoding()`
- [x] Encode and decode notebook with empty cells — DataModelTests: `sqlNotebookWithEmptyCells()`
- [x] Round-trip encoding/decoding preserves data — DataModelTests: `sqlNotebookEncodingDecoding()`
- [x] Notebook with connection config (password should not be encoded) — DataModelTests: `connectionConfigEncodingDoesNotIncludePassword()`
- [x] Notebook with multiple cells and results — DataModelTests: `sqlNotebookEncodingDecoding()`
- [x] Notebook encoding performance with 100+ cells — DataModelTests: `notebookEncodingPerformance()`

### NotebookCell Model
- [x] Encode and decode cell with all properties — DataModelTests: `notebookCellEncodingDecoding()`
- [x] Cell with result data — DataModelTests: `notebookCellWithResults()`
- [x] Cell with execution count — DataModelTests: `notebookCellEncodingDecoding()`
- [ ] Cell with running state
- [x] Cell with nil result — DataModelTests: `notebookCellEncodingDecoding()`
- [ ] Cell content updates preserve other properties

### CellValue Enum
- [x] Encode/decode `.string` case — DataModelTests: `cellValueStringEncodingDecoding()`
- [x] Encode/decode `.int` case — DataModelTests: `cellValueIntEncodingDecoding()`
- [x] Encode/decode `.double` case — DataModelTests: `cellValueDoubleEncodingDecoding()`
- [x] Encode/decode `.bool` case — DataModelTests: `cellValueBoolEncodingDecoding()`
- [x] Encode/decode `.null` case — DataModelTests: `cellValueNullEncodingDecoding()`
- [x] Encode/decode `.json` case — DataModelTests: `cellValueJSONEncodingDecoding()`
- [ ] Encode/decode `.date` case
- [ ] Encode/decode `.data` case
- [x] `displayString` property for all types — DataModelTests: `cellValueDisplayStrings()`
- [ ] `fullString` property for all types
- [x] `isNull` computed property — DataModelTests: `cellValueIsNull()`
- [x] `isJSON` computed property — DataModelTests: `cellValueIsJSON()`
- [ ] Long string truncation in `displayString`
- [ ] JSON formatting in display

### CellResult Model
- [x] Result with columns and rows — DataModelTests: `notebookCellWithResults()`
- [x] Result with execution time — DataModelTests: `notebookCellWithResults()`
- [x] Result with timestamp — DataModelTests: `notebookCellWithResults()`
- [ ] Result with error message
- [ ] Result with null values
- [ ] Result with mixed data types
- [ ] Empty result set (0 rows)
- [ ] Large result set encoding

### ConnectionConfig Model
- [x] Encode config WITHOUT password — DataModelTests: `connectionConfigEncodingDoesNotIncludePassword()`
- [x] Decode config preserves all fields except password — DataModelTests: `connectionConfigEncodingDoesNotIncludePassword()`
- [ ] Connection string parsing
- [ ] Default port and database values
- [x] All SSL modes (disable, require, verifyCA, verifyFull) — DataModelTests: `connectionConfigEncodingDoesNotIncludePassword()`
- [ ] Invalid config validation

### NotebookMetadata Model
- [x] Encode and decode metadata — DataModelTests: `notebookMetadataEncodingDecoding()`
- [x] Title, createdAt, modifiedAt preservation — DataModelTests: `notebookMetadataEncodingDecoding()`
- [ ] Metadata updates modify modifiedAt timestamp
- [ ] Custom tags/labels (if added)

### NotebookSettings Model
- [x] Encode and decode settings — DataModelTests: `notebookSettingsEncodingDecoding()`
- [x] maxResultTableHeight value — DataModelTests: `notebookSettingsEncodingDecoding()`
- [x] includeResultsWhenSaving flag — DataModelTests: `notebookSettingsEncodingDecoding()`
- [ ] Default settings values
- [ ] Settings updates persist globally
- [ ] Settings loaded on app reopen
- [ ] maxResultTableHeight applies in real-time to result table
- [ ] maxRows setting limits query before execution
- [ ] Warning shown when maxRows in settings < maxRows in query
- [ ] includeResultsWhenSaving saves results to .sqlnb when active
- [ ] includeResultsWhenSaving excludes results from .sqlnb when inactive

---

## SQL Syntax Highlighter

### Keyword Highlighting
- [x] SELECT, FROM, WHERE keywords — SQLSyntaxHighlighterTests: `keywordHighlighting()`
- [x] Keywords case-insensitive (SELECT, select, SeLeCt) — SQLSyntaxHighlighterTests: `keywordsCaseInsensitive()`
- [x] DDL keywords (CREATE, TABLE, PRIMARY KEY, etc.) — SQLSyntaxHighlighterTests: `ddlKeywords()`
- [x] DML keywords (INSERT, UPDATE, DELETE, VALUES) — SQLSyntaxHighlighterTests: `dmlKeywords()`
- [ ] DCL keywords (GRANT, REVOKE)
- [ ] TCL keywords (COMMIT, ROLLBACK, SAVEPOINT)
- [ ] Keywords in comments should not be highlighted
- [ ] Keywords in strings should not be highlighted

### Function Highlighting
- [x] Aggregate functions (COUNT, SUM, MAX, MIN, AVG) — SQLSyntaxHighlighterTests: `functionHighlighting()`, `multipleFunctions()`
- [x] String functions (UPPER, LOWER, TRIM) — SQLSyntaxHighlighterTests: `nestedFunctions()`
- [x] Nested functions — SQLSyntaxHighlighterTests: `nestedFunctions()`
- [ ] Window functions (ROW_NUMBER, RANK, PARTITION BY)
- [ ] PostgreSQL-specific functions (COALESCE, NOW, CURRENT_TIMESTAMP)
- [ ] Function case-insensitivity
- [ ] Functions must have opening parenthesis to match

### String Literal Highlighting
- [x] Single-quote strings ('text') — SQLSyntaxHighlighterTests: `singleQuoteStrings()`
- [x] Escaped quotes (O''Brien) — SQLSyntaxHighlighterTests: `stringWithEscapedQuotes()`
- [x] Multiple strings in same query — SQLSyntaxHighlighterTests: `multipleStrings()`
- [x] PostgreSQL dollar-quoted strings ($$text$$) — SQLSyntaxHighlighterTests: `dollarQuotedStrings()`
- [ ] Dollar-quoted with custom tags ($tag$text$tag$)
- [ ] Empty strings ('')
- [ ] Multiline strings
- [ ] Strings with special characters (\n, \t, etc.)

### Number Highlighting
- [x] Integers (123, 456) — SQLSyntaxHighlighterTests: `integerNumbers()`
- [x] Decimals (3.14, 19.99) — SQLSyntaxHighlighterTests: `decimalNumbers()`
- [x] Negative numbers (-100, -50.5) — SQLSyntaxHighlighterTests: `negativeNumbers()`
- [x] Scientific notation (1.5e10, 2.3e-5) — SQLSyntaxHighlighterTests: `scientificNotation()`
- [ ] Hexadecimal numbers (0x1A2B)
- [ ] Binary numbers (0b1010)

### Comment Highlighting
- [x] Single-line comments (-- comment) — SQLSyntaxHighlighterTests: `singleLineComment()`
- [x] Multi-line comments (/* comment */) — SQLSyntaxHighlighterTests: `multiLineComment()`
- [x] Nested multi-line comments — SQLSyntaxHighlighterTests: `nestedMultiLineComments()`
- [ ] Comments at end of line
- [ ] Comments preserving indentation
- [ ] Empty comments

### Operator Highlighting
- [x] Comparison operators (=, <>, <=, >=, <, >) — SQLSyntaxHighlighterTests: `comparisonOperators()`
- [x] Arithmetic operators (+, -, *, /) — SQLSyntaxHighlighterTests: `arithmeticOperators()`
- [x] Logical operators (AND, OR, NOT) — SQLSyntaxHighlighterTests: `logicalOperators()`
- [ ] PostgreSQL cast operator (::)
- [ ] Modulo operator (%)
- [ ] Concatenation operator (||)

### Complex Queries
- [x] SELECT with JOINs and GROUP BY — SQLSyntaxHighlighterTests: `complexSelectQuery()`
- [x] Common Table Expressions (WITH ... AS) — SQLSyntaxHighlighterTests: `cteQuery()`
- [x] Subqueries in WHERE clause — SQLSyntaxHighlighterTests: `subquery()`
- [ ] UNION/INTERSECT/EXCEPT queries
- [ ] Window functions queries
- [ ] Recursive CTEs

### PostgreSQL-Specific Syntax
- [x] PostgreSQL data types (SERIAL, JSONB, TIMESTAMPTZ) — SQLSyntaxHighlighterTests: `postgreSQLDataTypes()`
- [x] Cast operator (::DATE, ::INTEGER) — SQLSyntaxHighlighterTests: `postgreSQLCastOperator()`
- [x] Arrays (ARRAY[1, 2, 3]) — SQLSyntaxHighlighterTests: `postgreSQLArrays()`
- [ ] JSON operators (->, ->>)
- [ ] Range types (INT4RANGE, TSRANGE)
- [ ] Custom enum types

### Edge Cases
- [x] Empty string — SQLSyntaxHighlighterTests: `emptyString()`
- [x] Whitespace only — SQLSyntaxHighlighterTests: `whitespaceOnly()`
- [x] Single keyword — SQLSyntaxHighlighterTests: `singleKeyword()`
- [x] Unicode characters in strings — SQLSyntaxHighlighterTests: `unicodeCharacters()`
- [ ] Very long lines (1000+ characters)
- [ ] Mixed tabs and spaces
- [ ] Invalid SQL syntax (should still highlight)

### Performance
- [x] Highlighting 100 repeated queries under 5s — SQLSyntaxHighlighterTests: `highlightingPerformance()`
- [x] Very long query with 1000+ columns under 5s — SQLSyntaxHighlighterTests: `highlightingVeryLongQuery()`
- [ ] Real-time highlighting performance (debouncing)
- [ ] Memory usage with large queries

---

## ViewModel Logic

### Cell Management
- [x] Add cell at end of notebook — ViewModelTests: `addCell()`
- [x] Add cell after specific cell — ViewModelTests: `addCellAfterSpecificCell()`
- [x] Add cell to empty notebook — ViewModelTests: `addCellToEmptyNotebook()`
- [x] Delete existing cell — ViewModelTests: `deleteCell()`
- [x] Delete non-existent cell (no crash) — ViewModelTests: `deleteNonExistentCell()`
- [x] Move cell from position A to B — ViewModelTests: `moveCell()`
- [x] Move multiple cells — ViewModelTests: `moveCell()`
- [x] Add multiple cells (performance test) — ViewModelTests: `addMultipleCells()`
- [x] Delete all cells — ViewModelTests: `deleteAllCells()`
- [ ] Duplicate cell
- [ ] Duplicate cell with results
- [ ] Undo/redo cell operations

### Cell Selection
- [x] Select cell by ID — ViewModelTests: `selectCell()`
- [x] Deselect cell — ViewModelTests: `deselectCell()`
- [x] Select non-existent cell — ViewModelTests: `selectNonExistentCell()`
- [ ] Select next cell
- [ ] Select previous cell
- [ ] Multi-cell selection
- [ ] Selection preservation after add/delete

### Cell Output Management
- [x] Clear all outputs — ViewModelTests: `clearAllOutputs()`
- [x] Clear single cell output — ViewModelTests: `clearSingleCellOutput()`
- [ ] Clear outputs preserves cell content
- [ ] Clear running cell output
- [ ] Preserve outputs setting honored

### Execution State
- [x] Increment execution count — ViewModelTests: `incrementExecutionCount()`
- [x] Set cell running state to true — ViewModelTests: `setCellRunning()`
- [x] Set cell running state to false — ViewModelTests: `setCellNotRunning()`
- [x] Check if cell is running — ViewModelTests: `isCellRunning()`
- [ ] Cancel running query
- [ ] Multiple cells running concurrently
- [ ] Running state cleanup on error

### Sidebar Management
- [x] Toggle right sidebar — ViewModelTests: `toggleRightSidebar()`
- [x] Toggle left sidebar — ViewModelTests: `toggleLeftSidebar()`
- [x] Show specific sidebar content — ViewModelTests: `showSidebarContent()`
- [ ] Sidebar state persistence
- [ ] Sidebar width resize
- [ ] Hide sidebar on small screens

### Connection State
- [x] Initial state is disconnected — ViewModelTests: `connectionStateInitiallyDisconnected()`
- [ ] Transition to connecting state
- [ ] Transition to connected state
- [ ] Transition to disconnected after error
- [ ] Connection state changes trigger UI updates
- [ ] Reconnect after disconnect

### Notebook Metadata
- [x] Metadata accessible from ViewModel — ViewModelTests: `notebookMetadataAccessible()`
- [x] Settings accessible from ViewModel — ViewModelTests: `notebookSettings()`
- [ ] Update title through ViewModel
- [ ] Modified timestamp updates on changes
- [ ] Autosave triggers

### Cell Content
- [x] Update cell content directly — ViewModelTests: `updateCellContent()`
- [ ] Content change triggers modified timestamp
- [ ] Content validation (if any)
- [ ] Max content length handling

### Performance
- [x] Add 100 cells under 5s — ViewModelTests: `addCellPerformance()`
- [x] Delete 100 cells under 5s — ViewModelTests: `deleteCellPerformance()`
- [ ] Search through 1000+ cells
- [ ] Render 100+ cells efficiently

---

## Document Operations

### File Read Operations
- [ ] Read valid `.sqlnb` JSON file
- [ ] Read invalid JSON (should throw error)
- [ ] Read missing file (should throw error)
- [ ] Read corrupted file
- [ ] Read file with wrong version
- [ ] Read file with legacy format
- [ ] Read very large notebook file (100+ MB)

### File Write Operations
- [ ] Write notebook to valid JSON file
- [ ] Write with pretty-printed formatting
- [ ] Write excludes passwords
- [ ] Write respects includeResultsWhenSaving setting
- [ ] Atomic write (no corruption on crash)
- [ ] Write permission errors handled

### Round-Trip Operations
- [ ] Write then read preserves all data
- [ ] Round-trip with cells that have results
- [ ] Round-trip with connection config
- [ ] Round-trip with empty notebook
- [ ] Round-trip with large notebook

### Document State
- [ ] isDocumentEdited flag after changes
- [ ] isDocumentEdited false after save
- [ ] Autosave functionality
- [ ] Unsaved changes warning

---

## Database Connection (Integration Tests)

### PostgreSQL Connection
- [ ] Connect with valid config (localhost)
- [ ] Connect with valid config (production/remote server)
- [ ] Connect with invalid host (throws error)
- [ ] Connect with invalid port (throws error)
- [ ] Connect with invalid credentials (throws error)
- [ ] Connect with invalid database name (throws error)
- [ ] Test connection success case
- [ ] Test connection failure case
- [ ] Error messages displayed correctly at footer of connection sidebar
- [ ] Disconnect cleanup
- [ ] Connection timeout handling
- [ ] Reconnect after connection loss
- [ ] Connection state persisted when app closes
- [ ] Connection auto-reconnects when app reopens

### SSL/TLS Modes
- [ ] SSL mode: disable
- [ ] SSL mode: require
- [ ] SSL mode: verifyCA
- [ ] SSL mode: verifyFull
- [ ] Invalid certificate handling

### Connection String Parsing
- [ ] Parse standard connection string
- [ ] Parse connection string with all parameters
- [ ] Parse connection string with URL encoding
- [ ] Invalid connection string error

### Connection State Transitions
- [ ] disconnected → connecting → connected
- [ ] connected → disconnecting → disconnected
- [ ] connecting → error → disconnected
- [ ] Connection state observable by UI

### Connection Pooling
- [ ] Reuse existing connection
- [ ] Connection pool max size
- [ ] Connection cleanup on idle timeout

---

## Query Execution (Integration Tests)

### SELECT Queries
- [ ] Execute simple SELECT
- [ ] SELECT with WHERE clause
- [ ] SELECT with JOIN
- [ ] SELECT with GROUP BY and HAVING
- [ ] SELECT with ORDER BY and LIMIT
- [ ] SELECT returning large result set (1000+ rows)
- [ ] SELECT with NULL values
- [ ] SELECT with all supported data types

### DML Queries
- [ ] INSERT single row
- [ ] INSERT multiple rows
- [ ] INSERT RETURNING
- [ ] UPDATE rows (return affected count)
- [ ] UPDATE with WHERE clause
- [ ] DELETE rows (return affected count)
- [ ] DELETE with WHERE clause

### DDL Queries
- [ ] CREATE TABLE
- [ ] ALTER TABLE
- [ ] DROP TABLE
- [ ] CREATE INDEX
- [ ] Create/drop database objects

### Transaction Queries
- [ ] BEGIN transaction
- [ ] COMMIT transaction
- [ ] ROLLBACK transaction
- [ ] Savepoint operations

### Multiple Statements
- [ ] Execute multiple statements sequentially
- [ ] Error in one statement doesn't affect others
- [ ] Transaction semantics with multiple statements

### Error Handling
- [ ] Invalid SQL syntax (return error)
- [ ] Table not found error
- [ ] Column not found error
- [ ] Type mismatch error
- [ ] Permission denied error
- [ ] Connection lost during execution

### Data Type Mapping
- [ ] VARCHAR → `.string`
- [ ] TEXT → `.string`
- [ ] INTEGER → `.int`
- [ ] BIGINT → `.int`
- [ ] DECIMAL/NUMERIC → `.double`
- [ ] REAL/DOUBLE → `.double`
- [ ] BOOLEAN → `.bool`
- [ ] JSON/JSONB → `.json`
- [ ] DATE → `.date`
- [ ] TIMESTAMP → `.date`
- [ ] TIMESTAMPTZ → `.date`
- [ ] NULL → `.null`
- [ ] BYTEA → `.data`
- [ ] ARRAY types
- [ ] Custom enum types

### Performance
- [ ] Query execution time measurement accuracy
- [ ] Result row limiting (max fetch rows)
- [ ] Pagination for large results
- [ ] Query cancellation

---

## Schema Loading (Integration Tests)

### Table Discovery
- [ ] Fetch all tables in database
- [ ] Fetch tables from specific schema
- [ ] Filter system tables
- [ ] Table row count calculation
- [ ] Empty database returns empty list

### Column Discovery
- [ ] Fetch columns for table
- [ ] Column names and types correct
- [ ] Nullable column detection
- [ ] Primary key detection
- [ ] Foreign key relationships
- [ ] Default values

### Schema Organization
- [ ] List all schemas in database
- [ ] Schema filtering
- [ ] Public schema default

### Error Handling
- [ ] Schema loading with invalid connection
- [ ] Permission denied for schema info
- [ ] Schema load failure graceful handling

---

## UI Tests

### Document Lifecycle
- [ ] Create new notebook (Cmd+N)
- [ ] Open existing notebook (Cmd+O)
- [ ] Save notebook (Cmd+S)
- [ ] Save As functionality
- [ ] Close notebook with unsaved changes warning
- [ ] Reopen notebook preserves state

### Cell Operations
- [ ] Add code cell (Cmd+B)
- [ ] Delete cell (Cmd+Backspace)
- [ ] Duplicate cell (Cmd+D)
- [ ] Move cell up/down
- [ ] Select cell via click
- [ ] Focus cell editor

### Query Execution Flow
- [ ] Enter SQL query in cell
- [ ] Run cell (Cmd+Enter)
- [ ] Run cell and move to next (Shift+Enter)
- [ ] Run all cells (Cmd+Shift+Enter)
- [ ] Cancel running query
- [ ] Results display in table
- [ ] Execution time display
- [ ] Error message display

### Result Table Interaction
- [ ] Scroll through large result set
- [ ] Column resizing
- [ ] Column sorting (if implemented)
- [ ] Copy cell value
- [ ] Copy row
- [ ] Copy entire result
- [ ] JSON viewer for JSONB columns

### Connection Flow
- [ ] Open connection sheet
- [ ] Enter connection details
- [ ] Test connection button
- [ ] Connect to database
- [ ] Connection status in footer
- [ ] Schema loads in left sidebar
- [ ] Disconnect from database
- [ ] Switch databases

### Sidebar Interactions
- [ ] Toggle right sidebar (Cmd+Shift+R)
- [ ] Toggle left sidebar (Cmd+Shift+L)
- [ ] Browse schema tables
- [ ] Click table to insert name
- [ ] Resize sidebar width
- [ ] Sidebar content switching

### Keyboard Navigation
- [ ] All documented shortcuts work (comprehensive test)
- [ ] Tab navigation through cells
- [ ] Arrow key navigation
- [ ] Escape to deselect
- [ ] Cmd+N creates new notebook
- [ ] Cmd+O opens existing notebook
- [ ] Cmd+S saves notebook
- [ ] Cmd+Enter runs selected cell
- [ ] Shift+Enter runs cell and moves to next
- [ ] Cmd+Shift+Enter runs all cells (with confirmation)
- [ ] Cmd+B adds code cell below
- [ ] Cmd+Backspace deletes selected cell
- [ ] Cmd+D duplicates cell
- [ ] Cmd+Shift+R toggles right sidebar
- [ ] Cmd+Shift+L toggles left sidebar

### Visual Feedback
- [ ] Running indicator on cell
- [ ] Connection status indicator
- [ ] Progress indicator for long queries
- [ ] Error highlighting
- [ ] Syntax highlighting updates live

### Undo/Redo Functionality
- [ ] Undo/Redo works locally in focused query editor (cell-level)
- [ ] Undo/Redo works globally when editor unfocused (notebook-level)
- [ ] Undo removing a cell (global)
- [ ] Undo moving a cell (global)
- [ ] Undo adding a cell (global)
- [ ] Undo/Redo in sidebar cell value editor (isolated to editor)
- [ ] Undo/Redo scope switches correctly between local and global

### Run All Functionality
- [ ] Run all shows confirmation dialog when clicked via button
- [ ] Run all shows confirmation dialog when via menu option
- [ ] Run all shows confirmation dialog when via Cmd+Shift+Enter
- [ ] Confirmation dialog can be cancelled
- [ ] Confirmation dialog proceeds with execution when confirmed

### Cell Selection & Scrolling Behavior
- [ ] Clicking in query editor focuses editor and selects cell
- [ ] Clicking outside query editor selects cell but doesn't focus editor
- [ ] Selected cell change doesn't scroll if cell in viewport
- [ ] Selected cell change scrolls only when cell overflows viewport
- [ ] Scroll behavior correct for cell above viewport
- [ ] Scroll behavior correct for cell below viewport

---

## Accessibility & Polish

### Accessibility
- [ ] VoiceOver support
- [ ] Keyboard-only navigation
- [ ] Focus indicators visible
- [ ] Color contrast sufficient
- [ ] Screen reader labels

### Error Messages
- [ ] User-friendly database errors
- [ ] SQL syntax error suggestions
- [ ] Connection error guidance
- [ ] File I/O error messages

### Edge Cases
- [ ] Very long cell content (10,000+ chars)
- [ ] Very wide tables (100+ columns)
- [ ] Unicode in SQL queries
- [ ] Special characters in table/column names
- [ ] Emoji in data values

### Performance
- [ ] App launch time
- [ ] Large notebook load time (100+ cells)
- [ ] Smooth scrolling with many cells
- [ ] Memory usage with large results
- [ ] Responsive UI during query execution

---

## Test Infrastructure

### Mock Objects
- [ ] MockDatabaseConnectionManager
- [ ] Mock query results
- [ ] Mock error scenarios
- [ ] Mock connection states

### Test Helpers
- [ ] Create test notebook helper
- [ ] Create test cell helper
- [ ] Create test result helper
- [ ] Cleanup test database

### Test Database Setup
- [ ] Docker PostgreSQL container
- [ ] Test schema creation
- [ ] Sample data insertion
- [ ] Cleanup after tests

---

## Coverage Goals

- **Data Models**: 80%+ (Currently: ~70%)
- **SQL Highlighter**: 80%+ (Currently: ~65%)
- **ViewModel**: 75%+ (Currently: ~60%)
- **Database Operations**: 70%+ (Currently: 0%)
- **Document I/O**: 70%+ (Currently: 0%)
- **UI Tests**: Coverage of critical flows (Currently: 0%)

---

## Test Execution

### Xcode
- Run all: `Cmd+U`
- Run specific test: Click in Test Navigator
- Enable code coverage: Scheme → Test → Options → Code Coverage

### Command Line
```bash
xcodebuild test -scheme SQLNotebook -destination 'platform=macOS'
```

### CI/CD
- [ ] Setup GitHub Actions
- [ ] Run tests on PR
- [ ] Code coverage reports
- [ ] Performance regression tests
