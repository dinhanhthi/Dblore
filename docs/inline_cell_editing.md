# Inline Cell Editing Feature

## Overview

Allows users to directly edit query result cell values and persist changes back to the database. Clicking a cell opens the right sidebar with editing interface. Changes are automatically saved to the database using intelligent WHERE clause generation.

## User Workflow

1. **Execute SQL query** → Results displayed in table
2. **Click on a cell** → Right sidebar opens with cell details
3. **Edit value** → Enter new value in text field
4. **Save** → Value copied to clipboard AND saved to database
5. **Feedback** → Console logs success/error (TODO: show user notification)

## Architecture

### 1. UI Layer

**Cell Click Handler** ([ResultTableView.swift:211-246](../SQLNotebook/Views/Components/ResultTableView.swift#L211-L246))
- Detects cell taps
- Builds row data dictionary with all column values
- Extracts row identifier (ctid) if available
- Calls `viewModel.showCellDetail()`

**Right Sidebar** ([RightSidebarView.swift:125-142](../SQLNotebook/Views/Components/RightSidebarView.swift#L125-L142))
- `CellInfoContent` component shows editable cell value
- Provides text field for editing
- Calls `handleCellValueEdit()` on save

### 2. ViewModel Layer

**showCellDetail()** ([NotebookViewModel+Sidebar.swift:21-40](../SQLNotebook/ViewModels/NotebookViewModel+Sidebar.swift#L21-L40))
- Receives: column name, type, value, table name, row data, PK columns, row identifier
- Opens sidebar with cell editing interface

**handleCellValueEdit()** ([NotebookViewModel+Sidebar.swift:169-262](../SQLNotebook/ViewModels/NotebookViewModel+Sidebar.swift#L169-L262))
- Converts string input to appropriate CellValue type
- Copies value to clipboard
- Updates sidebar content
- Calls `connectionManager.updateCellValue()` to persist to database

### 3. Database Layer

**updateCellValue()** ([DatabaseConnectionManager.swift:461-534](../SQLNotebook/Database/DatabaseConnectionManager.swift#L461-L534))

Generates UPDATE statement with intelligent WHERE clause:

```sql
UPDATE "table_name"
SET "column_name" = <new_value>
WHERE <conditions>
```

**WHERE Clause Strategy** (Priority Order):

1. **Primary Key** (highest priority)
   - Example: `WHERE id = 123`
   - Most reliable and database-agnostic
   - Automatically fetched via `fetchPrimaryKeyColumns()`

2. **Row Identifier** (medium priority)
   - PostgreSQL: `WHERE ctid = '(0,1)'::tid`
   - SQLite: `WHERE rowid = 1` (planned phase 5)
   - Only used when no PK available
   - Automatically captured from `SELECT * FROM` queries

3. **All Columns** (fallback)
   - Example: `WHERE name = 'John' AND email = 'j@ex.com' AND age = 30`
   - Uses every column value as condition
   - **Risk**: May update multiple rows if duplicates exist

## Row Identifier (ctid) Implementation

**Automatic Capture** ([DatabaseConnectionManager.swift:331-451](../SQLNotebook/Database/DatabaseConnectionManager.swift#L331-L451))

For simple `SELECT *` queries:
```sql
-- User query:
SELECT * FROM users

-- Automatically modified to:
SELECT *, ctid AS _sqlnb_ctid FROM users
```

- `_sqlnb_ctid` column hidden from user (filtered out in UI)
- Stored in `CellResult.rowIdentifiers` array
- Only works for `SELECT * FROM table` patterns
- Complex queries (joins, subqueries) won't capture ctid

**Database Type Tracking** ([ConnectionConfig.swift:9-16](../SQLNotebook/Models/ConnectionConfig.swift#L9-L16))
- `DatabaseType` enum: PostgreSQL, SQLite
- Exposed via `DatabaseConnectionManager.databaseType`
- Used to generate correct row identifier syntax

## Data Flow

```
Query Execution → Capture ctid → Store in CellResult
     ↓
User clicks cell → Pass to sidebar with row data + ctid
     ↓
User edits → Save → Generate UPDATE with WHERE clause
     ↓
Success → Log to console (TODO: show notification)
```

## Type Conversion

**handleCellValueEdit()** supports these conversions:
- String → `.string(value)`
- Int → `.int(value)` (validates as Int)
- Double → `.double(value)` (validates as Double)
- Bool → `.bool(value)` (validates as Bool)
- Null → `.null` (if "null" or empty)
- JSON → `.json(value)`
- Date → `.date(value)` (parses ISO8601)
- Data → `.data(value)` (UTF-8 encoded)

## Supported Data Types

All PostgreSQL types supported via `CellValue` enum:
- Primitives: INT, BIGINT, SMALLINT, BOOLEAN
- Numeric: FLOAT, DOUBLE, NUMERIC, MONEY
- Text: VARCHAR, TEXT, CHAR
- Binary: BYTEA
- Temporal: DATE, TIMESTAMP, TIMESTAMPTZ
- Structured: JSON, JSONB
- Special: UUID

## Limitations

**Query Patterns**:
- ✅ `SELECT * FROM table`
- ✅ `SELECT * FROM schema.table`
- ✅ `SELECT * FROM table WHERE condition`
- ❌ `SELECT id, name FROM table` (column selection)
- ❌ `SELECT * FROM a JOIN b` (joins)
- ❌ `SELECT * FROM (SELECT ...)` (subqueries)

**Database Support**:
- ✅ PostgreSQL (full support)
- ⏳ SQLite (planned phase 5)

**Edge Cases**:
- Tables without PK and duplicate rows → May update wrong row
- NULL values in PK columns → Falls back to all columns
- Very wide tables → WHERE clause with all columns may be slow

## Future Enhancements

1. **User Notifications**: Replace console logs with toast/alert UI
2. **Optimistic UI**: Update table immediately, rollback on error
3. **Validation**: Client-side type validation before UPDATE
4. **Undo/Redo**: Support undoing cell edits
5. **Batch Edits**: Edit multiple cells before saving
6. **SQLite Support**: Add `rowid` support (phase 5)
7. **Better Query Detection**: Support more SELECT patterns for ctid capture
