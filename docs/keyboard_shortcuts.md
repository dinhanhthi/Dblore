# Keyboard Shortcuts

This document lists all keyboard shortcuts supported in SQLNotebook.

**Note:** SQLNotebook supports two main modes: Notebook mode (.sqlnb) and Editor mode (.sql). Each mode has a different set of shortcuts.

## Notebook Mode (.sqlnb)

### Cell Execution

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Ctrl+Enter` | Run Cell | Run the current cell, keep focus on the cell |
| `Shift+Enter` | Run Cell and Select Next | Run cell, move to next cell (create new if at end) |
| `Option+Enter` | Run Cell and Insert Below | Run cell, create new cell below |
| `Cmd+Shift+Enter` | Run All Cells | Run all cells in sequence |

### Cell Management

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Cmd+Option+N` | Add New Cell | Create a new SQL cell |
| `Cmd+D` | Duplicate Cell | Duplicate the selected cell |
| `Cmd+Delete` | Delete Cell | Delete the selected cell |

### Cell Navigation

| Shortcut | Action | Description |
|----------|--------|-------------|
| `↑` (Up Arrow) | Select Previous Cell | Select the cell above (when not focused in editor) |
| `↓` (Down Arrow) | Select Next Cell | Select the cell below (when not focused in editor) |
| `Enter` | Focus Editor | Focus into the text editor of the selected cell |
| `Esc` | Unfocus Editor | Exit editor, keep cell selected |

**Note:** When the cursor is at the first or last line of a cell, Arrow keys move between cells.

### Text Editing

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Cmd+/` | Toggle Comment | Comment/uncomment selected lines (add/remove `--`) |
| `Cmd+Z` | Undo | Undo cell changes (text or cell-level operations) |
| `Cmd+Shift+Z` | Redo | Redo undone changes |

**Note about Undo/Redo:**
- When focused in editor: Undo/Redo applies to text changes
- When not focused in editor: Undo/Redo applies to cell-level operations (add, delete, duplicate)

### Search & Find

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Cmd+F` | Find in Notebook | Open search panel to find text in all cells |
| `Cmd+G` | Find Next | Move to next match |
| `Cmd+Shift+G` | Find Previous | Move to previous match |
| `Enter` (in search field) | Find Next | Find next match |
| `Esc` (in search panel) | Close Search | Close search panel |

### View Management

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Cmd+B` | Toggle Left Sidebar | Show/hide left sidebar (Database Schema) |
| `Cmd+,` | Toggle Right Sidebar | Show/hide right sidebar (Cell Info) |

### Global Navigation

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Esc` | Global Escape | Priority: 1) Close search, 2) Unfocus editor, 3) Close right sidebar |

### Text Editor Autocomplete

When autocomplete popup is open:

| Shortcut | Action | Description |
|----------|--------|-------------|
| `↑` (Up Arrow) | Previous Suggestion | Select previous suggestion, wraps around |
| `↓` (Down Arrow) | Next Suggestion | Select next suggestion, wraps around |
| `Enter` / `Tab` | Accept Suggestion | Accept the selected suggestion |
| `Esc` | Hide Autocomplete | Close autocomplete popup |

---

## Editor Mode (.sql)

### Query Execution

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Cmd+R` | Run Query | Run the query in the editor |
| `Cmd+Enter` | Run Query (Alternative) | Run query - alternative shortcut |

### Text Editing

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Cmd+/` | Toggle Comment | Comment/uncomment selected lines |
| `Cmd+Z` | Undo | Undo text changes |
| `Cmd+Shift+Z` | Redo | Redo undone changes |

### Search & Find

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Cmd+F` | Find | Open search panel |
| `Cmd+G` | Find Next | Move to next match |
| `Cmd+Shift+G` | Find Previous | Move to previous match |
| `Esc` (in search panel) | Close Search | Close search panel |

### View Management

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Cmd+B` | Toggle Left Sidebar | Show/hide left sidebar (Database Schema) |
| `Cmd+,` | Toggle Right Sidebar | Show/hide right sidebar |

### Global Navigation

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Esc` | Global Escape | Priority: 1) Close search, 2) Close right sidebar |

### Text Editor Autocomplete

When autocomplete popup is open:

| Shortcut | Action | Description |
|----------|--------|-------------|
| `↑` (Up Arrow) | Previous Suggestion | Select previous suggestion, wraps around |
| `↓` (Down Arrow) | Next Suggestion | Select next suggestion, wraps around |
| `Enter` / `Tab` | Accept Suggestion | Accept the selected suggestion |
| `Esc` | Hide Autocomplete | Close autocomplete popup |

---

## Both Modes

### File Operations

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Cmd+Shift+N` | New Notebook | Create a new notebook (.sqlnb) |
| `Cmd+Shift+J` | New SQL File | Create a new SQL file (.sql) |
| `Cmd+Shift+S` | Save As | Save the current document with a new name |

**Note:** `Cmd+O` (Open) and `Cmd+S` (Save) are native macOS shortcuts supported automatically.

---

## Tips & Best Practices

### Notebook Mode

1. **Jupyter-like Workflow:**
   - Use `Shift+Enter` to run a cell and automatically move to the next cell (like Jupyter Notebook)
   - Use `Option+Enter` to run and insert a new cell immediately below

2. **Quick Navigation:**
   - When not editing, press `Esc` to exit editor mode
   - Use `↑`/`↓` to quickly navigate between cells
   - Press `Enter` to jump into the editor of the selected cell

3. **Efficient Editing:**
   - Use `Cmd+Option+N` to create a new cell
   - Use `Cmd+D` to duplicate cells with similar queries
   - Use `Ctrl+Enter` when you want to re-run a cell multiple times without jumping to the next cell

4. **View Management:**
   - Toggle `Cmd+B` to show/hide left sidebar (Database Schema)
   - Toggle `Cmd+,` to show/hide right sidebar (Cell Info)

### Editor Mode

1. **Quick Execution:**
   - Use `Cmd+R` or `Cmd+Enter` to run a query
   - Use `Cmd+/` to quickly comment/uncomment

2. **Search:**
   - Use `Cmd+F` to open search
   - Use `Cmd+G` / `Cmd+Shift+G` to navigate between matches

---

## Implementation Notes

### Architecture Overview

Shortcuts are implemented across multiple layers:

1. **Command Definition Layer** ([SQLNotebookApp.swift](SQLNotebook/SQLNotebookApp.swift))
   - Defines all commands and keyboard modifiers
   - Separated by mode: Notebook vs Editor

2. **Keyboard Event Handler Layer**
   - [SQLTextView.swift](SQLNotebook/Views/SQLTextView.swift): Text editor shortcuts (Ctrl+Enter, Shift+Enter, Option+Enter, Cmd+/, arrow navigation)
   - [NotebookContentView.swift](SQLNotebook/Views/NotebookContentView.swift): Notebook-level shortcuts (arrow navigation, Esc, Enter)
   - [EditorContentView.swift](SQLNotebook/Views/EditorContentView.swift): Editor-level shortcuts (Cmd+Enter, Esc)

3. **Event Processing**
   - Uses `NSEvent.addLocalMonitorForEvents` for global keyboard monitoring
   - KeyboardEvent handling for local shortcuts
   - NotificationCenter for menu-triggered commands

### Key Implementation Details

**Mode Detection:**
- Uses `@FocusedValue(\.documentMode)` to track focused document mode
- Auto-updates when user switches windows

**Undo/Redo Context Awareness:**
- When focused in editor: Undo/Redo uses TextEditor's undoManager
- When not focused: Undo/Redo applies to cell-level operations

**Search Panel:**
- Custom search implementation for Notebook mode
- Uses NotificationCenter to communicate with SearchPanelView

**Autocomplete Navigation:**
- Arrow keys (↑/↓) navigate between suggestions
- Enter/Tab to accept
- Esc to close popup

### File Organization

```
SQLNotebook/
├── SQLNotebookApp.swift              # Command definitions
├── Views/
│   ├── SQLTextView.swift             # Text editor keyboard handling
│   ├── NotebookContentView.swift     # Notebook keyboard handling
│   ├── EditorContentView.swift       # Editor keyboard handling
│   └── SearchPanelView.swift         # Search panel
└── ...
```
