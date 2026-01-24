# Search Panel ESC Key Handling Fix

## Problem

When the search panel was open and user pressed ESC key, the search panel did not close properly. Multiple issues occurred:

1. **Editor mode**: ESC key did nothing - search panel remained open
2. **Notebook mode**: Required pressing ESC twice to close the search panel
3. **Multi-window scenario**: When 2+ windows were open, ESC behavior was unpredictable - sometimes required 2 presses, sometimes didn't work at all
4. **Focus not restored**: After closing search, cursor didn't return to the editor (expected VSCode-like behavior)

## Solution

Implemented a comprehensive ESC key handling system with proper window ownership tracking and focus restoration:

1. **Window-scoped NSEvent monitors** - Each window tracks its own events to prevent cross-window interference
2. **Focus restoration** - Save and restore `firstResponder` when opening/closing search (VSCode behavior)
3. **Priority-based ESC handling** - Clear hierarchy for ESC actions
4. **Search field exclusion** - Don't treat search TextField as "text editor focused" when checking ESC priorities

### Key Changes

**1. Window Ownership Tracking**

- `EditorContentView.swift:15` - Added `@State private var monitorWindow: NSWindow?`
- `NotebookContentView.swift:15` - Added `@State private var monitorWindow: NSWindow?`
- `EditorContentView.swift:130-138` - Store window reference on first event, only handle events from that window
- `NotebookContentView.swift:167-175` - Same window ownership logic

**2. Focus Restoration (VSCode-like behavior)**

- `NotebookViewModel.swift:99` - Added `var previousFirstResponder: NSResponder?`
- `NotebookViewModel+Search.swift:7` - Import AppKit for NSApplication access
- `NotebookViewModel+Search.swift:256-257` - Save `firstResponder` when opening search
- `NotebookViewModel+Search.swift:242-246` - Restore `firstResponder` when closing search

**3. Search Field Focus Exclusion**

- `EditorContentView.swift:140-151` - When search panel visible, return `false` for `textViewIsFocused` to prevent unfocus action
- This ensures ESC closes search panel instead of unfocusing the search TextField

**4. Removed Conflicting .onKeyPress**

- `SearchPanelView.swift:26-29` - Removed `.onKeyPress(.escape)` handler that was causing duplicate handling

## Already Tried

❌ **Approach 1: SwiftUI `.onKeyPress` in SearchPanelView**
- **Why it failed**: In editor mode, SwiftUI event system didn't receive ESC events reliably. NSEvent monitor and `.onKeyPress` conflicted.

❌ **Approach 2: Pass ESC event through to SwiftUI (`return event`)**
- **Why it failed**: SwiftUI didn't receive the passed-through event. NSEvent local monitor doesn't guarantee SwiftUI delivery.

❌ **Approach 3: Priority-based without window tracking**
- **Why it failed**: Multiple windows' NSEvent monitors all received the same event, causing duplicate handling or missed events.

❌ **Approach 4: Check `isSearchPanelVisible` as first priority**
- **Why it failed**: SwiftUI TextField internally uses NSTextView, so `textViewIsFocused` returned `true` for search field, consuming ESC before reaching search close logic.

## Implementation Details

### ESC Key Priority Hierarchy

**When search panel is visible:**
```
Priority 0: Close search panel
  ↓
Priority 1: Unfocus text editor (if focused and search not visible)
  ↓
Priority 2: Close right sidebar (if open)
```

**Window Ownership Logic:**
```swift
// Store window on first event
if self.monitorWindow == nil {
  self.monitorWindow = eventWindow
}

// Only handle events from OUR window
guard eventWindow == self.monitorWindow else {
  return event  // Different window, pass through
}
```

### Focus Restoration Flow

**Open Search:**
1. Save current `firstResponder` → `previousFirstResponder`
2. Show search panel
3. Search field auto-focuses after 0.1s delay

**Close Search:**
1. Hide search panel
2. Clear search state
3. Restore `previousFirstResponder` → cursor returns to editor

### Multi-Window Behavior

**Before fix:**
- Window A's monitor received events from Window B → duplicate handling
- Both monitors tried to close search → required 2 ESC presses

**After fix:**
- Each monitor tracks its window (`monitorWindow`)
- Only handle events where `eventWindow == monitorWindow`
- Clean separation: Window A handles A's events, Window B handles B's events

## Testing

✅ **Single window - Editor mode**: ESC closes search in 1 press, focus restored to SQL editor
✅ **Single window - Notebook mode**: ESC closes search in 1 press, focus restored to cell editor
✅ **Multi-window scenario**: Open 2 windows (1 editor + 1 notebook), ESC only affects active window
✅ **Focus restoration**: After closing search, cursor returns to exact position in editor
✅ **Search field focused**: ESC from search field closes panel immediately
✅ **Search field not focused**: ESC still closes panel (NSEvent monitor handles)

## Technical Notes

### Why NSEvent Local Monitor?

- **Per-app, not per-window**: `NSEvent.addLocalMonitorForEvents` receives ALL key events in the app
- **Requires window filtering**: Must manually check window ownership to prevent cross-window handling
- **Alternative**: Could use global monitor, but local monitor is preferred for app-specific shortcuts

### Why TextField Uses NSTextView

- SwiftUI `TextField` internally uses `NSTextView` on macOS
- This caused `firstResponder is NSTextView` to return `true` for search field
- Solution: Exclude search field by checking `isSearchPanelVisible` in `textViewIsFocused` logic

### Why Store Window on First Event

- `NSApplication.shared.keyWindow` may be `nil` during view initialization
- Storing window reference during `setupKeyEventMonitor()` is unreliable
- Solution: Store window when first event arrives (window guaranteed to exist)

## Related Files

- `EditorContentView.swift` - Editor mode ESC handling
- `NotebookContentView.swift` - Notebook mode ESC handling
- `SearchPanelView.swift` - Search panel UI
- `NotebookViewModel+Search.swift` - Search state & focus restoration
- `NotebookViewModel.swift` - ViewModel with `previousFirstResponder` property
- `HighlightedTextEditor.swift` - Added `.unfocusEditor` notification observer

## Future Improvements

- [ ] Consider using SwiftUI `@FocusState` for focus management (requires macOS 12+)
- [ ] Add telemetry to track ESC key usage patterns
- [ ] Investigate using `focusedSceneValue` for window-scoped event handling

## References

- Apple NSEvent Documentation: https://developer.apple.com/documentation/appkit/nsevent
- SwiftUI Focus Management: https://developer.apple.com/documentation/swiftui/focusstate
- VSCode Search Behavior: https://code.visualstudio.com/docs/editor/codebasics#_search-across-files
