# optimize

Optimizes app performance - reduces CPU/RAM usage, prevents crashes, handles large datasets efficiently, ensures seamless operation with many cells and rows.

## How to Use This Command

When user requests performance optimization (check performance, optimize code, reduce memory usage, prevent crashes, handle large datasets), follow this workflow:

### Step 1: Identify Performance Issues

Determine what needs optimization:
- **Check performance**: Analyze current code for bottlenecks
- **Optimize specific component**: Focus on Views, ViewModels, Database queries
- **Handle large datasets**: Improve cell list, result tables, schema loading
- **Reduce memory usage**: Find and fix memory leaks, reduce allocations
- **Prevent crashes**: Add safeguards, error handling, resource limits

### Step 2: Profile and Measure

Before optimizing, understand current state:

```swift
// Add timing measurements
let start = CFAbsoluteTimeGetCurrent()
await executeQuery(sql)
let duration = CFAbsoluteTimeGetCurrent() - start
print("⏱️ Query took \(duration)s")

// Check memory usage
let memory = ProcessInfo.processInfo.physicalMemory
print("💾 Memory: \(memory / 1_000_000) MB")
```

**Use Xcode Instruments**:
```bash
# Product → Profile (Cmd+I)
# Choose: Time Profiler, Allocations, or Leaks
```

**Look for**:
- Functions taking >100ms
- Memory allocations >10MB
- Retain cycles
- High CPU usage during idle

### Step 3: Apply Optimization Strategies

Choose appropriate strategy based on issue:

#### Strategy 1: SwiftUI View Optimization

```swift
// ❌ BAD: Heavy computation in body
struct CellView: View {
  let cell: NotebookCell

  var body: some View {
    VStack {
      let processed = processContent(cell.content) // Recomputes every render!
      Text(processed)
    }
  }
}

// ✅ GOOD: Memoized computation
struct CellView: View {
  let cell: NotebookCell

  private var processedContent: String {
    processContent(cell.content) // Computed once per cell change
  }

  var body: some View {
    VStack {
      Text(processedContent)
    }
  }
}

// ✅ BETTER: Extract subview
struct CellView: View {
  let cell: NotebookCell

  var body: some View {
    VStack {
      CellContentView(content: cell.content)
    }
  }
}
```

#### Strategy 2: Lazy Loading for Large Lists

```swift
// ❌ BAD: Renders all cells at once
ScrollView {
  VStack {
    ForEach(notebook.cells) { cell in
      CellView(cell: cell)
    }
  }
}

// ✅ GOOD: Lazy loading
ScrollView {
  LazyVStack {
    ForEach(notebook.cells) { cell in
      CellView(cell: cell)
    }
  }
}
```

#### Strategy 3: Result Table Pagination

```swift
// ❌ BAD: Load all rows
func executeQuery(_ sql: String) async throws -> CellResult {
  let rows = try await connectionManager.execute(sql)
  return CellResult(rows: rows) // Could be 100,000 rows!
}

// ✅ GOOD: Limit rows
func executeQuery(_ sql: String) async throws -> CellResult {
  let limit = AppSettings.shared.maxRowLimit
  let limitedSQL = appendLimit(sql, limit: limit)
  let rows = try await connectionManager.execute(limitedSQL)
  return CellResult(rows: rows, hasMore: rows.count == limit)
}
```

#### Strategy 4: Memory Management

```swift
// ❌ BAD: Retain cycle
class ViewModel {
  var onUpdate: (() -> Void)?

  init() {
    onUpdate = {
      self.refresh() // Captures self strongly!
    }
  }
}

// ✅ GOOD: Weak capture
class ViewModel {
  var onUpdate: (() -> Void)?

  init() {
    onUpdate = { [weak self] in
      self?.refresh()
    }
  }
}
```

#### Strategy 5: Database Query Optimization

```swift
// ❌ BAD: N+1 queries
for table in tables {
  let columns = try await fetchColumns(table.name)
  table.columns = columns
}

// ✅ GOOD: Batch query
let allColumns = try await fetchAllColumns(tables.map { $0.name })
```

### Step 4: Common Performance Issues & Solutions

#### Issue 1: Too Many Cells Causing Lag

**Problem**: App slow with 100+ cells

**Solution**:
- Use `LazyVStack` instead of `VStack`
- Virtualize visible range
- Extract cell views to prevent redraws

```swift
ScrollView {
  LazyVStack(spacing: Spacing.lg) {
    ForEach(cells) { cell in
      CellView(cell: cell)
        .id(cell.id)
    }
  }
}
```

#### Issue 2: Large Result Tables Freezing UI

**Problem**: Displaying 10,000+ rows crashes/freezes

**Solution**:
- Implement row limit (default: 1000)
- Add pagination controls
- Use virtual scrolling

```swift
// Add LIMIT to queries
let maxRows = AppSettings.shared.maxRowLimit
let limitedSQL = "\(sql) LIMIT \(maxRows)"

// Virtual scrolling
LazyVStack {
  ForEach(visibleRows, id: \.self) { row in
    RowView(row: row)
  }
}
```

#### Issue 3: Memory Leaks

**Problem**: Memory grows indefinitely

**Solution**:
- Use `[weak self]` in closures
- Implement proper cleanup in `deinit`
- Clear caches when memory pressure

```swift
// Weak references
Task { [weak self] in
  await self?.loadData()
}

// Memory pressure handling
func clearCachesOnMemoryPressure() {
  databaseTables.removeAll()
  // Clear other caches
}
```

#### Issue 4: Slow Query Execution

**Problem**: Queries take too long

**Solution**:
- Add query timeout
- Show progress indicator
- Allow cancellation

```swift
// Timeout
try await withTimeout(.seconds(30)) {
  try await executeQuery(sql)
}

// Cancellation
@State private var currentTask: Task<Void, Never>?

func runQuery() {
  currentTask?.cancel()
  currentTask = Task {
    await executeWithCancellation()
  }
}
```

#### Issue 5: UI Unresponsive

**Problem**: UI freezes during operations

**Solution**:
- Move heavy work off main thread
- Use `async/await` properly
- Use actors for shared state

```swift
// Move to background
let result = await Task.detached {
  expensiveComputation()
}.value

await MainActor.run {
  updateUI(result)
}
```

### Step 5: Verify Improvements

After optimization:

1. **Re-measure performance**:
   ```swift
   // Compare before/after
   print("Before: \(oldDuration)s → After: \(newDuration)s")
   print("Improvement: \((oldDuration - newDuration) / oldDuration * 100)%")
   ```

2. **Test with realistic data**:
   - 1000+ cells
   - 10,000+ row result sets
   - Multiple concurrent queries

3. **Profile with Instruments**:
   - Check CPU usage
   - Monitor memory allocations
   - Verify no leaks

4. **User testing**:
   - Test on older Macs if possible
   - Verify UI remains responsive
   - Check for crashes

## Performance Checklist

### ✅ SwiftUI Optimization
- [ ] Use `LazyVStack`/`LazyHStack` for long lists
- [ ] Extract subviews to prevent unnecessary redraws
- [ ] Avoid heavy computations in `body`
- [ ] Use `id()` modifier for efficient list updates
- [ ] Minimize view hierarchy depth
- [ ] Use `task()` modifier for async work

### ✅ Memory Management
- [ ] Use `[weak self]` in closures
- [ ] Release large objects when not needed
- [ ] Implement cleanup in `deinit`
- [ ] Clear caches on memory pressure
- [ ] Monitor with Instruments

### ✅ Database Optimization
- [ ] Add `LIMIT` clauses to queries
- [ ] Use pagination for large results
- [ ] Cancel queries when not needed
- [ ] Batch operations when possible
- [ ] Index frequently queried columns

### ✅ Data Structures
- [ ] Use arrays for ordered collections
- [ ] Use dictionaries for lookups
- [ ] Avoid unnecessary copying
- [ ] Clear old data when not needed

### ✅ Concurrency
- [ ] Use `async/await` instead of callbacks
- [ ] Run heavy tasks off main thread
- [ ] Use actors for thread-safe state
- [ ] Cancel tasks when no longer needed

## Resource Limits

Implement safeguards to prevent crashes:

```swift
// Constants in AppSettings or dedicated file
enum PerformanceLimits {
  static let maxCellsPerNotebook = 1000
  static let maxRowsPerQuery = 10_000
  static let maxResultTableHeight: CGFloat = 500
  static let queryTimeout: TimeInterval = 30
  static let maxMemoryUsageMB = 500
}

// Enforce limits
guard notebook.cells.count < PerformanceLimits.maxCellsPerNotebook else {
  throw NotebookError.tooManyCells
}

// Add row limit to queries
let limitedSQL = appendLimit(sql, limit: PerformanceLimits.maxRowsPerQuery)
```

## Best Practices

### ✅ Always Do
1. **Profile before optimizing** - Measure first, optimize second
2. **Use lazy loading** - Don't load what you don't need
3. **Implement pagination** - Limit data displayed at once
4. **Monitor memory** - Use Instruments regularly
5. **Test with realistic data** - 1000 cells, 10,000 rows
6. **Clean up resources** - Release when not needed
7. **Handle errors gracefully** - Never crash on edge cases

### ❌ Never Do
1. **Premature optimization** - Profile first
2. **Block main thread** - Keep UI responsive
3. **Load everything upfront** - Use lazy loading
4. **Ignore memory warnings** - Handle gracefully
5. **Create retain cycles** - Use weak references
6. **Skip error handling** - Always handle failures
7. **Guess at problems** - Use Instruments

## Example Workflows

### Example 1: Optimize Cell Rendering

**User request**: "Optimize cell rendering - app is slow with 100 cells"

**AI should**:
1. Check if `VStack` is used → replace with `LazyVStack`
2. Look for heavy computations in cell `body` → extract to computed properties
3. Check for unnecessary view rebuilds → add `id()` modifiers
4. Profile with Instruments to verify improvement
5. Test with 1000 cells to ensure it scales

### Example 2: Optimize Result Table

**User request**: "Result table freezes with 10,000 rows"

**AI should**:
1. Check if row limit is implemented → add `LIMIT` to queries
2. Implement pagination controls
3. Use `LazyVStack` for row rendering
4. Add virtual scrolling if needed
5. Test with 50,000 rows to verify no freeze

### Example 3: Fix Memory Leak

**User request**: "Memory keeps growing when opening/closing notebooks"

**AI should**:
1. Profile with Instruments → Leaks tool
2. Find retain cycles in closures → add `[weak self]`
3. Check for unreleased resources → implement cleanup
4. Verify `deinit` is called when expected
5. Re-profile to confirm leak is fixed

### Example 4: Optimize Database Queries

**User request**: "Schema loading takes too long with 100 tables"

**AI should**:
1. Check for N+1 queries → batch into single query
2. Add indexes if needed
3. Cache results when appropriate
4. Show loading indicator for UX
5. Measure before/after query time

## Response Format

When reporting optimization results:

```markdown
# Performance Optimization Report

## 📊 Measurements

### Before Optimization
- Memory: X MB
- CPU: Y%
- Operation time: Z seconds

### After Optimization
- Memory: X MB (-A MB, -B%)
- CPU: Y% (-C%)
- Operation time: Z seconds (-D seconds, -E%)

## 🔧 Changes Made

### 1. [Component/File Name]
**Issue**: [Description of problem]
**Fix**: [What was changed]
**Impact**: [Performance improvement]

```swift
// Before
[old code]

// After
[new code]
```

## ✅ Verification

- [x] Profiled with Instruments
- [x] Tested with 1000 cells
- [x] Tested with 10,000 rows
- [x] No memory leaks detected
- [x] UI remains responsive

## 💡 Future Improvements

1. [Potential further optimization]
2. [Another suggestion]
```

## Performance Targets

Ensure the app meets these goals:

- ✅ **Smooth scrolling** with 1000+ cells
- ✅ **Instant queries** (<1s for typical workloads)
- ✅ **Handle 10,000+ rows** without freezing
- ✅ **Memory usage** <500 MB for normal use
- ✅ **Zero crashes** under normal operation
- ✅ **Responsive UI** at all times (<16ms frame time)

## Your Goal

Make SQLNotebook **fast, efficient, and stable**. Prioritize **user experience** and **stability** over minor micro-optimizations.

Always measure before and after. Focus on bottlenecks that actually impact users.
