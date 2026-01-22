# Multi-Statement Support in Editor Mode

## Problem
Editor mode could not execute SQL scripts with multiple statements separated by semicolons (e.g., `.sql` files). PostgreSQL's prepared statement API rejects multiple commands with error: `cannot insert multiple commands into a prepared statement`.

## Solution
Implemented a SQL parser to split multi-statement queries into individual statements, execute them sequentially, and provide a dropdown UI to view results from each statement independently.

### Key Changes

#### 1. SQL Statement Parser
- `SQLNotebook/Database/DatabaseConnectionManager+QueryParsing.swift:149-256`
  - Added `splitSQLStatements()` - Parses SQL string into individual statements
  - Added `hasMultipleStatements()` - Detects if query contains multiple statements
  - Handles string literals, escaped quotes, single-line comments (`--`), multi-line comments (`/* */`)
  - Marked as `nonisolated` (pure functions, no actor state access)

#### 2. Detailed Execution Method
- `SQLNotebook/Database/DatabaseConnectionManager+QueryExecution.swift:42-75`
  - Added `executeMultipleStatementsDetailed()` - Executes statements sequentially, returns array of results
  - Returns tuple: `(results: [(queryText, result)], totalTime: TimeInterval)`
  - Preserves original `executeMultipleStatements()` for backward compatibility (notebook mode)

#### 3. Data Model
- `SQLNotebook/Models/NotebookCell.swift:43-58`
  - Added `StatementResult` struct to wrap individual statement results
  - Contains: `queryText`, `result`, `statementIndex`

#### 4. ViewModel State
- `SQLNotebook/ViewModels/NotebookViewModel.swift:95-97`
  - Added `editorStatementResults: [StatementResult]` - Array of all statement results
  - Added `selectedStatementIndex: Int` - Currently displayed result (0-based)
  - Added `totalExecutionTime: TimeInterval` - Aggregate execution time

#### 5. Execution Logic
- `SQLNotebook/ViewModels/NotebookViewModel+EditorMode.swift:57-99`
  - Updated `executeEditorQuery()` to detect and handle multi-statement queries
  - Calls `executeMultipleStatementsDetailed()` for multi-statement queries
  - Selects last statement by default (psql behavior)
  - Added `selectEditorStatement(at:)` to switch between results

#### 6. UI - Result Header
- `SQLNotebook/Views/EditorModeView.swift:136-184`
  - Updated to show two levels of information:
    - **Total**: `3 statements • 0.045s`
    - **Current**: `2 rows • 0.015s` or `1 row affected • 0.012s`

#### 7. UI - Result Footer with Dropdown
- `SQLNotebook/Views/EditorModeView.swift:275-360`
  - Added dropdown selector (Menu) to choose which statement result to view
  - Dropdown label: `▼ Result 2` (with `.menuIndicator(.hidden)` to hide default arrow)
  - Dropdown items: `Result 1 • INSERT INTO users...` (max width 400pt)
  - Preserved "Run with query (click to copy)" section (spans remaining width)
  - Each item shows checkmark for selected statement

## Implementation Details

### SQL Parsing Strategy
The parser uses character-by-character iteration with state tracking:
- `inSingleQuote`, `inDoubleQuote` - Track string literal context
- `inSingleLineComment`, `inMultiLineComment` - Track comment context
- Handles escaped quotes (`O''Reilly` → keeps both quotes)
- Splits on semicolons only when outside strings/comments

### Execution Flow
```
User Query: "INSERT...; SELECT...; DELETE...;"
     ↓
splitSQLStatements() → ["INSERT...", "SELECT...", "DELETE..."]
     ↓
executeMultipleStatementsDetailed()
  → Execute sequentially
  → Collect (queryText, result) tuples
  → Return array + total time
     ↓
Convert to StatementResult array
     ↓
Select last result by default
     ↓
Display in UI with dropdown selector
```

### UI Behavior
- **Default**: Last statement result shown (matches `psql` behavior)
- **Dropdown**: Click to view any statement's result
- **Header**: Shows both total stats and current statement stats
- **Footer**: Dropdown on left, "Run with query" on right (full width)

## Testing
- ✅ 47 unit tests passed (including 12 new multi-statement parsing tests)
- ✅ Handles empty queries, single statements, multiple statements
- ✅ Correctly ignores semicolons in string literals and comments
- ✅ Escaped quotes handled properly (`'O''Reilly'`)
- ✅ Single-line and multi-line comments preserved

### Test Coverage
- `SQLNotebookTests/DatabaseQueryExecutionTests.swift:376-556`
  - `splitSimpleTwoStatements()` - Basic split test
  - `splitIgnoresSemicolonInString()` - String literal handling
  - `splitHandlesSingleLineComments()` - Comment handling
  - `splitHandlesEscapedQuotes()` - Escaped quote handling
  - `hasMultipleStatements()` - Detection tests

## Example Usage

### Input Query (3 statements)
```sql
INSERT INTO users (name) VALUES ('Alice');
INSERT INTO users (name) VALUES ('Bob');
SELECT * FROM users;
```

### Execution Result
- **Statement 1**: `INSERT` → 1 row affected • 0.012s
- **Statement 2**: `INSERT` → 1 row affected • 0.008s
- **Statement 3**: `SELECT` → 2 rows • 0.015s
- **Total**: 3 statements • 0.035s

### UI Display
```
┌──────────────────────────────────────────────────┐
│ Header                                            │
│ ✓ Total: 3 statements • 0.035s │ Current: 2 rows • 0.015s │
└──────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────┐
│ Result Table (Statement 3 - SELECT)               │
│ ┌────┬───────┐                                    │
│ │ id │ name  │                                    │
│ ├────┼───────┤                                    │
│ │ 1  │ Alice │                                    │
│ │ 2  │ Bob   │                                    │
│ └────┴───────┘                                    │
└──────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────┐
│ Footer                                            │
│ [▼ Result 3] 📋 Run with query: SELECT * FROM... │
│   ↓ Dropdown                                      │
│   ┌─────────────────────────────────┐            │
│   │ Result 1 • INSERT INTO us...    │            │
│   │ Result 2 • INSERT INTO us...    │            │
│   │ Result 3 • SELECT * FROM users; ✓│            │
│   └─────────────────────────────────┘            │
└──────────────────────────────────────────────────┘
```

## Design Decisions

### Why Last Result by Default?
Matches PostgreSQL `psql` client behavior - when executing multiple statements, the last result is most relevant (typically a SELECT to verify changes).

### Why Dropdown vs. Tabs?
- **Compact**: Doesn't consume vertical space
- **Scalable**: Works well with 2-10 statements
- **Familiar**: Standard macOS pattern

### Why Sequential Execution?
- **Transactional**: Later statements may depend on earlier ones
- **Error Handling**: Stop immediately if any statement fails
- **Predictable**: Matches database client behavior

## Backward Compatibility
- ✅ Single statement queries work exactly as before
- ✅ Notebook mode unchanged (uses existing `executeMultipleStatements()`)
- ✅ No breaking changes to existing code

## Limitations
- Each statement executes in separate transaction (PostgreSQL default)
- Very long statements (>400pt width) truncated in dropdown with `...`
- Maximum practical statements: ~20 (UI remains usable)

## Future Enhancements
- [ ] Option to execute statements in single transaction (`BEGIN; ...; COMMIT;`)
- [ ] Export all results to CSV
- [ ] Keyboard shortcuts to navigate between results (⌘[, ⌘])
- [ ] Show execution progress for long-running multi-statement queries

## Related Files
- `docs/implementation/editor_mode.md` - Editor mode overview
- `SQLNotebook/Database/DatabaseConnectionManager.swift` - Database actor
- `SQLNotebook/Models/DatabaseTypes.swift` - QueryResult model
