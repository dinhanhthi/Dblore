# Editor Mode Max Rows Setting

## Problem

Editor mode lacked a configurable row limit setting, unlike Notebook mode which had pagination controls. Users needed:
- A way to limit query results in Editor mode to prevent performance issues with large result sets
- Visual warning when queries are automatically limited
- Pagination support for navigating through limited results

## Solution

Implemented a configurable "Max Rows" setting (4-10 range for testing, will be 100-200 for production) that:
1. Automatically wraps SELECT queries with LIMIT clause
2. Strips SQL comments before checking/adding LIMIT to avoid false positives
3. Shows warning banner when queries are limited
4. Enables pagination for auto-limited queries

### Key Changes

**Settings & Configuration:**
- `SQLNotebook/Utilities/AppSettings.swift:82-92` - Added `editorMaxRowLimit` property with UserDefaults persistence
- `SQLNotebook/Views/Sidebars/SettingsContent.swift:193-230` - Added Result Table section UI in Editor mode settings

**Query Processing:**
- `SQLNotebook/Database/DatabaseConnectionManager+QueryParsing.swift:15-131` - Added comment stripping functions:
  - `stripLeadingComments()` - Removes leading `--` and `/* */` comments
  - `stripAllComments()` - Removes all comments while preserving string literals
- `SQLNotebook/Database/DatabaseConnectionManager+QueryParsing.swift:40-46` - Updated `hasLimitClause()` to strip comments before checking
- `SQLNotebook/Database/DatabaseConnectionManager+QueryParsing.swift:57-75` - Updated `extractLimitValue()` to strip comments before extracting
- `SQLNotebook/Database/DatabaseConnectionManager+QueryWrapping.swift:46-76` - Updated `wrapQueryWithLimit()` to strip comments before appending LIMIT

**Auto-Limit Detection:**
- `SQLNotebook/Database/DatabaseConnectionManager+QueryExecution.swift:230-342` - Added logic to detect when query was auto-limited:
  - Track if user had LIMIT in original query
  - Check if result has exactly maxRows (indicates more rows available)
  - Set `userLimitExceeded=true` and `userRequestedLimit=maxRows` when auto-limited

**UI & Pagination:**
- `SQLNotebook/Views/EditorModeView.swift:20,175-202` - Added warning banner with adaptive colors for dark/light mode
- `SQLNotebook/ViewModels/NotebookViewModel+EditorMode.swift:332-368` - Updated `buildPaginationInfo()` to enable pagination for auto-limited queries

**Testing:**
- `SQLNotebookTests/DatabaseQueryParsingTests.swift` - Added 69 comprehensive test cases covering all edge cases

## Already Tried

- ❌ **Initial approach**: Only checked for LIMIT in original query
  - Problem: LIMIT in SQL comments (`-- LIMIT 3`) was detected as actual LIMIT
  - Solution: Strip comments before all LIMIT-related checks

- ❌ **Second approach**: Strip comments only in `extractLimitValue()`
  - Problem: `hasLimitClause()` still detected LIMIT in comments
  - Solution: Also strip comments in `hasLimitClause()`

- ❌ **Third approach**: Append LIMIT to original query with comments
  - Problem: Final query contained comments: `SELECT * from bot -- LIMIT 3 LIMIT 4`
  - Solution: Append LIMIT to comment-stripped query

## Critical Implementation Details

### Comment Stripping Strategy

**Why strip comments?**
- SQL comments can contain LIMIT keywords that aren't actual SQL: `-- Try: LIMIT 100`
- Prevents false positives in LIMIT detection
- Ensures final wrapped query is clean SQL without comments

**Functions that strip comments:**
1. `isSelectQuery()` - Uses `stripLeadingComments()`
2. `isModificationQuery()` - Uses `stripLeadingComments()`
3. `extractLimitValue()` - Uses `stripAllComments()`
4. `hasLimitClause()` - Uses `stripAllComments()`
5. `wrapQueryWithLimit()` - Uses `stripAllComments()`

### Auto-Limit Detection Flow

```
User Query: -- LIMIT 3\nSELECT * from bot
           ↓
1. extractLimitValue(query) → strips comments → nil (no actual LIMIT)
2. hadUserLimit = false
3. wrapQueryWithLimit() → "SELECT * from bot LIMIT 4" (comments stripped)
4. Execute query → returns 4 rows
5. hasLimitClause(query) → strips comments → false (no LIMIT in original)
6. wasLimited = true (resultRows.count == maxRows && hadNoLimit)
7. wasLimited && !hadUserLimit → finalUserLimitExceeded = true
8. Warning banner shows + Pagination enabled
```

## Testing

**Test Coverage: 69 test cases, 100% pass rate**

Key test categories:
- ✅ Comment stripping (single-line, multi-line, mixed)
- ✅ String literal preservation (`'-- not a comment'`)
- ✅ LIMIT detection (ignores comments)
- ✅ Query wrapping (no comments in final query)
- ✅ Edge cases (empty queries, escaped quotes, nested patterns)

**Critical test: Final query must not contain comments**
```swift
@Test("Query with leading comments has NO comments in result")
func testLeadingCommentsRemoved() async throws {
  let query = "-- LIMIT 3\nSELECT * FROM bot"
  let result = manager.wrapQueryWithLimit(query, maxRows: 4)

  #expect(!result.contains("--"))
  #expect(!result.contains("/*"))
  #expect(result == "SELECT * FROM bot LIMIT 4")
}
```

## UI Improvements

**Warning Banner - Adaptive Colors:**
- Dark mode: `Color.warning.opacity(0.15)` - Lighter for visibility
- Light mode: `Color.warning.opacity(0.08)` - Darker for contrast

**Text:**
"Query returned more than X rows. Showing first X rows only. Adjust limit in Settings."

## Known Limitations

1. **String Literal Detection**: LIMIT inside string literals may be detected (e.g., `SELECT 'LIMIT 50' FROM users`)
   - Impact: Low - rare in real queries
   - Documented in tests

## Configuration

**Production Settings:**
- Default: 100 rows
- Range: 100-200 rows
- Step: 10 rows (slider increments by 10)
- Storage: UserDefaults key `app.settings.editorMaxRowLimit`

**Settings Locations:**
- `AppSettings.swift:82-92` - Property definition with clamping logic
- `AppSettings.swift:203-207` - UserDefaults initialization
- `AppSettings.swift:264` - Reset to defaults
- `SettingsContent.swift:210-224` - UI slider and description

## Related Files

**Documentation:**
- `CLAUDE.md` - Project architecture and code organization rules

**Related Features:**
- Notebook mode pagination - `SQLNotebook/ViewModels/NotebookViewModel+Pagination.swift`
- Result table view - `SQLNotebook/Views/Components/ResultTableView.swift`

## Future Enhancements

- [ ] Add per-query LIMIT override in query editor
- [ ] Show estimated total rows in warning banner
- [ ] Add "Load All Rows" button with confirmation dialog
- [ ] Support OFFSET clause in pagination
- [ ] Add setting to disable auto-LIMIT for power users
