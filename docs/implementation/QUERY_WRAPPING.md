# Query Wrapping Documentation

## Overview

SQLNotebook implements automatic SQL query wrapping to enhance functionality and user experience. There are three main wrapping mechanisms:

1. **LIMIT Wrapping** - Prevents fetching too many rows
2. **CTID Wrapping** - Enables row identification for PostgreSQL
3. **Modification Query Wrapping** - Captures affected row counts for UPDATE/DELETE/INSERT

## 1. LIMIT Wrapping (`wrapQueryWithLimit`)

### Purpose

Automatically enforces row limits to prevent performance issues and excessive memory usage.

### Implementation Location

- **File**: `DatabaseConnectionManager+QueryExecution.swift`
- **Function**: `wrapQueryWithLimit(_:maxRows:)`
- **Line**: ~409-433

### How It Works

```swift
// User query
SELECT * FROM users

// Wrapped query (maxRows = 1000)
SELECT * FROM users LIMIT 1000
```

### Rules

1. **Only wraps SELECT queries** with FROM clause
2. **Skips function calls** without FROM (e.g., `SELECT pg_sleep(3)`, `SELECT now()`)
3. **Respects user's LIMIT** if ≤ maxRows
4. **Replaces user's LIMIT** if > maxRows
5. **Appends LIMIT** if no LIMIT clause exists

### Edge Cases Handled

| Query Type | Behavior | Example |
|-----------|----------|---------|
| SELECT without FROM | Not wrapped | `SELECT 1 + 1` |
| Function calls | Not wrapped | `SELECT pg_sleep(3)` |
| With existing LIMIT ≤ max | Kept as-is | `SELECT * FROM users LIMIT 50` |
| With existing LIMIT > max | Replaced | `LIMIT 2000` → `LIMIT 1000` |
| No LIMIT, has FROM | LIMIT added | `SELECT * FROM users` → `... LIMIT 1000` |

### Known Limitations

1. **CTE (WITH) queries**: Not detected as SELECT queries if they start with WITH
   ```sql
   -- Not wrapped (should be, but isn't)
   WITH temp AS (SELECT * FROM users) SELECT * FROM temp
   ```

2. **Queries starting with comments**: Not detected
   ```sql
   -- Get all users
   SELECT * FROM users  -- Not wrapped if comment is on first line
   ```

3. **hasLimitClause() checks entire query**: May incorrectly detect LIMIT in subqueries
   ```sql
   -- Outer query has no LIMIT, but function thinks it does
   SELECT * FROM (SELECT * FROM users LIMIT 10) sub
   ```

### Related Documentation

See [row_limit_feature.md](./row_limit_feature.md) for user-facing documentation.

---

## 2. CTID Wrapping (`wrapQueryWithCtid`)

### Purpose

Adds PostgreSQL's `ctid` system column to SELECT queries for accurate row identification. This enables inline cell editing by providing a unique physical row identifier.

### Implementation Location

- **File**: `DatabaseConnectionManager+QueryExecution.swift`
- **Function**: `wrapQueryWithCtid(_:)`
- **Line**: ~468-506

### How It Works

```swift
// User query
SELECT * FROM users

// Wrapped query
SELECT *, ctid AS _sqlnb_ctid FROM users
```

### Rules

#### ✅ When CTID is Added

Only for **simple `SELECT * FROM table` queries**:

```sql
-- ✅ CTID added
SELECT * FROM users
SELECT * FROM users WHERE id = 1
SELECT * FROM users LIMIT 10
SELECT * FROM users ORDER BY name
```

#### ❌ When CTID is NOT Added

1. **Not SELECT * FROM**: Specific column selection
   ```sql
   -- ❌ No CTID
   SELECT id, name FROM users
   ```

2. **JOIN queries**: CTID would be ambiguous
   ```sql
   -- ❌ No CTID - Which table's ctid?
   SELECT * FROM users JOIN orders ON users.id = orders.user_id
   SELECT * FROM users LEFT JOIN orders ON users.id = orders.user_id
   SELECT * FROM users INNER JOIN orders ON users.id = orders.user_id
   ```

3. **Subqueries**: Derived tables don't have ctid
   ```sql
   -- ❌ No CTID - Would cause error: "subquery in FROM cannot have SELECT list aliases"
   SELECT * FROM (SELECT * FROM users) AS sub
   ```

4. **Set operations**: CTID not meaningful
   ```sql
   -- ❌ No CTID
   SELECT * FROM users UNION SELECT * FROM admins
   SELECT * FROM users INTERSECT SELECT * FROM active_users
   SELECT * FROM users EXCEPT SELECT * FROM banned_users
   ```

### Detection Logic

```swift
// 1. Must start with "SELECT * FROM"
guard trimmed.uppercased().hasPrefix("SELECT * FROM") else {
    return query
}

// 2. Skip JOINs
if upperQuery.contains(" JOIN ") || upperQuery.contains(" INNER JOIN ") ||
   upperQuery.contains(" LEFT JOIN ") || upperQuery.contains(" RIGHT JOIN ") ||
   upperQuery.contains(" FULL JOIN ") || upperQuery.contains(" CROSS JOIN ") {
    return query
}

// 3. Skip subqueries
if upperQuery.contains("(SELECT") {
    return query
}

// 4. Skip set operations
if upperQuery.contains(" UNION ") || upperQuery.contains(" INTERSECT ") ||
   upperQuery.contains(" EXCEPT ") {
    return query
}

// 5. Safe to add ctid
return addCtidToQuery(query)
```

### Why These Rules?

| Excluded Type | Reason | What Would Happen |
|---------------|--------|-------------------|
| JOINs | Ambiguity | Multiple tables have ctid, unclear which one is returned |
| Subqueries | No ctid column | **Runtime Error**: "column 'ctid' does not exist" |
| Set operations | Meaningless | Result is a new set, not tied to physical rows |
| Specific columns | User intent | User specifically chose columns, don't modify |

### Usage in SQLNotebook

The `_sqlnb_ctid` column is used for:

1. **Inline cell editing**: Identify exact row to UPDATE
2. **Row identification**: When no primary key exists
3. **Fallback mechanism**: Used when primary key approach fails

See `updateCellValue()` in `DatabaseConnectionManager+QueryExecution.swift:212-311`.

### PostgreSQL CTID Background

- **What is ctid?**: Physical location of row (page number, tuple index)
- **Format**: `(page, tuple)` e.g., `(0,1)`, `(5,23)`
- **Reliability**: Can change during VACUUM FULL or table rewrites
- **Performance**: Very fast lookup, no index needed

### Known Limitations

1. **CTID can change**: After VACUUM FULL, ctid values may change
   - **Mitigation**: SQLNotebook uses ctid only for immediate updates, not stored

2. **Only PostgreSQL**: SQLite uses `rowid` (not yet implemented)

3. **Complex queries**: Many valid SELECT * queries are not wrapped
   ```sql
   -- Not wrapped (too complex to safely detect)
   SELECT * FROM users WHERE id IN (SELECT user_id FROM orders)
   SELECT * FROM users, orders WHERE users.id = orders.user_id
   ```

---

## 3. Modification Query Wrapping (`wrapModificationQueryForCount`)

### Purpose

Wraps UPDATE/DELETE/INSERT queries with CTE (Common Table Expression) to capture the number of affected rows, since PostgresNIO 1.30.1 doesn't expose `commandTag` in its public API.

### Implementation Location

- **File**: `DatabaseConnectionManager+QueryExecution.swift`
- **Function**: `wrapModificationQueryForCount(_:)`
- **Line**: ~327-352

### How It Works

```swift
// User query
UPDATE users SET status = 'active' WHERE id = 1

// Wrapped query
WITH affected AS (
  UPDATE users SET status = 'active' WHERE id = 1 RETURNING 1
)
SELECT COUNT(*) FROM affected;
```

### PostgresNIO Context

**Problem**: PostgresNIO 1.30.1 doesn't provide `commandTag` which contains affected row count.

**Solution**: Use `RETURNING 1` to get one row per affected row, then count them.

### Rules

1. **Only wraps UPDATE/DELETE/INSERT** queries
2. **Removes trailing semicolons** before adding RETURNING
3. **Adds `RETURNING 1`** to modification query
4. **Wraps in CTE** and counts results
5. **Returns count as single row**

### Examples

#### UPDATE Query

```sql
-- Original
UPDATE users SET status = 'active' WHERE id < 100;

-- Wrapped
WITH affected AS (
  UPDATE users SET status = 'active' WHERE id < 100 RETURNING 1
)
SELECT COUNT(*) FROM affected;

-- Result: Single row with count, e.g., 42
```

#### DELETE Query

```sql
-- Original
DELETE FROM users WHERE inactive = true

-- Wrapped
WITH affected AS (
  DELETE FROM users WHERE inactive = true RETURNING 1
)
SELECT COUNT(*) FROM affected;
```

#### INSERT Query

```sql
-- Original
INSERT INTO users (name) VALUES ('John'), ('Jane')

-- Wrapped
WITH affected AS (
  INSERT INTO users (name) VALUES ('John'), ('Jane') RETURNING 1
)
SELECT COUNT(*) FROM affected;
```

### Complex Modifications Handled

| Query Type | Example | Wrapped Correctly? |
|-----------|---------|-------------------|
| UPDATE with WHERE | `UPDATE users SET status = 'active' WHERE id = 1` | ✅ Yes |
| UPDATE with subquery | `UPDATE users SET status = 'active' WHERE id IN (SELECT ...)` | ✅ Yes |
| UPDATE with FROM | `UPDATE users SET status = orders.status FROM orders WHERE ...` | ✅ Yes |
| DELETE with USING | `DELETE FROM users USING orders WHERE users.id = orders.user_id` | ✅ Yes |
| INSERT with SELECT | `INSERT INTO users (name) SELECT name FROM temp_users` | ✅ Yes |
| INSERT with RETURNING | `INSERT INTO users (name) VALUES ('John') RETURNING id` | ⚠️ Wrapped, but original RETURNING lost |
| INSERT ON CONFLICT | `INSERT INTO users (id, name) VALUES (1, 'John') ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name` | ✅ Yes |
| Multi-row INSERT | `INSERT INTO users (name) VALUES ('A'), ('B'), ('C')` | ✅ Yes |

### Known Limitations

1. **Original RETURNING clause is lost**: If user's query already has RETURNING, it's replaced
   ```sql
   -- User query
   INSERT INTO users (name) VALUES ('John') RETURNING id

   -- Wrapped (original RETURNING lost)
   WITH affected AS (
     INSERT INTO users (name) VALUES ('John') RETURNING 1
   )
   SELECT COUNT(*) FROM affected;
   ```
   **Impact**: User cannot get auto-generated IDs from INSERT
   **Mitigation**: Not implemented yet - would need to detect existing RETURNING

2. **Only PostgreSQL**: Uses PostgreSQL-specific CTE syntax
   - SQLite support planned for future

---

## Testing

### Test Coverage

All three wrapping functions have comprehensive unit tests in `DatabaseQueryWrappingTests.swift`:

- **wrapQueryWithLimit**: 17 tests
- **wrapQueryWithCtid**: 13 tests (including 5 new tests for JOINs/UNION/subqueries)
- **wrapModificationQueryForCount**: 13 tests

**Total**: 43 unit tests covering all edge cases

### Test Strategy

Tests are **unit tests** of string manipulation logic, not integration tests:

```swift
@Test("SELECT * with JOIN should not add ctid (ambiguous)")
func selectStarWithJoinNoCtid() async throws {
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users JOIN orders ON users.id = orders.user_id"

    let result = await manager.wrapQueryWithCtidPublic(query)

    #expect(result == query, "JOIN queries should not be modified")
    #expect(!result.contains("_sqlnb_ctid"), "Should not add ctid to JOIN queries")
}
```

### Running Tests

```bash
# All query wrapping tests
xcodebuild test -scheme SQLNotebook -only-testing SQLNotebookTests/DatabaseQueryWrappingTests

# Specific test
xcodebuild test -scheme SQLNotebook -only-testing SQLNotebookTests/DatabaseQueryWrappingTests/selectStarWithJoinNoCtid
```

---

## Query Execution Flow

### Complete Flow with All Wrappers

```
1. User submits query
   ↓
2. executeQuery() called in DatabaseConnectionManager
   ↓
3. Check query type
   ↓
   ├─ UPDATE/DELETE/INSERT
   │  ↓
   │  4a. wrapModificationQueryForCount()
   │  5a. Execute wrapped query
   │  6a. Parse COUNT(*) result
   │  7a. Return QueryResult with affectedRows
   │
   └─ SELECT
      ↓
      4b. wrapQueryWithLimit(query, maxRows)
      5b. wrapQueryWithCtid() if PostgreSQL
      6b. Execute wrapped query
      7b. Parse results, extract ctid column
      8b. Return QueryResult with rows and rowIdentifiers
```

### Example: Complete Transformation

```sql
-- User query
SELECT * FROM users WHERE active = true

-- After wrapQueryWithLimit() (maxRows = 1000)
SELECT * FROM users WHERE active = true LIMIT 1000

-- After wrapQueryWithCtid() (PostgreSQL)
SELECT *, ctid AS _sqlnb_ctid FROM users WHERE active = true LIMIT 1000

-- This is the final query sent to database
```

### Debug Logging

Two debug logs show transformation:

```swift
// Before wrapping
print("🗄️ [DatabaseConnectionManager] About to execute query: `\(query)` (maxRows: \(maxRows))")

// After all wrapping
print("🚀 [DatabaseConnectionManager] Final query to be sent to database: `\(executionQuery)`")
```

---

## Performance Implications

### LIMIT Wrapping

**Benefits**:
- ✅ Prevents excessive memory usage
- ✅ Faster query execution for large tables
- ✅ Better UI responsiveness

**Cost**:
- ❌ Minimal regex overhead (~microseconds)

### CTID Wrapping

**Benefits**:
- ✅ Enables inline editing without knowing primary key
- ✅ Very fast row lookup (physical location)

**Cost**:
- ❌ Minimal string replacement overhead
- ❌ One extra column in result set (~8 bytes per row)

### Modification Query Wrapping

**Benefits**:
- ✅ Accurate affected row counts
- ✅ Works reliably across all PostgreSQL versions

**Cost**:
- ❌ CTE overhead (negligible for most queries)
- ❌ Cannot use original RETURNING clause

---

## Future Improvements

### High Priority

1. **Fix CTE detection** in `wrapQueryWithLimit()`
   - Detect `WITH ... SELECT` as SELECT query
   - Current workaround: User can add LIMIT manually

2. **Support original RETURNING** in modification queries
   - Detect existing RETURNING clause
   - Preserve user's RETURNING columns
   - Still count affected rows

### Medium Priority

3. **Strip leading comments** before query type detection
   ```sql
   -- This comment prevents detection
   SELECT * FROM users
   ```

4. **Improve LIMIT detection** to only check outer query
   - Current: Detects LIMIT anywhere in query
   - Desired: Only detect LIMIT in outer SELECT

5. **SQLite rowid support** for `wrapQueryWithCtid()`
   - Similar to ctid but for SQLite
   - Use `rowid AS _sqlnb_rowid`

### Low Priority

6. **Smart ctid wrapping** for JOINs
   - Add ctid for main table only
   - Alias as `users_ctid` to indicate table
   - Requires query parsing to identify main table

7. **Support table aliases** in ctid wrapping
   ```sql
   -- Currently not wrapped
   SELECT * FROM users u WHERE u.active = true
   ```

---

## Troubleshooting

### Query Not Wrapped with LIMIT

**Symptoms**: Large result set returned, expected to be limited

**Check**:
1. Is it a SELECT query? (UPDATE/DELETE not wrapped)
2. Does it have FROM clause? (Function calls not wrapped)
3. Does it already have LIMIT? (May be kept if ≤ maxRows)
4. Does it start with comment? (Not detected)

**Solutions**:
- Add LIMIT manually
- Remove leading comments
- Check maxRows setting in Settings

### CTID Not Present in Results

**Symptoms**: `rowIdentifiers` array is empty, inline editing fails

**Check**:
1. Is it `SELECT * FROM table`? (Specific columns not wrapped)
2. Is it a JOIN? (JOINs not wrapped)
3. Is it a subquery? (Subqueries not wrapped)
4. Is it PostgreSQL? (SQLite not supported yet)

**Solutions**:
- Use simple `SELECT * FROM table` query
- Define primary key for table (better approach)
- Avoid JOINs if you need inline editing

### Affected Rows Count is 0

**Symptoms**: UPDATE/DELETE reports 0 rows affected, but data was modified

**Check**:
1. Is the query actually modifying data?
2. Check database logs for actual query executed
3. Verify CTE wrapping succeeded

**Debug**:
```swift
// Enable debug logging to see wrapped query
print("🚀 [DatabaseConnectionManager] Final query: \(executionQuery)")
```

---

## Related Files

### Implementation
- `DatabaseConnectionManager+QueryExecution.swift` - All wrapper functions
- `DatabaseConnectionManager.swift` - executeQuery() caller
- `NotebookViewModel+Execution.swift` - Query execution coordinator

### Tests
- `DatabaseQueryWrappingTests.swift` - 43 unit tests for all wrappers
- `DatabaseQueryExecutionTests.swift` - Integration tests with real database

### Documentation
- `row_limit_feature.md` - User-facing row limit documentation

---

## Changelog

### 2026-01-06 - CTID Wrapping Improvements
- ✅ Fixed: JOINs no longer get ctid (ambiguous)
- ✅ Fixed: Subqueries no longer get ctid (causes error)
- ✅ Added: UNION/INTERSECT/EXCEPT detection
- ✅ Added: 5 new unit tests for edge cases
- 📝 Created: This comprehensive documentation

### 2024-XX-XX - Initial Implementation
- ✅ Implemented: wrapQueryWithLimit()
- ✅ Implemented: wrapQueryWithCtid()
- ✅ Implemented: wrapModificationQueryForCount()
- ✅ Added: Basic unit tests
