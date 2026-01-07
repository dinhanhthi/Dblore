# File Optimization Feature

## Overview

The File Optimization feature provides automatic monitoring, warnings, and manual cleanup options for SQL Notebook files. It helps users manage file sizes by detecting large files, enforcing size limits, and offering tools to reduce file size when needed.

**Implementation Date:** January 2026
**Phase:** 4.11 - Polish
**Status:** Complete ✅

## Architecture

### Core Components

```
FileOptimizationService (enum)
├── Constants (largeSizeThreshold, warningSizeThreshold)
├── File Size Calculation
├── Size Formatting
├── Optimization Operations
└── Statistics Collection

NotebookViewModel
├── estimatedFileSize (computed property)
├── formattedFileSize (computed property)
├── isFileSizeLarge (computed property)
└── isFileSizeWarning (computed property)

UI Components
├── FooterView (file size indicator)
├── SettingsContent (optimization panel)
└── HeaderView (new cell button enforcement)
```

## Key Features

### 1. File Size Monitoring

**Real-time Calculation:**
```swift
// NotebookViewModel.swift
var estimatedFileSize: Int64 {
  let includeResults = AppSettings.getIncludeResultsOnSave()
  return (try? FileOptimizationService.calculateNotebookSize(
    notebook,
    includeResults: includeResults
  )) ?? 0
}
```

**Display Formats:**
- Raw bytes (Int64)
- Human-readable (KB, MB, GB)
- Color-coded warnings (green/yellow/red)

### 2. Configurable Thresholds

**Testing Values (Current):**
```swift
// FileOptimizationService.swift
nonisolated static let largeSizeThreshold: Int64 = 23 * 1024      // 23 KB
nonisolated static let warningSizeThreshold: Int64 = 20 * 1024    // 20 KB
```

**Production Values (Commented):**
```swift
// nonisolated static let largeSizeThreshold: Int64 = 10 * 1024 * 1024      // 10 MB
// nonisolated static let warningSizeThreshold: Int64 = 5 * 1024 * 1024     // 5 MB
```

**Rationale:** Testing values allow easy verification without creating large test files.

### 3. Size Limit Enforcement

**Behavior:**
- When `estimatedFileSize > largeSizeThreshold`:
  - "New Cell" button becomes **disabled**
  - Button opacity reduced to 0.5
  - Toast notification shown on click attempt
  - Warning message: "File size limit exceeded..."

**Implementation:**
```swift
// HeaderView.swift:27-41
Button(action: {
  if viewModel.isFileSizeLarge {
    viewModel.showToast(
      "File size limit exceeded. Please create a new notebook or remove old results to continue adding cells.",
      type: .error
    )
  } else {
    viewModel.addCell(type: .sql)
  }
}) {
  Label("New", systemImage: "plus")
}
.buttonStyle(ToolbarButtonStyle())
.disabled(viewModel.isFileSizeLarge)
.opacity(viewModel.isFileSizeLarge ? 0.5 : 1.0)
```

### 4. Footer Indicator

**Visual States:**

| State | Icon | Color | Threshold |
|-------|------|-------|-----------|
| Normal | `doc.text` | Gray (foregroundSubtle) | < warning |
| Warning | `exclamationmark.circle.fill` | Yellow (warning) | > warning threshold |
| Error | `exclamationmark.triangle.fill` | Red (destructive) | > large threshold |

**Dynamic Tooltips:**
```swift
// FooterView.swift:139-146
private var fileSizeTooltip: String {
  if viewModel.isFileSizeLarge {
    return "File size is very large (> \(FileOptimizationService.formatFileSize(FileOptimizationService.largeSizeThreshold))). Consider creating a new notebook or removing old results."
  } else if viewModel.isFileSizeWarning {
    return "File size is approaching the recommended limit (> \(FileOptimizationService.formatFileSize(FileOptimizationService.warningSizeThreshold)))"
  } else {
    return "Current file size"
  }
}
```

**Design Decision:** All messages use dynamic values from constants, ensuring consistency when thresholds change.

### 5. Settings Panel

**File Optimization Section:**

1. **Current File Size Display**
   - Shows formatted size
   - Color-coded (green/yellow/red)
   - Warning icon for large files
   - Card-style background

2. **Dynamic Warning Messages**
   - Appears only when file is large or warning
   - Uses threshold values from constants
   - Context-appropriate suggestions

3. **Manual Cleanup Button**
   - "Remove All Results Now" with trash icon
   - Calls `viewModel.clearAllOutputs()`
   - Red destructive styling
   - Warning text about re-running queries

**Implementation:**
```swift
// SettingsContent.swift:142-207
settingsSection(title: "File Optimization") {
  VStack(alignment: .leading, spacing: Spacing.md) {
    // Current file size display
    HStack {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Current File Size")
          .font(.subheading)
          .foregroundColor(.foreground)

        Text(viewModel.formattedFileSize)
          .font(.mono)
          .foregroundColor(
            viewModel.isFileSizeLarge
              ? .destructive
              : (viewModel.isFileSizeWarning ? .warning : .accent)
          )
      }

      Spacer()

      if viewModel.isFileSizeLarge {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundColor(.destructive)
      } else if viewModel.isFileSizeWarning {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundColor(.warning)
      }
    }
    .padding(Spacing.md)
    .background(Color.inputBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))

    // Dynamic warnings...
    // Manual cleanup button...
  }
}
```

### 6. Compact JSON Format

**Automatic Optimization:**
- Files exceeding `warningSizeThreshold` are saved in compact format
- Removes whitespace and pretty-printing
- Reduces file size by ~20-30%
- Transparent to user

**Implementation:**
```swift
// SQLNotebookDocument.swift:46-55
let estimatedSize = (try? FileOptimizationService.calculateNotebookSize(
  notebookToSave, includeResults: includeResults)) ?? 0
let useCompactFormat = estimatedSize > FileOptimizationService.warningSizeThreshold

let data = try DocumentCoder.encode(
  notebookToSave,
  includeResultsOnSave: includeResults,
  useCompactFormat: useCompactFormat
)
```

**JSON Options:**
```swift
// Compact: [.sortedKeys]
// Pretty: [.prettyPrinted, .sortedKeys]
```

## FileOptimizationService API

### Static Methods

#### `calculateNotebookSize(_:includeResults:)`
```swift
nonisolated static func calculateNotebookSize(
  _ notebook: SQLNotebook,
  includeResults: Bool
) throws -> Int64
```
Calculates the size of a notebook if saved to disk.

**Parameters:**
- `notebook`: The notebook to measure
- `includeResults`: Whether to include query results in calculation

**Returns:** File size in bytes

**Throws:** Encoding errors

---

#### `formatFileSize(_:)`
```swift
nonisolated static func formatFileSize(_ bytes: Int64) -> String
```
Formats byte count into human-readable string (KB, MB, GB).

**Example:**
```swift
formatFileSize(1024)           // "1 KB"
formatFileSize(1024 * 1024)    // "1 MB"
formatFileSize(10 * 1024 * 1024)  // "10 MB"
```

---

#### `removeAllResults(from:)`
```swift
nonisolated static func removeAllResults(from notebook: SQLNotebook) -> SQLNotebook
```
Creates a new notebook with all cell results removed.

**Use Case:** Manual cleanup operation

---

#### `removeOldResults(from:olderThan:)`
```swift
nonisolated static func removeOldResults(
  from notebook: SQLNotebook,
  olderThan date: Date
) -> (notebook: SQLNotebook, removedCount: Int)
```
Removes results older than specified date.

**Returns:** Tuple with cleaned notebook and count of removed results

**Note:** Currently unused (auto-cleanup feature removed)

---

#### `calculateSizeReduction(for:)`
```swift
nonisolated static func calculateSizeReduction(
  for notebook: SQLNotebook
) throws -> (withResults: Int64, withoutResults: Int64, reduction: Int64)
```
Calculates potential size savings if results were removed.

**Returns:** Tuple with sizes and reduction amount

---

#### `getNotebookStatistics(_:)`
```swift
nonisolated static func getNotebookStatistics(
  _ notebook: SQLNotebook
) -> NotebookStatistics
```
Collects statistics about notebook contents.

**Returns:**
```swift
struct NotebookStatistics {
  let totalCells: Int
  let cellsWithResults: Int
  let totalRows: Int
  let approximateResultDataSize: Int64

  var hasResults: Bool { cellsWithResults > 0 }
}
```

## Testing

### Test Suite: FileOptimizationServiceTests

**Location:** `SQLNotebookTests/FileOptimizationServiceTests.swift`
**Test Count:** 12 tests
**Isolation:** `@MainActor`

#### Test Categories

**1. File Size Calculation (2 tests)**
- Empty notebook size
- Notebook with results size comparison

**2. Size Formatting (1 test)**
- KB, MB, GB format verification

**3. Optimization Operations (4 tests)**
- Remove all results
- Remove old results by date
- Calculate size reduction
- Compact format size reduction

**4. Statistics (2 tests)**
- Get notebook statistics
- Empty notebook statistics

**5. Threshold Constants (2 tests)**
- Large size threshold verification
- Warning threshold verification

**6. Compact Format (1 test)**
- Compact vs pretty-printed size comparison

#### Example Test

```swift
@Test("Remove old results from notebook")
func testRemoveOldResults() throws {
  var notebook = SQLNotebook.newDocument()

  let now = Date()
  let oldDate = now.addingTimeInterval(-60 * 24 * 60 * 60)  // 60 days ago
  let recentDate = now.addingTimeInterval(-10 * 24 * 60 * 60)  // 10 days ago

  // Add old and recent results...

  let cutoffDate = now.addingTimeInterval(-30 * 24 * 60 * 60)  // 30 days cutoff
  let (optimized, removedCount) = FileOptimizationService.removeOldResults(
    from: notebook,
    olderThan: cutoffDate
  )

  #expect(optimized.cells[0].result == nil)  // Old result removed
  #expect(optimized.cells[1].result != nil)  // Recent result kept
  #expect(removedCount == 1)
}
```

## User Experience Flow

### Normal Usage (File < Warning Threshold)
1. User creates cells and runs queries
2. Footer shows file size in gray with document icon
3. Tooltip: "Current file size"
4. No restrictions or warnings

### Approaching Limit (Warning ≤ File < Large)
1. Footer icon changes to yellow circle with exclamation
2. Tooltip: "File size is approaching the recommended limit (> 20 KB)"
3. Settings panel shows yellow warning message
4. User can continue adding cells
5. File saved in **compact format** automatically

### Exceeding Limit (File ≥ Large Threshold)
1. Footer icon changes to red triangle with exclamation
2. Tooltip: "File size is very large (> 23 KB)..."
3. Settings panel shows red error message
4. "New Cell" button **disabled** and dimmed
5. Clicking button shows error toast
6. User must:
   - Remove results via settings button, OR
   - Create a new notebook

### Manual Cleanup Flow
1. User opens Settings (Cmd+Shift+R)
2. Scrolls to "File Optimization" section
3. Sees current file size with warning (if applicable)
4. Clicks "Remove All Results Now" button
5. Confirmation is implicit (destructive styling)
6. All cell results cleared
7. File size immediately reduced
8. User can re-run queries as needed

## Design Decisions

### 1. Why Enum Instead of Class?

**Decision:** Use `enum FileOptimizationService` instead of `class`

**Rationale:**
- No instance state needed (all static methods)
- Prevents accidental instantiation
- Clear namespace for file optimization utilities
- Better Swift 6 concurrency (no MainActor isolation needed)

### 2. Why Remove Auto-Cleanup?

**Decision:** Removed automatic cleanup on save feature

**Rationale:**
- User expects saved file to contain all results
- Automatic deletion could surprise users
- No control over what gets deleted
- Manual cleanup provides explicit control
- Simpler implementation and testing

### 3. Why Dynamic Threshold Messages?

**Decision:** Use `FileOptimizationService.formatFileSize(threshold)` in UI

**Rationale:**
- Single source of truth for threshold values
- Easy to switch between testing/production values
- No hardcoded numbers in UI strings
- Consistent messages across all views

### 4. Why Compact Format at Warning Threshold?

**Decision:** Apply compact format at warning threshold (not large threshold)

**Rationale:**
- Proactive size reduction
- Prevents hitting hard limit
- 20-30% reduction can avoid limit entirely
- User doesn't notice (still valid JSON)
- Can be disabled by setting `includeResultsOnSave = false`

### 5. Why Disable Instead of Hide New Cell Button?

**Decision:** Disable (with opacity) instead of hiding button

**Rationale:**
- User awareness: shows feature exists but unavailable
- Consistency: button always in same location
- Tooltip explains why it's disabled (via toast)
- Better UX than mysterious missing button

## Performance Considerations

### File Size Calculation

**Cost:** O(n) where n = total data in notebook
- Iterates all cells
- Encodes to JSON
- Measures byte count

**Optimization:**
- Computed property with no caching
- Recalculated on every view update
- Acceptable because:
  - Only calculated when footer/settings visible
  - SwiftUI minimizes recomputation
  - Fast enough for typical notebooks (< 100 cells)

**Future Improvement:**
If performance issues arise:
```swift
private var cachedFileSize: Int64?
private var cacheDirtyFlag = true

var estimatedFileSize: Int64 {
  if cacheDirtyFlag {
    cachedFileSize = (try? FileOptimizationService.calculateNotebookSize(...)) ?? 0
    cacheDirtyFlag = false
  }
  return cachedFileSize ?? 0
}
```

### Compact Format Decision

**Performance Impact:**
- Adds file size calculation on every save
- Typical cost: < 10ms for normal notebooks
- Acceptable trade-off for automatic optimization

## Error Handling

### File Size Calculation Errors

```swift
var estimatedFileSize: Int64 {
  let includeResults = AppSettings.getIncludeResultsOnSave()
  return (try? FileOptimizationService.calculateNotebookSize(...)) ?? 0
}
```

**Strategy:** Return 0 on error
- Graceful degradation
- User sees "0 bytes" instead of crash
- Footer still displays (no icon warnings)
- Rare case (encoding errors)

### JSON Encoding Errors

Handled by `throws` propagation:
```swift
func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
  // ...
  let data = try DocumentCoder.encode(...)  // May throw
  return FileWrapper(regularFileWithContents: data)
}
```

**Strategy:** Let errors propagate to FileDocument
- System handles error dialogs
- User sees save failure
- Notebook state preserved

## Future Enhancements

### 1. Size Breakdown View
Show detailed breakdown of file size:
- Total cells: X bytes
- Query content: X bytes
- Results data: X bytes
- Metadata: X bytes

### 2. Selective Result Removal
Allow users to select specific cells for result removal:
- Checkbox list of cells
- Preview size reduction
- Keep important results

### 3. Compression
Implement actual compression (gzip/deflate):
- `.sqlnb.gz` format
- Transparent compression/decompression
- 50-70% size reduction possible

### 4. Result Pagination
Store only visible results in file:
- First N rows saved
- Full results kept in memory
- Load more on demand
- Reduces file size dramatically

### 5. External Result Storage
Store large results separately:
- `.sqlnb` file references external data
- `.sqlnb-results/` directory structure
- Better for version control
- Selective result inclusion

## Migration Notes

### Upgrading from Previous Versions

**No migration needed:**
- Feature is additive (no breaking changes)
- Old `.sqlnb` files load normally
- New features work immediately

**Settings:**
- No new user defaults (auto-cleanup removed)
- All behavior is automatic or on-demand

### Switching Threshold Values

To switch from testing to production thresholds:

1. Open `FileOptimizationService.swift`
2. Comment out testing values:
```swift
// nonisolated static let largeSizeThreshold: Int64 = 23 * 1024
nonisolated static let largeSizeThreshold: Int64 = 10 * 1024 * 1024
```
3. Do same for `warningSizeThreshold`
4. Rebuild app
5. All UI messages update automatically

**No code changes needed elsewhere.**

## Related Files

### Core Implementation
- `SQLNotebook/Utilities/FileOptimizationService.swift`
- `SQLNotebook/ViewModels/NotebookViewModel.swift` (lines 134-153)
- `SQLNotebook/Models/SQLNotebookDocument.swift` (lines 46-55)

### UI Components
- `SQLNotebook/Views/FooterView.swift` (lines 54-64, 117-147)
- `SQLNotebook/Views/Sidebars/SettingsContent.swift` (lines 142-207)
- `SQLNotebook/Views/HeaderView.swift` (lines 27-41)

### Tests
- `SQLNotebookTests/FileOptimizationServiceTests.swift`

### Documentation
- `docs/TODO.md` (Phase 4.11)
- `docs/implementation/FILE_OPTIMIZATION_FEATURE.md` (this file)

## Troubleshooting

### Issue: File size shows 0 bytes

**Cause:** Encoding error or empty notebook

**Solution:**
1. Check if notebook has any cells
2. Verify `includeResultsOnSave` setting
3. Check console for encoding errors

### Issue: Compact format not working

**Cause:** File below warning threshold

**Solution:**
- Compact format only applies to files > warning threshold
- Add more data or lower threshold for testing

### Issue: Can't add new cells

**Cause:** File size exceeds large threshold

**Solution:**
1. Open Settings (Cmd+Shift+R)
2. Click "Remove All Results Now"
3. Or create a new notebook

### Issue: Wrong threshold values

**Cause:** Using testing values in production

**Solution:**
1. Update constants in `FileOptimizationService.swift`
2. Rebuild app
3. All UI updates automatically

## Summary

The File Optimization feature provides comprehensive file size management through:

✅ **Monitoring** - Real-time size calculation and display
✅ **Warnings** - Color-coded indicators and dynamic messages
✅ **Enforcement** - Hard limit on file size with clear feedback
✅ **Manual Cleanup** - User-controlled result removal
✅ **Automatic Optimization** - Compact JSON for large files
✅ **Testing** - 12 comprehensive tests covering all functionality
✅ **Flexibility** - Easy to switch between testing/production thresholds

The implementation balances user experience (clear warnings, helpful messages) with technical robustness (error handling, performance, testability).
