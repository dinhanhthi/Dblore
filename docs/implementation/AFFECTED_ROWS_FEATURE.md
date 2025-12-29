# Affected Rows Display Feature

## Overview

Feature này hiển thị số rows bị ảnh hưởng (affected rows) khi user chạy các SQL modification queries như UPDATE, DELETE, và INSERT. Thay vì không có output hoặc empty result, user sẽ thấy success message với số rows affected.

## User Experience

### Before
Khi chạy modification query như:
```sql
UPDATE users SET status = 'active' WHERE created_at < '2024-01-01';
```

Không có output hiển thị, user không biết query có chạy thành công hay bao nhiêu rows bị modify.

### After
User sẽ thấy success message:
```
✅ Success
15 rows affected | Execution time: 0.045s
```

- **Green checkmark icon** và "Success" header
- Số rows affected với proper singular/plural ("1 row" vs "3 rows")
- Execution time
- Green background (opacity 0.1) để distinguish từ error messages (red) và SELECT results

## Technical Implementation

### 1. Data Models

#### NotebookCell.swift
Thêm field `affectedRows` vào `CellResult`:

```swift
struct CellResult: Codable, Sendable {
  // ... existing fields ...

  /// Number of rows affected by UPDATE/DELETE/INSERT (nil for SELECT queries)
  let affectedRows: Int?
}
```

#### DatabaseTypes.swift
Thêm field tương tự vào `QueryResult`:

```swift
struct QueryResult: Sendable {
  // ... existing fields ...

  /// Number of rows affected by UPDATE/DELETE/INSERT (nil for SELECT queries)
  let affectedRows: Int?
}
```

### 2. Database Layer

#### Query Type Detection
Thêm helper function để detect modification queries:

```swift
private func isModificationQuery(_ query: String) -> Bool {
  let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  return trimmed.hasPrefix("UPDATE") ||
         trimmed.hasPrefix("DELETE") ||
         trimmed.hasPrefix("INSERT")
}
```

#### Getting Affected Rows Count

**Problem**: PostgresNIO version 1.30.1 không expose `commandTag` (chứa affected rows count) trong public streaming API. Newer versions có thể có `onMetadata` callback nhưng version hiện tại không support.

**Solution**: Wrap modification query với Common Table Expression (CTE) và RETURNING clause:

```swift
private func wrapModificationQueryForCount(_ query: String) -> String {
  let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
  let cleanQuery = trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed

  return """
    WITH affected AS (
      \(cleanQuery) RETURNING 1
    )
    SELECT COUNT(*) FROM affected;
    """
}
```

**How it works**:
1. `RETURNING 1` forces PostgreSQL trả về 1 row (value = 1) cho mỗi row affected
2. CTE `affected` captures những rows này
3. `SELECT COUNT(*) FROM affected` đếm số rows → chính là affected rows count
4. PostgresNIO stream trả về 1 row duy nhất chứa count number

**Example transformation**:
```sql
-- Original query
UPDATE users SET status = 'active' WHERE id = 1;

-- Wrapped query
WITH affected AS (
  UPDATE users SET status = 'active' WHERE id = 1 RETURNING 1
)
SELECT COUNT(*) FROM affected;
```

#### Query Execution Flow

```swift
func executeQuery(_ query: String, maxRows: Int) async throws -> QueryResult {
  let isModification = isModificationQuery(query)

  if isModification {
    let wrappedQuery = wrapModificationQueryForCount(query)
    let stream = try await connection.query(PostgresQuery(unsafeSQL: wrappedQuery))

    var affectedRows = 0
    for try await row in stream {
      let randomAccess = row.makeRandomAccess()
      if let cell = randomAccess.first {
        if let count = try? cell.decode(Int64.self, context: .default) {
          affectedRows = Int(count)
        }
      }
    }

    return QueryResult(
      columns: [],
      rows: [],
      rowCount: 0,
      executionTime: executionTime,
      affectedRows: affectedRows
    )
  }

  // SELECT query handling...
}
```

### 3. UI Layer (CellView.swift)

#### Success View

```swift
private func successView(affectedRows: Int, executionTime: TimeInterval) -> some View {
  VStack(alignment: .leading, spacing: 0) {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundColor(.green)

      Text("Success")
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(.green)
    }
    .padding(.bottom, Spacing.md)

    HStack(spacing: Spacing.md) {
      Text("\(affectedRows) row\(affectedRows == 1 ? "" : "s") affected")
        .font(.mono)
        .foregroundColor(.foreground)

      Text("|")
        .foregroundColor(.foregroundSubtle)

      Text(String(format: "Execution time: %.3fs", executionTime))
        .font(.mono)
        .foregroundColor(.foregroundSubtle)
    }
  }
  .padding(Spacing.md)
  .frame(maxWidth: .infinity, alignment: .leading)
  .background(Color.green.opacity(0.1))
  .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
}
```

#### Result Area Logic

```swift
private func resultArea(_ result: CellResult) -> some View {
  VStack(alignment: .leading, spacing: Spacing.md) {
    if let error = result.error {
      // Error display (red background)
      errorView(error)
    } else if let affectedRows = result.affectedRows {
      // Success message (green background)
      successView(affectedRows: affectedRows, executionTime: result.executionTime)
    } else {
      // Result table (for SELECT queries)
      ResultTableView(result: result, viewModel: viewModel, cellId: cell.id)
      resultMetadata(result)
    }
  }
}
```

## Design Decisions

### Why CTE + RETURNING approach?

**Alternatives considered**:
1. ❌ Count rows in stream - Doesn't work, modification queries return empty stream
2. ❌ Access PostgresNIO internal commandTag - Not exposed in public API
3. ✅ **CTE with RETURNING** - Standard SQL, officially supported by PostgreSQL

**Advantages**:
- Works với tất cả modification queries (UPDATE, DELETE, INSERT)
- Không cần access internal PostgresNIO APIs
- PostgreSQL standard SQL feature
- Accurate count thay vì luôn trả về 0
- Atomic operation - count và modification trong cùng transaction

### Why separate success view instead of reusing result table?

- **Clear visual distinction**: Green = success modification, vs table = query results
- **Consistent with error pattern**: Errors show red banner, success shows green banner
- **Simpler UX**: Users don't need to interpret empty tables
- **Following conventions**: SQL tools like pgAdmin, DBeaver hiển thị affected rows messages

## Supported Query Types

### ✅ Supported
- `UPDATE` statements
- `DELETE` statements
- `INSERT` statements (including INSERT INTO ... SELECT)

### ❌ Not Supported (shows as modification queries)
- `TRUNCATE` - DDL, không có RETURNING support
- `CREATE`, `ALTER`, `DROP` - DDL commands
- `COPY` - Bulk operations

These queries sẽ cần được detected riêng hoặc fall back to different handling.

## Future Enhancements

### 1. Use PostgresNIO onMetadata callback (when available)
Future versions of PostgresNIO may expose `onMetadata` callback that provides access to `commandTag`:

```swift
let stream = try await connection.query(
  PostgresQuery(unsafeSQL: query),
  logger: logger,
  onMetadata: { metadata in
    // commandTag format: "UPDATE 5", "DELETE 3", "INSERT 0 1"
    affectedRows = parseAffectedRows(from: metadata.string)
  }
)
```

This would eliminate the need for CTE wrapping and provide direct access to PostgreSQL's command completion metadata.

**Implementation ready**: The `parseAffectedRows()` helper function is already implemented and ready to use when PostgresNIO API becomes available.

### 2. Support for other SQL statements
- DDL statements (CREATE, ALTER, DROP) - Show "Query executed successfully"
- TRUNCATE - May need special handling
- COPY commands

### 2. Multiple statements
Hiện tại chỉ handle single statement. Nếu user chạy multiple statements separated by semicolons, chỉ statement cuối sẽ có count.

Potential solution: Split và execute separately, aggregate results.

### 3. Transaction support
- BEGIN, COMMIT, ROLLBACK messages
- Show transaction state in UI

### 4. Query metadata
- Show query plan (EXPLAIN)
- Execution statistics (timing breakdown)
- Warning messages from PostgreSQL

## Error Handling

### Query wrapping errors
If CTE wrapping fails or RETURNING không supported (e.g., older PostgreSQL versions < 8.2), error sẽ được caught và displayed như normal query error.

### Count parsing errors
If count value không parse được từ stream, `affectedRows` sẽ = 0 và vẫn show success message với "0 rows affected".

## Testing Recommendations

### Manual Testing
1. **UPDATE query**: `UPDATE users SET status = 'active' WHERE id < 5;`
   - Verify count matches actual rows modified
2. **DELETE query**: `DELETE FROM logs WHERE created_at < NOW() - INTERVAL '1 day';`
   - Verify count is correct
3. **INSERT query**: `INSERT INTO users (name, email) VALUES ('Test', 'test@example.com');`
   - Should show "1 row affected"
4. **Zero rows affected**: `UPDATE users SET status = 'active' WHERE 1=0;`
   - Should show "0 rows affected"
5. **Error cases**: `UPDATE non_existent_table SET x = 1;`
   - Should show error message (red), not success

### Edge Cases
- Queries with trailing semicolons
- Queries with comments
- Multiline queries
- Queries with existing RETURNING clause (may conflict)

## Performance Considerations

### Overhead
The CTE wrapping adds minimal overhead:
- Same query execution (không slow down actual UPDATE/DELETE/INSERT)
- Chỉ thêm COUNT(*) operation trên already-modified rows
- No additional I/O or table scans

### Memory
Affected rows count được stored as single Int64, negligible memory impact.

## Database Compatibility

### PostgreSQL
- ✅ Full support (version 8.2+)
- RETURNING clause available since PostgreSQL 8.2

### SQLite (Future)
- ✅ Partial support (version 3.35.0+)
- RETURNING clause available since SQLite 3.35.0 (March 2021)
- May need different implementation for older SQLite versions

## File Persistence

### Storage in .sqlnb Files

The `affectedRows` value is **automatically persisted** trong `.sqlnb` files khi user saves notebook (if "Include Results on Save" setting is enabled).

**JSON Structure Example**:
```json
{
  "cells": [
    {
      "id": "cell-uuid",
      "cellType": "sql",
      "content": "UPDATE users SET status = 'active' WHERE id = 1;",
      "executionCount": 1,
      "result": {
        "executionTime": 0.045,
        "rowCount": 0,
        "timestamp": "2025-12-29T10:30:00Z",
        "wasLimited": false,
        "columns": [],
        "rows": [],
        "affectedRows": 1
      }
    }
  ]
}
```

**Key Points**:
- `affectedRows` is saved for modification queries (UPDATE, DELETE, INSERT)
- For SELECT queries, `affectedRows` is `null`
- Results are only saved if user enables "Include Results on Save" in Settings
- When loading notebook, affected rows messages are restored and displayed

### Implementation Details

Serialization is handled in `SQLNotebookDocument.swift`:
- **Encoding** ([SQLNotebookDocument.swift:235-238](SQLNotebook/Models/SQLNotebookDocument.swift#L235-L238)): `affectedRows` field is encoded if not nil
- **Decoding** ([SQLNotebookDocument.swift:193](SQLNotebookDocument.swift#L193)): `affectedRows` is decoded from saved JSON

This ensures query results (including affected rows count) persist across app sessions.

## References

- [PostgreSQL RETURNING Documentation](https://www.postgresql.org/docs/current/dml-returning.html)
- [PostgreSQL CTE Documentation](https://www.postgresql.org/docs/current/queries-with.html)
- [PostgresNIO GitHub](https://github.com/vapor/postgres-nio)
- [Get affected rows with RETURNING clause](https://dev.to/asifroyal/get-the-count-of-affected-rows-with-ease-the-power-of-the-returning-clause-3g2j)

## Version History

- **v1.0** (2025-12-29): Initial implementation
  - Support for UPDATE, DELETE, INSERT queries
  - CTE + RETURNING approach for affected rows count
  - Green success banner UI
  - PostgreSQL only

---

**Last Updated**: December 29, 2025
**Author**: SQLNotebook Team
