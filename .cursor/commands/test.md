# test

Manages testing aspects for SQLNotebook - creates test targets, writes test cases, sets up test infrastructure, and ensures comprehensive test coverage following the testing plan.

## Testing Framework Strategy

**IMPORTANT - Use Internet Search First:**
- **ALWAYS** search for latest Swift Testing framework features and best practices
- Look for latest XCTest patterns and macOS UI testing techniques
- Verify compatibility between Swift Testing framework versions and Swift 6.2+
- Search for latest testing patterns for async/await, actors, and concurrency

**IMPORTANT**: This project uses TWO testing frameworks:

1. **Swift Testing** (primary for unit & integration tests)
   - Use `import Testing`
   - Use `@Suite` and `@Test` macros
   - Use `#expect()` assertions
   - Modern, type-safe, async-first

2. **XCTest** (for UI tests ONLY)
   - Use `import XCTest`
   - Use `XCTestCase` classes
   - Use `XCTAssert*()` assertions
   - Required for `XCUIApplication` and UI automation

## How to Use This Command

When user requests testing work (create tests, setup test targets, write test cases, check test coverage), follow this workflow:

### Step 1: Read Testing Plan

**ALWAYS** read `@docs/testing_plan.md` first to understand:
- Testing architecture và structure
- Test cases requirements
- Test infrastructure needs
- Best practices

### Step 2: Understand the Request

Identify what the user needs:
- **Setup**: Create test targets, configure Xcode project
- **Unit Tests**: Write tests for models, utilities, ViewModels
- **Integration Tests**: Write tests for database operations
- **UI Tests**: Write tests for user flows
- **Performance Tests**: Write tests for performance-critical code
- **Mock Objects**: Create mock dependencies
- **Test Helpers**: Create utility functions
- **Run Tests**: Execute tests và check coverage
- **Fix Tests**: Debug và fix failing tests

### Step 3: Check Current Test Status

Before starting, check if test infrastructure exists:

```bash
# Check for test targets
ls -la SQLNotebookTests/ 2>/dev/null || echo "No test target found"
ls -la SQLNotebookUITests/ 2>/dev/null || echo "No UI test target found"

# Check for existing test files
find . -name "*Tests.swift" -o -name "*Test.swift" 2>/dev/null
```

### Step 4: Execute Testing Tasks

Based on the request, follow the appropriate workflow below.

---

## Testing Strategy

### Test Types to Create

1. **Unit Tests**
   - Data models (Codable, business logic)
   - Utilities (syntax highlighters, formatters)
   - ViewModels (state management, user actions)
   - Isolated components

2. **Integration Tests**
   - Database connections và operations
   - Query execution và result parsing
   - Schema loading
   - Document persistence (read/write)

3. **UI Tests**
   - User flows (create, open, save notebooks)
   - Keyboard shortcuts
   - UI interactions (buttons, sidebars, cells)
   - End-to-end scenarios

4. **Performance Tests**
   - Large dataset handling
   - Query execution timing
   - UI rendering với many cells

## Testing Approach

### 1. Analyze Requirements
- Read the testing plan (`docs/testing_plan.md`)
- Understand the feature being tested
- Identify test boundaries và dependencies
- Determine appropriate test types

### 2. Set Up Test Infrastructure
- Create test targets if needed
- Set up mock objects và test helpers
- Configure test database (Docker hoặc local PostgreSQL)
- Create test data builders

### 3. Write Tests
- Follow AAA pattern (Arrange-Act-Assert)
- **For Swift Testing**: Use `@Test("description")` với descriptive function names
- **For XCTest UI tests**: Use descriptive test names like `testFunctionName_Scenario_ExpectedResult()`
- Keep tests isolated và independent
- Mock external dependencies (database, file system, network)
- Handle async testing với `async/await` (Swift Testing) hoặc `XCTestExpectation` (XCTest)

### 4. Verify Coverage
- Run tests với `Cmd+U` hoặc CLI
- Check code coverage reports
- Identify gaps trong test coverage
- Add missing test cases

### 5. Maintain Tests
- Update tests when code changes
- Refactor tests for clarity
- Remove obsolete tests
- Keep test suite fast

---

## Phase 6.1: Test Target Setup

### Create Unit Test Target

**When**: User requests test setup hoặc no test targets exist

**Steps**:
1. Check if `SQLNotebookTests` target exists trong Xcode project
2. If not, guide user to create via Xcode:
   - File → New → Target → Unit Testing Bundle
   - Name: `SQLNotebookTests`
   - Target to be Tested: `SQLNotebook`
3. Create folder structure:
   ```
   SQLNotebookTests/
   ├── Models/
   ├── Utilities/
   ├── ViewModels/
   ├── Database/
   ├── Document/
   └── Helpers/
   ```

### Create UI Test Target

**When**: User requests UI testing setup

**Steps**:
1. Check if `SQLNotebookUITests` target exists
2. If not, guide user to create via Xcode:
   - File → New → Target → UI Testing Bundle
   - Name: `SQLNotebookUITests`
   - Target to be Tested: `SQLNotebook`
3. Create basic UI test structure

---

## Phase 6.2-6.5: Unit Tests

### Writing Model Tests (Swift Testing)

**Reference**: `@docs/testing_plan.md` section "6.2 Unit Tests - Data Models"

**Template**:
```swift
import Testing
@testable import SQLNotebook

@Suite("SQLNotebook Tests")
struct SQLNotebookTests {
    @Test("Encoding and decoding valid notebook succeeds")
    func encodingDecodingValidNotebookRoundTripSuccess() throws {
        // Arrange
        let notebook = SQLNotebook.newDocument()

        // Act
        let encoder = JSONEncoder()
        let data = try encoder.encode(notebook)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SQLNotebook.self, from: data)

        // Assert
        #expect(notebook.id == decoded.id)
        #expect(notebook.cells.count == decoded.cells.count)
    }

    @Test("New document has default state with one cell")
    func newDocumentDefaultStateReturnsNotebookWithOneCell() {
        // Arrange & Act
        let notebook = SQLNotebook.newDocument()

        // Assert
        #expect(notebook.cells.count == 1)
        #expect(notebook.cells.first?.cellType == .sql)
    }
}
```

**Test Files to Create**:
- `SQLNotebookTests/Models/SQLNotebookTests.swift`
- `SQLNotebookTests/Models/NotebookCellTests.swift`
- `SQLNotebookTests/Models/CellValueTests.swift`
- `SQLNotebookTests/Models/ConnectionConfigTests.swift`

### Writing Utility Tests (Swift Testing)

**Reference**: `@docs/testing_plan.md` section "6.3 Unit Tests - Utilities"

**Template**:
```swift
import Testing
@testable import SQLNotebook

@Suite("SQL Syntax Highlighter Tests")
struct SQLSyntaxHighlighterTests {
    @Test("Keyword highlighting works correctly")
    func keywordHighlighting() {
        // Arrange
        let sql = "SELECT * FROM users WHERE id = 1"

        // Act
        let highlighted = SQLSyntaxHighlighter.highlight(sql)

        // Assert
        // Check that keywords are highlighted with correct color
        // (This requires checking NSAttributedString attributes)
    }

    @Test("Case insensitive keywords are highlighted")
    func caseInsensitiveKeywords() {
        // Test: SELECT, select, Select all get highlighted
    }

    @Test("String highlighting works")
    func stringHighlighting() {
        // Test single-quote và dollar-quote strings
    }

    @Test("Comment highlighting works")
    func commentHighlighting() {
        // Test single-line và multi-line comments
    }
}
```

**Test Files to Create**:
- `SQLNotebookTests/Utilities/SQLSyntaxHighlighterTests.swift`
- `SQLNotebookTests/Utilities/JSONSyntaxHighlighterTests.swift` (if exists)

### Writing Document Tests (Swift Testing)

**Reference**: `@docs/testing_plan.md` section "6.4 Unit Tests - Document Operations"

**Template**:
```swift
import Testing
@testable import SQLNotebook
import Foundation

@Suite("SQLNotebook Document Tests")
struct SQLNotebookDocumentTests {
    @Test("Read write round trip preserves data")
    func readWriteRoundTrip() throws {
        // Arrange
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlnb")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let original = SQLNotebook.newDocument()
        let document = SQLNotebookDocument(notebook: original)

        // Act
        try document.write(to: tempURL)
        let loaded = try SQLNotebookDocument.read(from: tempURL)

        // Assert
        #expect(original.id == loaded.notebook.id)
    }
}
```

### Writing ViewModel Tests (Swift Testing)

**Reference**: `@docs/testing_plan.md` section "6.5 Unit Tests - ViewModel Logic"

**Note**: ViewModels thường cần `@MainActor` vì SwiftUI ViewModels chạy trên main thread.

**Template**:
```swift
import Testing
@testable import SQLNotebook

@Suite("Notebook ViewModel Tests")
@MainActor
struct NotebookViewModelTests {
    @Test("Add cell increases cell count")
    func addCell() {
        // Arrange
        let viewModel = NotebookViewModel(notebook: SQLNotebook.newDocument())
        let initialCount = viewModel.notebook.cells.count

        // Act
        viewModel.addCell(type: .sql, after: nil)

        // Assert
        #expect(viewModel.notebook.cells.count == initialCount + 1)
    }

    @Test("Delete cell removes cell")
    func deleteCell() {
        // Test delete existing cell
    }

    @Test("Move cell reorders cells")
    func moveCell() {
        // Test reorder cells
    }
}
```

---

## Phase 6.6-6.8: Integration Tests

### Writing Database Connection Tests (Swift Testing)

**Reference**: `@docs/testing_plan.md` section "6.6 Integration Tests - Database Connection"

**Requirements**:
- Test database setup (local PostgreSQL hoặc Docker)
- Cleanup sau mỗi test
- Mock hoặc real database connection

**Template**:
```swift
import Testing
@testable import SQLNotebook

@Suite("Database Connection Manager Tests")
struct DatabaseConnectionManagerTests {
    let testConfig = ConnectionConfig(
        host: "localhost",
        port: 5432,
        database: "test_db",
        username: "test_user",
        password: "test_password"
    )

    @Test("Connect with valid config establishes connection")
    func connectSuccessValidConfigConnectionEstablished() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        // (Requires test database setup)

        // Act
        try await manager.connect(config: testConfig)

        // Assert
        let state = await manager.connectionState
        #expect(state == .connected)
    }

    @Test("Connect with invalid host throws error")
    func connectInvalidHostThrowsError() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let invalidConfig = ConnectionConfig(
            host: "invalid.host",
            port: 5432,
            database: "test_db",
            username: "test_user",
            password: "test_password"
        )

        // Act & Assert
        #expect(throws: Error.self) {
            try await manager.connect(config: invalidConfig)
        }
    }
}
```

### Writing Query Execution Tests

**Reference**: `@docs/testing_plan.md` section "6.7 Integration Tests - Query Execution"

**Test Cases**:
- SELECT queries
- INSERT/UPDATE/DELETE queries
- DDL statements
- Error handling
- Type mapping
- Result row limiting

---

## Phase 6.9-6.12: UI Tests (XCTest Required)

### Writing UI Tests

**IMPORTANT**: UI tests MUST use XCTest because Swift Testing does not support `XCUIApplication` and UI automation.

**Reference**: `@docs/testing_plan.md` section "6.9-6.12 UI Tests"

**Template**:
```swift
import XCTest

final class NotebookUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    @MainActor
    func testCreateNewNotebook() {
        // Act
        app.typeKey("n", modifierFlags: .command)

        // Assert
        // Verify new notebook created
        XCTAssertTrue(app.windows.count > 0)
    }

    @MainActor
    func testAddCodeCell() {
        // Test Cmd+B adds new cell
        app.typeKey("b", modifierFlags: .command)
    }

    @MainActor
    func testRunCell() {
        // Test Cmd+Enter executes cell
        app.typeKey(.enter, modifierFlags: .command)
    }
}
```

**UI Test Files to Create**:
- `SQLNotebookUITests/NotebookUITests.swift`
- `SQLNotebookUITests/QueryExecutionUITests.swift`
- `SQLNotebookUITests/ConnectionUITests.swift`
- `SQLNotebookUITests/DocumentPersistenceUITests.swift`

**Note**: All UI test files use XCTest framework, not Swift Testing.

---

## Test Categories from Testing Plan

### Data Models
- Encoding/decoding (JSON round-trip)
- Validation logic
- Computed properties
- Enum cases (CellValue types)

### Database Operations
- Connection lifecycle (connect, disconnect, reconnect)
- Query execution (SELECT, INSERT, UPDATE, DELETE, DDL)
- Error handling (invalid SQL, connection failures)
- Type mapping (PostgreSQL types → CellValue enum)
- SSL/TLS modes

### Document Persistence
- Read valid/invalid JSON files
- Write notebooks to disk
- Round-trip testing (save → load → verify)
- Password security (not saved trong files)

### ViewModel Logic
- Cell management (add, delete, move, duplicate)
- Selection state
- Execution flow
- Output clearing

### UI Flows
- Keyboard shortcuts
- Sidebar toggles
- Cell execution
- Result display

---

## Test Infrastructure

### Creating Mock Objects

**Reference**: `@docs/testing_plan.md` section "Test Infrastructure"

**Location**: `SQLNotebookTests/Helpers/MockDatabaseConnectionManager.swift`

**Template**:
```swift
import Foundation
@testable import SQLNotebook

actor MockDatabaseConnectionManager {
    var connectionState: ConnectionState = .disconnected
    var mockResults: CellResult?
    var shouldThrowError = false
    var lastQuery: String?
    
    func connect(config: ConnectionConfig) async throws {
        if shouldThrowError {
            throw DatabaseError.connectionFailed("Mock error")
        }
        connectionState = .connected
    }
    
    func disconnect() async {
        connectionState = .disconnected
    }
    
    func execute(query: String) async throws -> CellResult {
        lastQuery = query
        if shouldThrowError {
            throw DatabaseError.queryFailed("Mock query error")
        }
        return mockResults ?? CellResult()
    }
}
```

### Creating Test Helpers

**Location**: `SQLNotebookTests/Helpers/TestHelpers.swift`

**Template**:
```swift
import Foundation
@testable import SQLNotebook

extension XCTestCase {
    func createTestNotebook() -> SQLNotebook {
        SQLNotebook.newDocument()
    }
    
    func createTestCell(content: String = "SELECT 1") -> NotebookCell {
        NotebookCell(cellType: .sql, content: content)
    }
    
    func createTestResult() -> CellResult {
        CellResult(
            columns: [
                ColumnInfo(name: "id", type: "INTEGER"),
                ColumnInfo(name: "name", type: "VARCHAR")
            ],
            rows: [
                [.int(1), .string("Test")]
            ],
            executionTime: 0.1,
            rowCount: 1
        )
    }
}
```

---

## Running Tests

### In Xcode
- `Cmd+U` - Run all tests
- Test Navigator (`Cmd+6`) - Run individual tests
- Code Coverage: Product → Scheme → Edit Scheme → Test → Options → Code Coverage

### Command Line

**Run All Tests**:
```bash
xcodebuild test -scheme SQLNotebook -destination 'platform=macOS'
```

**Run Specific Test**:
```bash
xcodebuild test -scheme SQLNotebook -destination 'platform=macOS' -only-testing:SQLNotebookTests/FeatureTests/testSpecificCase
```

**Enable Code Coverage**:
Product → Scheme → Edit Scheme → Test → Options → Code Coverage

**View Coverage Report**:
In Xcode: Report Navigator (⌘9) → Coverage tab

**Build with Strict Concurrency (Match GitHub Actions)**:
```bash
./scripts/build-strict.sh
```

**IMPORTANT**: Always run strict build before pushing to catch concurrency issues!

---

## Test Coverage Goals

- **Unit Tests**: 80%+ coverage cho models, utilities, ViewModels
- **Integration Tests**: Cover all database operations
- **UI Tests**: Cover critical user flows

---

## Best Practices

### ✅ Always Do
1. **Read testing plan** trước khi viết tests
2. **Choose correct framework**:
   - Unit/Integration tests → Swift Testing (`@Test`, `#expect`)
   - UI tests → XCTest (`XCTestCase`, `XCTAssert*`)
3. **Follow Arrange-Act-Assert** pattern
4. **Use descriptive test names**:
   - Swift Testing: `@Test("Description")` với clear function names
   - XCTest: `testFunctionName_Scenario_ExpectedResult()`
5. **Keep tests isolated** - mỗi test independent
6. **Mock external dependencies** - database, file system, network
7. **Clean up** test data sau mỗi test (use `defer` trong Swift Testing)
8. **Test edge cases** - empty data, nil values, errors
9. **Use async testing** với `async/await` (preferred) hoặc `XCTestExpectation`
10. **Test behavior, not implementation** - Focus on what code does, not how
11. **Keep tests focused** - One assertion per test (when practical)
12. **Make tests readable** - Tests are documentation, make them clear

### ❌ Never Do
1. **Skip reading testing plan** - always check `@docs/testing_plan.md`
2. **Use wrong framework** - Don't use XCTest for unit tests, don't use Swift Testing for UI tests
3. **Write tests without understanding** the code being tested
4. **Depend on test execution order** - tests must be independent
5. **Use real database** trong unit tests (use mocks)
6. **Skip cleanup** - always clean up test data
7. **Test implementation details** - test behavior, not internals
8. **Write flaky tests** - tests should be deterministic
9. **Ignore async/await** - Handle async code properly với `async throws` hoặc `XCTestExpectation`
10. **Forget Sendable** - Ensure test mocks meet Sendable requirements
11. **Push without strict build** - Always run `./scripts/build-strict.sh` before pushing!

## Swift 6 Testing Checklist

When testing concurrent code:
- [ ] Are async tests using `async throws`?
- [ ] Are actor-isolated methods tested correctly?
- [ ] Is `@MainActor` isolation respected trong tests?
- [ ] Are race conditions tested?
- [ ] Is Task cancellation handled?
- [ ] Are Sendable requirements met trong test mocks?
- [ ] Did you run `./scripts/build-strict.sh` to catch concurrency issues?

### Common Concurrency Test Issues

#### Missing `await` for @MainActor
```swift
// ❌ Fails in GitHub Actions
let value = AppSettings.shared.property

// ✅ Correct
let value = await AppSettings.shared.property
```

#### Task Capture Lists
```swift
// ❌ Sending main actor to nonisolated context
Task { @MainActor in
    await viewModel.doSomething()
}

// ✅ Explicit capture
Task { @MainActor [viewModel] in
    await viewModel.doSomething()
}
```

**Reference**: `docs/implementation/SWIFT_CONCURRENCY_FIXES.md`

---

## Common Testing Scenarios

### Scenario 1: Create Test Target
**User request**: "Set up testing cho project"

**AI should**:
1. Check if test targets exist
2. Guide user to create targets trong Xcode (hoặc provide instructions)
3. Create folder structure
4. Create basic test infrastructure (helpers, mocks)

### Scenario 2: Write Model Tests
**User request**: "Write tests cho SQLNotebook model"

**AI should**:
1. Read `@docs/testing_plan.md` section 6.2
2. Read `SQLNotebook/Models/SQLNotebook.swift` để understand structure
3. Create `SQLNotebookTests/Models/SQLNotebookTests.swift`
4. Write test cases cho encoding/decoding, newDocument(), etc.
5. Ensure tests follow Arrange-Act-Assert pattern

### Scenario 3: Write Integration Tests
**User request**: "Write tests cho database connection"

**AI should**:
1. Read `@docs/testing_plan.md` section 6.6
2. Read `SQLNotebook/Database/DatabaseConnectionManager.swift`
3. Create `SQLNotebookTests/Database/DatabaseConnectionManagerTests.swift`
4. Write tests cho connect, disconnect, execute
5. Note về test database setup requirements

### Scenario 4: Fix Failing Tests
**User request**: "Fix failing tests"

**AI should**:
1. Run tests để see failures
2. Analyze error messages
3. Fix issues trong test code hoặc production code
4. Verify tests pass

---

## Response Format

When reporting test status, use this format:

```markdown
## Test Suite Created
[Name of test file/suite]

## Test Cases Implemented
- ✅ testCase1_Scenario_ExpectedResult
- ✅ testCase2_Scenario_ExpectedResult
- ✅ testCase3_Scenario_ExpectedResult

## Test Infrastructure
[Mocks, helpers, hoặc test utilities created]

## Coverage
[Code coverage percentage hoặc areas covered]

## Test Results
[Pass/fail status, any issues found]
```

Or for comprehensive status report:

```markdown
# Testing Status Report

## 📊 Test Coverage
- Unit Tests: X/Y files tested (Z% coverage)
- Integration Tests: X/Y scenarios tested
- UI Tests: X/Y flows tested

## ✅ Completed
- [x] Test target setup
- [x] Model tests (SQLNotebook, NotebookCell, CellValue)
- [x] Utility tests (SQLSyntaxHighlighter)

## ⏳ In Progress
- [ ] ViewModel tests
- [ ] Integration tests

## 📋 Next Steps
- [ ] Write DatabaseConnectionManager tests
- [ ] Write UI tests for critical flows
- [ ] Set up test database for integration tests
```

## Key Reference Files

- `docs/testing_plan.md` - Comprehensive testing plan. **IMPORTANT**: Always check, verify và update this doc.
- `CLAUDE.md` - Development guidelines
- `docs/TODO.md` - Task breakdown

---

## Your Goal

Maintain **comprehensive test coverage** với:
- Unit tests cho all models và utilities
- Integration tests cho database operations
- UI tests cho critical user flows
- Mock objects cho external dependencies
- Test helpers để reduce code duplication
- Clear test structure following testing plan

Prioritize **test quality over quantity** và **meaningful tests over coverage numbers**.

## Workflow Summary

1. **Read the testing plan**: Understand what needs testing
2. **Identify test category**: Unit, integration, hoặc UI test?
3. **Create test file**: Follow naming convention `[Feature]Tests.swift`
4. **Write test cases**: Implement test methods với AAA pattern
5. **Add test helpers**: Create mocks và utilities as needed
6. **Run tests**: Use Xcode (`Cmd+U`) hoặc CLI
7. **Check coverage**: Verify adequate coverage
8. **Report results**: Summarize what was tested và results

