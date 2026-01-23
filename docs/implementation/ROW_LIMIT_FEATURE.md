# Row Limit Feature Documentation

## Overview

SQLNotebook implements a configurable row limit system to prevent users from accidentally fetching too many rows from the database, which could cause performance issues or memory problems.

## Features

### 1. Configurable Row Limit

- **Default limit**: 50 rows
- **Maximum allowed**: 200 rows
- **Minimum allowed**: 10 rows
- **Configuration**: Adjustable via Settings in the right sidebar

### 2. Automatic Query Modification

The system automatically modifies SELECT queries to enforce the row limit:

#### Case 1: Query without LIMIT
```sql
-- User query
SELECT * FROM users WHERE active = true

-- Executed query (with maxRowLimit = 50)
SELECT * FROM users WHERE active = true LIMIT 50
```

#### Case 2: Query with LIMIT exceeding maxRowLimit
```sql
-- User query
SELECT * FROM users ORDER BY id LIMIT 100

-- Executed query (with maxRowLimit = 50)
SELECT * FROM users ORDER BY id LIMIT 50
```

#### Case 3: Query with LIMIT within maxRowLimit
```sql
-- User query
SELECT * FROM users LIMIT 30

-- Executed query (with maxRowLimit = 50)
SELECT * FROM users LIMIT 30  -- No modification
```

### 3. User Notifications

The system provides two types of notifications when limits are applied:

#### Toast Notification (Bottom-right corner)
- **When**: User's LIMIT clause exceeds maxRowLimit and is capped
- **Duration**: 4 seconds (auto-dismiss)
- **Message**: "Query limit capped from {requested} to {actual} rows. Increase in Settings."
- **Type**: Warning (yellow)

#### Metadata Warning (Below result table)
- **When**: Results are limited (either auto-limited or user LIMIT capped)
- **Display**: "Rows: {count} ⚠️ (limited to {maxRowLimit} rows)"
- **Location**: Result metadata bar, next to execution time

## Implementation Details

### Files Modified

1. **NotebookSettings.swift**
   - Added `maxRowLimit: Int` property
   - Default value: 50
   - Clamped between 1-200 in both init and decode

2. **DatabaseConnectionManager.swift**
   - `extractLimitValue()`: Parse LIMIT value from SQL query
   - `wrapQueryWithLimit()`: Add or replace LIMIT clause
   - `replaceLimitValue()`: Replace existing LIMIT value
   - `executeQuery()`: Detect when user LIMIT exceeds maxRows

3. **NotebookCell.swift (CellResult)**
   - Added `userLimitExceeded: Bool`
   - Added `userRequestedLimit: Int?`

4. **QueryResult** (in DatabaseConnectionManager.swift)
   - Added `userLimitExceeded: Bool`
   - Added `userRequestedLimit: Int?`

5. **NotebookViewModel+Execution.swift**
   - Show toast when `userLimitExceeded` is true
   - Pass new fields from QueryResult to CellResult

6. **SettingsContent.swift**
   - Added "Max Rows" slider (10-200, step: 10)

7. **CellView.swift**
   - Updated `resultMetadata()` to show warning when `wasLimited || userLimitExceeded`

8. **ToastView.swift** (new file)
   - Toast notification component
   - Supports: info, warning, error, success types

9. **NotebookViewModel.swift**
   - Added `currentToast: ToastMessage?`
   - Added `showToast()` method with auto-dismiss

10. **ContentView.swift**
    - Added toast overlay at bottom-right corner
    - Smooth slide-in animation

### Logic Flow

```
1. User executes query
   ↓
2. Extract LIMIT value (if present)
   ↓
3. Check if userLimit > maxRowLimit
   ↓
4. Modify query:
   - No LIMIT → Append LIMIT maxRowLimit
   - LIMIT > maxRowLimit → Replace with LIMIT maxRowLimit
   - LIMIT ≤ maxRowLimit → Keep original
   ↓
5. Execute modified query on database
   ↓
6. Collect results (up to maxRowLimit rows)
   ↓
7. Set flags:
   - wasLimited = true (if no LIMIT and got maxRows)
   - userLimitExceeded = true (if user LIMIT > maxRows)
   ↓
8. Show notifications:
   - Toast if userLimitExceeded
   - Metadata warning if wasLimited OR userLimitExceeded
```

## User Guide

### Adjusting Row Limit

1. Open Settings sidebar (Cmd+, or Settings button)
2. Navigate to "Result Table" section
3. Adjust "Max Rows" slider (10-200 rows)
4. Changes apply immediately to new queries

### Understanding Warnings

**Toast Notification**
- Appears when your LIMIT clause is reduced
- Example: `LIMIT 100` reduced to `LIMIT 50`
- Click anywhere to dismiss, or wait 4 seconds

**Metadata Warning**
- Shows ⚠️ icon next to row count
- Indicates results may be incomplete
- Use LIMIT in your query for precise control

### Best Practices

1. **For large tables**: Always use LIMIT clause explicitly
   ```sql
   SELECT * FROM large_table ORDER BY id LIMIT 100
   ```

2. **For pagination**: Combine LIMIT with OFFSET
   ```sql
   SELECT * FROM users ORDER BY created_at DESC LIMIT 50 OFFSET 100
   ```

3. **Increase limit temporarily**: Adjust in Settings for specific queries
   - Set to 200 for comprehensive results
   - Remember to reset to default (50) after

4. **For exports**: Consider using database native export tools for large datasets

## Technical Notes

### Query Modification Strategy

The system uses regex replacement rather than subquery wrapping to preserve query structure:

**Advantages**:
- Preserves ORDER BY, WHERE, GROUP BY clauses
- No subquery overhead
- Compatible with all valid SELECT syntax
- Maintains query readability

**Pattern Matching**:
- LIMIT detection: `\\blimit\\b` (case-insensitive)
- LIMIT extraction: `\\blimit\\s+(\\d+)`
- LIMIT replacement: `\\bLIMIT\\s+\\d+` → `LIMIT {maxRows}`

### Edge Cases Handled

1. **Semicolons**: Removed before parsing
   ```sql
   SELECT * FROM users LIMIT 100; -- Works correctly
   ```

2. **Case insensitive**: LIMIT, limit, Limit all detected
   ```sql
   SELECT * FROM users LiMiT 100  -- Works correctly
   ```

3. **Whitespace variations**
   ```sql
   SELECT * FROM users LIMIT    100   -- Works correctly
   ```

4. **Non-SELECT queries**: Not modified
   ```sql
   INSERT INTO users VALUES (...);  -- No LIMIT added
   UPDATE users SET active = true;  -- No LIMIT added
   ```

## Performance Implications

### Benefits

1. **Reduced memory usage**: Client only receives limited rows
2. **Faster query execution**: Database processes fewer rows
3. **Better responsiveness**: UI remains responsive with smaller result sets

### Considerations

1. **Database still processes query**: LIMIT applied at result level
2. **For very large tables**: Add WHERE clauses to filter early
3. **Indexes**: Ensure proper indexes on ORDER BY columns

## Future Enhancements

Potential improvements for future versions:

1. **Per-query override**: Allow inline comments to override limit
   ```sql
   -- @limit 500
   SELECT * FROM large_table
   ```

2. **Smart limits**: Different limits based on table size
   ```sql
   Small tables (< 1000 rows): No limit
   Medium tables (< 100k rows): 100 rows
   Large tables (> 100k rows): 50 rows
   ```

3. **Result streaming**: Load additional rows on-demand
4. **Export options**: Quick export to CSV without limit
5. **Warning threshold**: Show warning before executing large queries

## Troubleshooting

### Toast not appearing

**Issue**: Query LIMIT exceeds maxRowLimit but no toast shows

**Solutions**:
1. Check Settings → Max Rows value
2. Ensure query has LIMIT clause
3. Verify LIMIT value > maxRowLimit
4. Check console for errors

### Warning always shows

**Issue**: Warning appears even with small result sets

**Solutions**:
1. Check if query has LIMIT clause
2. Verify result count < maxRowLimit
3. Check for stale result data (re-run query)

### Query modified incorrectly

**Issue**: LIMIT clause not detected or replaced

**Solutions**:
1. Remove semicolons and extra whitespace
2. Ensure LIMIT is uppercase or lowercase (not mixed case pattern)
3. Check for typos in LIMIT keyword
4. Verify number after LIMIT is valid integer

## Related Documentation

- [Settings Guide](./SETTINGS.md)
- [Query Execution](./QUERY_EXECUTION.md)
- [Performance Tips](./PERFORMANCE.md)

## Changelog

### Version 1.0 (Initial Release)
- Added configurable row limit (default: 50, max: 200)
- Automatic query modification with LIMIT clause
- Toast notifications for capped queries
- Metadata warnings for limited results
- Settings UI for adjusting limits
