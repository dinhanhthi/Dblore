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

## Migration Notes (2026-01-10)

**Previous approach:** Single DocumentGroup with dynamic mode switching
- ❌ Save panel extension issue
- ❌ Complex mode switching logic
- ❌ Runtime save panel hacks

**Current approach:** Multiple DocumentGroups
- ✅ Save panel works natively
- ✅ Simple, clean code
- ✅ Each type has dedicated document class

**Files created:**
- `SQLEditorDocument.swift`
- `NotebookContentView.swift`
- `EditorContentView.swift`

**Files deleted:**
- `ContentView.swift` (replaced by 2 specialized views)

**Code removed:**
- ~200 lines of save panel monitoring/customization
- Mode switching logic
- `pendingModeForNewWindow` static variable
