# Test Templates

This directory contains test file templates for the SQLNotebook application. These templates provide comprehensive test coverage examples for different parts of the application.

## Available Templates

### 1. DataModelTests.swift.template
**Purpose:** Unit tests for data models (SQLNotebook, NotebookCell, CellValue, etc.)

**Covers:**
- Encoding/Decoding (JSON serialization) for all models
- CellValue enum cases (string, int, double, bool, null, json, date, data)
- ConnectionConfig (verifies password is not encoded)
- NotebookMetadata and NotebookSettings
- Display string formatting
- Performance tests for large notebooks

**Copy to:** `SQLNotebookTests/DataModelTests.swift`

### 2. SQLSyntaxHighlighterTests.swift.template
**Purpose:** Unit tests for SQL syntax highlighting utility

**Covers:**
- Keyword detection (case-insensitive: SELECT, FROM, WHERE, etc.)
- Function detection (COUNT, MAX, SUM, AVG, etc.)
- String literals (single-quote, escaped quotes, dollar-quoted)
- Number highlighting (integers, decimals, negative, scientific notation)
- Comment highlighting (single-line `--`, multi-line `/* */`)
- Operators (comparison, arithmetic, logical)
- Complex queries (CTEs, subqueries, JOINs)
- PostgreSQL-specific syntax (JSONB, arrays, cast operator `::`)
- Edge cases (empty strings, whitespace, unicode)
- Performance tests

**Copy to:** `SQLNotebookTests/SQLSyntaxHighlighterTests.swift`

### 3. ViewModelTests.swift.template
**Purpose:** Unit tests for NotebookViewModel business logic

**Covers:**
- Cell management (add, delete, move)
- Cell selection state
- Clear outputs (all cells, single cell)
- Execution count tracking
- Running state management
- Sidebar toggles (left, right)
- Sidebar content switching
- Connection state
- Multiple cells operations
- Edge cases (empty notebook, non-existent cells)
- Performance tests

**Copy to:** `SQLNotebookTests/ViewModelTests.swift`

## How to Use These Templates

### Step 1: Create Test Targets
Follow the instructions in [TESTING_SETUP_GUIDE.md](../TESTING_SETUP_GUIDE.md) to create test targets in Xcode.

### Step 2: Copy Templates to Test Targets

After creating `SQLNotebookTests` target:

```bash
# From project root
cp docs/test-templates/DataModelTests.swift.template SQLNotebookTests/DataModelTests.swift
cp docs/test-templates/SQLSyntaxHighlighterTests.swift.template SQLNotebookTests/SQLSyntaxHighlighterTests.swift
cp docs/test-templates/ViewModelTests.swift.template SQLNotebookTests/ViewModelTests.swift
```

### Step 3: Add Files to Xcode Project

1. In Xcode Project Navigator, right-click on `SQLNotebookTests` folder
2. Select **Add Files to "SQLNotebook"...**
3. Select the copied test files
4. Ensure **Target Membership** is set to `SQLNotebookTests`
5. Click **Add**

### Step 4: Build and Run Tests

Press **Cmd+U** to run all tests, or:
- **Cmd+6** to open Test Navigator
- Click the ▶ icon next to specific test classes or methods

## Additional Test Files to Create

These templates cover the basics. You should also create:

### Integration Tests

**DatabaseConnectionManagerTests.swift**
- Test actual database connections (requires test database)
- Test query execution with real PostgreSQL
- Test connection pooling and cleanup
- Test SSL/TLS modes
- Test error handling

**SchemaLoadingTests.swift**
- Test fetching tables from information_schema
- Test fetching columns for each table
- Test row count calculations
- Test schema loading errors

### UI Tests

**BasicFlowsUITests.swift**
- Test creating new notebook (Cmd+N)
- Test saving notebook (Cmd+S)
- Test adding/deleting cells (Cmd+B, Cmd+Backspace)
- Test running cells (Cmd+Enter)
- Test keyboard navigation

**ConnectionFlowUITests.swift**
- Test opening connection sheet
- Test entering connection details
- Test connection/disconnection
- Test error display

**QueryExecutionUITests.swift**
- Test entering SQL in cell
- Test executing query
- Test verifying results display
- Test error handling

## Writing Effective Tests

### Best Practices

1. **Arrange-Act-Assert Pattern**
   ```swift
   func testExample() {
       // Arrange - Set up test data
       let input = "test"

       // Act - Execute the code being tested
       let result = functionUnderTest(input)

       // Assert - Verify the results
       XCTAssertEqual(result, expectedOutput)
   }
   ```

2. **Test One Thing Per Test**
   - Each test should verify a single behavior
   - Keep tests focused and readable

3. **Use Descriptive Test Names**
   ```swift
   func testAddCellInsertsAtCorrectPosition() { }  // Good
   func testAddCell() { }  // Less clear
   ```

4. **Clean Up in tearDown**
   ```swift
   override func tearDownWithError() throws {
       viewModel = nil
       testData = nil
   }
   ```

5. **Test Edge Cases**
   - Empty inputs
   - Nil values
   - Maximum/minimum values
   - Invalid inputs

6. **Use XCTAssert Variants**
   - `XCTAssertEqual` - Check equality
   - `XCTAssertTrue/False` - Check boolean
   - `XCTAssertNil/NotNil` - Check optionals
   - `XCTAssertThrowsError` - Check errors
   - `XCTAssertNoThrow` - Verify no errors

### Performance Testing

```swift
func testPerformance() {
    measure {
        // Code to measure performance
    }
}
```

### Async Testing

```swift
func testAsyncOperation() async throws {
    let result = await asyncFunction()
    XCTAssertNotNil(result)
}
```

## Test Coverage Goals

Aim for these coverage targets:

- **Data Models:** 90%+ (critical for data integrity)
- **Utilities:** 80%+ (syntax highlighter, formatters)
- **ViewModels:** 70%+ (business logic)
- **Integration Tests:** 60%+ (database operations)
- **UI Tests:** Focus on critical paths, not coverage %

## Running Tests

### Run All Tests
```bash
# Command line
xcodebuild test -scheme SQLNotebook -destination 'platform=macOS'

# Xcode
Cmd+U
```

### Run Specific Test Class
```bash
xcodebuild test -scheme SQLNotebook -destination 'platform=macOS' -only-testing:SQLNotebookTests/DataModelTests
```

### Run Specific Test Method
```bash
xcodebuild test -scheme SQLNotebook -destination 'platform=macOS' -only-testing:SQLNotebookTests/DataModelTests/testSQLNotebookEncodingDecoding
```

## Continuous Integration (Optional)

Consider setting up CI with:
- GitHub Actions
- GitLab CI
- Jenkins
- CircleCI

Example GitHub Actions workflow:
```yaml
name: Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v2
      - name: Run tests
        run: xcodebuild test -scheme SQLNotebook -destination 'platform=macOS'
```

## Next Steps

1. ✅ Set up test targets (see TESTING_SETUP_GUIDE.md)
2. ✅ Copy templates to test targets
3. ✅ Run initial tests to verify setup
4. 🔄 Customize tests for your specific needs
5. 🔄 Add integration tests with database
6. 🔄 Add UI tests for critical flows
7. 🔄 Set up code coverage tracking
8. 🔄 Consider CI/CD integration

## Resources

- [XCTest Documentation](https://developer.apple.com/documentation/xctest)
- [Testing Tips - Apple WWDC](https://developer.apple.com/videos/play/wwdc2018/417/)
- [Test-Driven Development in Swift](https://www.swiftbysundell.com/basics/test-driven-development/)

---

**Status:** Templates ready for use
**Last Updated:** December 2025
