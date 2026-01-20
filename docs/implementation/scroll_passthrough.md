# Scroll Passthrough for Result Tables

## Problem

When the mouse cursor is over a result table, scroll wheel events are captured by that scroll view instead of propagating to the parent scroll view (the main notebook List). This prevents global scrolling of the app when hovering over result tables.

**Expected behavior:**
- Vertical scroll events should pass through to parent notebook list for global scrolling
- Horizontal scroll events should scroll the result table columns
- Shift+scroll (mouse) should scroll horizontally

**Issues solved:**
1. Vertical scrolling blocked when hovering over result tables
2. Horizontal scrolling not working with trackpad
3. Shift+scroll (mouse) not working for horizontal scrolling
4. Result table content not visible (NSHostingView sizing issue)
5. Horizontal scrollbar covering last row

## Solution

### Architecture

Result tables use a custom `NSScrollView` subclass (`ResultTableScrollView`) wrapped in `NSViewRepresentable`:

1. **Custom ResultTableScrollView** - Subclasses `NSScrollView` and overrides `scrollWheel(with:)` to:
   - Handle horizontal scrolls internally
   - Forward vertical scrolls to parent via `nextResponder`
   - Convert shift+scroll to horizontal scroll

2. **HorizontalScrollableContent** - `NSViewRepresentable` wrapper that:
   - Creates and configures the `ResultTableScrollView`
   - Hosts SwiftUI content via `NSHostingView`
   - Syncs horizontal scroll position with header
   - Implements `sizeThatFits` for proper SwiftUI layout integration

3. **No max-height constraint** - Result tables expand to fit content naturally

4. **Bottom padding** - Prevents horizontal scrollbar from covering last row

### Key Files

- `ResultTableView.swift` - Main implementation
  - Line 65-83: `HorizontalScrollableContent` usage with bottom padding
  - Line 682-764: `HorizontalScrollableContent` struct
  - Line 766-823: `ResultTableScrollView` class

### ResultTableScrollView Logic

```swift
override func scrollWheel(with event: NSEvent) {
  let isShiftScroll = event.modifierFlags.contains(.shift)
  let deltaX = event.scrollingDeltaX
  let deltaY = event.scrollingDeltaY

  // Shift+scroll: convert vertical to horizontal
  if isShiftScroll && deltaY != 0 && deltaX == 0 {
    scrollHorizontally(by: deltaY)
    return  // Consume
  }

  // Pure horizontal scroll (trackpad swipe)
  if deltaX != 0 && deltaY == 0 {
    scrollHorizontally(by: deltaX)
    return  // Consume
  }

  // Diagonal scroll: handle horizontal, pass vertical to parent
  if deltaX != 0 && deltaY != 0 {
    scrollHorizontally(by: deltaX)
    nextResponder?.scrollWheel(with: event)
    return
  }

  // Pure vertical scroll: pass entirely to parent
  nextResponder?.scrollWheel(with: event)
}
```

### NSHostingView Sizing

The `HorizontalScrollableContent` properly sizes the `NSHostingView`:

```swift
func updateNSView(_ scrollView: ResultTableScrollView, context: Context) {
  if let hostingView = scrollView.documentView as? NSHostingView<Content> {
    hostingView.rootView = content()
    // Let hosting view calculate its intrinsic size
    let fittingSize = hostingView.fittingSize
    hostingView.frame = NSRect(origin: .zero, size: fittingSize)
  }
}

func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: ResultTableScrollView, context: Context) -> CGSize? {
  guard let hostingView = scrollView.documentView as? NSHostingView<Content> else { return nil }
  let fittingSize = hostingView.fittingSize
  let width = proposal.width ?? fittingSize.width
  return CGSize(width: width, height: fittingSize.height)
}
```

### Why This Works

- **Custom NSScrollView subclass** - Full control over `scrollWheel(with:)` method
- **nextResponder forwarding** - Events propagate up the responder chain to parent scroll view
- **No SwiftUI ScrollView for content** - Avoids SwiftUI's event interception
- **Shift+scroll detection** - `event.modifierFlags.contains(.shift)` for mouse horizontal scrolling
- **NSHostingView.fittingSize** - Properly calculates content size for SwiftUI layout
- **sizeThatFits implementation** - Tells SwiftUI the exact size needed
- **Bottom padding** - `.padding(.bottom, 12)` prevents scrollbar overlap

## Query Editor

The query editor uses a similar approach with `PassthroughScrollView`:

**File:** `HighlightedTextEditor.swift`

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

## Failed Approaches

These approaches were tried but didn't work:

- **SwiftUI ScrollView with .horizontal axes** - Still captured vertical scroll events
- **Local event monitor** - `NSEvent.addLocalMonitorForEvents` consumed events before responder chain
- **Method Swizzling** - Swizzled NSScrollView.scrollWheel globally → caused infinite recursion crashes
- **Replace NSClipView** - Custom PassthroughClipView → NSScrollView handles events before NSClipView
- **ISA-Swizzling** - `object_setClass()` on SwiftUI's internal NSScrollView → SwiftUI still intercepted events
- **Overlay-based approach** - `.overlay` modifier with event monitor → blocked horizontal scrolls
- **Max-height constraint** - Limited result table height → blocked global scrolling when content exceeded max height
- **NSHostingView without fittingSize** - Content was invisible because frame wasn't set

## Current Status

✅ **Working:**
- Result tables: No vertical scrollbar, expands to fit content
- Horizontal scroll: Works (scrollbar click, trackpad, shift+scroll)
- Global vertical scroll: Works (events pass to parent notebook list)
- Diagonal scroll (trackpad): Horizontal applied to table, vertical to parent
- Content visibility: NSHostingView properly sized
- Last row visible: Bottom padding prevents scrollbar overlap

## Testing

Test the following scenarios:

1. **Small result table** (few rows):
   - Vertical scroll with mouse wheel → parent list scrolls ✅
   - Vertical scroll with trackpad → parent list scrolls ✅
   - Horizontal scroll with trackpad → result table scrolls ✅
   - Shift+scroll with mouse → result table scrolls horizontally ✅
   - Click horizontal scrollbar → result table scrolls ✅
   - Last row fully visible (not covered by scrollbar) ✅

2. **Wide result table** (many columns):
   - All horizontal scroll methods work ✅
   - Vertical scroll passes to parent ✅

3. **Diagonal scroll** (trackpad):
   - Horizontal component scrolls result table ✅
   - Vertical component scrolls parent list ✅

## References

- [Apple scrollWheel documentation](https://developer.apple.com/documentation/appkit/nsscrollview/1403494-scrollwheel)
- [Passing scroll events to parent NSScrollView](https://copyprogramming.com/howto/how-to-pass-scroll-events-to-parent-nsscrollview)
- [How scroll views work on macOS](https://medium.com/hyperoslo/how-scroll-views-work-on-macos-f809225adcd)
- [Electron nested scrollview issues](https://github.com/electron/electron/issues/32751)
- [NSHostingView sizing](https://developer.apple.com/documentation/swiftui/nshostingview)
