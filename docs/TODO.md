# TODO.md - SQL Notebook Implementation Tasks

## Current Status Overview

- ✅ **Phase 1-4: Foundation** - COMPLETE (Core structure, Cell editor, Database integration, Polish)
- 🟡 **Phase 5: Advanced Features** - PARTIAL (Autocomplete ✅, Multi-SQL ✅; AI/Schema Visualizer pending)
- ✅ **Phase 6: Security & Safety** - COMPLETE (Connection security, Query confirmations, Read-only mode, Value validation)
- ✅ **Phase 7: Testing** - COMPLETE (387/387 unit tests passing; Integration/UI tests deferred)
- ✅ **Phase 8: Editor Mode** - COMPLETE (Run Selection, Multi-SQL, Export CSV/Excel/JSON/Markdown, Executed Query Viewer)
- 🟡 **Phase 10: Performance Optimization** - IN PROGRESS (11/19 tasks complete; 1 invalid task; see [TODO_OPTIMIZE.md](TODO_OPTIMIZE.md))

---

## Pending Tasks

### Phase 5: Advanced Features

#### 5.8 Multi-SQL Command Execution - COMPLETE ✅
Execute multiple SQL commands in single cell (like pgAdmin/DBeaver):
- [x] Support semicolon (`;`) as command separator
- [x] Execute all commands sequentially (stop on first error)
- [x] Display result of LAST query in table view (Notebook mode)
- [x] Display ALL statements with selector (Editor mode)
- [x] Previous commands (CREATE, INSERT, UPDATE, DELETE) execute silently
- [x] Show execution status for each command (Editor mode)
- [x] Accumulate affected rows across multiple modification queries

**Implementation Details:**
- ✅ DatabaseConnectionManager+QueryExecution.swift
  - `hasMultipleStatements()` - Detect semicolon-separated statements
  - `executeMultipleStatements()` - Returns last result (for Notebook mode)
  - `executeMultipleStatementsDetailed()` - Returns all results (for Editor mode)
  - `splitSQLStatements()` - Parse SQL and split by semicolons (ignores semicolons in strings/comments)
- ✅ Notebook Mode: Automatically executes all statements, shows last result only
- ✅ Editor Mode: Shows all statement results with selector UI, pagination support per statement
- ✅ StatementResult model for storing individual statement results
- ✅ Tests: DatabaseQueryExecutionTests.swift (multi-statement detection and execution)

**Known Limitations:**
- Error stops execution (no continue-on-error mode)
- No selective re-execution of failed commands (would require UI redesign)

#### 5.7 Schema Visualizer (FUTURE - Large Effort)
- [ ] Query foreign key relationships
- [ ] Build relationship graph
- [ ] Create visual graph component with pan/zoom

#### 5.6 AI-Powered Natural Language Query (FUTURE - Large Effort)
Local model only:
- [ ] Select local LLM framework
- [ ] Integrate local model into app
- [ ] Implement prompt engineering for natural language → SQL
- [ ] Create UI component for AI query input

---

### Phase 6: Future Security Enhancements

#### 6.0.5 Query Audit Trail (FUTURE)
- [ ] Query execution logging and audit trail
- [ ] Connection security indicator in UI

#### 6.0.6 User Security Education (FUTURE)
- [ ] Security warnings and tips in UI
- [ ] Best practices documentation

#### Other Security TODOs
- [ ] Keychain storage for passwords (DataModelTests.swift:304) - LOW PRIORITY
- [ ] Add confirmation for inline cell editing - FUTURE
- [ ] Add transaction support for inline edits - FUTURE
- [ ] Transaction management for queries - FUTURE

---

### Phase 7: Integration & UI Tests (DO LAST - Medium Effort)

**Note:** Complete all features first before doing these tests.

#### Integration Tests
- [ ] DatabaseConnectionManager connection tests
- [ ] Query execution tests (SELECT, INSERT/UPDATE/DELETE)
- [ ] Schema loading tests (blocked on public API - DatabaseIntegrationTests.swift:284)
- [ ] Type mapping tests (JSON/JSONB, DATE, TIMESTAMP)

#### UI Tests
- [ ] Basic workflow tests (create, open, save notebook)
- [ ] Query execution flow tests
- [ ] Connection flow tests
- [ ] Document persistence tests

---

### Phase 8: Future Editor Mode Enhancements

#### 8.7 Multiple Database Support (FUTURE - Large Effort)
- [ ] Abstract database connection interface
- [ ] Add SQLite support
- [ ] Add MySQL support (optional)

#### 8.2 Additional Features (FUTURE)
- [ ] Implement "Run All" functionality (run all cells/statements)

---

### Phase 9: Schema Visualizer (FUTURE - Large Effort)
- [ ] Query foreign key relationships
- [ ] Build relationship graph
- [ ] Create visual graph component
- [ ] Implement pan and zoom functionality

---

## Code-Level TODOs

Active TODOs found in codebase (verified 2026-01-22):

1. **NotebookViewModel+Sidebar.swift:181** - Future JSON DB update (LOW PRIORITY)
   - Currently only copies JSON edits to clipboard
   - Could update actual database value in future

2. **DataModelTests.swift:304** - Keychain storage for passwords (FUTURE)
   - Passwords should use Keychain instead of .sqlnb JSON files
   - Part of Phase 6 Security enhancements

3. **DatabaseIntegrationTests.swift:284** - Schema loading tests (BLOCKED)
   - Waiting for public API availability

---

## Completed Major Features (Recent)

### Phase 8: Editor Mode ✅
- ViewMode enum (.notebook, .editor)
- EditorModeView with VSplitView layout
- SQL editor with syntax highlighting and autocomplete
- Run Selection support (Cmd+Shift+Enter)
- Multi-SQL execution with statement selector UI
- Mode toggle in header (Notebook/Editor buttons)
- Export Results: CSV/Excel/JSON/Markdown (DataExporter.swift - 530 lines)
- Executed Query Viewer with syntax highlighting and word wrap (ExecutedQuerySidebarContent.swift - 165 lines)

### Phase 5.8: Multi-SQL Command Execution ✅
- Automatic detection of semicolon-separated statements
- Sequential execution (stops on first error)
- Notebook Mode: Shows last result only
- Editor Mode: Shows all results with selector, pagination per statement
- Accumulate affected rows for modification queries
- DatabaseConnectionManager+QueryExecution.swift - executeMultipleStatements(), executeMultipleStatementsDetailed()
- DatabaseConnectionManager+QueryParsing.swift - splitSQLStatements(), hasMultipleStatements()

### Phase 7: Unit Tests ✅
- 387/387 tests passing (100% pass rate)
- Data model serialization tests
- SQL syntax highlighter tests
- ViewModel logic tests
- Document operations tests
- CellResult and DatabaseSchema model tests

### Phase 6: Security & Safety ✅
- SSL/TLS support (all 6 PostgreSQL modes)
- Connection retry with exponential backoff
- Connection timeout configuration (default 30s)
- Confirmation dialogs for destructive queries
- Read-only mode option
- Value format validation (integer, uuid, jsonb, date, timestamp)
- Primary key and ctid row identification

### Phase 5.4: Query Autocomplete ✅
- 95+ SQL keywords (DML, DDL, DCL, window functions, CTEs)
- Context-aware suggestions (tables after FROM/JOIN, columns after SELECT/WHERE)
- Keyboard navigation (Up/Down, Enter to select)
- Schema integration for table/column suggestions

### Phase 4: Polish ✅
- Global keyboard shortcuts (Cmd+Enter, Cmd+S, Cmd+D, etc.)
- Global search (Cmd+F) with match highlighting
- Drag & drop cell reordering
- Theme toggle (System/Light/Dark)
- File optimization system (5MB/10MB thresholds)
- Logging system (AppLogger with OSLog)

---

## Next Steps

### Immediate Priority
1. **Phase 10 Performance Optimization** (See TODO_OPTIMIZE.md) - Improve performance for large datasets
2. **Phase 5.7 Schema Visualizer** (Large effort) - Visualize foreign key relationships

### Future Enhancements
3. **Phase 5.7 Schema Visualizer** (Large effort) - Foreign key graph
4. **Phase 8.7 Multiple Database Support** (Large effort) - SQLite/MySQL
5. **Phase 5.6 AI-Powered Queries** (Large effort) - Local LLM integration

### Do Last
6. **Phase 7 Integration & UI Tests** (Medium effort) - After all features complete

---

## Definition of Done

Each task is complete when:
1. Feature implemented according to specifications
2. Code follows Swift/SwiftUI best practices
3. Relevant tests written and passing
4. Works in both light and dark mode
5. No compiler warnings or runtime errors
6. Code reviewed and committed

---

## Latest Status (2026-01-24)

**Git HEAD:** main branch

**Phase Status:**
- ✅ Phase 1-4: Complete (~27,000+ lines)
- 🟡 Phase 5: Mostly complete (5.4 Autocomplete ✅, 5.8 Multi-SQL ✅; 5.6 AI/5.7 Schema Visualizer pending)
- ✅ Phase 6: Complete (6.0.2-6.0.4; 6.0.5-6.0.6 future)
- ✅ Phase 7: Complete (47/47 unit tests; integration/UI tests deferred)
- ✅ Phase 8: Complete (8.1-8.6, 8.8 including Multi-SQL; 8.7 future)
- 🟡 Phase 10: In Progress (11/19 tasks complete: Phase 10.1 Quick Wins ✅ 9/9 complete, 10.2.2 ExecutionQueue ✅, 10.2.5 Primary Key Detection ✅; 10.1.1 LazyVStack ❌ INVALID)

**Recommended Next Actions:**
1. **Phase 10 Performance Optimization** - Address performance bottlenecks for large datasets (see TODO_OPTIMIZE.md)
2. **Phase 5.7 Schema Visualizer** - Foreign key relationship graph (large effort)
3. **Phase 5.6 AI Natural Language Query** - Local LLM integration (large effort)

---

## Verification Report (2026-01-24)

### ✅ Verified Complete (Since Last Update)

#### Phase 10.1: Quick Wins (9/9 Complete) - 2026-01-24
All quick-win optimization tasks completed in single session:

1. **10.1.2: Memory - Search Cache Optimization** ✅
   - Location: `ResultTableView.swift:118-120, 125-128`
   - Note: macOS doesn't have memory warnings; existing cache limits sufficient

2. **10.1.3: UI Performance - Debounce Search Navigation** ✅
   - Location: `NotebookViewModel.swift:93`, `NotebookViewModel+Search.swift:193-212`
   - Added `searchNavigationTask` to cancel previous navigations

3. **10.1.4: Database - Schema Fetching Cache (5min validity)** ✅
   - Location: `SQLAutocompleteProvider.swift:42-43, 61-62, 100, 111`
   - Added `lastRefreshTime`, `cacheValidityDuration`, `clearCache()`

4. **10.1.5: Concurrency - Query Timeout (60s)** ✅
   - Location: `TaskExtensions.swift` (NEW), `NotebookViewModel+Execution.swift:81-84, 156-160, 248-263`
   - Created `Task.withTimeout()` helper with `TaskTimeoutError`

5. **10.1.6: UI Performance - Cache Column Widths** ✅
   - Location: `ResultTableView.swift:24, 129, 310, 319, 323-326`
   - Added `cachedTotalColumnsWidth`, `recalculateTotalWidth()`

6. **10.1.7: Memory - Auto-Clear ExecutionQueue (keep 10)** ✅
   - Location: `ExecutionQueue.swift:27, 166-174`
   - Added `maxHistorySize = 10`, auto-clear logic

7. **10.1.8: Memory - Clear Autocomplete Cache on Disconnect** ✅
   - Location: `SQLAutocompleteProvider.swift:96-102`, `NotebookViewModel+Connection.swift:48-49`
   - Call `clearCache()` on disconnect

8. **10.1.9: Concurrency - Search Task Cancellation** ✅
   - Location: `NotebookViewModel+Search.swift:322-325`
   - Added `Task.isCancelled` check in `searchInTableData()` inner loop

9. **10.1.10: File I/O - JSON Encoding Performance** ✅
   - Location: `SQLNotebookDocument+Coding.swift:249-252`, `FileOptimizationService.swift:216-218`
   - Removed `.prettyPrinted`, kept only `[.sortedKeys]`

**Expected Impact:** 40-50% overall performance improvement (memory, CPU, I/O)

#### Phase 10.2.2: ExecutionQueue Off Main Actor ✅ (2026-01-24)
- **Location:** `ExecutionQueue.swift:118-220`
- **Implementation:**
  - `startProcessing()` uses `Task.detached` instead of `Task { @MainActor in }`
  - `processQueue()` marked `nonisolated` to run off main actor
  - State access via `MainActor.run { }` blocks
  - Keeps `@Observable` for SwiftUI integration
- **Impact:** Non-blocking UI during query execution

#### Phase 10.2.5: Primary Key Detection ✅
- **Phase 10.2.5: Primary Key Detection** - ✅ IMPLEMENTED
  - Location: `DatabaseConnectionManager+Schema.swift:65-237`
  - `fetchPrimaryKeyColumns()` queries `pg_constraint` system catalog
  - Primary key information properly populated in `ColumnSchema.isPrimaryKey`

### 🚧 Partial Implementation (Noted in TODO_OPTIMIZE.md)
- **Phase 10.2.1: Large Result Set Pagination** - 🚧 PARTIAL (Basic row limiting only)
  - Location: `ResultTableView.swift:30-38`
  - Current: Hard limit of 500 rows with truncation warning
  - Missing: True viewport-based rendering, virtual scrolling, row recycling (TanStack-like pattern)

### ❌ Invalid Tasks (Cannot Implement)
- **Phase 10.1.1: LazyVStack for Cells** - ❌ INVALID (2026-01-24)
  - **Reason:** LazyVStack causes app crashes with variable-height NSTextView content
  - **Evidence:** scroll_crash_fix.md documents extensive research (2026-01-03)
  - **Memory Issue:** LazyVStack leaks 33MB per scroll vs List (151MB vs 118MB)
  - **Decision:** Keep current `List` implementation (proven stable)
  - **Reference:** [scroll_crash_fix.md](implementation/scroll_crash_fix.md)

### 🎯 Recommended Next Priority (Phase 10.2: Major Refactors)

**High Priority Tasks (MEDIUM-HIGH effort):**
1. ~~**10.2.3: ResultTableView Search Optimization**~~ ✅ COMPLETE (2026-01-24)
2. **10.2.1: True Virtual Scrolling (TanStack-like)** - HIGH priority, HIGH effort
3. **10.2.4: Query Result Streaming** - HIGH priority, HIGH effort

**Code Quality (Phase 10.3):**
- **10.3.1: Split ResultTableView** (920 lines → ~300 lines) - MEDIUM effort
- **10.3.5: Toast Deadlock Prevention** - LOW effort (quick fix)

See [TODO_OPTIMIZE.md](TODO_OPTIMIZE.md) for detailed task descriptions.
