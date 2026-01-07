# SQLNotebook - Gemini Guide

## Project Overview

SQLNotebook is a native macOS application for interactive SQL development in a cell-based interface, similar to Jupyter Notebook. Supports PostgreSQL and SQLite with persistent query results and a rich SwiftUI interface.

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

## Architecture

### Core Patterns

**1. MVVM with Observable (Swift 6)**
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

**2. Actor Pattern for Database**
```swift
actor DatabaseConnectionManager {
    private var connection: PostgresConnection?

    func execute(query: String) async throws -> QueryResult {
        // Thread-safe by design
    }
}
```
- Compiler-enforced thread safety
- All methods implicitly `async`
- Single-access guarantee (like mutex but safer)

**3. Extension-based Organization**
- `NotebookViewModel+Connection.swift` — Database connections
- `NotebookViewModel+Execution.swift` — Query execution
- `NotebookViewModel+CellManagement.swift` — Cell CRUD
- `NotebookViewModel+Sidebar.swift` — Sidebar state
- Keep files under 400 lines

### Project Structure

```
SQLNotebook/
├── SQLNotebookApp.swift        # App entry point
├── Models/
│   ├── NotebookCell.swift      # Cell model (query + results)
│   ├── SQLNotebook.swift       # Notebook model
│   ├── ConnectionConfig.swift  # DB connection config
│   └── SQLNotebookDocument.swift
├── ViewModels/
│   └── NotebookViewModel*.swift # Main ViewModel (split into extensions)
├── Views/
│   ├── ContentView.swift       # Main UI
│   ├── Components/             # Cell, Result table
│   └── Sidebars/               # Left/Right sidebars
├── Database/
│   └── DatabaseConnectionManager.swift # Database actor
└── Utils/                      # Helpers, extensions
```

---

## Key Implementation Details

### Database Layer

**DatabaseConnectionManager (Actor)**
- Thread-safe PostgreSQL/SQLite operations
- SSL/TLS support (6 modes: disable, allow, prefer, require, verify-ca, verify-full)
- Connection retry with exponential backoff
- Cloud database detection (Supabase, AWS, Azure, GCP)

**Query Execution**
- SELECT → result sets with column metadata
- INSERT/UPDATE/DELETE → affected row counts
- Row limit enforcement (1-200 rows, configurable)
- Query modification detection for safety

**Type System**
```swift
enum CellValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case json(String)
    case date(Date)
    case data(Data)
}
```

### UI Features

- Cell-based interface with SQL syntax highlighting
- Collapsible sidebars (schema browser, connection settings)
- Inline result editing with UPDATE query execution
- Toast notifications for feedback
- Theme support: System/Light/Dark
- Keyboard shortcuts for common operations

### Persistence

- Document-based app (`.sqlnb` files)
- JSON format with Codable serialization
- Auto-save with debouncing
- Undo/Redo via `UndoManager`

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
// ✅ Custom error enum
enum DatabaseError: Error {
    case notConnected
    case queryFailed(String)
    case invalidResult
}

// ✅ Proper propagation
do {
    let result = try await manager.execute(query)
} catch let error as DatabaseError {
    // Handle specific errors
} catch {
    // Handle unexpected errors
}

// ❌ Never use force unwrap/try
let result = try! manager.execute(query) // NO
```

### Type Safety
- Use `CellValue` enum for database values
- Validate types before UPDATE queries
- Strong typing throughout the stack

### Adding New Features

**Example: Add query timeout**

1. Update ConnectionConfig:
```swift
struct ConnectionConfig: Codable {
    var host: String
    var port: Int
    var timeout: TimeInterval? // New property
}
```

2. Update DatabaseConnectionManager:
```swift
extension DatabaseConnectionManager {
    func connect(config: ConnectionConfig) async throws {
        let timeout = config.timeout ?? 30.0
        // Use timeout in connection logic
    }
}
```

3. Update UI:
```swift
TextField("Timeout (seconds)", value: $config.timeout, format: .number)
```

---

## Testing

### Unit Tests (Swift Testing Framework)
```swift
import Testing
@testable import SQLNotebook

struct DatabaseTests {
    @Test("Connection to PostgreSQL")
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

**Notes:**
- Use `@Test` macro (not XCTest)
- Use `#expect()` (not `XCTAssertEqual`)
- Tests run in parallel by default

### Integration Tests

**Docker Test Database:**
```bash
# Start PostgreSQL test database
cd docker/postgresql && docker compose up -d

# Run all tests
xcodebuild test -scheme SQLNotebook

# Skip integration tests (no DB required)
SKIP_INTEGRATION_TESTS=true xcodebuild test -scheme SQLNotebook
```

---

## Important Rules

1. **Concurrency:** Always use `async/await` for DB ops, update UI on `@MainActor`
2. **Safety:** No force unwrap (`!`), no force try (`try!`)
3. **Performance:** Use `LazyVStack` for long lists, test with 100+ cells/rows
4. **Security:** Validate inputs, use SSL for production (Keychain not yet implemented ⚠️)
5. **Design:** Check `DesignSystem.swift` for colors/spacing (8pt grid)
6. **Documentation:** Never read files in `docs/implementation/` unless you are asked for

---

## Build Commands

```bash
# Build with strict concurrency checking (matches CI)
./scripts/build-strict.sh

# Format code
swift-format -i -r SQLNotebook/

# Run tests
xcodebuild test -scheme SQLNotebook
```

---

## Current Implementation Status

**Core Features:** ✅ Complete
- Cell-based notebook interface
- PostgreSQL/SQLite support
- Query execution with result display
- Document persistence (`.sqlnb` files)
- Undo/Redo support

**Polish Features:** ✅ Mostly complete
- Keyboard shortcuts, auto-save, theme toggle, result controls
- ⏳ TODO: Cell execution queue, drag-and-drop reordering

**Security:** ⚠️ Partial
- ✅ SSL/TLS support, connection retry, value validation
- ⏳ TODO: Keychain password storage (currently stored in files - NOT SECURE)

**Advanced Features:** ⏳ Not started
- Query history, CSV export, autocomplete, multiple connections, tabs