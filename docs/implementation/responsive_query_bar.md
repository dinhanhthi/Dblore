# Responsive Query Copy Bar

## Problem

The "Run with Query" bar (QueryCopyBar component) displayed poorly when the window was resized to smaller widths. UI elements became cramped, text got truncated, and buttons overlapped, creating a poor user experience during window resizing.

## Solution

Implemented responsive layout using `GeometryReader` to track available width and conditionally show/hide UI elements based on three breakpoint modes:

1. **Full mode (≥600pt)**: Show all elements with labels
2. **Intermediate mode (300-599pt)**: Icon-only buttons, hide "Run with query:" label
3. **Compact mode (<300pt)**: Hide entire query section, show full buttons

### Key Changes

- `SQLNotebook/Views/Components/QueryCopyBar.swift:50` - Added `@State private var availableWidth: CGFloat` to track width
- `SQLNotebook/Views/Components/QueryCopyBar.swift:58-72` - Created `LayoutMode` enum with three states and factory method
- `SQLNotebook/Views/Components/QueryCopyBar.swift:82-112` - Wrapped query section in conditional `if layoutMode != .compact`
- `SQLNotebook/Views/Components/QueryCopyBar.swift:93-97` - Hide "Run with query:" label in intermediate mode
- `SQLNotebook/Views/Components/QueryCopyBar.swift:169-172` - Show button labels only in full/compact mode
- `SQLNotebook/Views/Components/QueryCopyBar.swift:279-283` - Show Download label and chevron only in full/compact mode
- `SQLNotebook/Views/Components/QueryCopyBar.swift:120-130` - Added GeometryReader to track width changes in real-time

## Layout Modes Explained

### Full Mode (≥600pt)
```
[📄 Run with query (click to copy): SELECT * FROM...] [👁 View Query] [⬇ Download ▼]
```
- All labels visible
- Full text for "Run with query (click to copy):"
- Button labels shown
- Chevron shown on Download button

### Intermediate Mode (300-599pt)
```
[📄 SELECT * FROM...] [👁] [⬇]
```
- "Run with query:" label hidden
- Query text still visible
- Icon-only buttons (no labels)
- No chevron on Download button

### Compact Mode (<300pt)
```
[👁 View Query] [⬇ Download ▼]
```
- Entire query section hidden (icon, label, query text)
- Full buttons with labels shown
- Chevron shown on Download button
- Maintains essential functionality

## Implementation Details

### Width Tracking
```swift
@State private var availableWidth: CGFloat = 0

.background(
  GeometryReader { geometry in
    Color.clear
      .onAppear {
        availableWidth = geometry.size.width
      }
      .onChange(of: geometry.size.width) { oldValue, newValue in
        availableWidth = newValue
      }
  }
)
```

This approach ensures:
- Real-time width updates during window resize
- No performance impact (GeometryReader in background)
- Smooth transitions between modes

### Breakpoint Selection

Breakpoints were chosen based on:
- 600pt: Minimum width for comfortable full layout
- 300pt: Minimum width to show query text without cramping
- <300pt: Better to hide query entirely and focus on actions

## Testing

Manual testing performed:
- ✅ Full mode displays correctly at 700pt width
- ✅ Intermediate mode hides labels at 450pt width
- ✅ Compact mode hides query at 250pt width
- ✅ Real-time transitions work smoothly during resize
- ✅ All functionality preserved across modes (copy, view, download)

## User Experience Impact

**Before:**
- Query bar became unreadable at small widths
- Buttons overlapped and became hard to click
- No graceful degradation

**After:**
- Clean adaptation to available space
- Essential actions always accessible
- Smooth transitions during resize
- Maintains all functionality

## Future Enhancements

- [ ] Add animation transitions between layout modes
- [ ] Make breakpoints configurable via AppSettings
- [ ] Add visual indicator for truncated query in intermediate mode
- [ ] Consider adding a tooltip showing full query when truncated

## Related Files

- [QueryCopyBar.swift](SQLNotebook/Views/Components/QueryCopyBar.swift) - Main component
- [responsive_ui_design.md](docs/implementation/responsive_ui_design.md) - General responsive UI guide

## Notes

This implementation uses `GeometryReader` instead of `ViewThatFits` because:
1. Need precise control over three breakpoint modes
2. Progressive disclosure of content (not just 2 layouts)
3. Different behavior for query section vs buttons

The `onChange(of:)` modifier ensures real-time updates during window resize, providing smooth responsive behavior that users expect from modern macOS applications.
