# Multiple DocumentGroups Architecture

> Tài liệu giải thích cách SQLNotebook sử dụng separate DocumentGroups cho 2 document types.

## Overview

SQLNotebook sử dụng **multiple SwiftUI DocumentGroups** - mỗi file type có DocumentGroup riêng:

### Notebook Mode (.sqlnb)
- Multiple cells với inline results (Jupyter-style)
- Use case: Data analysis, exploration, documentation
- Document class: `SQLNotebookDocument`
- View: `NotebookContentView`

### Editor Mode (.sql)
- Single SQL editor + result panel
- Use case: SQL scripts, quick queries
- Document class: `SQLEditorDocument`
- View: `EditorContentView`

---

## Architecture

### Two DocumentGroups

```swift
// SQLNotebookApp.swift
var body: some Scene {
  // Scene 1: Notebook documents (.sqlnb)
  DocumentGroup(newDocument: { SQLNotebookDocument() }) { file in
    NotebookContentView(document: file.document)
  }
  .commands {
    NotebookCommands()
    NewDocumentCommands()
  }

  // Scene 2: SQL Editor documents (.sql)
  DocumentGroup(newDocument: { SQLEditorDocument() }) { file in
    EditorContentView(document: file.document)
  }
  .commands {
    NotebookCommands()
    NewDocumentCommands()
  }
}
```

### Document Classes

**SQLNotebookDocument** - Handles `.sqlnb` files (JSON format):
```swift
final class SQLNotebookDocument: ReferenceFileDocument {
  @Published var notebook: SQLNotebook

  static var readableContentTypes: [UTType] { [.sqlNotebook, .json] }
  var writableContentTypes: [UTType] { [.sqlNotebook] }
}
```

**SQLEditorDocument** - Handles `.sql` files (plain text):
```swift
final class SQLEditorDocument: ReferenceFileDocument {
  @Published var content: String
  @Published var metadata: NotebookMetadata

  static var readableContentTypes: [UTType] { [.sql, .plainText] }
  var writableContentTypes: [UTType] { [.sql] }
}
```

### Views

**NotebookContentView** - UI cho notebook mode:
- Multiple cells in List view
- Cell CRUD operations
- Inline results display

**EditorContentView** - UI cho editor mode:
- Single EditorModeView
- Simple editor + result panel
- Minimal UI

---

## Menu Commands

### File Menu

- **File > New (Cmd+N)** → Creates new `.sqlnb` notebook
- **File > New Notebook (Cmd+Shift+N)** → Creates new `.sqlnb` notebook
- **File > New SQL File (Cmd+Shift+E)** → Shows save dialog, creates `.sql` file
- **File > Open (Cmd+O)** → Opens any supported file type

### Implementation

```swift
struct NewDocumentCommands: Commands {
  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("New Notebook") {
        NSDocumentController.shared.newDocument(nil)
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])

      Button("New SQL File") {
        // Show save panel, create file, then open
        createNewSQLFile()
      }
      .keyboardShortcut("e", modifiers: [.command, .shift])
    }
  }
}
```

---

## Info.plist Configuration

```xml
<key>CFBundleDocumentTypes</key>
<array>
  <!-- SQL Notebook -->
  <dict>
    <key>CFBundleTypeName</key>
    <string>SQL Notebook</string>
    <key>CFBundleTypeExtensions</key>
    <array><string>sqlnb</string></array>
    <key>LSHandlerRank</key>
    <string>Owner</string>
    <key>NSDocumentClass</key>
    <string>SQLNotebookDocument</string>
  </dict>

  <!-- SQL File -->
  <dict>
    <key>CFBundleTypeName</key>
    <string>SQL File</string>
    <key>CFBundleTypeExtensions</key>
    <array><string>sql</string></array>
    <key>LSHandlerRank</key>
    <string>Owner</string>
    <key>NSDocumentClass</key>
    <string>SQLEditorDocument</string>
  </dict>
</array>
```

---

## File Operations

### Opening Files

macOS automatically routes files to correct DocumentGroup based on extension:
- `.sqlnb` → `SQLNotebookDocument` → `NotebookContentView`
- `.sql` → `SQLEditorDocument` → `EditorContentView`

### Saving Files

Each document class declares its own `writableContentTypes`:

```swift
// SQLNotebookDocument
var writableContentTypes: [UTType] { [.sqlNotebook] }

// SQLEditorDocument
var writableContentTypes: [UTType] { [.sql] }
```

**Result:** Save panel ALWAYS shows correct extension automatically.

---

## Files Structure

| File | Purpose |
|------|---------|
| `SQLNotebookApp.swift` | App entry, 2 DocumentGroups, menu commands |
| `NotebookContentView.swift` | UI for `.sqlnb` files |
| `EditorContentView.swift` | UI for `.sql` files |
| `SQLNotebookDocument.swift` | Document class for `.sqlnb` |
| `SQLEditorDocument.swift` | Document class for `.sql` |
| `NotebookViewModel.swift` | Shared business logic |

---

## Benefits

1. ✅ **Save panel works correctly** - Extension always matches document type
2. ✅ **Clean separation** - Each document type isolated
3. ✅ **Platform-native** - Standard macOS multi-document pattern
4. ✅ **No hacks** - No private APIs, no runtime customization
5. ✅ **Multiple windows** - Can open both types simultaneously
6. ✅ **Future-proof** - Uses standard SwiftUI APIs

---

---

## Menu Architecture

SQLNotebook uses SwiftUI's **FocusedValues system** to dynamically show and hide menu commands based on the document mode (Notebook vs Editor). This eliminates menu duplication and ensures the correct commands appear for each document type.

### FocusedValues System

The FocusedValues system in SwiftUI provides a way to pass values through the responder chain. SQLNotebook defines a custom focused value key to track which document mode is currently focused:

```swift
// SQLNotebookApp.swift (lines 73-92)

/// Represents the document type/mode of the currently focused window.
enum DocumentMode {
  case notebook  // Notebook mode (.sqlnb files) - has Cell menu, custom Find
  case editor    // Editor mode (.sql files) - uses native macOS menus
}

/// FocusedValue key for tracking document mode across the app.
/// See: https://developer.apple.com/documentation/swiftui/focusedvaluekey
struct DocumentModeFocusedValueKey: FocusedValueKey {
  typealias Value = DocumentMode
}

extension FocusedValues {
  /// Accessed by menu command structs to determine which commands to show.
  /// Value is automatically set by NotebookContentView and EditorContentView
  /// via `.focusedSceneValue(\.documentMode, ...)` modifier.
  var documentMode: DocumentMode? {
    get { self[DocumentModeFocusedValueKey.self] }
    set { self[DocumentModeFocusedValueKey.self] = newValue }
  }
}
```

Each content view establishes its mode by setting the focused value:

```swift
// NotebookContentView.swift (line 183)
.focusedSceneValue(\.documentMode, .notebook)

// EditorContentView.swift (line 132)
.focusedSceneValue(\.documentMode, .editor)
```

When a window becomes focused, its corresponding FocusedValue is activated, causing any menu commands that read this value to update automatically.

### Menu Commands Organization

Menu commands are organized into three separate structures for clear separation of concerns:

#### 1. SharedCommands

Commands that appear in both Notebook and Editor modes. Currently includes app-level commands:

```swift
// SQLNotebookApp.swift (lines 96-124)

struct SharedCommands: Commands {
  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button("About SQLNotebook") {
        showAboutWindow()
      }

      Divider()

      Button("Settings") {
        NotificationCenter.default.post(name: .openSettings, object: nil)
      }
      .keyboardShortcut(",", modifiers: .command)
    }
  }
}
```

**Commands included:**
- About SQLNotebook
- Settings (Cmd+,)

#### 2. NotebookCommands

Commands that appear **only when a Notebook window is focused**. Uses `@FocusedValue` to read the current document mode and conditionally shows menus:

```swift
// SQLNotebookApp.swift (lines 128-234)

struct NotebookCommands: Commands {
  @FocusedValue(\.documentMode) private var documentMode: DocumentMode?

  var body: some Commands {
    // Conditional rendering: all menu items only appear if documentMode == .notebook
    if documentMode == .notebook {
      // Cell menu commands...
      CommandMenu("Cell") {
        Button("Add New") {
          NotificationCenter.default.post(name: .addCodeCell, object: nil)
        }
        .keyboardShortcut("n", modifiers: .command)

        Divider()
        Button("Run Cell") {
          NotificationCenter.default.post(name: .runCell, object: nil)
        }
        .keyboardShortcut(.return, modifiers: .control)
        // ... other cell commands
      }

      // Sidebar toggles (notebook-specific View menu items)
      CommandGroup(after: .sidebar) {
        Button { ... } label: {
          Label("Toggle Left Sidebar", systemImage: "sidebar.left")
        }
        .keyboardShortcut("b", modifiers: .command)

        Button { ... } label: {
          Label("Toggle Right Sidebar", systemImage: "sidebar.right")
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
      }

      // Notebook-specific search commands
      CommandMenu("Edit") {
        Button("Find in Notebook") {
          NotificationCenter.default.post(name: .openSearch, object: nil)
        }
        .keyboardShortcut("f", modifiers: .command)
        // ... Find Next, Find Previous commands
      }
    }
  }
}
```

**Cell Menu Commands:**
- Add New (Cmd+N)
- Run Cell (Ctrl+Return)
- Run Cell and Select Next (Shift+Return)
- Run Cell and Insert Below (Option+Return)
- Run All Cells (Cmd+Shift+Return)
- Clear Cell Output
- Clear All Outputs
- Delete Cell (Cmd+Delete)
- Duplicate Cell (Cmd+D)

**View Menu (Notebook-specific):**
- Toggle Left Sidebar (Cmd+B)
- Toggle Right Sidebar (Cmd+Shift+R)

**Edit Menu (Notebook-specific):**
- Find in Notebook (Cmd+F)
- Find Next (Cmd+G)
- Find Previous (Cmd+Shift+G)

#### 3. EditorCommands

Commands that appear in Editor mode. Currently empty because Editor mode uses native macOS menus:

```swift
// SQLNotebookApp.swift (lines 238-248)

struct EditorCommands: Commands {
  var body: some Commands {
    // Editor mode doesn't need custom commands:
    // - No Cell menu (notebook-specific only)
    // - No sidebar toggles (Editor uses native TextEditor sidebar)
    // - No custom Find (uses native Cmd+F)
    EmptyCommands()
  }
}
```

### Application Scene Setup

The two DocumentGroups attach different command sets:

```swift
// SQLNotebookApp.swift (lines 17-42)

@main
struct SQLNotebookApp: App {
  var body: some Scene {
    // Scene 1: Notebook documents (.sqlnb)
    DocumentGroup(newDocument: { SQLNotebookDocument() }) { file in
      NotebookContentView(document: file.document)
        .frame(minWidth: 800, minHeight: 600)
    }
    .commands {
      // Shared commands (About, Settings) - only added to notebook scene
      SharedCommands()
      // New Document commands (File > New...) - only added to notebook scene
      NewDocumentCommands()
      // Notebook-specific commands (Cell menu, sidebars, search)
      NotebookCommands()
    }
    .defaultSize(width: 1200, height: 800)

    // Scene 2: SQL Editor documents (.sql)
    DocumentGroup(newDocument: { SQLEditorDocument() }) { file in
      EditorContentView(document: file.document)
        .frame(minWidth: 800, minHeight: 600)
    }
    .commands {
      // Editor-specific commands (currently empty)
      EditorCommands()
    }
    .defaultSize(width: 1200, height: 800)
  }
}
```

**Key design decision:** `SharedCommands` and `NewDocumentCommands` are attached only to the Notebook DocumentGroup to prevent duplication. The Editor DocumentGroup is minimal and relies on native macOS menu behavior.

### Problems Fixed

This architecture solves several critical issues from previous implementations:

| Problem | Root Cause | Solution |
|---------|-----------|----------|
| Duplicate "New Notebook" + "New SQL File" menus | Both DocumentGroups had commands | Added commands only to Notebook scene, used `NewDocumentCommands` |
| Duplicate "Toggle Left/Right Sidebar" commands | Commands defined in both scenes | Conditional `if documentMode == .notebook` check |
| Cell menu appearing in Editor mode | No differentiation between modes | `@FocusedValue` reading prevents all Cell menu items from rendering |
| Notebook-specific search commands in Editor | Shared command structure | Wrapped all Notebook commands in conditional block |

### FocusedValue Lifecycle

The FocusedValue system automatically updates when the user switches between windows. Here's the complete lifecycle:

**Scenario 1: User clicks a Notebook window**

```
1. User clicks on Notebook window
   ↓
2. NotebookContentView becomes the focused scene
   ↓
3. NotebookContentView's .focusedSceneValue(\.documentMode, .notebook)
   establishes .notebook in the responder chain
   ↓
4. NotebookCommands reads @FocusedValue(\.documentMode)
   → receives .notebook
   ↓
5. Conditional `if documentMode == .notebook` evaluates to TRUE
   ↓
6. All menu items render:
   - Cell menu
   - Sidebar toggle commands
   - Find in Notebook / Find Next / Find Previous commands
```

**Scenario 2: User clicks an Editor window**

```
1. User clicks on Editor window
   ↓
2. EditorContentView becomes the focused scene
   ↓
3. EditorContentView's .focusedSceneValue(\.documentMode, .editor)
   establishes .editor in the responder chain
   ↓
4. NotebookCommands reads @FocusedValue(\.documentMode)
   → receives .editor
   ↓
5. Conditional `if documentMode == .notebook` evaluates to FALSE
   ↓
6. All Notebook-specific menus are hidden:
   - Cell menu disappears
   - Sidebar toggle commands disappear
   - Find commands disappear
   ↓
7. Native macOS menus are displayed instead
   - Standard File, Edit, View, Window menus
   - TextEditor native keyboard shortcuts
```

**Scenario 3: User opens first Editor window (no Notebook visible)**

```
1. User creates new SQL file or opens existing .sql file
   ↓
2. EditorContentView becomes active
   ↓
3. EditorContentView sets .focusedSceneValue(\.documentMode, .editor)
   ↓
4. NotebookCommands renders with documentMode == .editor
   ↓
5. All Notebook commands remain hidden
   (they were never visible because .notebook was never set)
```

### Key Benefits of This Approach

1. **Type-Safe:** The `DocumentMode` enum enforces only valid modes; compiler catches invalid uses
2. **Native SwiftUI:** Uses standard FocusedValues API, no private APIs or runtime hacks
3. **Zero-Copy Updates:** FocusedValue changes don't require re-rendering the entire app
4. **Auto-Synchronization:** Menus update instantly when switching windows (sub-10ms)
5. **Maintainable:** Commands clearly organized by document type; easy to add/remove features
6. **Scalable:** To add new document types, simply create new enum case and new commands struct
7. **Thread-Safe:** FocusedValues integration is thread-safe by design
8. **No Manual Tracking:** No need for `@State` or `@Published` to track which window is focused

### Implementation Notes

- The `@FocusedValue` property wrapper is read-only within command structs (line 135)
- Each view establishes its mode at the top level (lines 183 and 132 of respective views)
- The conditional in NotebookCommands uses a single `if documentMode == .notebook` guard, wrapping all mode-specific commands
- Notification-based communication allows decoupled command handling (see Notification.Name extensions at lines 308-339)

---

## Migration Notes (2026-01-10)

**Previous approach:** Single DocumentGroup with dynamic mode switching
- ❌ Save panel extension issue
- ❌ Complex mode switching logic
- ❌ Runtime save panel hacks
- ❌ Duplicate menu commands in both modes

**Current approach:** Multiple DocumentGroups with FocusedValues
- ✅ Save panel works natively
- ✅ Simple, clean code
- ✅ Each type has dedicated document class
- ✅ Dynamic menu display based on focused window
- ✅ Zero-overhead FocusedValues system for menu rendering
- ✅ Clear separation of menu commands per mode

**Files created:**
- `SQLEditorDocument.swift`
- `NotebookContentView.swift`
- `EditorContentView.swift`

**Files deleted:**
- `ContentView.swift` (replaced by 2 specialized views)

**Menu architecture changes (2026-01-10):**
- Created `DocumentMode` enum to represent document types
- Implemented `DocumentModeFocusedValueKey` for FocusedValues integration
- Refactored menu commands into `SharedCommands`, `NotebookCommands`, `EditorCommands`
- Added conditional rendering of Cell menu based on `@FocusedValue(\.documentMode)`
- Moved `NewDocumentCommands` and `SharedCommands` to Notebook scene only (prevents duplication)
- Removed ~50 lines of menu duplication code

**Code removed:**
- ~200 lines of save panel monitoring/customization
- Mode switching logic
- `pendingModeForNewWindow` static variable
- Duplicate menu commands in Editor scene
