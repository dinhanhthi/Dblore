# Keyboard Shortcuts

Document này liệt kê tất cả các keyboard shortcuts được hỗ trợ trong SQLNotebook.

**Note:** Nhiều shortcuts chỉ khả dụng ở Notebook mode (.sqlnb). Editor mode (.sql) sử dụng native macOS shortcuts.

## File Operations

| Shortcut | Action | Available In | Description |
|----------|--------|------------|-------------|
| `Cmd+N` | New Notebook | Both | Tạo notebook mới (.sqlnb) |
| `Cmd+Shift+N` | New Notebook | Both | Explicit command để tạo notebook |
| `Cmd+Shift+E` | New SQL File | Both | Tạo SQL file mới (.sql) |
| `Cmd+O` | Open | Both | Mở file hiện có (.sqlnb hoặc .sql) |
| `Cmd+S` | Save | Both | Lưu file hiện tại |

## Cell Management

| Shortcut | Action | Available In | Description |
|----------|--------|------------|-------------|
| `Cmd+N` | Add Code Cell | Notebook only | Thêm SQL cell mới |
| `Cmd+Delete` | Delete Cell | Notebook only | Xóa cell đang được chọn |
| `Cmd+D` | Duplicate Cell | Notebook only | Nhân đôi cell đang được chọn |

## Cell Execution

| Shortcut | Action | Available In | Description |
|----------|--------|------------|-------------|
| `Ctrl+Enter` | Run Cell | Notebook only | Chạy cell hiện tại và giữ nguyên focus |
| `Shift+Enter` | Run Cell and Select Next | Notebook only | Chạy cell và chuyển sang cell tiếp theo (tạo mới nếu là cell cuối) |
| `Option+Enter` | Run Cell and Insert Below | Notebook only | Chạy cell và chèn cell mới bên dưới |
| `Cmd+Shift+Enter` | Run All Cells | Notebook only | Chạy tất cả các cells trong notebook |

**Note:** Các shortcuts này chỉ khả dụng ở Notebook mode (.sqlnb files). Editor mode (.sql) không có Cell menu.

## Cell Output Management

| Action | Description |
|--------|-------------|
| Clear Cell Output | Xóa output của cell đang được chọn (không có shortcut) |
| Clear All Outputs | Xóa output của tất cả các cells (không có shortcut) |

## Cell Navigation

### Khi KHÔNG focus vào editor:

| Shortcut | Action | Description |
|----------|--------|-------------|
| `↑` (Up Arrow) | Select Previous Cell | Chọn cell phía trên |
| `↓` (Down Arrow) | Select Next Cell | Chọn cell phía dưới |
| `Enter` | Focus Editor | Focus vào editor của cell đang chọn |

### Khi ĐANG focus vào editor:

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Esc` | Unfocus Editor | Thoát khỏi editor nhưng vẫn giữ cell được chọn |
| `↑` (Up Arrow) | Navigate to Previous Cell | Chuyển sang cell trước (chỉ khi cursor ở dòng đầu tiên) |
| `↓` (Down Arrow) | Navigate to Next Cell | Chuyển sang cell sau (chỉ khi cursor ở dòng cuối cùng) |

**Note:** Arrow navigation trong editor chỉ hoạt động khi cursor ở dòng đầu/cuối để tránh conflict với việc di chuyển cursor trong multi-line code.

## View Management

| Shortcut | Action | Available In | Description |
|----------|--------|------------|-------------|
| `Cmd+B` | Toggle Left Sidebar | Notebook only | Hiện/ẩn left sidebar (cell outline) |
| `Cmd+,` | Toggle Right Sidebar | Both | Hiện/ẩn right sidebar (connection info, schema, settings) |

## Editing

| Shortcut | Action | Available In | Description |
|----------|--------|------------|-------------|
| `Cmd+Z` | Undo | Both | Hoàn tác thay đổi (context-aware: editor hoặc cell-level) |
| `Cmd+Shift+Z` | Redo | Both | Làm lại thay đổi đã hoàn tác (context-aware) |

**Note về Undo/Redo:**
- Khi focus vào editor: Undo/Redo áp dụng cho text changes trong editor
- Khi KHÔNG focus vào editor: Undo/Redo áp dụng cho cell-level operations (add, delete, move cells)

## Search & Find

| Shortcut | Action | Available In | Description |
|----------|--------|------------|-------------|
| `Cmd+F` | Find in Notebook | Notebook only | Mở search panel để tìm text trong notebook |
| `Cmd+G` | Find Next | Notebook only | Tìm match tiếp theo |
| `Cmd+Shift+G` | Find Previous | Notebook only | Tìm match trước đó |
| `Esc` | Close Search | Notebook only | Đóng search panel |

**Note:** Editor mode sử dụng native macOS Find (Cmd+F) từ TextEditor.

## Menu Access

### Notebook Mode (.sqlnb)
Các shortcuts này cũng có thể được access qua menu bar:

- **Cell Menu:** Add New, Run Cell, Run Cell and Select Next, Run Cell and Insert Below, Run All Cells, Clear Cell Output, Clear All Outputs, Delete Cell, Duplicate Cell
- **View Menu:** Toggle Left Sidebar, Toggle Right Sidebar
- **Edit Menu:** Find in Notebook, Find Next, Find Previous, Undo, Redo
- **File Menu:** New Notebook, New SQL File, Open, Save
- **App Menu:** About, Settings

### Editor Mode (.sql)
- **View Menu:** Toggle Right Sidebar (basic macOS sidebars)
- **Edit Menu:** Native macOS Undo, Redo, Find
- **File Menu:** New Notebook, New SQL File, Open, Save
- **App Menu:** About, Settings

**Key Difference:** Notebook mode có Cell menu và custom Find/sidebar commands, Editor mode sử dụng native macOS menus.

## Tips & Best Practices

1. **Jupyter-like Workflow:**
   - Dùng `Shift+Enter` để chạy cell và tự động chuyển sang cell tiếp theo (giống Jupyter Notebook)
   - Dùng `Option+Enter` để chạy và insert cell mới ngay lập tức

2. **Quick Navigation:**
   - Khi không cần edit, press `Esc` để thoát editor mode và dùng `↑`/`↓` để navigate nhanh
   - Press `Enter` để jump vào editor của cell đang chọn

3. **Efficient Editing:**
   - Dùng `Cmd+B` để quickly add cells
   - Dùng `Cmd+D` để duplicate cells có queries tương tự
   - Dùng `Ctrl+Enter` khi muốn re-run cell nhiều lần mà không jump sang cell khác

4. **Multi-tasking:**
   - Toggle sidebars với `Cmd+Shift+L/R` để có thêm screen space khi cần
   - Left sidebar hiển thị cell outline để navigate large notebooks
   - Right sidebar hiển thị connection info và database schema

## Implementation Notes

### Menu Architecture

Shortcuts được define trong menu commands ở [SQLNotebookApp.swift](/Users/thi/git/SQLNotebook/SQLNotebook/SQLNotebookApp.swift):

1. **FocusedValues System** (Lines 55-92)
   - `DocumentMode` enum tracks Notebook vs Editor mode
   - `@FocusedValue(\.documentMode)` tracks focused scene
   - Auto-updates khi user switches windows

2. **SharedCommands** (Lines 94-124)
   - About, Settings (chung cho cả 2 modes)
   - Defined ở Notebook scene

3. **NotebookCommands** (Lines 126-220)
   - Conditional: `if documentMode == .notebook { ... }`
   - Cell menu, sidebar toggles, search commands
   - Chỉ show khi Notebook window focused

4. **EditorCommands** (Lines 222-240)
   - Empty (editor sử dụng native macOS menus)
   - Placeholder cho future editor-specific commands

5. **NewDocumentCommands** (Lines 242-288)
   - New Notebook, New SQL File
   - Defined ở Notebook scene để tránh duplicate

### Keyboard Event Handling

Shortcuts cũng được handle ở many levels:

1. **Menu System** (SQLNotebookApp.swift)
   - Commands trigger notifications qua `NotificationCenter`

2. **Text View Level** (Editor UI)
   - SQLTextView intercepts keyboard events
   - Handles execution shortcuts (`Ctrl+Enter`, etc.)
   - Handles smart arrow navigation

3. **Window Level** (Content Views)
   - `NSEvent.addLocalMonitorForEvents` monitors keyboard events
   - Handles arrow navigation, Enter/Esc keys
   - Code ở NotebookContentView.swift (lines 216-319) và EditorContentView.swift (lines 170-203)

4. **Notification Handlers**
   - Modifiers listen to notifications từ menu commands
   - Triggers actual ViewModel actions
   - Code ở NotebookContentView.swift (lines 384-536)

### Context-Aware Undo/Redo

Undo/Redo logic ở NotebookContentView.swift (lines 515-535):
- Khi focus vào editor: Dùng TextEditor's undoManager
- Khi KHÔNG focus: Dùng cell-level undoManager cho operations
