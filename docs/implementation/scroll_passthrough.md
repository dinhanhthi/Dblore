# Scroll Passthrough Issue

## Problem Description

When the mouse cursor is over a nested scroll view (query editor or result table), scroll wheel events are captured by that scroll view instead of propagating to the parent scroll view (the main notebook List). This prevents global scrolling of the app when hovering over these areas.

**Expected behavior:** When content inside a nested scroll view doesn't need scrolling (e.g., short query, few result rows), scroll events should pass through to the parent scroll view for global scrolling.

**Current behavior:** Scroll events are captured by the nested scroll view even when it has no scrollable content.

## Affected Areas

1. **Query Editor** (`HighlightedTextEditor.swift`)
   - Uses `NSScrollView` wrapping `SQLTextView` (NSTextView subclass)
   - Status: ✅ **FIXED** with `PassthroughScrollView`

2. **Result Table** (`ResultTableView.swift`)
   - Uses SwiftUI `ScrollView` with underlying `NSScrollView`
   - Status: ✅ **FIXED** with Local Event Monitor + Overlay

## Solutions Attempted

### 1. Override `scrollWheel` in NSTextView (Query Editor) ✅

**File:** `SQLTextView.swift`

**Approach:** Override `scrollWheel(with:)` to forward events to parent when content doesn't need scrolling.

**Result:** Did not work because `NSScrollView` handles scroll events before they reach `NSTextView`.

### 2. Custom PassthroughScrollView (Query Editor) ✅

**File:** `HighlightedTextEditor.swift`

**Approach:** Create custom `NSScrollView` subclass that overrides `scrollWheel(with:)`.

```swift
class PassthroughScrollView: NSScrollView {
  override func scrollWheel(with event: NSEvent) {
    guard let textView = documentView as? NSTextView else {
      super.scrollWheel(with: event)
      return
    }

    let contentHeight = textView.frame.height
    let visibleHeight = contentView.bounds.height

    // If content doesn't need scrolling, forward to parent
    if contentHeight <= visibleHeight {
      nextResponder?.scrollWheel(with: event)
      return
    }

    // Check boundaries for passthrough
    let currentY = contentView.bounds.origin.y
    let maxY = max(0, contentHeight - visibleHeight)
    let isAtTop = currentY <= 0
    let isAtBottom = currentY >= maxY - 1
    let scrollingUp = event.scrollingDeltaY > 0
    let scrollingDown = event.scrollingDeltaY < 0

    if (isAtTop && scrollingUp) || (isAtBottom && scrollingDown) {
      nextResponder?.scrollWheel(with: event)
    } else {
      super.scrollWheel(with: event)
    }
  }
}
```

**Result:** ✅ Works for query editor because we control the `NSScrollView` creation.

### 3. Local Event Monitor Only (Result Table) ❌

**Approach:** Use `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)` to intercept scroll events globally without an overlay view.

```swift
eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
  // Check if event is over registered scroll view
  // Forward to parent if needed
}
```

**Result:** Did not work - without an overlay view to determine bounds, we couldn't reliably identify which scroll events to intercept.

### 4. NSViewRepresentable Overlay (Result Table) ❌

**Approach:** Add transparent `NSView` overlay that intercepts scroll events.

**Result:** Did not work - scroll events are handled by underlying `NSScrollView` before reaching overlay.

### 5. Replace NSClipView (Result Table) ❌

**Approach:** Replace `NSScrollView.contentView` with custom `PassthroughClipView`.

```swift
class PassthroughClipView: NSClipView {
  override func scrollWheel(with event: NSEvent) {
    if let parentScrollView = findParentScrollView() {
      parentScrollView.scrollWheel(with: event)
    } else {
      super.scrollWheel(with: event)
    }
  }
}
```

**Result:** Did not work - `NSScrollView` handles events before delegating to `NSClipView`.

### 6. Disable Vertical Scroll Elasticity (Result Table) ❌

**Approach:** Set `scrollView.verticalScrollElasticity = .none`

**Result:** Did not prevent scroll event capture.

### 7. ISA-Swizzling (Result Table) ❌

**Approach:** Use `object_setClass()` to change the class of SwiftUI's internal `NSScrollView` at runtime to a custom subclass.

**Result:** Did not work reliably - SwiftUI's internal scroll handling still intercepted events before our override could process them.

### 8. Local Event Monitor with Overlay (Result Table) ✅

**Approach:** Combine `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)` with an `NSViewRepresentable` overlay to intercept scroll events before they reach SwiftUI's scroll view.

```swift
private struct ScrollPassthroughOverlay: NSViewRepresentable {
  func makeNSView(context: Context) -> ScrollMonitorView {
    ScrollMonitorView()
  }

  func updateNSView(_ nsView: ScrollMonitorView, context: Context) {}

  static func dismantleNSView(_ nsView: ScrollMonitorView, coordinator: ()) {
    nsView.removeMonitor()
  }
}

private class ScrollMonitorView: NSView {
  private var eventMonitor: Any?
  private weak var cachedParentScrollView: NSScrollView?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { setupMonitor() }
    else { removeMonitor() }
  }

  func removeMonitor() {
    if let monitor = eventMonitor {
      NSEvent.removeMonitor(monitor)
      eventMonitor = nil
    }
  }

  private func setupMonitor() {
    guard eventMonitor == nil else { return }
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      guard let self = self else { return event }
      return self.handleScrollEvent(event)
    }
  }

  private func handleScrollEvent(_ event: NSEvent) -> NSEvent? {
    guard self.window != nil else { return event }

    let locationInWindow = event.locationInWindow
    let locationInView = self.convert(locationInWindow, from: nil)

    // Only intercept if event is within our bounds
    guard self.bounds.contains(locationInView) else { return event }

    // Find and cache the parent scroll view
    if cachedParentScrollView == nil {
      cachedParentScrollView = findParentScrollView()
    }

    // Forward to parent and consume the event
    if let parent = cachedParentScrollView {
      parent.scrollWheel(with: event)
      return nil  // Consume the event
    }

    return event
  }

  private func findParentScrollView() -> NSScrollView? {
    var scrollViewCount = 0
    var current: NSView? = superview
    while let view = current {
      if let scrollView = view as? NSScrollView {
        scrollViewCount += 1
        // Skip first 2 scroll views (header and content of result table)
        if scrollViewCount >= 2 { return scrollView }
      }
      current = view.superview
    }
    return nil
  }
}
```

**Key insights:**
1. The overlay view (`ScrollMonitorView`) is placed as a SwiftUI `.overlay` on the entire `ResultTableView`
2. The local event monitor runs **before** events are dispatched to views
3. We check if the event location is within our overlay bounds to only intercept relevant events
4. By returning `nil` from the monitor, we consume the event and prevent it from reaching SwiftUI's scroll view
5. The parent scroll view (notebook List) is cached for performance

**Result:** ✅ Works! The local event monitor intercepts scroll events before SwiftUI processes them.

## Root Cause Analysis

### Why Query Editor Fix Works

The query editor uses `NSViewRepresentable` where we create the `NSScrollView` directly:

```swift
func makeNSView(context: Context) -> NSScrollView {
  let scrollView = PassthroughScrollView()  // We control this
  // ...
}
```

### Why Result Table Fix Doesn't Work

The result table uses SwiftUI `ScrollView`:

```swift
ScrollView(scrollAxes, showsIndicators: true) {
  // content
}
```

SwiftUI creates its own internal `NSScrollView` that we cannot directly replace or subclass. The `NSScrollView` is created and managed by SwiftUI's internal implementation.

## Solution Summary

The key insight is that **local event monitors run before events are dispatched to views**. By combining:

1. An `NSViewRepresentable` overlay to get accurate bounds checking
2. A local event monitor to intercept events before SwiftUI processes them
3. Forwarding intercepted events directly to the parent scroll view

We can effectively bypass SwiftUI's scroll event handling when the result table doesn't need vertical scrolling.

## Current Status

- **Query Editor:** ✅ Fixed with `PassthroughScrollView` (custom `NSScrollView` subclass)
- **Result Table:** ✅ Fixed with Local Event Monitor + Overlay (`ScrollMonitorView`)

## References

- [Apple scrollWheel documentation](https://developer.apple.com/documentation/appkit/nsscrollview/1403494-scrollwheel)
- [Cocoa: Passing scroll events to parent NSScrollView](https://copyprogramming.com/howto/how-to-pass-scroll-events-to-parent-nsscrollview)
- [How scroll views work on macOS](https://medium.com/hyperoslo/how-scroll-views-work-on-macos-f809225adcd)
- [10.9 AppKit Release Notes - Gesture scrolling](https://gist.github.com/zwaldowski/8710fddc8b0b39d2c152)
