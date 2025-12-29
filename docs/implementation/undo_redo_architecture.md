# Undo/Redo Architecture

## Overview

SQLNotebook implements a sophisticated undo/redo system that handles three distinct contexts:
1. **Cell content editing** - SQL code editing in notebook cells
2. **Cell-level operations** - Adding, deleting, duplicating cells
3. **Cell value editing** - Editing data values in the right sidebar

Each context requires different undo/redo behavior, and the system must intelligently route undo/redo commands to the appropriate handler.

---

## Problem Statement

### Initial Issue

When editing a cell value in the right sidebar's TextEditor, the undo/redo functionality (Cmd+Z, Cmd+Shift+Z) was not working. The Undo/Redo menu items appeared grayed out, and keyboard shortcuts had no effect.

### Root Cause

The app had a global undo/redo command system that replaced the default `.undoRedo` CommandGroup. This custom implementation:
1. Intercepted all Cmd+Z and Cmd+Shift+Z keyboard shortcuts globally
2. Posted notifications that were handled by `UndoRedoHandlerModifier`
3. Routed commands to either:
   - Cell editor's undo manager (when a cell editor was focused)
   - Cell-level undo manager (for structural changes)

However, this approach had a critical flaw: **when editing cell values in the right sidebar's TextEditor, the global command interception prevented the TextEditor from receiving native undo/redo events**, breaking its built-in undo functionality.

---

## Solution Architecture

### High-Level Approach

Instead of completely replacing the system's undo/redo commands, we implemented a **context-aware routing system** that:
1. Detects which editing context is active
2. Routes undo/redo commands appropriately based on context
3. Preserves native TextEditor undo/redo for cell value editing

### Key Components

#### 1. Cell Value Editing State Tracking

**File: `Utilities/FocusedValues.swift`**

```swift
struct CellValueEditingKey: FocusedValueKey {
  typealias Value = Bool
}

extension FocusedValues {
  var isCellValueEditing: CellValueEditingKey.Value? {
    get { self[CellValueEditingKey.self] }
    set { self[CellValueEditingKey.self] = newValue }
  }
}
```

- Uses SwiftUI's `FocusedValues` system to communicate editing state across the app
- Allows both view hierarchy and menu commands to access the state

#### 2. Cell Value Editor Integration

**File: `Views/Sidebars/CellInfoContent.swift`**

```swift
struct CellInfoContent: View {
  @State private var isEditing = false
  @FocusState private var isTextEditorFocused: Bool

  var body: some View {
    // ...
    TextEditor(text: $editedValue)
      .focused($isTextEditorFocused)
      .focusedValue(\.isCellValueEditing, isEditing)  // Expose state
    // ...
  }

  private func startEdit() {
    isEditing = true
    isTextEditorFocused = true
    NotificationCenter.default.post(name: .cellValueEditingStarted, object: nil)
  }

  private func cancelEdit() {
    isEditing = false
    isTextEditorFocused = false
    NotificationCenter.default.post(name: .cellValueEditingEnded, object: nil)
  }
}
```

- Maintains editing state and programmatic focus control
- Posts notifications when entering/exiting edit mode
- Exposes editing state via `focusedValue` modifier

#### 3. Key Event Interception

**File: `ContentView.swift`**

```swift
private func setupKeyEventMonitor() {
  keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
    // ... other event handling ...

    // Handle Cmd+Z (Undo) and Cmd+Shift+Z (Redo)
    let isZ = event.keyCode == 6  // Z key
    let hasCommand = event.modifierFlags.contains(.command)
    let hasShift = event.modifierFlags.contains(.shift)

    if isZ && hasCommand {
      // If editing cell value, let TextEditor handle its own undo/redo natively
      if self.isCellValueEditing {
        return event  // Pass through to TextEditor
      }

      // For cell content editors and cell-level operations, post notifications
      if hasShift {
        NotificationCenter.default.post(name: .redo, object: nil)
      } else {
        NotificationCenter.default.post(name: .undo, object: nil)
      }
      return nil  // Event consumed
    }

    return event
  }
}
```

**Key behavior:**
- Intercepts **ALL** Cmd+Z and Cmd+Shift+Z keyboard events at the window level (before they reach views)
- **Critically:** Does NOT check if a text view is focused - intercepts globally
- Checks if cell value editing is active via `isCellValueEditing` state
- **If editing cell value:** Returns the event untouched, allowing TextEditor to handle it natively
- **For all other cases (cell content editing OR cell-level operations):** Posts notification for custom handler
- This ensures cell-level undo/redo works even when no editor is focused

#### 4. Notification-Based State Synchronization

**File: `ContentView.swift`**

```swift
private struct UndoRedoHandlerModifier: ViewModifier {
  @Binding var isCellValueEditing: Bool

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .cellValueEditingStarted)) { _ in
        isCellValueEditing = true
      }
      .onReceive(NotificationCenter.default.publisher(for: .cellValueEditingEnded)) { _ in
        isCellValueEditing = false
      }
      .onReceive(NotificationCenter.default.publisher(for: .undo)) { _ in
        handleUndo()
      }
      .onReceive(NotificationCenter.default.publisher(for: .redo)) { _ in
        handleRedo()
      }
      // ... other handlers ...
  }

  private func handleUndo() {
    // Note: Cell value editing is handled by key event monitor
    // If we reach here, it's either cell content editing or cell-level operations

    if let textView = focusedTextView, let undoManager = textView.undoManager {
      // Editor is focused - use editor's undo manager
      undoManager.undo()
    } else {
      // No editor focused - use cell-level undo manager
      viewModel.undoManager.undo()
      syncDocument()
    }
  }

  private func handleRedo() {
    // Note: Cell value editing is handled by key event monitor
    // If we reach here, it's either cell content editing or cell-level operations

    if let textView = focusedTextView, let undoManager = textView.undoManager {
      // Editor is focused - use editor's undo manager
      undoManager.redo()
    } else {
      // No editor focused - use cell-level undo manager
      viewModel.undoManager.redo()
      syncDocument()
    }
  }
}
```

**Key points:**
- Synchronizes state across the app using NotificationCenter
- Updates `isCellValueEditing` binding used by key event monitor
- Maintains single source of truth for editing context
- **Simplified handler logic:** Does NOT check `isCellValueEditing` because key monitor already filtered out cell value editing cases
- Handles two scenarios: cell content editing (uses focused text view's undo manager) or cell-level operations (uses view model's undo manager)

#### 5. Menu Command Awareness

**File: `SQLNotebookApp.swift`**

```swift
struct NotebookCommands: Commands {
  @FocusedValue(\.isCellValueEditing) private var isCellValueEditing: Bool?

  var body: some Commands {
    // ... other commands ...

    // Note: We don't replace .undoRedo here to preserve native undo/redo for TextEditor
    // Custom undo/redo handling is done via key event monitoring in ContentView
  }
}
```

- Reads editing state via `@FocusedValue`
- **Crucially:** Does NOT replace `.undoRedo` CommandGroup
- Allows system's native undo/redo to work for TextEditor

---

## Data Flow

### Cell Value Editing Flow

```
1. User clicks "Edit" in CellInfoContent
   ↓
2. startEdit() called
   ├─ isEditing = true
   ├─ isTextEditorFocused = true (programmatic focus)
   └─ Post .cellValueEditingStarted notification
   ↓
3. UndoRedoHandlerModifier receives notification
   └─ isCellValueEditing = true (binding update)
   ↓
4. User presses Cmd+Z
   ↓
5. Key event monitor intercepts
   ├─ Checks: isCellValueEditing == true?
   └─ YES → return event (pass through)
   ↓
6. TextEditor receives Cmd+Z
   └─ Uses native undo manager → text changes are undone
   ↓
7. User clicks "Save" or "Cancel"
   ↓
8. Post .cellValueEditingEnded notification
   └─ isCellValueEditing = false
```

### Cell Content Editing Flow

```
1. User focuses on cell editor (SQL code)
   ↓
2. NSTextView becomes first responder
   ↓
3. User presses Cmd+Z
   ↓
4. Key event monitor intercepts
   ├─ Checks: isCellValueEditing == true?
   └─ NO → post .undo notification
   ↓
5. UndoRedoHandlerModifier.handleUndo()
   ├─ Checks: focusedTextView exists?
   └─ YES → focusedTextView.undoManager.undo()
```

### Cell-Level Operations Flow

```
1. User performs cell-level operation
   (e.g., delete cell, add cell, duplicate cell)
   ↓
2. Operation modifies notebook structure
   ↓
3. Changes registered with viewModel.undoManager
   ↓
4. User presses Cmd+Z (no editor focused)
   ↓
5. Key event monitor intercepts (ALL Cmd+Z are intercepted)
   ├─ Checks: isCellValueEditing == true?
   └─ NO → post .undo notification
   ↓
6. UndoRedoHandlerModifier.handleUndo()
   ├─ Checks: focusedTextView exists?
   └─ NO → viewModel.undoManager.undo()
   ↓
7. Structural change reverted (cell restored, etc.)
   └─ syncDocument() called to persist changes
```

---

## Key Design Decisions

### 1. Why Not Disable Global Commands?

**Attempted Solution:**
```swift
// This DOESN'T work
CommandGroup(replacing: .undoRedo) {
  Button("Undo") { ... }
    .disabled(isCellValueEditing == true)
}
```

**Problem:** When commands are disabled, both the menu item AND keyboard shortcuts are disabled. This prevents TextEditor from receiving any undo/redo events at all.

### 2. Why Not Post Notifications in Disabled Commands?

**Attempted Solution:**
```swift
CommandGroup(replacing: .undoRedo) {
  Button("Undo") {
    if isCellValueEditing != true {
      NotificationCenter.default.post(name: .undo, object: nil)
    }
  }
}
```

**Problem:** When we replace `.undoRedo`, we take over the keyboard shortcut routing. If the button action does nothing (due to the `if` check), the shortcut is consumed but no action occurs. The event never reaches TextEditor.

### 3. Why Key Event Monitor?

**Final Solution:** Use `NSEvent.addLocalMonitorForEvents` to intercept **ALL** Cmd+Z/Cmd+Shift+Z keyboard events BEFORE they reach the responder chain.

**Benefits:**
- Can examine event and decide whether to consume or pass through
- Operates at window level, before view-specific handling
- Allows selective interception based on application state
- Preserves native behavior when passing events through
- **Critical:** Intercepts globally (not just when text view focused), ensuring cell-level undo/redo works even when no editor has focus

**Implementation Detail:**
```swift
if isZ && hasCommand {
  // Check editing context, NOT focus state
  if self.isCellValueEditing {
    return event  // Pass to TextEditor
  }
  // Post notification for all other cases
  NotificationCenter.default.post(name: .undo, object: nil)
  return nil
}
```

This approach ensures:
- Cell value editing: Event passes through → TextEditor handles natively
- Cell content editing: Notification posted → Editor's undo manager used
- Cell-level operations: Notification posted → ViewModel's undo manager used

### 4. Why Both Notifications and FocusedValues?

- **FocusedValues:** For view hierarchy and menu commands (declarative SwiftUI)
- **Notifications:** For imperative coordination (key monitor, state updates)
- **Dual approach:** Ensures state consistency across different architectural layers

---

## Edge Cases Handled

### 1. Focus State Mismatch
**Problem:** FocusState might not reflect actual focus immediately.
**Solution:** Use both `@FocusState` (SwiftUI) and explicit focus management (`isTextEditorFocused = true`)

### 2. Multiple TextEditors
**Problem:** Both cell editor and cell value editor use NSTextView.
**Solution:** Track editing context via `isCellValueEditing` flag, not just view type.

### 3. Keyboard Shortcut Conflicts
**Problem:** System shortcuts, app shortcuts, and view-specific shortcuts can conflict.
**Solution:** Layer-based approach:
1. Key event monitor (highest priority, selective)
2. Command shortcuts (system-level)
3. View responders (lowest priority, default)

### 4. State Synchronization
**Problem:** State must be consistent across ContentView, CellInfoContent, and Commands.
**Solution:** Single source of truth with two-way communication:
- Notifications: CellInfoContent → ContentView
- FocusedValues: CellInfoContent → NotebookCommands
- Binding: ContentView internal state

---

## Testing Scenarios

### Verify Correct Behavior

1. **Cell Value Editing:**
   - ✅ Edit cell value → Cmd+Z undoes text changes
   - ✅ Redo with Cmd+Shift+Z works
   - ✅ Multiple undo/redo steps preserved

2. **Cell Content Editing:**
   - ✅ Edit SQL code → Cmd+Z undoes code changes
   - ✅ Undo works independently from cell value edits

3. **Cell-Level Operations:**
   - ✅ Delete cell → Cmd+Z restores cell
   - ✅ Add cell → Cmd+Z removes cell
   - ✅ Duplicate cell → Cmd+Z removes duplicate

4. **Context Switching:**
   - ✅ Edit cell value → save → edit cell content → undo works for cell content
   - ✅ Edit cell content → click edit cell value → undo works for cell value
   - ✅ No cross-contamination between contexts

5. **Menu State:**
   - ✅ Undo/Redo menu items not grayed out during cell value editing
   - ✅ Menu items show "Undo Typing" or similar during cell value editing

---

## File Changes Summary

### New Files
- `SQLNotebook/Utilities/FocusedValues.swift` - FocusedValue key definitions

### Modified Files
- `SQLNotebook/SQLNotebookApp.swift`
  - Removed custom `.undoRedo` CommandGroup replacement
  - Added `@FocusedValue` for awareness (though not actively used in final solution)

- `SQLNotebook/ContentView.swift`
  - Added `isCellValueEditing` state tracking
  - Enhanced key event monitor with context-aware Cmd+Z/Cmd+Shift+Z handling
  - Updated `UndoRedoHandlerModifier` to sync editing state

- `SQLNotebook/Views/Sidebars/CellInfoContent.swift`
  - Added `@FocusState` for TextEditor focus management
  - Added `.focusedValue()` modifier to expose editing state
  - Enhanced edit functions to post notifications

### Notification Names Added
- `.cellValueEditingStarted` - Posted when cell value editing begins
- `.cellValueEditingEnded` - Posted when cell value editing ends (save or cancel)

---

## Potential Future Improvements

### 1. Menu Item Labels
Update Undo/Redo menu item labels to reflect current context:
- "Undo Typing" when editing text
- "Undo Delete Cell" after deleting
- "Undo Add Cell" after adding

### 2. Undo Grouping
Group related operations:
- "Undo Run All Cells" to revert all results from a single run
- "Undo Cell Edits" to revert multiple changes made in sequence

### 3. Persistent Undo History
Currently undo history is lost when:
- Closing the document
- Switching between documents

Could persist undo stack in document metadata.

### 4. Visual Undo Feedback
Add visual indicators:
- Flash/highlight cells that change during undo
- Show undo history timeline
- Preview undo action before applying

---

## Related Documentation

- `keyboard_shortcuts.md` - Full list of keyboard shortcuts including undo/redo
- `project.md` - Overall architecture and design decisions
- Apple's [Undo Architecture](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/UndoArchitecture.html)
- SwiftUI [FocusedValues](https://developer.apple.com/documentation/swiftui/focusedvalues)

---

## Common Issues and Fixes

### Undo/Redo Only Works for Single Character

**Symptom:** When pressing Cmd+Z multiple times, only the last character typed is undone. The undo stack appears to only contain one undo operation instead of multiple text changes.

**Root Cause:** The binding update in `textDidChange()` was interfering with the undo manager. When the text binding is updated immediately on every keystroke, it creates conflicts with the undo stack, causing only the last character to be undoable.

**Solution:**

1. **Move binding updates to focus loss**: Only update the SwiftUI binding when the editor loses focus (via `onBlur` callback in `resignFirstResponder`), not on every text change.

2. **Disable undo registration for syntax highlighting**: Explicitly disable undo registration when applying syntax highlighting to prevent these operations from polluting the undo stack.

```swift
// In textDidChange - DO NOT update binding here
func textDidChange(_ notification: Notification) {
  guard let textView = notification.object as? NSTextView else { return }

  // Apply syntax highlighting without affecting undo stack
  applyHighlightingWithoutUndo(to: textView, text: textView.string)

  // Update height to fit content
  updateHeight(textView: textView)

  // DO NOT update binding here - it causes undo/redo issues!
  // The binding will be updated when editor loses focus
}

// In makeNSView and updateNSView - setup onBlur callback
textView.onBlur = { [weak coordinator = context.coordinator] newText in
  coordinator?.text.wrappedValue = newText
}

// In applyHighlightingWithoutUndo - disable undo registration
func applyHighlightingWithoutUndo(to textView: NSTextView, text: String) {
  let undoManager = textView.undoManager
  undoManager?.disableUndoRegistration()

  textStorage.beginEditing()
  // ... modify attributes ...
  textStorage.endEditing()

  undoManager?.enableUndoRegistration()
}
```

This ensures that:
- User text edits are properly tracked by the undo manager
- Syntax highlighting operations are completely invisible to the undo manager
- The binding stays in sync (updated on blur) without interfering with undo/redo
- Placeholder disappears immediately when typing (via separate `isEmpty` state)

**Placeholder Reactivity:**

Since the text binding is only updated on blur, the placeholder needs a separate mechanism to react immediately when user types. This is solved by:

1. Adding an `isEmpty: Bool` binding to track whether text is empty
2. Updating this binding in `textDidChange()` (safe because it's just a Bool, not the full text)
3. Placeholder checks `isEmpty` instead of `content.isEmpty`

```swift
// In SQLEditorView
@State private var isTextEmpty: Bool = true

// Placeholder checks isTextEmpty
if isTextEmpty {
  Text("-- Write your SQL query here...")
}

// In textDidChange - update isEmpty immediately
isEmpty.wrappedValue = textView.string.isEmpty
```

**Files Changed:**
- `SQLNotebook/Views/Components/HighlightedTextEditor.swift`
  - Removed text binding update from `textDidChange()`
  - Added `isEmpty` binding parameter and update it in `textDidChange()`
  - Added `onBlur` callback setup in `makeNSView()` and `updateNSView()`
  - Added `disableUndoRegistration()` and `enableUndoRegistration()` calls around syntax highlighting operations

- `SQLNotebook/Views/Components/CellView+Editor.swift`
  - Added `isTextEmpty` state to track empty status
  - Placeholder now checks `isTextEmpty` instead of `content.isEmpty`
  - Added `onChange(of: content)` to sync `isTextEmpty` when content changes externally

---

## Conclusion

The undo/redo system demonstrates how to build context-aware command routing in SwiftUI apps that mix native AppKit controls (NSTextView) with SwiftUI views. The key insight is using **selective event interception** rather than complete command replacement, allowing native behaviors to work where appropriate while providing custom handling where needed.
