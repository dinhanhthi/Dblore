# TODO_OPTIMIZE.md - Performance Optimization Tasks

## Phase 10: Performance Optimization (PENDING - Analysis Complete)

**Analysis Date:** 2026-01-21
**Expected Overall Impact:** 70-80% performance improvement when fully implemented

---

### 10.1 Quick Wins (LOW Effort - 1-2 weeks)

#### 10.1.1 UI Performance - LazyVStack for Cells ⚡ HIGH PRIORITY
- **Current Status:** ❌ NOT USING LazyVStack - Uses `List` with `ForEach` (NotebookContentView.swift:377-395)
- [ ] Verify NotebookContentView uses LazyVStack (not ForEach alone)
- [ ] Add LazyVStack wrapper if missing
- **Location:** NotebookContentView.swift:377-395
- **Impact:** 80% faster initial render for 100+ cells
- **Effort:** LOW
- **Verified:** 2026-01-23

#### 10.1.2 Memory - Search Cache Optimization
- [ ] Add memory pressure notification handler to clear SearchHighlighter cache
- [ ] Verify cache clears when search panel closes (already at line 218)
- **Location:** ResultTableView.swift:266-278, SearchHighlighter
- **Impact:** 20-30% less memory during search operations
- **Effort:** LOW

#### 10.1.3 UI Performance - Debounce Search Navigation Notifications
- [ ] Debounce `.highlightSearchMatch` notification posting (wait 100ms)
- [ ] Consider direct property binding instead of NotificationCenter
- **Location:** NotebookViewModel+Search.swift:193-208
- **Impact:** 30% less CPU during search navigation
- **Effort:** LOW

#### 10.1.4 Database - Schema Fetching Cache
- [ ] Add `lastRefreshTime` and `cacheValidityDuration` (5 minutes) to SQLAutocompleteProvider
- [ ] Skip refetch if cache is still valid
- **Location:** SQLAutocompleteProvider.swift:53-89
- **Impact:** 90% faster autocomplete popup after first fetch
- **Effort:** LOW

#### 10.1.5 Concurrency - Query Timeout
- [ ] Add query execution timeout (default 60s) beyond connection timeout
- [ ] Use `withTimeout()` helper in NotebookViewModel+Execution.swift
- **Location:** NotebookViewModel+Execution.swift:76-81
- **Impact:** Prevents app hangs from long queries
- **Effort:** LOW

#### 10.1.6 UI Performance - Cache Column Widths
- [ ] Cache `totalColumnsWidth` in @State instead of recomputing every render
- [ ] Update cache only when columnWidths changes via .onChange
- **Location:** ResultTableView.swift:298-302
- **Impact:** 5-10% faster table rendering
- **Effort:** LOW

#### 10.1.7 Memory - Auto-Clear ExecutionQueue History
- [ ] Auto-clear completed tasks after 10 tasks (keep recent history)
- [ ] Add `maxHistorySize` configuration
- **Location:** ExecutionQueue.swift:15-83
- **Impact:** Prevents 5-10MB memory leak per 100 executions
- **Effort:** LOW

#### 10.1.8 Memory - Clear Autocomplete Cache on Disconnect
- [ ] Add `clearCache()` method to SQLAutocompleteProvider
- [ ] Call on disconnect in connection management
- **Location:** SQLAutocompleteProvider.swift:38-39
- **Impact:** Frees 1-5MB per connection
- **Effort:** LOW

#### 10.1.9 Concurrency - Search Task Cancellation Propagation
- [ ] Add `Task.isCancelled` check in inner loops of `buildSearchMatches()`
- **Location:** NotebookViewModel+Search.swift:89-90
- **Impact:** 80% faster search cancellation
- **Effort:** LOW

#### 10.1.10 File I/O - JSON Encoding Performance
- [ ] Use `encoder.outputFormatting = [.sortedKeys]` (remove .prettyPrinted for speed)
- [ ] Consider background thread for encoding
- **Location:** SQLNotebookDocument+Coding.swift
- **Impact:** 50% faster save/load for large files
- **Effort:** LOW

---

### 10.2 Major Refactors (MEDIUM-HIGH Effort - 3-4 weeks)

#### 10.2.1 Memory - Large Result Set Pagination ⚡ HIGH PRIORITY (TanStack-like Virtual Scrolling)
- **Current Status:** 🚧 PARTIAL - Basic row limiting implemented (500 rows max), NOT true virtualization
- **Current Implementation:** ResultTableView.swift:28-37 uses `result.rows.prefix(maxRowsToRender)`
- **Missing vs TanStack Virtual:**
  - [ ] No viewport-based rendering (renders all 500 rows upfront)
  - [ ] No virtual scrolling (uses standard ForEach, not lazy)
  - [ ] No on-demand row creation (all rows created immediately)
  - [ ] No row recycling/reuse pattern
  - [ ] No dynamic row heights support
  - [ ] No pagination/infinite scroll UI (just truncation warning)
- **Proposed TanStack-like Implementation:**
  - [ ] Research SwiftUI table virtualization approaches (NSTableView wrapper vs LazyVStack)
  - [ ] Implement `ResultRowStorage` with disk-backed or paged storage
  - [ ] Add `visibleRows` property returning ArraySlice for current viewport
  - [ ] Implement viewport-based rendering (only render visible rows + buffer)
  - [ ] Add pagination controls (load more, page size selection, jump to page)
  - [ ] Auto-clear old results when memory pressure detected
  - [ ] Add row recycling for smooth scrolling performance
- **Location:** NotebookCell.swift:43-65 (CellResult struct), ResultTableView.swift:28-37, 68-72
- **Impact:** 60-70% memory reduction for large notebooks, TanStack-like UX
- **Effort:** HIGH (3-4 weeks)
- **Verified:** 2026-01-23

#### 10.2.2 Concurrency - Move ExecutionQueue Off Main Actor ⚡ HIGH PRIORITY
- [ ] Change ExecutionQueue from `@MainActor class` to `actor`
- [ ] Update UI via `MainActor.run { }` blocks only
- **Location:** ExecutionQueue.swift:11-13
- **Impact:** Non-blocking UI during query execution
- **Effort:** MEDIUM

#### 10.2.3 UI Performance - Optimize ResultTableView Search Rendering ⚡ HIGH PRIORITY
- [ ] Add `@State private var searchVersion: Int` to control re-renders
- [ ] Only re-render when current match changes, not every search property change
- [ ] Memoize SearchHighlightText computations
- **Location:** ResultTableView.swift:40-46, 266-278
- **Impact:** 50-70% faster search operations
- **Effort:** MEDIUM

#### 10.2.4 Database - Query Result Streaming ⚡ HIGH PRIORITY
- [ ] Implement `executeQueryStreaming()` returning `AsyncThrowingStream`
- [ ] Load results in chunks instead of all at once
- [ ] Update UI progressively as chunks arrive
- **Location:** DatabaseConnectionManager+QueryExecution.swift
- **Impact:** 3x faster perceived performance, non-blocking UI
- **Effort:** HIGH

#### 10.2.5 Database - Primary Key Detection
- [ ] Query pg_constraint for primary key information
- [ ] Update schema loading to populate `isPrimaryKey` correctly
- **Location:** DatabaseConnectionManager+Schema.swift:101
- **Impact:** Better UPDATE WHERE clauses, improved data safety
- **Effort:** MEDIUM

---

### 10.3 Polish & Code Quality (MEDIUM Effort - 1-2 weeks)

#### 10.3.1 Code Quality - Split ResultTableView
- [ ] Extract `ResultTableScrollView` to separate file (~250 lines)
- [ ] Extract search matching logic to `ResultTableSearchService` (~200 lines)
- [ ] Keep ResultTableView at ~300 lines (main layout only)
- **Current Size:** 911 lines (exceeds 600 line limit for complex views)
- **Location:** ResultTableView.swift
- **Impact:** Better maintainability, easier to optimize components
- **Effort:** MEDIUM

#### 10.3.2 Code Quality - Optimize ViewModel State Structure
- [ ] Group related state into nested structs (e.g., SearchState, ToastState)
- [ ] Use `@ObservationIgnored` for internal-only properties
- [ ] Reduce observable surface area
- **Location:** NotebookViewModel.swift:36-96
- **Impact:** 10-15% fewer unnecessary view updates
- **Effort:** MEDIUM

#### 10.3.3 UI Performance - EditorModeView GeometryReader
- [ ] Extract GeometryReader to dedicated view
- [ ] Store size in @State, update only when needed
- **Location:** EditorModeView.swift:20-112
- **Impact:** 10-20% less lag in editor mode
- **Effort:** MEDIUM

#### 10.3.4 File I/O - Reduce File Size Calculation Frequency
- [ ] Cache file size, invalidate on document change
- [ ] Calculate only every 5 executions instead of every execution
- [ ] Move calculation to background thread
- **Location:** NotebookViewModel+Execution.swift:143, 257-273
- **Impact:** 20% faster cell execution
- **Effort:** LOW

#### 10.3.5 Concurrency - Toast Deadlock Prevention
- [ ] Add timeout to `while self.isToastHovered` loop (max 20 seconds)
- **Location:** NotebookViewModel.swift:128-140
- **Impact:** Prevents rare toast stuck issue
- **Effort:** LOW

---

### 10.4 Future Enhancements (HIGH Effort - Optional)

#### 10.4.1 Database - Connection Pooling
- [ ] Implement actor-based connection pool (max 5 connections)
- [ ] Reuse connections instead of recreating
- [ ] Add connection health check before reuse
- **Location:** DatabaseConnectionManager.swift:51-53
- **Impact:** 50% faster reconnection times
- **Effort:** HIGH
- **Note:** Low priority for single-connection app

#### 10.4.2 File I/O - Incremental Save
- [ ] Save diff only instead of full file
- [ ] Move file write to background actor
- **Location:** NotebookViewModel.swift:68
- **Impact:** 30% faster save for large files
- **Effort:** MEDIUM
- **Note:** Low priority, already has auto-save debounce

---

## Summary Table

| Phase | Item | Priority | Effort | Impact |
|-------|------|----------|--------|--------|
| 10.1.1 | LazyVStack for Cells | HIGH | LOW | 80% faster render |
| 10.1.2 | Search Cache Optimization | MEDIUM | LOW | 20-30% less memory |
| 10.1.3 | Debounce Search Notifications | MEDIUM | LOW | 30% less CPU |
| 10.1.4 | Schema Fetching Cache | MEDIUM | LOW | 90% faster autocomplete |
| 10.1.5 | Query Timeout | MEDIUM | LOW | Prevents hangs |
| 10.1.6 | Cache Column Widths | LOW | LOW | 5-10% faster table |
| 10.1.7 | Auto-Clear ExecutionQueue | LOW | LOW | Prevents memory leak |
| 10.1.8 | Clear Autocomplete Cache | LOW | LOW | Frees 1-5MB |
| 10.1.9 | Search Task Cancellation | MEDIUM | LOW | 80% faster cancel |
| 10.1.10 | JSON Encoding Performance | MEDIUM | LOW | 50% faster I/O |
| 10.2.1 | Result Set Pagination | HIGH | HIGH | 60-70% less memory |
| 10.2.2 | ExecutionQueue Off Main Actor | HIGH | MEDIUM | Non-blocking UI |
| 10.2.3 | ResultTableView Search Optimization | HIGH | MEDIUM | 50-70% faster search |
| 10.2.4 | Query Result Streaming | HIGH | HIGH | 3x faster perceived |
| 10.2.5 | Primary Key Detection | MEDIUM | MEDIUM | Better data safety |
| 10.3.1 | Split ResultTableView | MEDIUM | MEDIUM | Maintainability |
| 10.3.2 | ViewModel State Structure | LOW | MEDIUM | 10-15% fewer updates |
| 10.3.3 | EditorModeView GeometryReader | LOW | MEDIUM | 10-20% less lag |
| 10.3.4 | File Size Calculation | MEDIUM | LOW | 20% faster execution |
| 10.3.5 | Toast Deadlock Prevention | LOW | LOW | Prevents rare bug |

---

## Recommended Implementation Order

1. **Start with Phase 10.1 (Quick Wins)** - ~40-50% improvement
2. **Proceed to Phase 10.2 (Major Refactors)** - additional 30-40% improvement
3. **Polish with Phase 10.3** as needed

---

## Sources

- [Apple: Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance)
- Swift 6.2 Performance Optimization best practices (2026)

---

## Latest Verification Report

**Date:** 2026-01-23
**Task:** Verify lazy load implementation for table results (TanStack-like virtualization)
**Verified By:** /todo agent

### Findings Summary

#### ⚠️ 10.2.1 Large Result Set Pagination - PARTIAL Implementation

**Current State:**
- ✅ Basic row limiting: 500 rows max (ResultTableView.swift:28)
- ✅ Truncation warning UI when rows exceed limit
- ✅ Performance protection against rendering 10,000+ rows
- ❌ **NOT true lazy loading** - renders all 500 rows upfront
- ❌ **NOT virtualized** - uses standard `VStack` + `ForEach`
- ❌ No viewport-based rendering (TanStack Virtual pattern)
- ❌ No pagination/infinite scroll
- ❌ No row recycling

**Comparison to TanStack Virtual:**

| Feature | TanStack Virtual | SQLNotebook Current |
|---------|-----------------|---------------------|
| Viewport rendering | ✅ O(viewport size) | ❌ O(500 rows) |
| Virtual scrolling | ✅ Yes | ❌ No |
| On-demand creation | ✅ Yes | ❌ No |
| Row recycling | ✅ Yes | ❌ No |
| Dynamic heights | ✅ Yes | ❌ Fixed only |
| Pagination | ✅ Yes | ❌ Hard truncation |

**Recommendation:** This is a HIGH PRIORITY task requiring significant architectural changes. Current implementation provides basic protection but doesn't match TanStack's lazy loading UX.

#### ❌ 10.1.1 LazyVStack for Cells - NOT IMPLEMENTED

**Current State:**
- NotebookContentView.swift:377-395 uses `List` with `ForEach`
- **NOT using LazyVStack** for cell rendering
- Quick win opportunity (LOW effort, HIGH impact)

**Next Steps:**
1. Start with Phase 10.1.1 (LazyVStack for cells) - LOW effort, 80% improvement
2. Then tackle Phase 10.2.1 (True virtualization) - HIGH effort, 60-70% memory reduction
3. Consider NSTableView wrapper for native virtualization support

---
