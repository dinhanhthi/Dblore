# Claude Code Guide for SQLNotebook

**Common Documentation:** See [docs/AI_GUIDE.md](docs/AI_GUIDE.md) for complete project overview, architecture, and development guidelines.

---

## Claude-Specific Instructions

**IMPORTANT**: Answer me in Vietnamese, keep terminologies in English. Don't automatically open the app, I do it myself with XCode.

---

## Communication Style

When working with this codebase:

1. **Language**: Answer in Vietnamese, keep technical terms in English
   - ✅ "Tôi sẽ sử dụng `async/await` để execute query này"
   - ❌ "I will use async/await to execute this query"

2. **Technical Explanations**: Explain Swift/SwiftUI concepts in detail when needed
   - Provide examples and code snippets

3. **Workflow**: Don't automatically open app, user opens with XCode
   - ✅ "Code đã được cập nhật, bạn có thể build bằng XCode"
   - ❌ [Automatically run Bash command to open XCode]

---

## Key Architectural Patterns

### Observable Macro Pattern
```swift
@MainActor
@Observable
class NotebookViewModel {
    var notebook: SQLNotebook
    var connectionState: ConnectionState
}
```

**Key Points:**
- `@Observable` is Swift 6's new macro, replacing the old `ObservableObject` pattern
- `@MainActor` ensures all state updates happen on the main thread (UI thread)
- SwiftUI automatically tracks dependencies and re-renders views when properties change

### Actor Pattern for Database
```swift
actor DatabaseConnectionManager {
    private var connection: PostgresConnection?

    func execute(query: String) async throws -> QueryResult {
        // Thread-safe operations
    }
}
```

**Key Points:**
- `actor` is a reference type that's thread-safe by default
- All actor methods are implicitly async
- Only one task can access actor state at a time
- Similar to mutex/locks in other languages but compiler-enforced

### Extension-based Organization
ViewModel is split into focused extensions:
- `NotebookViewModel+Connection.swift` — Database connection logic
- `NotebookViewModel+Execution.swift` — Query execution
- `NotebookViewModel+CellManagement.swift` — Cell CRUD operations
- `NotebookViewModel+Sidebar.swift` — Sidebar state management

**Benefits:**
- Clearer code organization
- Easier to navigate and maintain
- Avoids overly long files (400-line limit per file recommended)

---

## Common Workflows

### Adding a New Feature to Cell

1. **Update Model** (`NotebookCell.swift`):
```swift
struct NotebookCell: Codable, Sendable {
    let id: UUID
    var content: String
    var newProperty: String? // Add new property
}
```

2. **Update ViewModel Extension**:
```swift
// In NotebookViewModel+CellManagement.swift
extension NotebookViewModel {
    func updateNewProperty(cellId: UUID, value: String) {
        guard let index = notebook.cells.firstIndex(where: { $0.id == cellId }) else { return }
        notebook.cells[index].newProperty = value
    }
}
```

3. **Update View** (`CellView.swift`):
```swift
struct CellView: View {
    let cell: NotebookCell

    var body: some View {
        VStack {
            // Existing code...
            if let newValue = cell.newProperty {
                Text(newValue)
            }
        }
    }
}
```

### Adding a New Database Operation

1. **Update DatabaseConnectionManager**:
```swift
// In DatabaseConnectionManager+QueryExecution.swift or new file
extension DatabaseConnectionManager {
    func newOperation() async throws -> Result {
        guard let connection = self.connection else {
            throw DatabaseError.notConnected
        }
        // Implementation...
    }
}
```

2. **Call from ViewModel**:
```swift
// In NotebookViewModel+Execution.swift
func performNewOperation() async {
    do {
        let result = try await connectionManager.newOperation()
        // Update UI on main actor
        await MainActor.run {
            self.showToast("Operation successful", type: .success)
        }
    } catch {
        await MainActor.run {
            self.showToast("Error: \(error.localizedDescription)", type: .error)
        }
    }
}
```

---

## Testing Guidelines

### Unit Tests
Create new test file in `SQLNotebookTests/`:
```swift
import Testing
@testable import SQLNotebook

struct MyFeatureTests {
    @Test("Test case description")
    func testMyFeature() async throws {
        // Arrange
        let model = NotebookCell(...)

        // Act
        let result = model.someMethod()

        // Assert
        #expect(result == expectedValue)
    }
}
```

**Notes:**
- Use Swift Testing framework (not XCTest)
- Use `@Test` macro instead of `func testXXX()`
- Use `#expect()` instead of `XCTAssertEqual()`

### Integration Tests with Database
```swift
@Test("Database connection test")
func testDatabaseConnection() async throws {
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

---

## Build & Development Commands

### Build with strict concurrency checking
```bash
# Local build with same strict settings as GitHub Actions
./scripts/build-strict.sh
```

### Format code
```bash
# Install swift-format if not already installed
brew install swift-format

# Format all files
swift-format -i -r SQLNotebook/

# Check only (don't modify files)
swift-format lint -r SQLNotebook/
```

### Run tests
```bash
# All tests
xcodebuild test -scheme SQLNotebook

# Only unit tests (skip integration tests that need database)
SKIP_INTEGRATION_TESTS=true xcodebuild test -scheme SQLNotebook

# Specific test class
xcodebuild test -scheme SQLNotebook -only-testing SQLNotebookTests/DataModelTests
```

---

## Important Reminders

1. **Concurrency Safety:**
   - Always use `async/await` for database operations
   - Update UI only on `@MainActor`
   - Use `actor` for shared mutable state

2. **Error Handling:**
   - Don't use force unwrap (`!`) or force try (`try!`)
   - Use `if let` or `guard let` for optional unwrapping
   - Display user-friendly errors in UI, log technical details

3. **Performance:**
   - Test with large notebooks (100+ cells)
   - Test with large result sets (1000+ rows)
   - Use `LazyVStack` instead of `VStack` for long lists

4. **Security:**
   - **NOT IMPLEMENTED:** Passwords should be stored in Keychain, not in `.sqlnb` files
   - Validate user inputs before executing queries
   - Use SSL/TLS for production connections

5. **Design System:**
   - Check `DesignSystem.swift` before creating custom styles
   - Use semantic colors (e.g., `Color.appBackground`) instead of hardcoded hex
   - Follow 8pt spacing grid

---

## Quick Reference Links

- 📖 [Complete AI Guide](docs/AI_GUIDE.md) — Full documentation
- 📋 [Project Spec](docs/project.md) — Technical specifications
- ✅ [TODO](docs/TODO.md) — Task breakdown