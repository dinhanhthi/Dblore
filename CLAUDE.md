# SQLNotebook - Claude Code Guide

## Project Overview

SQLNotebook is a macOS application for interactive SQL development, similar to Jupyter notebooks but for SQL queries. Built with Swift 6, SwiftUI, and PostgreSQL.

**Stack:** Swift 6.2 • SwiftUI • PostgreSQL • Swift Concurrency • Swift Testing

---

## Communication Rules

**IMPORTANT:** Answer in Vietnamese, keep technical terms in English. Don't automatically open the app (user opens with XCode). Write docs in English only.

Examples:
- ✅ "Tôi sẽ sử dụng `async/await` để execute query này"
- ✅ "Code đã được cập nhật, bạn có thể build bằng XCode"
- ❌ "I will use async/await to execute this query"

---

## Architecture

### Core Patterns

**1. Observable Pattern (Swift 6)**
```swift
@MainActor
@Observable
class NotebookViewModel {
    var notebook: SQLNotebook
    var connectionState: ConnectionState
}
```
- `@Observable` replaces old `ObservableObject` pattern
- `@MainActor` ensures UI updates on main thread
- SwiftUI auto-tracks dependencies

**2. Actor Pattern for Thread Safety**
```swift
actor DatabaseConnectionManager {
    private var connection: PostgresConnection?

    func execute(query: String) async throws -> QueryResult {
        // Thread-safe by design
    }
}
```
- `actor` provides compiler-enforced thread safety
- All methods are implicitly `async`
- Single-access guarantee (like mutex but better)

**3. Extension-based Organization**
- `NotebookViewModel+Connection.swift` — Database connections
- `NotebookViewModel+Execution.swift` — Query execution
- `NotebookViewModel+CellManagement.swift` — Cell CRUD
- Follow file size guidelines (see Code Organization below)

### Project Structure

```
SQLNotebook/
├── Models/              # Data models (Codable, Sendable)
├── ViewModels/          # @Observable view models (split into extensions)
├── Views/               # SwiftUI views
├── Database/            # DatabaseConnectionManager (actor)
└── Utils/               # Helpers, extensions
```

---

## Key Files

- **NotebookCell.swift** — Cell model (query + results)
- **SQLNotebook.swift** — Notebook model (array of cells)
- **NotebookViewModel.swift** — Main view model
- **DatabaseConnectionManager.swift** — Database actor
- **ContentView.swift** — Main UI

---

## Code Organization

### File Size Guidelines

Use a **tiered approach** based on file type and complexity:

| File Type | Max Lines | Strictness | Examples |
|-----------|-----------|------------|----------|
| **Logic files** | 400 | Strict | Models, ViewModels, Managers, Utilities |
| **Simple Views** | 400 | Recommended | Small components, form fields, buttons |
| **Complex Views** | 600 | Acceptable | Table views, editors, multi-section layouts |
| **Test files** | 800 | Acceptable | Integration tests, comprehensive test suites |

**Rationale:**
- Logic code should be focused and single-responsibility (strict 400 lines)
- Simple UI components should be small and reusable (400 lines recommended)
- Complex Views naturally include more declarative code (600 lines acceptable)
- Test files may be longer due to multiple test cases and setup code

### When to Refactor Large Files

**✅ Refactor when:**
- Logic can be split into separate, focused modules
- View can be decomposed into independent, reusable components
- Helper components are used in multiple places
- File exceeds limits AND can be simplified without adding complexity

**❌ Don't refactor when:**
- Splitting creates excessive parameter passing (10+ parameters)
- Helper views/functions are only used once
- Refactoring makes code harder to understand
- View state (`@State`) needs to be shared across many components

**Example - Good refactoring:**
```swift
// Before: ConnectionFormContent.swift (579 lines)
// After: Split into reusable form sections
- ConnectionFormContent.swift (250 lines) - Main layout
- DatabaseFormFields.swift (150 lines) - Reusable form fields
- SSLConfigSection.swift (120 lines) - SSL configuration UI
```

**Example - Bad refactoring:**
```swift
// DON'T: Splitting a complex table view with 15+ @State properties
// Results in helper views needing 10+ @Binding parameters
// Better: Keep in single file or move state to ViewModel
```

### Extension-based Split for Logic

For logic files (ViewModels, Managers), use extensions to organize by feature:

```swift
// NotebookViewModel.swift (base) - 200 lines
@MainActor
@Observable
class NotebookViewModel {
    var cells: [NotebookCell] = []
    var connectionState: ConnectionState = .disconnected
}

// NotebookViewModel+Connection.swift - 150 lines
extension NotebookViewModel {
    func connect(config: ConnectionConfig) async throws { ... }
    func disconnect() async { ... }
}

// NotebookViewModel+Execution.swift - 180 lines
extension NotebookViewModel {
    func executeCell(_ cellId: UUID) async { ... }
    func cancelExecution() { ... }
}
```

---

## Development Guidelines

### Concurrency (Critical)
```swift
// ✅ Correct: async database ops
let result = try await connectionManager.execute(query)

// ✅ Update UI on main actor
await MainActor.run {
    self.showToast("Success", type: .success)
}

// ❌ Wrong: blocking UI thread
let result = try connectionManager.execute(query) // Compiler error
```

### Error Handling
```swift
// ✅ Safe unwrapping
guard let index = cells.firstIndex(where: { $0.id == cellId }) else { return }

// ❌ Never use force unwrap/try
let index = cells.firstIndex(where: { $0.id == cellId })! // NO
```

### Adding New Features

**Example: Add cell metadata**

1. Update model:
```swift
struct NotebookCell: Codable, Sendable {
    let id: UUID
    var content: String
    var metadata: [String: String]? // New property
}
```

2. Update ViewModel extension:
```swift
extension NotebookViewModel {
    func updateMetadata(cellId: UUID, key: String, value: String) {
        guard let index = notebook.cells.firstIndex(where: { $0.id == cellId }) else { return }
        notebook.cells[index].metadata?[key] = value
        syncDocument()
    }
}
```

3. Update View:
```swift
if let metadata = cell.metadata {
    ForEach(metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
        Text("\(key): \(value)")
    }
}
```

---

## Testing

### Unit Tests (Swift Testing Framework)
```swift
import Testing
@testable import SQLNotebook

struct CellTests {
    @Test("Cell creation")
    func testCellCreation() {
        let cell = NotebookCell(content: "SELECT 1")
        #expect(cell.content == "SELECT 1")
        #expect(cell.result == nil)
    }
}
```

**Notes:**
- Use `@Test` macro (not XCTest)
- Use `#expect()` (not `XCTAssertEqual`)

### Integration Tests
```swift
@Test("Database connection")
func testConnection() async throws {
    let manager = DatabaseConnectionManager()
    let config = ConnectionConfig(
        host: "localhost",
        port: 5433,
        database: "test_db",
        username: "test_user",
        password: "test_pass",
        sslMode: .disable,
        databaseType: .postgresql
    )

    try await manager.connect(config: config)
    #expect(manager.isConnected)
}
```

### Run Tests
```bash
# All tests
xcodebuild test -scheme SQLNotebook

# Skip integration tests (no DB required)
SKIP_INTEGRATION_TESTS=true xcodebuild test -scheme SQLNotebook
```

---

## Important Rules

1. **Concurrency:** Always use `async/await` for DB ops, update UI on `@MainActor`
2. **Safety:** No force unwrap (`!`), no force try (`try!`)
3. **Performance:** Use `LazyVStack` for long lists, test with 100+ cells
4. **Design:** Check `DesignSystem.swift` for colors/spacing (8pt grid)
5. **Security:** Validate inputs, use SSL for production (Keychain not yet implemented)
6. **Code Formatting (REQUIRED):** **ALWAYS** run `swift-format -i -r SQLNotebook/` after modifying any Swift code. This is mandatory to maintain consistent code style.
7. **Documentation:**
   - Never read files in `docs/implementation/` unless you are asked for
   - **ALWAYS use the `docer` agent** when asked to write documentation
   - Follow `docer` agent rules strictly:
     - Use `snake_case.md` for file names (e.g., `api_reference.md`, `user_guide.md`)
     - Write comprehensive, clear documentation
     - Include code examples where relevant
     - Maintain consistent formatting and structure

---

## Build Commands

```bash
# Strict build (matches CI)
./scripts/build-strict.sh

# Format code
swift-format -i -r SQLNotebook/
```
