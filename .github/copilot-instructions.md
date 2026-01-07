# SQLNotebook - GitHub Copilot Instructions

## Project Overview

SQLNotebook is a native macOS application for interactive SQL development in a cell-based interface (similar to Jupyter Notebook). Supports PostgreSQL and SQLite with persistent `.sqlnb` JSON files, syntax highlighting, and result visualization.

**Stack:** Swift 6.2 • SwiftUI • PostgresNIO • Swift Concurrency • Swift Testing

**Target:** macOS 16.0+ • Xcode 16.0+

---

## Communication Rules

**IMPORTANT:** Answer in Vietnamese, keep technical terms in English. Don't automatically open the app (user opens with XCode).

Examples:
- ✅ "Tôi sẽ sử dụng `async/await` để execute query này"
- ✅ "Code đã được cập nhật, bạn có thể build bằng XCode"
- ❌ "I will use async/await to execute this query"

---

## Architecture Patterns

### MVVM + Observable + Actor

```swift
// ViewModels (UI layer)
@MainActor
@Observable
class NotebookViewModel {
    var notebook: SQLNotebook
    var connectionState: ConnectionState
}

// Database layer (thread-safe)
actor DatabaseConnectionManager {
    private var connection: PostgresConnection?

    func execute(query: String) async throws -> QueryResult {
        // Thread-safe operations
    }
}

// Models (data layer)
struct NotebookCell: Codable, Sendable {
    let id: UUID
    var content: String
    var result: CellResult?
}
```

### Extension-based Organization

ViewModels are split into focused extensions:
- `NotebookViewModel+Connection.swift` — Database connections
- `NotebookViewModel+Execution.swift` — Query execution
- `NotebookViewModel+CellManagement.swift` — Cell CRUD
- `NotebookViewModel+Sidebar.swift` — Sidebar state
- Keep files under 400 lines

### Data Flow

```
.sqlnb file → SQLNotebookDocument → SQLNotebook → NotebookViewModel → SwiftUI Views
```

---

## Code Patterns

### ViewModel Methods (Always Async)

```swift
extension NotebookViewModel {
    func executeQuery(cellId: UUID) async {
        do {
            let result = try await connectionManager.execute(query)

            // Update UI on main actor
            await MainActor.run {
                updateCell(cellId, result: result)
            }
        } catch {
            await MainActor.run {
                showToast("Error: \(error.localizedDescription)", type: .error)
            }
        }
    }
}
```

### Database Operations

```swift
extension DatabaseConnectionManager {
    func fetchSchema() async throws -> [SchemaTable] {
        guard let connection = self.connection else {
            throw DatabaseError.notConnected
        }

        let rows = try await connection.query("""
            SELECT table_name, column_name, data_type
            FROM information_schema.columns
            WHERE table_schema = 'public'
        """)

        return parseSchemaRows(rows)
    }
}
```

### SwiftUI Views (Use Design System)

```swift
struct CellView: View {
    let cell: NotebookCell

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
            Text(cell.content)
                .foregroundColor(.appText)
                .padding(DesignSystem.Spacing.medium)
                .background(Color.appBackground)
                .cornerRadius(DesignSystem.BorderRadius.small)
        }
    }
}
```

---

## Swift 6 Concurrency Rules (CRITICAL)

### Required Patterns

```swift
// ✅ Async database operations
let result = try await connectionManager.execute(query)

// ✅ Update UI on main actor
await MainActor.run {
    self.cells.append(newCell)
}

// ✅ Safe optional unwrapping
guard let index = cells.firstIndex(where: { $0.id == cellId }) else { return }

// ❌ NEVER do this
let result = try! connectionManager.execute(query)  // NO force try
let index = cells.firstIndex(where: { $0.id == cellId })!  // NO force unwrap
```

### Actor Isolation

- All database operations are `async` (via `actor`)
- All UI updates run on `@MainActor`
- Build with `SWIFT_STRICT_CONCURRENCY=complete`

---

## Design System

### Semantic Colors (Always Use These)

```swift
// ✅ Correct
.foregroundColor(.appText)
.background(Color.appBackground)
.border(Color.appBorder)

// ❌ Wrong
.foregroundColor(.black)
.background(Color(hex: "#FFFFFF"))
```

### Spacing (8pt Grid)

```swift
DesignSystem.Spacing.small    // 8pt
DesignSystem.Spacing.medium   // 16pt
DesignSystem.Spacing.large    // 24pt
DesignSystem.Spacing.xlarge   // 32pt
```

### Border Radius

```swift
DesignSystem.BorderRadius.small   // 6pt
DesignSystem.BorderRadius.medium  // 8pt
```

---

## Testing (Swift Testing Framework)

### Unit Tests

```swift
import Testing
@testable import SQLNotebook

struct CellTests {
    @Test("Cell creation with query")
    func testCellCreation() {
        let cell = NotebookCell(content: "SELECT * FROM users")
        #expect(cell.content == "SELECT * FROM users")
        #expect(cell.result == nil)
    }

    @Test("Async database connection")
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
}
```

**Key Points:**
- Use `@Test` macro (not `func testXXX()`)
- Use `#expect()` (not `XCTAssertEqual()`)
- Use `struct` (not `class`)

---

## File Structure

```
SQLNotebook/
├── SQLNotebookApp.swift
├── Models/
│   ├── NotebookCell.swift           # Cell model (query + results)
│   ├── SQLNotebook.swift            # Notebook model (array of cells)
│   ├── ConnectionConfig.swift       # DB connection config
│   └── AppSettings.swift            # Global settings
├── ViewModels/
│   ├── NotebookViewModel.swift      # Main ViewModel
│   ├── NotebookViewModel+Connection.swift
│   ├── NotebookViewModel+Execution.swift
│   ├── NotebookViewModel+CellManagement.swift
│   └── NotebookViewModel+Sidebar.swift
├── Views/
│   ├── ContentView.swift            # Main UI container
│   ├── Components/                  # Reusable components
│   └── Sidebars/                    # Left/Right sidebars
├── Database/
│   └── DatabaseConnectionManager.swift  # Database actor
└── Utilities/
    ├── DesignSystem.swift           # Design tokens
    ├── SQLSyntaxHighlighter.swift   # Syntax highlighting
    └── CellValueValidator.swift     # Value validation
```

---

## Important Rules

1. **Concurrency:** Always `async/await` for DB ops, update UI on `@MainActor`
2. **Safety:** No force unwrap (`!`), no force try (`try!`)
3. **Design System:** Use semantic colors/spacing from `DesignSystem.swift`
4. **Testing:** Use Swift Testing framework (not XCTest)
5. **Extensions:** Keep files under 400 lines, split into extensions
6. **Documentation:** Never read files in `docs/implementation/` unless you are asked for

---

## Common Gotchas

1. **Passwords:** Currently in `.sqlnb` files (NOT SECURE - TODO: use Keychain)
2. **Result Limits:** Default max 50 rows (configurable 1-200)
3. **Row IDs:** PostgreSQL uses `ctid`, SQLite uses `rowid`
4. **MainActor:** All UI updates must run on main actor
5. **Format Code:** Run `swift-format -i -r SQLNotebook/` before committing

---

## Build Commands

```bash
# Build with strict concurrency (matches CI)
./scripts/build-strict.sh

# Run all tests
xcodebuild test -scheme SQLNotebook

# Skip integration tests (no DB required)
SKIP_INTEGRATION_TESTS=true xcodebuild test -scheme SQLNotebook

# Format code
swift-format -i -r SQLNotebook/
```