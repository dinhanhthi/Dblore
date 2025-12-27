# Keyboard Shortcuts

Document này liệt kê tất cả các keyboard shortcuts được hỗ trợ trong SQLNotebook.

## File Operations

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Cmd+N` | New Notebook | Tạo notebook mới |
| `Cmd+O` | Open Notebook | Mở notebook hiện có |
| `Cmd+S` | Save Notebook | Lưu notebook hiện tại |

## Cell Management

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Cmd+B` | Add Code Cell | Thêm SQL cell mới vào cuối notebook |
| `Cmd+Delete` | Delete Cell | Xóa cell đang được chọn |
| `Cmd+D` | Duplicate Cell | Nhân đôi cell đang được chọn |

## Cell Execution

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Ctrl+Enter` | Run Cell | Chạy cell hiện tại và giữ nguyên focus |
| `Shift+Enter` | Run Cell and Select Next | Chạy cell và chuyển sang cell tiếp theo (tạo mới nếu là cell cuối) |
| `Option+Enter` | Run Cell and Insert Below | Chạy cell và chèn cell mới bên dưới |
| `Cmd+Shift+Enter` | Run All Cells | Chạy tất cả các cells trong notebook |

**Note:** Các shortcuts này hoạt động cả khi đang focus vào editor hoặc khi không focus.

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

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Cmd+Shift+L` | Toggle Left Sidebar | Hiện/ẩn left sidebar (file outline) |
| `Cmd+Shift+R` | Toggle Right Sidebar | Hiện/ẩn right sidebar (connection info, schema) |

## Editing

| Shortcut | Action | Description |
|----------|--------|-------------|
| `Cmd+Z` | Undo | Hoàn tác thay đổi (context-aware: editor hoặc cell-level) |
| `Cmd+Shift+Z` | Redo | Làm lại thay đổi đã hoàn tác (context-aware) |

**Note về Undo/Redo:**
- Khi focus vào editor: Undo/Redo áp dụng cho text changes trong editor
- Khi KHÔNG focus vào editor: Undo/Redo áp dụng cho cell-level operations (add, delete, move cells)

## Menu Access

Các shortcuts này cũng có thể được access qua menu bar:

- **Cell Menu:** Chứa tất cả cell-related operations (Run, Clear, Delete, Duplicate)
- **View Menu:** Chứa sidebar toggles
- **File Menu:** Chứa file operations (New, Open, Save)
- **Edit Menu:** Chứa Undo/Redo

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

### Keyboard Shortcuts Architecture

Shortcuts được implement ở nhiều levels:

1. **Menu Commands** ([SQLNotebookApp.swift:40-123](SQLNotebookApp.swift#L40-L123))
   - Defined trong `NotebookCommands` struct
   - Trigger notifications qua `NotificationCenter`

2. **Text View Level** ([SQLTextView.swift:38-134](SQLTextView.swift#L38-L134))
   - `SQLTextView` intercepts keyboard events trong `keyDown(with:)` và `performKeyEquivalent(with:)`
   - Handles execution shortcuts (`Ctrl+Enter`, `Shift+Enter`, etc.)
   - Handles smart arrow navigation

3. **Window Level** ([ContentView.swift:91-155](ContentView.swift#L91-L155))
   - `NSEvent.addLocalMonitorForEvents` trong `ContentView`
   - Handles arrow navigation khi KHÔNG focus vào editor
   - Handles `Enter` để focus editor và `Esc` để unfocus

4. **Notification Handlers** ([ContentView.swift:327-404](ContentView.swift#L327-L404))
   - `NotificationHandlerModifier` listens to notifications
   - Triggers actual ViewModel actions

### Context-Aware Undo/Redo

Implementation ở [ContentView.swift:408-452](ContentView.swift#L408-L452) cho phép:
- Editor-level undo khi focus vào text view
- Cell-level undo khi không focus (add/delete/move cells)
