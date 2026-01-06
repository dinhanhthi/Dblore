# GitHub Copilot Instructions for SQLNotebook

**Common Documentation:** See [docs/AI_GUIDE.md](../docs/AI_GUIDE.md) for complete project overview, architecture, and development guidelines.

---

## Copilot-Specific Instructions

This document provides GitHub Copilot-specific guidance optimized for inline code completion and chat suggestions.

---

## Quick Project Context

**SQLNotebook** is a native macOS SQL notebook application (Swift 6, SwiftUI) enabling users to write, execute, and persist SQL queries in a cell-based interface. Supports PostgreSQL and SQLite with persistent `.sqlnb` JSON files, syntax highlighting, and result visualization.

---

## Code Completion Guidelines

### MVVM + Actors Pattern
- **ViewModels**: `NotebookViewModel` (marked `@MainActor @Observable`) is the single source of truth
- **Extensions**: Organized into focused extensions:
  - `NotebookViewModel+Connection.swift` — database connection logic
  - `NotebookViewModel+Execution.swift` — query execution
  - `NotebookViewModel+CellManagement.swift` — cell CRUD operations
  - `NotebookViewModel+Sidebar.swift` — sidebar state management
- **Database Layer**: `DatabaseConnectionManager` is an `actor` for thread-safe PostgreSQL operations
- **Models**: Use `Sendable` protocol with `nonisolated` init decorators

### Swift 6 Concurrency (CRITICAL)
- All database calls MUST be `async`/`await`
- Use actors for shared mutable state
- Use `@MainActor` for ViewModels
- Dispatch to `@MainActor` when updating UI from background tasks
- Build with `SWIFT_STRICT_CONCURRENCY=complete`
- Avoid force unwraps; prefer `if let` or `guard` statements

### Data Flow
```
Document (.sqlnb file)
  → SQLNotebookDocument
  → SQLNotebook model
  → NotebookViewModel
  → SwiftUI Views
```

---

## Common Patterns

### Adding ViewModel Methods
```swift
// In appropriate NotebookViewModel+*.swift extension
extension NotebookViewModel {
    func newMethod() async {
        // Database operations
        do {
            let result = try await connectionManager.execute(...)

            // Update UI on main actor
            await MainActor.run {
                self.someProperty = result
            }
        } catch {
            await MainActor.run {
                self.showToast("Error: \(error.localizedDescription)", type: .error)
            }
        }
    }
}
```

### Database Operations
```swift
// In DatabaseConnectionManager extension
extension DatabaseConnectionManager {
    func newOperation() async throws -> Result {
        guard let connection = self.connection else {
            throw DatabaseError.notConnected
        }
        // Implementation using PostgresNIO
    }
}
```

### SwiftUI Views
```swift
struct MyView: View {
    let data: SomeModel

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.small) {
            // Use semantic colors from DesignSystem
            Text(data.title)
                .foregroundColor(.appText)
        }
        .padding(DesignSystem.Spacing.medium)
    }
}
```

---

## Design System

### Always Use Semantic Colors
```swift
// ✅ Correct
.foregroundColor(.appText)
.background(Color.appBackground)
.border(Color.appBorder)

// ❌ Incorrect
.foregroundColor(.black)
.background(Color(hex: "#FFFFFF"))
```

### Spacing (8pt grid)
```swift
DesignSystem.Spacing.small    // 8pt
DesignSystem.Spacing.medium   // 16pt
DesignSystem.Spacing.large    // 24pt
```

### Border Radius
```swift
DesignSystem.BorderRadius.small  // 6pt
DesignSystem.BorderRadius.medium // 8pt
```

---

## Testing Patterns

### Swift Testing Framework (NOT XCTest)
```swift
import Testing
@testable import SQLNotebook

struct MyFeatureTests {
    @Test("Description of test case")
    func testMyFeature() async throws {
        // Arrange
        let model = SomeModel(...)

        // Act
        let result = model.someMethod()

        // Assert
        #expect(result == expectedValue)
    }
}
```

**Key Differences:**
- Use `@Test` macro instead of `func testXXX()`
- Use `#expect()` instead of `XCTAssertEqual()`
- Use `struct` instead of `class`

---

## Common File Locations

### Models
- `SQLNotebook/Models/NotebookCell.swift` — Cell data model
- `SQLNotebook/Models/SQLNotebook.swift` — Notebook data model
- `SQLNotebook/Models/ConnectionConfig.swift` — Connection configuration
- `SQLNotebook/Models/AppSettings.swift` — Global app settings

### ViewModels
- `SQLNotebook/ViewModels/NotebookViewModel.swift` — Main ViewModel
- Extensions in same directory with `+` suffix

### Views
- `SQLNotebook/Views/ContentView.swift` — Main container
- `SQLNotebook/Views/Components/*` — Reusable components
- `SQLNotebook/Views/Sidebars/*` — Sidebar content views

### Database
- `SQLNotebook/Database/DatabaseConnectionManager.swift` — Main actor
- Extensions in same directory

### Utilities
- `SQLNotebook/Utilities/DesignSystem.swift` — Design tokens
- `SQLNotebook/Utilities/SQLSyntaxHighlighter.swift` — Syntax highlighting
- `SQLNotebook/Utilities/CellValueValidator.swift` — Value validation

---

## Code Style

### Formatting
- Install: `brew install swift-format`
- Format: `swift-format -i -r SQLNotebook/`
- Uses `.swift-format` config at project root

### Important Rules
1. **Concurrency**: Always `async`/`await` for DB operations
2. **Error Handling**: No force unwrap (`!`) or force try (`try!`)
3. **Optional Unwrapping**: Use `if let` or `guard let`
4. **UI Updates**: Always on `@MainActor`
5. **Design System**: Use semantic colors and spacing constants

---

## Build Commands

```bash
# Local build with strict concurrency
./scripts/build-strict.sh

# Run all tests
xcodebuild test -scheme SQLNotebook

# Skip integration tests (no database needed)
SKIP_INTEGRATION_TESTS=true xcodebuild test -scheme SQLNotebook

# Format code
swift-format -i -r SQLNotebook/
```

---

## Important Gotchas

1. **Password Security**: Passwords should NOT be in `.sqlnb` files (TODO: use Keychain)
2. **Result Limits**: Default max rows = 50 (configurable 1-200)
3. **MainActor Dispatch**: UI updates must be on main actor
4. **Row Identification**: PostgreSQL uses `ctid`, SQLite uses `rowid`
5. **Primary Keys**: Currently hardcoded to false in schema (TODO: detect from DB)

---

## Quick Reference Links

- 📖 [Complete AI Guide](../docs/AI_GUIDE.md) — Full documentation
- 📋 [Project Spec](../docs/project.md) — Technical specifications
- ✅ [TODO](../docs/TODO.md) — Task breakdown