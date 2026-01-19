# Editor Mode Table Alignment Bug

## Problem Description

In Editor Mode, when the result table has many rows and displays a vertical scrollbar, the table body content is centered horizontally while the header row remains left-aligned. This creates a visual misalignment between the header and body.

### Screenshots
- With few rows (no scrollbar): Header and body align correctly
- With many rows (scrollbar present): Body content shifts to center, header stays left

## Root Cause Analysis

The issue occurs because:
1. `ResultTableView` uses two separate `ScrollView`s - one for the header (horizontal only) and one for the body (horizontal + vertical when needed)
2. When vertical scrollbar appears, it takes up space (~15px) on the right side of the body ScrollView
3. The body content inside ScrollView gets centered within the available space
4. The header ScrollView doesn't have a vertical scrollbar, so its content width differs

## Code Structure

```
ResultTableView.swift
├── VStack (outer container)
│   ├── ScrollView(.horizontal) - Header
│   │   └── headerRow
│   └── ScrollView(scrollAxes) - Body (horizontal + vertical when needsVerticalScroll)
│       └── VStack
│           └── ForEach rows
```

## Solutions Attempted

### 1. Add `.fixedSize(horizontal: false, vertical: true)` to body VStack
**File:** `ResultTableView.swift:95`
**Result:** Fixed the row height expansion issue but not the alignment

### 2. Add `alignment: .topLeading` to body VStack frame
**File:** `ResultTableView.swift:95`
**Result:** No effect on horizontal centering

### 3. Add `alignment: .top` to ScrollView frame
**File:** `ResultTableView.swift:115`
**Result:** Fixed vertical alignment but not horizontal

### 4. Add `Spacer(minLength: 0)` in EditorModeView
**File:** `EditorModeView.swift:64`
**Result:** Pushes content to top in the container but doesn't fix ScrollView internal alignment

### 5. Add padding to header to compensate for scrollbar width
```swift
.padding(.trailing, needsVerticalScroll ? 15 : 0)
```
**Result:** Didn't work because the centering happens inside the ScrollView content area

### 6. Move `.frame(maxWidth: .infinity, alignment: .leading)` outside ScrollView
**File:** `ResultTableView.swift:61, 97`
**Result:** Still doesn't affect content alignment inside ScrollView

## Potential Solutions to Try

### A. Use `scrollTargetLayout()` and `scrollTargetBehavior()`
SwiftUI's newer scroll APIs might help control content positioning.

### B. Use `GeometryReader` to calculate exact widths
Calculate the total column width and set explicit width for both header and body content.

### C. Wrap content in HStack with Spacer
```swift
HStack {
    VStack { ... actual content ... }
    Spacer(minLength: 0)
}
```
This might force left alignment.

### D. Use NSViewRepresentable for NSScrollView
AppKit's NSScrollView has more control over content alignment via `documentView` positioning.

### E. Single ScrollView approach
Use a single ScrollView with sticky header using `LazyVStack(pinnedViews: [.sectionHeaders])`, but this was previously avoided due to scroll crash issues.

### F. Calculate and match content widths explicitly
```swift
let totalColumnsWidth = result.columns.reduce(0) { $0 + columnWidth(for: $1.name) }
// Apply this width to both header and body content
```

## Current Status

**RESOLVED** - Fixed by using same scroll axes for both header and body ScrollViews.

### Final Solution

The key insight: when body ScrollView has `[.horizontal, .vertical]` axes and header has only `.horizontal`, they have different centering behaviors. The fix is to use the **same scroll axes** for both, with header scrolling disabled (synced via `scrollPosition`).

```swift
// Header ScrollView - use same axes as body for consistent centering
ScrollView(scrollAxes, showsIndicators: false) {
    headerRow
        .frame(width: totalColumnsWidth, alignment: .leading)
        .background(Color.tableHeaderBackground)
}
.scrollDisabled(true)  // Disable direct scrolling - synced via contentScrollPosition
.frame(height: headerHeight)
.scrollPosition($headerScrollPosition)

// Body ScrollView
ScrollView(scrollAxes, showsIndicators: true) {
    VStack(alignment: .leading, spacing: 0) {
        // ... rows ...
    }
    .frame(width: totalColumnsWidth, alignment: .leading)
}
.scrollPosition($contentScrollPosition)
```

Both ScrollViews now have the same centering behavior, so header and body stay aligned regardless of whether a vertical scrollbar is present.

## Files Involved

- `/SQLNotebook/Views/Components/ResultTableView.swift` - Main table component
- `/SQLNotebook/Views/EditorModeView.swift` - Editor mode container

## Related Issues

- Row height expansion (FIXED)
- Gap above rows when few results (FIXED)
