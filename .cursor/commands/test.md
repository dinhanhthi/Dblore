# test

Manages testing aspects for SQLNotebook - creates test targets, writes test cases, sets up test infrastructure, and ensures comprehensive test coverage following the testing plan.

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

### Writing Model Tests

**Reference**: `@docs/testing_plan.md` section "6.2 Unit Tests - Data Models"

**Template**:
```swift
import XCTest
@testable import SQLNotebook

final class SQLNotebookTests: XCTestCase {
    func testEncodingDecoding() throws {
        // Arrange
        let notebook = SQLNotebook.newDocument()
        
        // Act
        let encoder = JSONEncoder()
        let data = try encoder.encode(notebook)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SQLNotebook.self, from: data)
        
        // Assert
        XCTAssertEqual(notebook.id, decoded.id)
        XCTAssertEqual(notebook.cells.count, decoded.cells.count)
    }
    
    func testNewDocument() {
        // Arrange & Act
        let notebook = SQLNotebook.newDocument()
        
        // Assert
        XCTAssertEqual(notebook.cells.count, 1)
        XCTAssertEqual(notebook.cells.first?.cellType, .sql)
    }
}
```

**Test Files to Create**:
- `SQLNotebookTests/Models/SQLNotebookTests.swift`
- `SQLNotebookTests/Models/NotebookCellTests.swift`
- `SQLNotebookTests/Models/CellValueTests.swift`
- `SQLNotebookTests/Models/ConnectionConfigTests.swift`

### Writing Utility Tests

**Reference**: `@docs/testing_plan.md` section "6.3 Unit Tests - Utilities"

**Template**:
```swift
import XCTest
@testable import SQLNotebook

final class SQLSyntaxHighlighterTests: XCTestCase {
    func testKeywordHighlighting() {
        // Arrange
        let sql = "SELECT * FROM users WHERE id = 1"
        
        // Act
        let highlighted = SQLSyntaxHighlighter.highlight(sql)
        
        // Assert
        // Check that keywords are highlighted with correct color
        // (This requires checking NSAttributedString attributes)
    }
    
    func testCaseInsensitiveKeywords() {
        // Test: SELECT, select, Select all get highlighted
    }
    
    func testStringHighlighting() {
        // Test single-quote và dollar-quote strings
    }
    
    func testCommentHighlighting() {
        // Test single-line và multi-line comments
    }
}
```

**Test Files to Create**:
- `SQLNotebookTests/Utilities/SQLSyntaxHighlighterTests.swift`
- `SQLNotebookTests/Utilities/JSONSyntaxHighlighterTests.swift` (if exists)

### Writing Document Tests

**Reference**: `@docs/testing_plan.md` section "6.4 Unit Tests - Document Operations"

**Template**:
```swift
import XCTest
@testable import SQLNotebook

final class SQLNotebookDocumentTests: XCTestCase {
    var tempURL: URL!
    
    override func setUp() {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlnb")
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
    }
    
    func testReadWriteRoundTrip() throws {
        // Arrange
        let original = SQLNotebook.newDocument()
        let document = SQLNotebookDocument(notebook: original)
        
        // Act
        try document.write(to: tempURL)
        let loaded = try SQLNotebookDocument.read(from: tempURL)
        
        // Assert
        XCTAssertEqual(original.id, loaded.notebook.id)
    }
}
```

### Writing ViewModel Tests

**Reference**: `@docs/testing_plan.md` section "6.5 Unit Tests - ViewModel Logic"

**Note**: ViewModels thường cần `@MainActor` vì SwiftUI ViewModels chạy trên main thread.

**Template**:
```swift
import XCTest
@testable import SQLNotebook

@MainActor
final class NotebookViewModelTests: XCTestCase {
    var viewModel: NotebookViewModel!
    
    override func setUp() {
        viewModel = NotebookViewModel(notebook: SQLNotebook.newDocument())
    }
    
    func testAddCell() {
        // Arrange
        let initialCount = viewModel.notebook.cells.count
        
        // Act
        viewModel.addCell(type: .sql, after: nil)
        
        // Assert
        XCTAssertEqual(viewModel.notebook.cells.count, initialCount + 1)
    }
    
    func testDeleteCell() {
        // Test delete existing cell
    }
    
    func testMoveCell() {
        // Test reorder cells
    }
}
```

---

## Phase 6.6-6.8: Integration Tests

### Writing Database Connection Tests

**Reference**: `@docs/testing_plan.md` section "6.6 Integration Tests - Database Connection"

**Requirements**:
- Test database setup (local PostgreSQL hoặc Docker)
- Cleanup sau mỗi test
- Mock hoặc real database connection

**Template**:
```swift
import XCTest
@testable import SQLNotebook

final class DatabaseConnectionManagerTests: XCTestCase {
    var manager: DatabaseConnectionManager!
    var testConfig: ConnectionConfig!
    
    override func setUp() {
        manager = DatabaseConnectionManager()
        testConfig = ConnectionConfig(
            host: "localhost",
            port: 5432,
            database: "test_db",
            username: "test_user",
            password: "test_password"
        )
    }
    
    func testConnectSuccess() async throws {
        // Arrange
        // (Requires test database setup)
        
        // Act
        try await manager.connect(config: testConfig)
        
        // Assert
        // Verify connection state
    }
    
    func testConnectInvalidHost() async throws {
        // Test error handling
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

## Phase 6.9-6.12: UI Tests

### Writing UI Tests

**Reference**: `@docs/testing_plan.md` section "6.9-6.12 UI Tests"

**Template**:
```swift
import XCTest

final class NotebookUITests: XCTestCase {
    var app: XCUIApplication!
    
    override func setUp() {
        app = XCUIApplication()
        app.launch()
    }
    
    func testCreateNewNotebook() {
        // Act
        app.typeKey("n", modifierFlags: .command)
        
        // Assert
        // Verify new notebook created
    }
    
    func testAddCodeCell() {
        // Test Cmd+B adds new cell
    }
    
    func testRunCell() {
        // Test Cmd+Enter executes cell
    }
}
```

**UI Test Files to Create**:
- `SQLNotebookUITests/NotebookUITests.swift`
- `SQLNotebookUITests/QueryExecutionUITests.swift`
- `SQLNotebookUITests/ConnectionUITests.swift`
- `SQLNotebookUITests/DocumentPersistenceUITests.swift`

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
```bash
xcodebuild test -scheme SQLNotebook -destination 'platform=macOS'
```

---

## Test Coverage Goals

- **Unit Tests**: 80%+ coverage cho models, utilities, ViewModels
- **Integration Tests**: Cover all database operations
- **UI Tests**: Cover critical user flows

---

## Best Practices

### ✅ Always Do
1. **Read testing plan** trước khi viết tests
2. **Follow Arrange-Act-Assert** pattern
3. **Use descriptive test names**: `testFunctionName_Scenario_ExpectedResult()`
4. **Keep tests isolated** - mỗi test independent
5. **Mock external dependencies** - database, file system, network
6. **Clean up** test data sau mỗi test
7. **Test edge cases** - empty data, nil values, errors
8. **Use async testing** với `XCTestExpectation` cho async code

### ❌ Never Do
1. **Skip reading testing plan** - always check `@docs/testing_plan.md`
2. **Write tests without understanding** the code being tested
3. **Depend on test execution order** - tests must be independent
4. **Use real database** trong unit tests (use mocks)
5. **Skip cleanup** - always clean up test data
6. **Test implementation details** - test behavior, not internals
7. **Write flaky tests** - tests should be deterministic

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

When reporting test status:

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

