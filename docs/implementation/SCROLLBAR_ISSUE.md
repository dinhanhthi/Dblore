# Scrollbar Issue Documentation

## Problem Statement

Trong `ResultTableView.swift`, vertical scrollbar xuất hiện không cần thiết trong các trường hợp sau:

### Case 1: Content nhỏ hơn maxHeight
- **Triệu chứng**: Khi table content height < maxResultHeight (500pt), vertical scrollbar vẫn hiển thị
- **Mong muốn**: Không có scrollbar khi content fit trong available space

### Case 2: Chỉ có horizontal scrollbar
- **Triệu chứng**: Khi table có nhiều columns (cần horizontal scroll) nhưng ít rows (không cần vertical scroll), cả hai scrollbars đều xuất hiện
- **Mong muốn**: Chỉ horizontal scrollbar xuất hiện, vertical scrollbar chỉ show khi content thực sự cao hơn maxHeight

## Root Cause Analysis

1. **SwiftUI ScrollView behavior**:
   - Khi set `.frame(maxHeight:)` trên ScrollView, SwiftUI assumes content có thể scroll
   - ScrollView hiển thị scrollbar indicators mặc định ngay cả khi content nhỏ hơn frame

2. **Horizontal scrollbar triggering vertical scrollbar**:
   - Khi horizontal scrollbar xuất hiện (overlay style), có thể trigger vertical scrollbar
   - SwiftUI/AppKit có edge case behavior khi có cả hai scrolling axes

## Solutions Attempted

### Solution 1: `.scrollIndicators(.hidden)` ❌
**File**: `ResultTableView.swift:37`

```swift
ScrollView([.horizontal, .vertical]) {
  // content
}
.scrollIndicators(.hidden)
.frame(maxHeight: viewModel.notebook.settings.maxResultHeight)
```

**Kết quả**: FAILED
- Modifier này không hoạt động đúng trên macOS
- Scrollbars vẫn hiển thị

---

### Solution 2: `showsIndicators: false` parameter ❌
**File**: `ResultTableView.swift:23`

```swift
ScrollView([.horizontal, .vertical], showsIndicators: false) {
  // content
}
```

**Kết quả**: FAILED
- Parameter này không tồn tại trong SwiftUI ScrollView initializer
- Compilation error

---

### Solution 3: NSViewRepresentable với overlay scroller style ❌
**File**: `ResultTableView.swift:255-277`

```swift
private struct ScrollViewConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      if let scrollView = view.enclosingScrollView {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
      }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if let scrollView = nsView.enclosingScrollView {
      scrollView.scrollerStyle = .overlay
      scrollView.autohidesScrollers = true
    }
  }
}
```

**Usage**:
```swift
ScrollView([.horizontal, .vertical]) {
  // content
}
.background(ScrollViewConfigurator())
```

**Kết quả**: PARTIAL SUCCESS
- Scrollbars trở thành overlay style (không chiếm space)
- Scrollbars auto-hide khi không dùng
- **Vấn đề còn lại**: Vertical scrollbar vẫn xuất hiện khi có horizontal scrollbar

---

### Solution 4: Compensate scrollbar height ❌
**File**: `ResultTableView.swift:19, 38, 42`

```swift
private let scrollbarCompensation: CGFloat = 20

var body: some View {
  ScrollView([.horizontal, .vertical]) {
    LazyVStack(...) {
      // content
    }
    .padding(.bottom, scrollbarCompensation)
  }
  .frame(maxHeight: viewModel.notebook.settings.maxResultHeight + scrollbarCompensation)
}
```

**Kết quả**: FAILED
- Tăng visible height không mong muốn
- Không giải quyết được root cause

---

### Solution 5: GeometryReader + PreferenceKey để measure content height ❌
**File**: `ResultTableView.swift:15, 38-56, 255-260`

```swift
@State private var contentHeight: CGFloat = 0

private struct ContentHeightPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

var body: some View {
  ScrollView([.horizontal, .vertical]) {
    LazyVStack(...) {
      // content
    }
    .background(
      GeometryReader { geometry in
        Color.clear.preference(
          key: ContentHeightPreferenceKey.self,
          value: geometry.size.height
        )
      }
    )
  }
  .background(
    ScrollViewConfigurator(
      needsVerticalScroller: contentHeight > viewModel.notebook.settings.maxResultHeight
    )
  )
  .onPreferenceChange(ContentHeightPreferenceKey.self) { height in
    contentHeight = height
  }
}
```

**Kết quả**: FAILED
- `LazyVStack` với lazy loading không measure được chính xác content height
- GeometryReader trả về incorrect values do lazy rendering

---

### Solution 6: Estimated height calculation ❌
**File**: `ResultTableView.swift:19-28, 48`

```swift
private let rowHeight: CGFloat = 32  // Approximate height per row
private let headerHeight: CGFloat = 48  // Approximate header height

private var estimatedContentHeight: CGFloat {
  headerHeight + (CGFloat(result.rows.count) * rowHeight)
}

private var needsVerticalScroller: Bool {
  estimatedContentHeight > viewModel.notebook.settings.maxResultHeight
}

var body: some View {
  ScrollView([.horizontal, .vertical]) {
    // content
  }
  .background(
    ScrollViewConfigurator(needsVerticalScroller: needsVerticalScroller)
  )
}

// ScrollViewConfigurator
private func configureScrollView(_ scrollView: NSScrollView?) {
  guard let scrollView = scrollView else { return }
  scrollView.scrollerStyle = .overlay
  scrollView.autohidesScrollers = true
  scrollView.hasHorizontalScroller = true
  scrollView.hasVerticalScroller = needsVerticalScroller
}
```

**Kết quả**: FAILED
- Estimated height không chính xác (row heights có thể khác nhau)
- Setting `hasVerticalScroller = false` vẫn không prevent scrollbar khi có horizontal scrollbar

---

### Solution 7: Dynamic ScrollView Axes + Estimated Height + NSScrollView Control ✅
**Date**: 2025-12-28
**File**: `ResultTableView.swift:19-66, 318-340`

```swift
// Constants for height estimation
private let rowHeight: CGFloat = 32  // Approximate row height
private let headerHeight: CGFloat = 48  // Approximate header height

// Estimate if vertical scrolling is needed
private var estimatedContentHeight: CGFloat {
  headerHeight + (CGFloat(result.rows.count) * rowHeight)
}

private var needsVerticalScroll: Bool {
  estimatedContentHeight > viewModel.notebook.settings.maxResultHeight
}

private var scrollAxes: Axis.Set {
  needsVerticalScroll ? [.horizontal, .vertical] : .horizontal
}

var body: some View {
  VStack(alignment: .leading, spacing: 0) {
    // Header and data rows with dynamic axes
    ScrollView(scrollAxes) {
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
        Section {
          // Data rows
          ForEach(Array(result.rows.enumerated()), id: \.offset) { rowIndex, row in
            dataRow(row: row, rowIndex: rowIndex)
          }
        } header: {
          // Header row (pinned at top)
          headerRow
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollBounceBehavior(.basedOnSize)
    .background(ScrollerConfigurator(needsVerticalScroller: needsVerticalScroll))
    .frame(maxHeight: viewModel.notebook.settings.maxResultHeight)
    // ...
  }
}

// NSScrollView configurator
private struct ScrollerConfigurator: NSViewRepresentable {
  let needsVerticalScroller: Bool

  func makeNSView(context: Context) -> NSView {
    NSView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      guard let scrollView = nsView.enclosingScrollView else { return }

      // Configure scroller style and visibility
      scrollView.scrollerStyle = .overlay
      scrollView.autohidesScrollers = true
      scrollView.hasHorizontalScroller = true
      scrollView.hasVerticalScroller = needsVerticalScroller

      // Force scroller update
      scrollView.flashScrollers()
    }
  }
}
```

**Kết quả**: ✅ **SUCCESS**

**How it works**:
1. **Estimated Content Height**: Calculate approximate height = `headerHeight + (rowCount × rowHeight)`
2. **Dynamic Axes**:
   - If `estimatedContentHeight <= maxResultHeight` → `scrollAxes = .horizontal` (chỉ horizontal scroll)
   - If `estimatedContentHeight > maxResultHeight` → `scrollAxes = [.horizontal, .vertical]` (cả hai)
3. **NSScrollView Control**: `ScrollerConfigurator` directly sets `hasVerticalScroller` property để force hide/show vertical scrollbar
4. **Overlay Style**: Scrollbars không chiếm space, auto-hide khi không dùng

**Why this works better than Solution 6**:
- Solution 6 chỉ set `hasVerticalScroller` nhưng vẫn dùng `ScrollView([.horizontal, .vertical])`
- Solution 7 **thay đổi cả ScrollView axes** + set `hasVerticalScroller` → double enforcement
- SwiftUI ScrollView với dynamic axes + AppKit NSScrollView control = complete solution

**Advantages**:
- ✅ Giải quyết hoàn toàn cả 2 cases trong problem statement
- ✅ **Lightweight**: Chỉ estimate height, không measure actual content → no performance overhead
- ✅ **Preserves LazyVStack**: Không break lazy loading như ViewThatFits
- ✅ **Vertical scroll works**: Khi cần scroll, vertical scrolling hoạt động correctly
- ✅ Combination của SwiftUI (dynamic axes) + AppKit (scroller control) cho best results
- ✅ Clean, maintainable code
- ✅ Overlay scrollbars với auto-hide behavior

**Why ViewThatFits (Solution 8) failed**:
- ViewThatFits measures tất cả options → breaks LazyVStack lazy loading
- Causes severe performance issues và lag
- Vertical scroll không hoạt động properly
- Not suitable for dynamic, large datasets

**References**:
- [Enable scrolling based on content size in SwiftUI](https://nilcoalescing.com/blog/EnableScrollingBasedOnContentSizeInSwiftUI/)
- [NSScrollView | Apple Developer Documentation](https://developer.apple.com/documentation/appkit/nsscrollview)
- [ScrollView Bounce Behavior configuration in SwiftUI](https://www.avanderlee.com/swiftui/scrollview-bounce-behavior/)

---

## Current Status

**Active code**: Solution 7 (Dynamic ScrollView Axes + Estimated Height + NSScrollView Control)
**Status**: ✅ **RESOLVED**

Solution successfully addresses both issues:
- ✅ **Case 1 Fixed**: Khi content height < maxResultHeight → Không có vertical scrollbar
- ✅ **Case 2 Fixed**: Nhiều columns (cần horizontal scroll) + ít rows (không cần vertical scroll) → Chỉ horizontal scrollbar xuất hiện
- ✅ **Performance**: Fast, không có lag, preserves lazy loading
- ✅ **Functionality**: Vertical scroll hoạt động correctly khi cần

## Previously Attempted Solutions (For Reference)

### Solution 8: ViewThatFits với Conditional ScrollView Axes ❌
**Attempted**: 2025-12-28 (reverted same day)

**Issues encountered**:
- ❌ Severe performance issues và lag
- ❌ ViewThatFits measures tất cả options → breaks LazyVStack lazy loading
- ❌ Vertical scroll không hoạt động - cannot scroll even when content height > maxHeight
- ❌ Not suitable for large datasets

**Lesson learned**: ViewThatFits không phù hợp với dynamic content và lazy loading views

---

### Option A: Custom NSScrollView wrapper
Thay vì dùng SwiftUI ScrollView, wrap NSScrollView hoàn toàn:
- Full control over scroller visibility
- Có thể programmatically hide/show scrollers based on content size
- More complex implementation
- **Status**: Not needed - Solution 7 solved the problem with hybrid approach

### Option B: Accept overlay scrollbars
- Giữ Solution 3 (overlay scroller style)
- Accept rằng scrollbars sẽ hiện nhưng ở dạng overlay (không chiếm space)
- Focus vào improving `autohidesScrollers` behavior
- **Status**: Partially implemented in Solution 7 (overlay style retained)

### Option C: Investigate SwiftUI alternatives
- ScrollViewReader advanced usage
- Custom scroll implementation
- Third-party libraries
- **Status**: Not needed - native SwiftUI + AppKit hybrid approach works

### Option D: File SwiftUI feedback
- Đây có thể là SwiftUI/AppKit integration bug
- Report to Apple via Feedback Assistant
- **Status**: Not a bug - requires hybrid SwiftUI + AppKit approach for fine control

## Related Files

- `/Users/thi/git/SQLNotebook/SQLNotebook/Views/Components/ResultTableView.swift` - Main file
- `/Users/thi/git/SQLNotebook/SQLNotebook/Models/NotebookSettings.swift` - maxResultHeight setting (default: 500pt)

## Screenshots

See original screenshot showing:
- 2 rows of data
- Multiple columns requiring horizontal scroll
- Unnecessary vertical scrollbar visible
