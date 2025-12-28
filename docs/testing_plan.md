# Testing Plan for SQLNotebook

## Có thể tạo Unit Tests/Testing Suite cho Swift/macOS App không?

**CÓ!** Swift và Xcode cung cấp comprehensive testing framework:

### 1. **XCTest Framework** (Built-in)
- **Unit Tests**: Test individual functions, classes, structs
- **Integration Tests**: Test interactions giữa components
- **UI Tests**: Test user interface flows
- **Performance Tests**: Measure code performance

### 2. **Test Targets trong Xcode**
- **Unit Test Target**: `SQLNotebookTests` - cho business logic tests
- **UI Test Target**: `SQLNotebookUITests` - cho user interface tests
- Tự động integrate với Xcode Test Navigator
- Run tests với `Cmd+U` hoặc từ Test Navigator

### 3. **Testing Capabilities**
- ✅ Test Swift structs, classes, enums
- ✅ Test async/await code (PostgresNIO operations)
- ✅ Test SwiftUI views (với ViewInspector hoặc UI tests)
- ✅ Test Codable serialization/deserialization
- ✅ Mock objects và dependencies
- ✅ Test database operations (với test database)
- ✅ Test document read/write operations

---

## Testing Architecture Plan

### Phase 6.1: Test Target Setup

#### Tạo Test Targets trong Xcode:
1. **Unit Test Target** (`SQLNotebookTests`)
   - File location: `SQLNotebookTests/`
   - Dependencies: Main app target, PostgresNIO (nếu cần)
   - Test các models, utilities, ViewModels

2. **UI Test Target** (`SQLNotebookUITests`)
   - File location: `SQLNotebookUITests/`
   - Dependencies: Main app target
   - Test user interactions, keyboard shortcuts, flows

#### Test Helper Structure:
```
SQLNotebookTests/
├── Models/
│   ├── SQLNotebookTests.swift
│   ├── NotebookCellTests.swift
│   └── CellValueTests.swift
├── Utilities/
│   └── SQLSyntaxHighlighterTests.swift
├── ViewModels/
│   └── NotebookViewModelTests.swift
├── Database/
│   └── DatabaseConnectionManagerTests.swift
├── Document/
│   └── SQLNotebookDocumentTests.swift
└── Helpers/
    ├── MockDatabaseConnectionManager.swift
    └── TestHelpers.swift
```

---

## Detailed Test Cases

### 6.2 Unit Tests - Data Models

#### `SQLNotebookTests.swift`
```swift
import XCTest
@testable import SQLNotebook

final class SQLNotebookTests: XCTestCase {
    func testEncodingDecoding() throws {
        // Test round-trip encoding/decoding
    }
    
    func testNewDocument() {
        // Test newDocument() creates notebook với empty SQL cell
    }
}
```

**Test Cases:**
- ✅ Encode `SQLNotebook` to JSON
- ✅ Decode JSON to `SQLNotebook`
- ✅ Round-trip (encode → decode → verify)
- ✅ `newDocument()` creates notebook với default cell
- ✅ Notebook với multiple cells
- ✅ Notebook với connection config (không lưu password)

#### `NotebookCellTests.swift`
**Test Cases:**
- ✅ Encode/decode cell với all properties
- ✅ Cell với result
- ✅ Cell với execution count
- ✅ Cell với isRunning state

#### `CellValueTests.swift`
**Test Cases:**
- ✅ Encode/decode all enum cases:
  - `.string("test")`
  - `.int(42)`
  - `.double(3.14)`
  - `.bool(true)`
  - `.null`
  - `.json("{\"key\":\"value\"}")`
  - `.date(Date())`
  - `.data(Data())`
- ✅ `displayString` property cho all types
- ✅ `fullString` property cho all types
- ✅ `isNull` và `isJSON` computed properties

---

### 6.3 Unit Tests - Utilities

#### `SQLSyntaxHighlighterTests.swift`
**Test Cases:**
- ✅ Keyword highlighting (case-insensitive)
  - Test: `SELECT`, `select`, `Select` đều được highlight
- ✅ Function highlighting với parentheses
  - Test: `COUNT(` được highlight, `COUNT` không có `(` thì không
- ✅ String highlighting
  - Single-quote: `'hello world'`
  - Dollar-quote: `$$text$$`
- ✅ Comment highlighting
  - Single-line: `-- comment`
  - Multi-line: `/* comment */`
- ✅ Number highlighting: `123`, `45.67`
- ✅ Operator highlighting: `=`, `<>`, `+`, `-`, etc.
- ✅ Complex SQL query highlighting

---

### 6.4 Unit Tests - Document Operations

#### `SQLNotebookDocumentTests.swift`
**Test Cases:**
- ✅ `read()` với valid JSON file
- ✅ `read()` với invalid JSON (throws error)
- ✅ `read()` với missing file (throws error)
- ✅ `write()` tạo valid JSON file
- ✅ Round-trip: write → read → verify
- ✅ Document với empty cells
- ✅ Document với cells có results
- ✅ Document với connection config (password không được lưu)

---

### 6.5 Unit Tests - ViewModel Logic

#### `NotebookViewModelTests.swift`
**Test Cases:**
- ✅ `addCell()` - add ở đầu, giữa, cuối
- ✅ `deleteCell()` - delete existing cell
- ✅ `moveCell()` - move từ position A → B
- ✅ `selectCell()` - selection state
- ✅ `clearAllOutputs()` - clear all results
- ✅ Execution count increment
- ✅ Cell running state management

**Note:** ViewModel tests có thể cần `@MainActor` vì SwiftUI ViewModels thường chạy trên main thread.

---

### 6.6 Integration Tests - Database Connection

#### `DatabaseConnectionManagerTests.swift`
**Test Cases:**
- ✅ `connect()` với valid PostgreSQL config
- ✅ `connect()` với invalid host (throws error)
- ✅ `connect()` với invalid credentials (throws error)
- ✅ `testConnection()` success case
- ✅ `testConnection()` failure case
- ✅ `disconnect()` cleanup
- ✅ Connection state transitions
- ✅ SSL/TLS modes:
  - `.disable`
  - `.require`
  - `.verifyCA`
  - `.verifyFull`
- ✅ Connection string parsing

**Test Database Setup:**
- Sử dụng local PostgreSQL instance hoặc Docker container
- Test database với sample tables
- Cleanup sau mỗi test

---

### 6.7 Integration Tests - Query Execution

#### `QueryExecutionTests.swift`
**Test Cases:**
- ✅ SELECT query → parse results
- ✅ INSERT query → verify affected rows
- ✅ UPDATE query → verify affected rows
- ✅ DELETE query → verify affected rows
- ✅ DDL (CREATE TABLE) → verify success
- ✅ Multiple statements → execute sequentially
- ✅ Invalid SQL syntax → error handling
- ✅ Database errors (table not found) → error handling
- ✅ Type mapping:
  - VARCHAR → `.string`
  - INTEGER → `.int`
  - BIGINT → `.int`
  - DECIMAL → `.double`
  - BOOLEAN → `.bool`
  - JSON/JSONB → `.json`
  - DATE/TIMESTAMP → `.date`
  - NULL → `.null`
- ✅ Result row limiting (max fetch rows)
- ✅ Execution time measurement

---

### 6.8 Integration Tests - Schema Loading

#### `SchemaLoadingTests.swift`
**Test Cases:**
- ✅ `fetchTables()` returns correct tables
- ✅ `fetchColumns()` returns correct columns với types
- ✅ Schema với empty database
- ✅ Schema loading error handling
- ✅ Table row count calculation

---

### 6.9 UI Tests - Basic Flows

#### `NotebookUITests.swift`
**Test Cases:**
- ✅ Create new notebook (`Cmd+N`)
- ✅ Open notebook (`Cmd+O`)
- ✅ Save notebook (`Cmd+S`)
- ✅ Add code cell (`Cmd+B`)
- ✅ Delete cell (`Cmd+Backspace`)
- ✅ Duplicate cell (`Cmd+D`)
- ✅ Run cell (`Cmd+Enter`)
- ✅ Run all cells (`Cmd+Shift+Enter`)
- ✅ Toggle right sidebar (`Cmd+Shift+R`)
- ✅ Toggle left sidebar (`Cmd+Shift+L`)

**UI Test Example:**
```swift
import XCTest

final class NotebookUITests: XCTestCase {
    var app: XCUIApplication!
    
    override func setUp() {
        app = XCUIApplication()
        app.launch()
    }
    
    func testCreateNewNotebook() {
        app.typeKey("n", modifierFlags: .command)
        // Verify new notebook created
    }
}
```

---

### 6.10 UI Tests - Query Execution Flow

**Test Cases:**
- ✅ Enter SQL query trong cell
- ✅ Execute query
- ✅ Verify results display trong table
- ✅ Verify columns và rows
- ✅ Verify execution time
- ✅ Verify error display cho invalid queries
- ✅ Test với empty result set
- ✅ Test với large result set (scrolling)

---

### 6.11 UI Tests - Connection Flow

**Test Cases:**
- ✅ Open connection sheet
- ✅ Enter connection details
- ✅ Test connection button
- ✅ Connect to database
- ✅ Verify connection status trong footer
- ✅ Verify schema loads trong left sidebar
- ✅ Disconnect from database

---

### 6.12 UI Tests - Document Persistence

**Test Cases:**
- ✅ Save notebook với cells và results
- ✅ Close app
- ✅ Reopen notebook
- ✅ Verify cells content preserved
- ✅ Verify results preserved (nếu settings allow)
- ✅ Verify connection config preserved (không có password)

---

## Test Infrastructure

### Mock Objects

#### `MockDatabaseConnectionManager.swift`
```swift
actor MockDatabaseConnectionManager {
    var connectionState: ConnectionState = .disconnected
    var mockResults: CellResult?
    var shouldThrowError = false
    
    func connect(config: ConnectionConfig) async throws {
        if shouldThrowError {
            throw DatabaseError.connectionFailed
        }
        connectionState = .connected
    }
    
    func execute(query: String) async throws -> CellResult {
        if shouldThrowError {
            throw DatabaseError.queryFailed
        }
        return mockResults ?? CellResult()
    }
}
```

### Test Helpers

#### `TestHelpers.swift`
```swift
extension XCTestCase {
    func createTestNotebook() -> SQLNotebook {
        // Helper để tạo test notebook
    }
    
    func createTestCell() -> NotebookCell {
        // Helper để tạo test cell
    }
}
```

### Test Database Setup

- Sử dụng Docker PostgreSQL container cho integration tests
- Hoặc local PostgreSQL instance
- Sample data: tables, rows
- Cleanup sau mỗi test

---

## Test Coverage Goals

- **Unit Tests**: 80%+ coverage cho models, utilities, ViewModels
- **Integration Tests**: Cover all database operations
- **UI Tests**: Cover critical user flows

---

## Running Tests

### Trong Xcode:
1. `Cmd+U` - Run all tests
2. Test Navigator (`Cmd+6`) - Run individual tests
3. Code coverage: Product → Scheme → Edit Scheme → Test → Options → Code Coverage

### Command Line:
```bash
xcodebuild test -scheme SQLNotebook -destination 'platform=macOS'
```

---

## Best Practices

1. **Arrange-Act-Assert Pattern**: Structure tests clearly
2. **Test Naming**: `testFunctionName_Scenario_ExpectedResult()`
3. **Isolation**: Mỗi test independent, không depend on others
4. **Mock External Dependencies**: Database, file system, network
5. **Async Testing**: Sử dụng `XCTestExpectation` cho async code
6. **Cleanup**: Clean up test data sau mỗi test

---

## Next Steps

1. ✅ Create test targets trong Xcode
2. ✅ Set up test infrastructure (helpers, mocks)
3. ✅ Start với Unit Tests (models, utilities)
4. ✅ Add Integration Tests (database operations)
5. ✅ Add UI Tests (critical flows)
6. ✅ Set up CI/CD test execution (optional)

