# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**IMPORTANT**: Answer me in Vietnamese, keep terminologies in English. Don't automatically open the app, I do it myself with XCode.

---

## 📋 Project Overview

**SQLNotebook** là một native macOS application được xây dựng bằng Swift và SwiftUI, hoạt động như một interactive SQL notebook (tương tự Jupyter Notebook nhưng chuyên cho SQL queries). App cho phép users viết, thực thi và lưu trữ SQL queries trong cell-based interface với persistent results.

### Key Features
- Cell-based interface với SQL cells
- Execute SQL queries với syntax highlighting
- Save notebooks dưới dạng `.sqlnb` files (JSON format)
- Display query results trong table format
- Integrated JSON viewer cho JSON/JSONB data
- Database connectivity: PostgreSQL (via PostgresNIO) và SQLite (native)

---

## 🏗️ Architecture & Structure

### Tech Stack
- **Language:** Swift 6+
- **UI Framework:** SwiftUI (latest)
- **Target:** macOS 16.0+
- **Architecture:** MVVM với Observable macro
- **Database Connectivity:** PostgresNIO (PostgreSQL), native Swift APIs (SQLite)
- **Persistence:** Codable documents saved as `.sqlnb` JSON files

### Project Structure

```
SQLNotebook/
├── Database/
│   └── DatabaseConnectionManager.swift    # Actor quản lý database connections
├── Models/
│   ├── ConnectionConfig.swift            # Database connection configuration
│   ├── NotebookCell.swift                # Cell model (SQL only)
│   ├── SQLNotebook.swift                 # Main notebook model
│   └── SQLNotebookDocument.swift         # FileDocument implementation
├── ViewModels/
│   └── NotebookViewModel.swift           # @Observable ViewModel
├── Views/
│   ├── Components/
│   │   ├── CellView.swift                # Individual cell rendering
│   │   └── ResultTableView.swift         # Query result table
│   ├── ConnectionSheet.swift             # Database connection UI
│   ├── FooterView.swift                  # Footer bar
│   ├── HeaderView.swift                  # Header toolbar
│   └── RightSidebarView.swift            # Collapsible sidebar
├── Utilities/
│   ├── DesignSystem.swift                # Shadcn-inspired design tokens
│   └── SQLSyntaxHighlighter.swift        # SQL syntax highlighting
└── ContentView.swift                      # Main view container
```

---

## 💾 Data Models

### Core Models
- **SQLNotebook**: Main document model với cells, metadata, connection config
- **NotebookCell**: Individual SQL cell với content và results
- **CellResult**: Execution results với columns, rows, timing info
- **ConnectionConfig**: Database connection parameters
- **CellValue**: Enum cho các data types (string, int, double, bool, null, json, date, data)

### State Management
- **NotebookViewModel**: @Observable class quản lý notebook state
- **ConnectionState**: Enum tracking connection status
- **SidebarContent**: Enum cho right sidebar content modes

---

## 🎨 UI Layout & Design System

### Layout Structure
```
┌─────────────────────────────────────────────────┐
│ HEADER BAR (44pt)                               │
├──────────────────────────────┬──────────────────┤
│                              │                  │
│  MAIN CONTENT (scrollable)   │ RIGHT SIDEBAR    │
│  - LazyVStack of Cells       │ (collapsible)    │
│                              │ 320pt width      │
├──────────────────────────────┴──────────────────┤
│ FOOTER BAR (24pt)                               │
└─────────────────────────────────────────────────┘
```

### Design System (Shadcn-inspired)
- **Colors**: Semantic colors adapting to light/dark mode
- **Typography**: SF Mono/Menlo cho code, system fonts cho UI
- **Components**: Buttons, Cards, Inputs, Tables với consistent styling
- **Spacing**: 8pt grid system
- **Border Radius**: 6-8pt cho cards và inputs

### SQL Syntax Highlighting
Token categories:
- Keywords (SELECT, FROM, WHERE) - Blue
- Functions (COUNT, SUM) - Purple  
- Strings ('text') - Green
- Numbers (123, 45.67) - Orange
- Comments (-- comment) - Gray

---

## 🔧 Development Guidelines

### Code Conventions
1. **Swift 6 Concurrency**: Sử dụng async/await, actors cho database operations
2. **Observable Macro**: Dùng @Observable thay vì ObservableObject
3. **Type Safety**: Leverage Swift's strong type system, avoid force unwrapping
4. **Error Handling**: Proper error propagation với try/catch và Result types
5. **SwiftUI Best Practices**: 
   - Prefer composition over inheritance
   - Keep views small và focused
   - Extract reusable components

### Key Implementation Notes
1. **Performance**: 
   - Dùng LazyVStack cho cell list
   - Virtual scrolling cho large result sets
   - Debounce user inputs
2. **Memory Management**:
   - Pagination cho large queries
   - Clean up connections properly
3. **Security**:
   - Store passwords trong Keychain (NOT in `.sqlnb` files)
   - Validate user inputs
4. **Persistence**:
   - Document-based app architecture
   - Auto-save với undo/redo support
5. **Database**:
   - Actor-based connection manager
   - Connection pooling nếu cần
   - Proper query cancellation

---

## 🔌 Database Connectivity

### DatabaseConnectionManager (Actor)
- Manages PostgreSQL connections via PostgresNIO
- Thread-safe operations với actor isolation
- Methods: connect, disconnect, execute, testConnection

### Supported Operations
- SELECT queries → return result sets
- INSERT/UPDATE/DELETE → return affected row counts
- DDL statements → success/failure status
- Multiple statements → execute sequentially

### Error Handling
Display SQL errors inline below cells với:
- Error message from database
- Query position if available
- User-friendly suggestions

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+N` | New notebook |
| `Cmd+O` | Open notebook |
| `Cmd+S` | Save notebook |
| `Cmd+Enter` | Run selected cell |
| `Shift+Enter` | Run cell and move to next |
| `Cmd+Shift+Enter` | Run all cells |
| `Cmd+B` | Add code cell below |
| `Cmd+Backspace` | Delete selected cell |
| `Cmd+D` | Duplicate cell |
| `Cmd+Shift+R` | Toggle right sidebar |

---

## 📦 Dependencies

### Swift Package Manager
- **PostgresNIO**: PostgreSQL async client library
- Các dependencies khác được fetch tự động

---

## 📄 File Format

`.sqlnb` files are JSON with structure:
```json
{
  "version": "1.0",
  "id": "uuid",
  "metadata": {...},
  "connectionConfig": {...},
  "cells": [...]
}
```

**Note**: Passwords KHÔNG được lưu trong file, chỉ lưu trong Keychain.

---

## 🧪 Testing Strategy

- Unit tests cho data models và serialization
- Unit tests cho SQL syntax tokenizer
- Integration tests cho database operations
- UI tests cho critical user flows

---

## 📚 Additional Documentation

- Detailed specifications: `docs/project.md`
- Task breakdown: `docs/TODO.md`
- PostgreSQL setup: `docs/POSTGRESQL_SETUP.md`

---

## 🎯 When Working on This Codebase

1. **Always check**: Existing design system trong `DesignSystem.swift` trước khi tạo new styles
2. **Follow MVVM**: ViewModels handle business logic, Views chỉ render UI
3. **Async operations**: Database calls phải async, update UI trên main actor
4. **Type safety**: Leverage CellValue enum cho different data types
5. **Error handling**: Show user-friendly errors, log detailed info cho debugging
6. **Performance**: Test với large notebooks (100+ cells) và large result sets (1000+ rows)
7. **Accessibility**: Ensure proper labels và keyboard navigation
8. **Documentation**: Update docs khi thay đổi architecture hoặc add major features