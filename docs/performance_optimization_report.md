# Performance Optimization Report

**Date:** December 23, 2025
**Scope:** Whole Project Analysis for Performance Bottlenecks

## Executive Summary

The application exhibits several critical performance bottlenecks that likely contribute to the "lag" experienced during development (Xcode responsiveness) and runtime execution. The primary issues stem from **non-virtualized UI rendering** of database results and **in-memory processing of large datasets**. Addressing these will significantly improve the application's responsiveness and memory footprint.

## 1. Critical UI Rendering Bottlenecks

### Issue: Lack of View Virtualization in `ResultTableView`
**Location:** `SQLNotebook/Views/Components/ResultTableView.swift`

The current implementation renders query results using a nested stack structure inside a `ScrollView`:

```swift
ScrollView([.horizontal, .vertical]) {
    VStack(alignment: .leading, spacing: 0) {
        // Headers...
        // Data Rows
        ForEach(0..<result.rows.count, id: \.self) { rowIndex in
            // Renders every single row immediately
            dataRow(row: result.rows[rowIndex], rowIndex: rowIndex)
        }
    }
}
```

*   **Impact:** SwiftUI attempts to create and layout a view for *every single row* in the result set immediately. If a query returns 1,000+ rows, this causes massive main-thread blocking, leading to UI freezes and high memory usage.
*   **Recommendation:** 
    *   **Immediate Fix:** Replace `ForEach` with `LazyVStack` to ensure rows are only rendered when they scroll into view.
    *   **Long-term Fix:** Adopt the standard SwiftUI `Table` component (available on macOS) or `List`, which are highly optimized for large datasets and handle virtualization natively.

### Issue: Expensive & Redundant Layout Calculations
**Location:** `SQLNotebook/Views/Components/ResultTableView.swift` -> `calculateContentWidth(for:)`

The app calculates the width of every column by iterating through the first 100 rows *every time the view body is re-evaluated*.

*   **Impact:** This O(N*M) operation (where N is rows, M is columns) runs on the main thread during render passes, causing dropped frames during scrolling or window resizing.
*   **Recommendation:**
    *   Calculate column widths *once* when the `CellResult` is received/processed and cache the values in the `NotebookViewModel` or the `CellResult` struct itself.
    *   Use `GeometryReader` or standard `Table` column constraints to let the layout system handle this naturally.

## 2. Data Processing & Memory Architecture

### Issue: Full In-Memory Result Storage
**Location:** `SQLNotebook/Models/NotebookCell.swift` (`CellResult`) & `SQLNotebook/Database/DatabaseConnectionManager.swift`

The application fetches *all* rows from a query into memory at once:

```swift
// DatabaseConnectionManager.swift
for try await row in stream {
    // ... parse values ...
    resultRows.append(rowValues) // Appends ALL rows to a single array
}
```

*   **Impact:** 
    *   **Memory Spikes:** A query returning large datasets (e.g., 100k rows or heavy `bytea`/JSON columns) will spike RAM usage, potentially crashing the app.
    *   **UI Blocking:** The "Execute" action blocks until *all* data is received and parsed.
*   **Recommendation:**
    *   Implement **Pagination**: Fetch data in chunks (e.g., `LIMIT 100 OFFSET N`).
    *   Implement **Streaming**: Process the `PostgresNIO` stream and update the UI incrementally (though this requires complex UI handling).
    *   Cap the maximum number of rows displayed in the UI (e.g., show the first 1,000 rows and warn the user).

### Issue: Heavy Type Conversion (`CellValue`)
**Location:** `SQLNotebook/Database/DatabaseConnectionManager.swift`

Every single cell from the database is wrapped in a `CellValue` enum.

*   **Impact:** The `parseCellValue` function performs extensive type checking and string decoding for every cell.
*   **Recommendation:** 
    *   Consider using more lightweight raw storage (like `[Any]`) and only converting to display strings when the cell is actually rendered in the UI (Lazy evaluation).

## 3. Editor Performance

### Issue: Inefficient Syntax Highlighting
**Location:** `SQLNotebook/Utilities/SQLSyntaxHighlighter.swift`

The highlighter applies multiple regular expressions over the *entire* text content on every character change.

```swift
// Re-runs for the whole file on every keystroke
func highlight(_ code: String) -> AttributedString { ... }
```

*   **Impact:** As the SQL query in a cell grows (e.g., >500 lines), typing will become noticeably laggy.
*   **Recommendation:**
    *   **Debouncing:** Only run the highlighter after the user stops typing for a few milliseconds.
    *   **Incremental Parsing:** (Advanced) Only re-highlight the changed lines.
    *   **Optimization:** Combine regex patterns where possible to reduce the number of passes over the string.

## 4. State Management (Xcode "Lag")

### Issue: Coarse-Grained Observability
**Location:** `SQLNotebook/ViewModels/NotebookViewModel.swift`

The entire `NotebookViewModel` is an `@Observable` object that holds the entire `Notebook` struct.

*   **Impact:** Modifying a single property of a single cell (e.g., `isRunning`) might trigger a diffing pass over the entire notebook hierarchy in SwiftUI. While `@Observable` in Swift 6 is smarter than `ObservableObject`, complex nested structs can still cause compilation overhead (Xcode lag) and runtime over-invalidation.
*   **Recommendation:** 
    *   Ensure `NotebookCell` implements `Identifiable` and `Equatable` correctly.
    *   Break down the view hierarchy so that `CellView` observes only its specific `NotebookCell` data, minimizing the scope of view updates.

## Summary of Actionable Steps

1.  **[High Priority]** Refactor `ResultTableView` to use `LazyVStack` or `Table`.
2.  **[Medium Priority]** Cache column width calculations; do not compute them in the `body`.
3.  **[Medium Priority]** Limit the maximum number of rows fetched/stored in `DatabaseConnectionManager`.
4.  **[Low Priority]** Debounce syntax highlighting in `SQLSyntaxHighlighter`.

These changes should resolve the perceived lag and improve the overall robustness of the application.
