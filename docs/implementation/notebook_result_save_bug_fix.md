# Notebook Result Save Bug Fix

## Problem

Query results were not being saved to `.sqlnb` files when executing new queries. Users could execute SQL queries, see results display correctly in the UI, save the file with Cmd+S, but when reopening the file, the newly executed results would be lost. Only old results that were already in the file were preserved.

### Symptoms

- User executes a query in a cell → result displays correctly in UI
- User saves file (Cmd+S) → save indicator shows "Saved"
- User checks the `.sqlnb` file content → NO "result" field for new queries
- User reopens the file → new results are lost, only old results remain
- Query text (content) was saved correctly, only results were missing
- Closing file without saving still shows results (temporary in-memory state only)

### Impact

- Critical data loss issue: users' query results are lost on file reopen
- Defeats the purpose of a notebook application (reproducible, persistent results)
- New results never persisted, only old cached results from previous sessions
- Affects all query executions: SELECT, INSERT, UPDATE, DELETE, etc.

---

## Root Cause Analysis

### The Missing `onDocumentChanged()` Callback

When executing a query and setting the result in `NotebookViewModel+Execution.swift`, the `onDocumentChanged()` callback was **NOT being called**. This callback is critical for:

1. **Triggering document synchronization** - Calls `syncDocument()` in NotebookContentView
2. **Registering undo action** - Marks the document as "dirty" (changed) with the UndoManager
3. **Signaling macOS** - Tells macOS the document has unsaved changes
4. **Enabling autosave** - macOS autosave mechanism respects dirty state

Without calling `onDocumentChanged()`, the ReferenceFileDocument never knew the document changed, so it didn't include new results in the save operation.

### Why Results Weren't Saved

```
User executes query
    ↓
executeTask() runs query → Gets result ✅
    ↓
notebook.cells[index].result = result ✅
    ↓
❌ onDocumentChanged() NOT called
    ↓
NotebookContentView.syncDocument() NOT triggered
    ↓
Document still marked as "clean"
    ↓
ReferenceFileDocument doesn't know about change
    ↓
Save operation ignores results
    ↓
.sqlnb file saved without result field ❌
```

### Comparison with Successful Cases

Query **text** (content) was saved correctly because:
- `CellContentEditorView` has keyboard event handler
- Detects changes via text binding
- Calls `onDocumentChanged?()` after content updates
- Result: `.sqlnb` file includes updated "content" field

Query **results** were not saved because:
- `executeTask()` directly modifies `notebook.cells[index].result`
- Never calls `onDocumentChanged?()` after setting result
- No synchronization triggered
- Result: `.sqlnb` file missing "result" field

---

## Solution Implemented

Added `onDocumentChanged?()` calls to 4 locations in `NotebookViewModel+Execution.swift` where cell results are modified:

### Location 1: After Query Execution (Line ~139)

**File**: `/Users/thi/git/SQLNotebook/SQLNotebook/ViewModels/NotebookViewModel+Execution.swift`

```swift
notebook.cells[index].isRunning = false

// Notify document changed to trigger save
onDocumentChanged?()  // ✅ Added - critical for persistence

// Check file size after execution and show warning if needed
checkFileSizeAfterExecution()
```

**Why**: This is the most critical location. After successfully executing a query and setting the result, we must notify that the document changed so it gets saved.

### Location 2: Not Connected Error (Line ~17)

**File**: `/Users/thi/git/SQLNotebook/SQLNotebook/ViewModels/NotebookViewModel+Execution.swift`

```swift
guard connectionState.isConnected else {
  notebook.cells[index].result = .errorResult("Not connected to database")
  onDocumentChanged?()  // ✅ Added - error results should also be saved
  return
}
```

**Why**: Error messages are important feedback. When the database isn't connected, we set an error result that should be persisted so the user knows what happened when reopening the file.

### Location 3: Restore Cell Output (Line ~204)

**File**: `/Users/thi/git/SQLNotebook/SQLNotebook/ViewModels/NotebookViewModel+Execution.swift`

```swift
func restoreCellOutput(
  id: UUID, result: CellResult?, executionCount: Int?, registerUndo: Bool
) {
  guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }

  notebook.cells[index].result = result
  notebook.cells[index].executionCount = executionCount

  // Register redo
  if registerUndo {
    undoManager.registerUndo(withTarget: self) { target in
      MainActor.assumeIsolated {
        target.clearCellOutput(id: id, registerUndo: true)
      }
    }
    onDocumentChanged?()  // ✅ Added - undo operations should trigger save
  }
}
```

**Why**: When undoing a "clear output" operation, we restore the result. This restoration should be saved to disk so the redo state is persisted.

### Location 4: Restore All Outputs (Line ~250)

**File**: `/Users/thi/git/SQLNotebook/SQLNotebook/ViewModels/NotebookViewModel+Execution.swift`

```swift
func restoreAllOutputs(
  outputs: [(id: UUID, result: CellResult?, executionCount: Int?)], registerUndo: Bool
) {
  for output in outputs {
    if let index = notebook.cells.firstIndex(where: { $0.id == output.id }) {
      notebook.cells[index].result = output.result
      notebook.cells[index].executionCount = output.executionCount
    }
  }

  // Register redo
  if registerUndo {
    undoManager.registerUndo(withTarget: self) { target in
      MainActor.assumeIsolated {
        target.clearAllOutputs(registerUndo: true)
      }
    }
    onDocumentChanged?()  // ✅ Added - bulk undo operations should trigger save
  }
}
```

**Why**: When undoing a "clear all outputs" operation, we restore all results. This bulk restoration should also trigger document synchronization.

---

## How It Works End-to-End

### The Complete Save Flow with Fix

```
User executes query (Cmd+R or Ctrl+Enter)
    ↓
NotebookViewModel.runCell(id:) → enqueues cell execution
    ↓
ExecutionQueue processes → calls executeTask()
    ↓
executeTask() runs query against database
    ↓
Set result: notebook.cells[index].result = result
    ↓
Call: onDocumentChanged?() ✅ [FIX]
    ↓
NotebookContentView.syncDocument() triggered
    ↓
Capture old notebook state for undo
    ↓
Update document.notebook = viewModel.notebook
    ↓
Register undo action with UndoManager ✅
    ↓
macOS detects document is dirty
    ↓
Autosave triggers (or manual Cmd+S)
    ↓
ReferenceFileDocument.snapshot() called
    ↓
DocumentCoder.encode() with includeResultsOnSave: true
    ↓
Results written to .sqlnb file ✅
    ↓
File persisted with results ✅
```

### The Callback Chain

```
NotebookContentView (View Layer)
    ↓
.onAppear: viewModel.onDocumentChanged = syncDocument
    ↓
NotebookViewModel (ViewModel Layer)
    ↓
executeTask() calls onDocumentChanged?()
    ↓
Triggers syncDocument() closure
    ↓
NotebookContentView.syncDocument() runs (back in View)
    ↓
Marks document dirty via UndoManager
    ↓
macOS ReferenceFileDocument saves changes
```

---

## Testing Verification

### Manual Test Steps

1. **Execute Query and Save**
   - Open a `.sqlnb` file in the app
   - Create a new SQL cell with query like "SELECT 1 as test_column"
   - Execute with Cmd+R or Ctrl+Enter
   - Verify result displays in UI
   - Save with Cmd+S
   - Wait for autosave completion (watch status bar)

2. **Close and Reopen**
   - Close the file (File → Close or Cmd+W)
   - Reopen it in Finder
   - Result should still be present ✅

3. **Modify and Save Again**
   - Change the query to "SELECT 2 as test_column"
   - Execute again
   - Verify new result displays
   - Save with Cmd+S
   - Close and reopen
   - New result should be there ✅

4. **Test Error Results**
   - Disconnect from database (if using PostgreSQL)
   - Execute a query
   - Should show "Not connected to database" error
   - Save the file
   - Reopen - error message should persist
   - Reconnect - error persists until query is executed again

### Debug Output to Monitor

When saving, watch the console for these logs:

```
🔄 [NotebookContentView] syncDocument() - notebook changed (cells: 1)
📝 [NotebookContentView] Registering undo action
```

These indicate the fix is working - document synchronization was triggered.

### File Content Verification

To verify results are actually in the file:

```bash
# Open .sqlnb file and check for result field
cat yourfile.sqlnb | jq '.cells[0].result'

# Should show something like:
# {
#   "columns": ["test_column"],
#   "rows": [[1]],
#   "executionTime": 0.015,
#   "rowCount": 1,
#   "timestamp": "2024-01-19T10:30:45Z",
#   ...
# }
```

### Test Coverage Scenarios

- ✅ Single query execution and save
- ✅ Multiple queries in same notebook
- ✅ Error results (not connected, query errors)
- ✅ Large result sets with many rows
- ✅ JSON/JSONB column results
- ✅ Complex data types (arrays, dates, etc.)
- ✅ Undo/redo operations on results
- ✅ Clear output and restore via undo
- ✅ Autosave vs manual save (Cmd+S)
- ✅ File reopen preserves results

---

## Code Changes Summary

| File | Line | Function | Change | Purpose |
|------|------|----------|--------|---------|
| `NotebookViewModel+Execution.swift` | ~17 | `runCell()` | Add `onDocumentChanged?()` | Save error results |
| `NotebookViewModel+Execution.swift` | ~139 | `executeTask()` | Add `onDocumentChanged?()` | Save query results |
| `NotebookViewModel+Execution.swift` | ~204 | `restoreCellOutput()` | Add `onDocumentChanged?()` | Save undo restoration |
| `NotebookViewModel+Execution.swift` | ~250 | `restoreAllOutputs()` | Add `onDocumentChanged?()` | Save bulk undo restoration |

---

## Related Architecture

### How `onDocumentChanged` Works

The callback is set in `NotebookContentView.onAppear`:

```swift
.onAppear {
  // Setup the callback from ViewModel to View
  // When ViewModel calls onDocumentChanged?(), it triggers syncDocument()
  viewModel.onDocumentChanged = syncDocument

  // ...
}
```

### The syncDocument() Function

Located in `NotebookContentView`:

```swift
private func syncDocument() {
  // Capture old value before changing
  let oldNotebook = document.notebook

  print("🔄 [NotebookContentView] syncDocument() - notebook changed (cells: \(viewModel.notebook.cells.count))")

  // Sync notebook back to document
  document.notebook = viewModel.notebook

  // Register undo action to mark document as dirty
  // This is critical for ReferenceFileDocument to know the document has changed
  if let undoManager = undoManager {
    print("📝 [NotebookContentView] Registering undo action")
    undoManager.registerUndo(withTarget: document) { [oldNotebook] doc in
      doc.notebook = oldNotebook
    }
  } else {
    print("⚠️ [NotebookContentView] No undoManager available!")
  }

  lastSaved = nil  // Mark as unsaved
}
```

### ReferenceFileDocument Integration

The document uses SwiftUI's `ReferenceFileDocument` which:
- Monitors `UndoManager` for changes
- When undo is registered → document marked as dirty
- Dirty state triggers `snapshot()` when saving
- `snapshot()` reads latest `notebook` property
- Results are encoded via `DocumentCoder`

---

## Why This Bug Existed

### Query Execution vs Text Editing

The codebase handles text changes correctly:
- `CellContentEditorView` (text input) → detects changes → calls `onDocumentChanged?()` ✅
- But `NotebookViewModel+Execution.swift` (result assignment) → no callback ❌

This asymmetry meant content was saved but results weren't.

### The Implicit Contract

The `onDocumentChanged` closure represents an implicit contract:
- "ViewModel: When you modify the notebook, call this callback"
- "View: When called, I'll sync changes to the document and register undo"

The fix enforces this contract in the execution code paths that were missing it.

---

## Prevention Guidelines

To prevent similar bugs in the future:

### 1. **Always Call `onDocumentChanged?()` When Modifying Cells**

Pattern to follow:
```swift
// Bad: Modifies notebook but forgets callback
notebook.cells[index].result = result  // ❌ Missing callback

// Good: Modifies notebook and notifies
notebook.cells[index].result = result
onDocumentChanged?()  // ✅ Document aware of change
```

### 2. **Audit All Modification Points**

When reviewing code, search for places that modify `notebook.cells`:
```bash
grep -n "notebook.cells\[.*\] =" SQLNotebook/ViewModels/NotebookViewModel*.swift
```

Each assignment should have `onDocumentChanged?()` call nearby.

### 3. **Test Save/Load Cycle**

Every feature that modifies cells should include:
1. Make change
2. Save file
3. Close file
4. Reopen file
5. Verify change persists

### 4. **Use Debug Logging**

The `syncDocument()` function logs when called:
```
🔄 [NotebookContentView] syncDocument() - notebook changed (cells: X)
📝 [NotebookContentView] Registering undo action
```

Watch for these in console during testing. If missing, the callback wasn't triggered.

### 5. **Understand ReferenceFileDocument Design**

ReferenceFileDocument requires undo manager involvement. This is by design:
- It ensures users can undo document changes
- It avoids marking document dirty for every tiny update
- It respects macOS document lifecycle

Always register undo when making document-level changes.

---

## Related Bug Fixes

### Similar Issue: SQL File Save Bug

See `/Users/thi/git/SQLNotebook/docs/implementation/sql_file_save_bug_fix.md`

That bug had similar symptoms but different root cause:
- **SQL File Bug**: Text binding was stale during typing (not updated immediately)
- **Notebook Bug**: Document callback wasn't called after execution

Both required fixing the "dirty state" tracking mechanism, but at different layers:
- **SQL File**: Fixed binding update layer
- **Notebook**: Fixed callback notification layer

---

## Implementation Checklist

- [x] Add `onDocumentChanged?()` after executeTask() sets result (line ~139)
- [x] Add `onDocumentChanged?()` in runCell() error case (line ~17)
- [x] Add `onDocumentChanged?()` in restoreCellOutput() undo restoration (line ~204)
- [x] Add `onDocumentChanged?()` in restoreAllOutputs() bulk undo (line ~250)
- [x] Verify results display in UI
- [x] Verify results save to .sqlnb file
- [x] Test file reopen shows results
- [x] Test error results are saved
- [x] Test undo/redo operations
- [x] Check debug logs appear in console

---

## Important Notes

### Settings Configuration

The `includeResultsOnSave` setting in AppSettings must be `true` (default) for results to be saved:

```swift
// In AppSettings
var includeResultsOnSave: Bool = true
```

If this is `false`, results won't be included even with `onDocumentChanged()` calls. The setting controls whether results are even encoded into the .sqlnb file.

### Performance Implications

Adding `onDocumentChanged?()` calls has minimal performance impact:
- Callback is just a function call (closure invocation)
- Only triggered on query execution (not on every keystroke)
- Document syncing is already optimized in NotebookContentView
- No additional database operations

### Autosave Behavior

With this fix, autosave now works correctly for results:
- Results are persisted during autosave intervals
- Users don't need manual Cmd+S for results (though they can still use it)
- Autosave respects the document dirty state properly

---

## Conclusion

The notebook result save bug was caused by **missing `onDocumentChanged()` callbacks** in the query execution code path. While other parts of the code (text editing, cell creation) correctly notified the document of changes, the result-setting code did not.

The fix is simple: **Add 4 lines calling `onDocumentChanged?()` in critical locations** where cell results are modified.

This ensures:
- ✅ New query results are persisted correctly
- ✅ Old results still preserved (no regression)
- ✅ Error results are saved
- ✅ Undo/redo operations also trigger save
- ✅ Works with both autosave and manual save
- ✅ Results survive file close and reopen

The fix leverages the existing `onDocumentChanged` callback mechanism that was already working for text changes, extending it to result changes. This maintains consistency across the codebase and ensures all document modifications are properly synchronized.

---

## Files Modified

1. `/Users/thi/git/SQLNotebook/SQLNotebook/ViewModels/NotebookViewModel+Execution.swift`
   - Line ~17: Add `onDocumentChanged?()` in `runCell()` not connected case
   - Line ~139: Add `onDocumentChanged?()` in `executeTask()` after setting result
   - Line ~204: Add `onDocumentChanged?()` in `restoreCellOutput()` undo restoration
   - Line ~250: Add `onDocumentChanged?()` in `restoreAllOutputs()` bulk undo

No other files were modified. The fix is focused and minimal.

---

## Commit Message

```
fix: save query results to .sqlnb files

Query results were not being persisted when executing new queries.
The executeTask() method modified notebook.cells[].result but didn't
call onDocumentChanged(), so the view never synced changes and the
document wasn't marked dirty. Results displayed in UI but weren't saved.

Added onDocumentChanged?() calls at 4 critical locations:
1. After query execution in executeTask()
2. When setting error result in runCell()
3. When undoing clear output in restoreCellOutput()
4. When undoing clear all in restoreAllOutputs()

This ensures the document knows about result changes and persists them
to disk via ReferenceFileDocument's save mechanism.

Fixes: Results lost on file reopen
```
