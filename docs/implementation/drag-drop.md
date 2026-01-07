# Drag and Drop Cell Reordering

## Overview

SQLNotebook implements drag and drop cell reordering using a **blue drop indicator** approach (similar to Jupyter notebook in VSCode) instead of opacity-based feedback. This solution avoids the inherent SwiftUI drag lifecycle limitations.

**Status:** ✅ Solved (2026-01-06)

---

## Implementation

### Architecture

The implementation uses a centralized state management approach with visual drop indicators:

```swift
// NotebookViewModel.swift
enum DropPosition {
  case above
  case below
}

@Observable
class NotebookViewModel {
  var draggingCellId: UUID? = nil        // Cell being dragged
  var dropTargetCellId: UUID? = nil      // Cell being hovered over
  var dropPosition: DropPosition? = nil  // Where to show indicator
}
```

### Key Components

**1. Drop Indicator Component** ([CellComponents.swift:271-282](SQLNotebook/Views/Components/CellComponents.swift#L271-L282))

```swift
struct DropIndicatorView: View {
  let position: DropPosition

  var body: some View {
    Rectangle()
      .fill(Color.accentColor)
      .frame(height: 2)
      .padding(.horizontal, Spacing.md)
  }
}
```

**2. Indicator Display Logic** ([CellView.swift:32-48](SQLNotebook/Views/Components/CellView.swift#L32-L48))

```swift
// Show indicator above cell
if viewModel.dropTargetCellId == cell.id && viewModel.dropPosition == .above {
  VStack {
    DropIndicatorView(position: .above)
    Spacer()
  }
  .zIndex(100)
}

// Show indicator below cell
if viewModel.dropTargetCellId == cell.id && viewModel.dropPosition == .below {
  VStack {
    Spacer()
    DropIndicatorView(position: .below)
  }
  .zIndex(100)
}
```

**3. Drop Position Calculation** ([CellView.swift:206-224](SQLNotebook/Views/Components/CellView.swift#L206-L224))

```swift
func dropEntered(info: DropInfo) {
  viewModel.dropTargetCellId = cell.id

  // Blue indicator semantics:
  // - Indicator at TOP of cell → drop ABOVE this cell
  // - Indicator at BOTTOM of cell → drop BELOW this cell
  let dropLocation = info.location.y
  viewModel.dropPosition = dropLocation < 60 ? .above : .below
}

func dropUpdated(info: DropInfo) -> DropProposal? {
  // Update position as mouse moves
  let dropLocation = info.location.y
  viewModel.dropPosition = dropLocation < 60 ? .above : .below
  return DropProposal(operation: .move)
}
```

**4. Drop Execution** ([CellView.swift:234-288](SQLNotebook/Views/Components/CellView.swift#L234-L288))

```swift
func performDrop(info: DropInfo) -> Bool {
  // Capture drop position BEFORE clearing state
  let capturedDropPosition = viewModel.dropPosition

  defer {
    viewModel.draggingCellId = nil
    viewModel.dropTargetCellId = nil
    viewModel.dropPosition = nil
  }

  // ... get dragged cell ID from pasteboard ...

  Task { @MainActor in
    guard let fromIndex = viewModel.notebook.cells.firstIndex(where: { $0.id == draggedCellId }),
          let toIndex = viewModel.notebook.cells.firstIndex(where: { $0.id == cell.id })
    else { return }

    guard fromIndex != toIndex else { return }

    // Calculate destination based on drop position
    let destination: Int
    if capturedDropPosition == .below {
      destination = toIndex + 1  // Drop after target
    } else {
      destination = toIndex      // Drop at target position
    }

    // moveCell handles index adjustment for move direction
    viewModel.moveCell(from: IndexSet([fromIndex]), to: destination)
  }

  return true
}
```

---

## UX Behavior

### Drop Indicator Semantics

The blue drop indicator always represents the **exact position** where the cell will be inserted:

| Scenario | Indicator Position | Result |
|----------|-------------------|--------|
| Drag C between A and B (closer to A) | Bottom edge of A | C inserted after A → `[A, C, B]` |
| Drag C between A and B (closer to B) | Top edge of B | C inserted before B → `[A, C, B]` |
| Drag C above A | Top edge of A | C inserted before A → `[C, A, B]` |
| Drag C below B | Bottom edge of B | C inserted after B → `[A, B, C]` |

**Key insight:** The blue line between two cells always means "drop between them", regardless of which cell triggered the `dropEntered` event.

---

## Why This Approach Works

### Advantages Over Opacity-Based Feedback

1. **No state management issues:** Opacity required tracking drag end events (which SwiftUI doesn't provide reliably)
2. **Clear visual feedback:** Blue line shows exact drop position
3. **Familiar UX:** Matches Jupyter notebook in VSCode
4. **Reliable state cleanup:** `defer` block in `performDrop` ensures cleanup
5. **No timing dependencies:** No need for timeouts or polling

### State Capture Pattern

Critical implementation detail - capture state **before** `defer` block:

```swift
func performDrop(info: DropInfo) -> Bool {
  let capturedDropPosition = viewModel.dropPosition  // ✅ Capture first

  defer {
    viewModel.dropPosition = nil  // Then clear in defer
  }

  // Use capturedDropPosition in async Task
  Task { @MainActor in
    if capturedDropPosition == .below { ... }
  }
}
```

**Why:** The `defer` block executes before the async `Task`, so accessing `viewModel.dropPosition` inside the Task would always get `nil` without capturing.

---

## Index Calculation Logic

The `moveCell` function in `NotebookViewModel+CellManagement.swift` already adjusts indices based on move direction:

```swift
func moveCell(from source: IndexSet, to destination: Int) {
  let actualDestination = sourceIndex < destination ? destination - 1 : destination
  notebook.cells.move(fromOffsets: source, toOffset: destination)
}
```

Therefore, `performDrop` provides the "raw" destination:
- Drop **below** target at index N → `destination = N + 1`
- Drop **above** target at index N → `destination = N`

`moveCell` handles the final adjustment based on whether we're moving up or down.

---

## Previous Approach: Opacity-Based Feedback (Failed)

The original implementation used `.opacity(isDragging ? 0.5 : 1.0)` for drag feedback, which had fundamental issues:

### Why Opacity Failed

1. **SwiftUI `.onDrag` limitations:**
   - Only triggers when drag **starts**, not when it ends
   - No `onEnded` callback (unlike `DragGesture`)
   - Drop delegates only fire on drop **targets**, not the dragged cell

2. **State management problems:**
   - Local per-cell `isDragging` state couldn't be reset reliably
   - `dropExited` doesn't fire in all scenarios (ESC key, drop outside zone)
   - Race conditions between timeout-based cleanup and actual drop

3. **Failed solutions attempted:**
   - `onEnded` callback → Compiler error (not supported)
   - Reset in drop delegates → Wrong cell (architectural mismatch)
   - Short timeout (300ms) → Opacity disappears while still dragging
   - Long timeout (5s) → Delayed cleanup, unreliable

### Technical Constraints That Led to Blue Indicator Approach

**SwiftUI Drag & Drop Lifecycle Gaps:**
- No drag end callback
- `dropExited` unreliable
- `performDrop` only called on successful drops in valid zones
- Cancellation scenarios not covered (ESC, drop outside, interrupts)

**Solution:** Avoid drag end detection entirely by using **positional visual feedback** (blue indicator) instead of **state-based visual feedback** (opacity).

---

## Code Locations

- **Drop Indicator Component:** [CellComponents.swift:271-282](SQLNotebook/Views/Components/CellComponents.swift#L271-L282)
- **Indicator Display:** [CellView.swift:32-48](SQLNotebook/Views/Components/CellView.swift#L32-L48)
- **Drop Delegate:** [CellView.swift:202-288](SQLNotebook/Views/Components/CellView.swift#L202-L288)
- **State Management:** [NotebookViewModel.swift:9-39](SQLNotebook/ViewModels/NotebookViewModel.swift#L9-L39)
- **Move Logic:** [NotebookViewModel+CellManagement.swift:159-180](SQLNotebook/ViewModels/NotebookViewModel+CellManagement.swift#L159-L180)
- **Drag Handle:** [CellComponents.swift:99-130](SQLNotebook/Views/Components/CellComponents.swift#L99-L130)

---

## References

- [SwiftUI Drag Gestures - iTwenty's Space](https://itwenty.me/posts/06-swiftui-drawerview-p2/)
- [Move your view around with Drag Gesture in SwiftUI | Sarunw](https://sarunw.com/posts/move-view-around-with-drag-gesture-in-swiftui/)
- [Drag and drop in SwiftUI | Swift with Majid](https://swiftwithmajid.com/2020/04/01/drag-and-drop-in-swiftui/)

**Key Learning:** When SwiftUI doesn't provide lifecycle hooks you need, redesign the UX to avoid needing those hooks. Positional feedback (blue indicator) > State-based feedback (opacity) for drag & drop.

---

**Created:** 2026-01-06
**Status:** ✅ Solved - Blue drop indicator implementation working perfectly
