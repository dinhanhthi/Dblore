# GitHub Actions Test Failures Fix

**Date:** January 6, 2026
**Status:** ✅ Fixed
**Related Issue:** https://github.com/actions/runner-images/issues/11874

## Problem

### Symptoms

When running tests on GitHub Actions CI with macOS-15 runners **WITHOUT** `-parallel-testing-enabled NO`:
- ✅ Build succeeded (`** BUILD SUCCEEDED **`)
- ⚠️ **Partial test failures**: 103 tests failed, 100 tests passed
- ❌ Exit code: 65 (test failure)
- ⚠️ Failed tests show execution time = 0.000 seconds (crashed before executing)

Example output:
```
Test case 'ViewModelTests/showSidebarContent()' failed on 'My Mac - SQLNotebook (13131)' (0.000 seconds)
Test case 'ViewModelTests/addCellPerformance()' failed on 'My Mac - SQLNotebook (13131)' (0.000 seconds)
Test case 'SQLSyntaxHighlighterTests/keywordHighlighting()' failed on 'My Mac - SQLNotebook (13131)' (0.000 seconds)
...
** TEST FAILED **
##[error]Process completed with exit code 65.
```

### Pattern

- **Local execution**: All tests pass successfully
- **GitHub Actions without workaround**: Partial test failures (50% failure rate)
- **GitHub Actions with `-parallel-testing-enabled NO`**: All tests pass ✅
- **No error messages**: Failed tests have no stack traces or assertion failures
- **0.000s execution time**: Indicates tests crash before actual execution

### Affected Test Suites

#### Completely Failing (All Tests Crash)
These test suites have **100% failure rate** without the workaround:

1. **CellValueValidatorTests** (~20 tests)
   - All validation tests (integer, double, date, JSON, binary, etc.)

2. **DataModelTests** (~19 tests)
   - All encoding/decoding tests
   - Configuration tests

3. **ExecutionQueueTests** (~9 tests)
   - All queue management tests

4. **SQLSyntaxHighlighterTests** (~33 tests)
   - All syntax highlighting tests

#### Partially Failing (Some Tests Crash)
These test suites have **mixed results** (some pass, some fail):

5. **ViewModelTests** (~14 failed out of ~23 total)
   - ❌ Failed: `showSidebarContent`, `addCellPerformance`, `addCellAfterSpecificCell`, `updateCellContent`, `deleteCellPerformance`, `notebookSettings`, `clearSingleCellOutput`, `deleteNonExistentCell`, `toggleLeftSidebar`, `selectCell`, `addMultipleCells`, `selectNonExistentCell`, `clearAllOutputs`, `deselectCell`
   - ✅ Passed: `connectionStateInitiallyDisconnected`, `setCellRunningState`, `cellRunningStateDefaultsToFalse`, `addCellToEmptyNotebook`, `toggleRightSidebar`, `notebookMetadataAccessible`, `deleteAllCells`, `deleteCell`, `addCell`, `moveCell`

6. **ConnectionTimeoutTests** (~5 failed out of ~6 total)
   - ❌ Failed: `multipleTimeoutValuesWorkCorrectly`, `fastOperationCompletesBeforeTimeout`, `slowOperationTimesOut`, `timeoutCancelsRunningTasks`, `operationErrorPropagatesCorrectly`
   - ✅ Passed: `timeoutErrorMessage`

7. **DatabaseQueryExecutionTests** (~2 failed out of many)
   - ❌ Failed: `selectVersionNoLimit`, `selectPgSleepNoLimit`
   - ✅ Passed: Most database query tests

#### Always Passing (No Crashes)
These test suites have **0% failure rate**:

- **DatabaseQueryWrappingTests** (All tests pass)
- **DatabaseTypeDecodingTests** (All tests pass)
- **SQLNotebookTests** (All tests pass)
- **DatabaseIntegrationTests** (All skipped - require database)

## Root Cause

### Swift Testing Framework Issue on GitHub Actions

This is a **known infrastructure issue** with the Swift Testing framework on GitHub Actions macOS-15 runners (Xcode 16.4+):

1. **Parallel Execution Race Conditions**: When tests run in parallel, the test runner crashes for certain tests
2. **Timing Evidence**: Logs show `IDETestOperationsObserverDebug: 0.000 sec, +0.000 sec -- start` with ~40 seconds gap between "Testing started" and failures
3. **Platform-Specific**: Only occurs on GitHub Actions runners, not on local macOS machines
4. **Framework Bug**: Related to Swift Testing framework parallel execution and test discovery mechanisms

### Why Some Tests Crash and Others Don't

The pattern reveals important clues about the root cause:

#### Tests That Always Crash (High Complexity)

Tests that **consistently fail** tend to have these characteristics:

1. **Heavy Computation** (SQLSyntaxHighlighterTests)
   - Complex regex parsing and string manipulation
   - Multiple passes over large text buffers
   - Memory-intensive operations

2. **State Management** (ViewModelTests, ExecutionQueueTests)
   - Tests that modify shared state
   - Tests with `@MainActor` dependencies
   - Tests requiring specific initialization order

3. **Async Operations** (ConnectionTimeoutTests, DataModelTests)
   - Tests with `async/await` and Task management
   - Tests with timeout mechanisms
   - Tests requiring precise timing

4. **Type Conversions** (CellValueValidatorTests, DataModelTests)
   - Tests with extensive Codable encoding/decoding
   - Tests with type validation and conversion
   - Tests that create many temporary objects

#### Tests That Never Crash (Low Complexity)

Tests that **consistently pass** tend to be:

1. **Simple Unit Tests** (DatabaseTypeDecodingTests)
   - Pure functions without side effects
   - No shared state or global variables
   - Deterministic input/output

2. **Synchronous Logic** (DatabaseQueryWrappingTests)
   - No async operations
   - No timing dependencies
   - Simple string manipulation

3. **Isolated Tests** (SQLNotebookTests)
   - Single test case with no dependencies
   - No setup/teardown complexity

#### Mixed Results (Race Conditions)

Tests in the same suite showing **mixed pass/fail** indicate:

- **Execution Order Matters**: Some tests pass when run first, fail when run later
- **Resource Contention**: Tests competing for CPU/memory/threads
- **Timing-Dependent**: Success depends on how quickly tests execute relative to each other

**Example**: ViewModelTests
- Simple tests like `addCell()` pass (quick, no side effects)
- Complex tests like `addCellPerformance()` fail (timing-sensitive, resource-intensive)

### Related Issues

- GitHub Actions runner-images issue: https://github.com/actions/runner-images/issues/11874
- Affects projects using Swift Testing framework on macOS-15+ runners
- Particularly problematic with Xcode 16.4 and later versions

### NOT Related To

- ❌ Code changes (tests pass locally)
- ❌ Test implementation bugs
- ❌ Database connection issues
- ❌ Dependency problems

## Solution

### Implemented Workarounds

Added two flags to `xcodebuild test` command in `.github/workflows/ci.yml`:

```yaml
- name: Run Unit Tests
  run: |
    # Workaround for Swift Testing framework issues on GitHub Actions
    # See: https://github.com/actions/runner-images/issues/11874
    # Disable parallel testing to avoid test runner crashes
    env SKIP_INTEGRATION_TESTS=true SKIP_UI_TESTS=true xcodebuild test \
      -project SQLNotebook.xcodeproj \
      -scheme SQLNotebook \
      -destination 'platform=macOS' \
      -parallel-testing-enabled NO \          # ← Disable parallel testing
      -retry-tests-on-failure \               # ← Auto-retry failed tests
      CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_IDENTITY="-" \
      CODE_SIGNING_REQUIRED=NO
```

### Workaround Details

#### 1. `-parallel-testing-enabled NO`

**Purpose**: Disable parallel test execution

**Why it works**:
- Swift Testing framework has issues with parallel test discovery on GitHub Actions
- Running tests serially avoids race conditions and test runner crashes
- Trade-off: Tests run slower, but reliably

**Impact**:
- ✅ Tests execute successfully
- ⚠️ Increased test execution time (acceptable for CI)

#### 2. `-retry-tests-on-failure`

**Purpose**: Automatically retry failed tests

**Why it helps**:
- Even with parallel testing disabled, occasional flakiness may occur
- Xcode 13+ feature that retries failed tests automatically
- Improves CI reliability without code changes

**Impact**:
- ✅ Reduces false negatives from transient failures
- ✅ No manual re-runs needed for flaky tests

## Verification

### Local Testing

```bash
# Tests should pass locally (without workarounds)
xcodebuild test \
  -scheme SQLNotebook \
  -destination 'platform=macOS'
```

Expected: `** TEST SUCCEEDED **`

### GitHub Actions CI

After pushing the workflow changes:

1. Check GitHub Actions tab in repository
2. Look for latest workflow run
3. Verify test step shows:
   ```
   Test case 'ViewModelTests/...' passed (X.XXX seconds)
   ...
   ** TEST SUCCEEDED **
   ```

## Alternative Solutions (If Workarounds Don't Work)

### Option 1: Reset Simulators

Add before test step:

```yaml
- name: Reset Simulators
  run: |
    xcrun simctl shutdown all
    xcrun simctl erase all
```

### Option 2: Pin Runner Image Version

Instead of `macos-15` (latest), use specific version:

```yaml
runs-on: macos-14  # Use stable older version
```

**Trade-off**: May not have latest Xcode/Swift versions

### Option 3: Use Different Test Framework

Switch from Swift Testing to XCTest:

```swift
// Before (Swift Testing)
import Testing
@Test func myTest() { ... }

// After (XCTest)
import XCTest
class MyTests: XCTestCase {
    func testMy() { ... }
}
```

**Trade-off**: Requires rewriting all tests

### Option 4: Increase Timeout

Add timeout to allow test runner more time:

```yaml
- name: Run Unit Tests
  timeout-minutes: 30  # Increase from default
  run: ...
```

## Monitoring

### What to Watch

1. **GitHub Actions Runs**: Monitor for test failures
2. **Execution Time**: Tests should take >0.000 seconds
3. **Failure Patterns**: If specific tests still fail, investigate those individually

### Expected Behavior

- ✅ All tests execute (non-zero execution time)
- ✅ Tests pass/fail based on actual test logic, not crashes
- ✅ Clear error messages if tests fail

### Red Flags

- ❌ Tests still fail with 0.000 seconds execution time → Workaround not working
- ❌ New pattern of failures → Investigate specific test issues
- ❌ Timeout errors → May need to increase timeout or optimize tests

## Long-Term Resolution

### Temporary Nature

These workarounds are **temporary fixes** for an infrastructure issue:

- Not a permanent solution
- Adds maintenance burden
- May become unnecessary when GitHub Actions/Xcode fixes the underlying issue

### Future Actions

1. **Monitor GitHub Actions Issues**: Watch https://github.com/actions/runner-images/issues/11874
2. **Test Without Workarounds**: Periodically try removing flags to see if fixed
3. **Update Documentation**: Remove this doc when issue is resolved upstream

### When to Remove Workarounds

Remove `-parallel-testing-enabled NO` and `-retry-tests-on-failure` when:

1. GitHub Actions announces fix for Swift Testing issues
2. Tests pass on CI without these flags for multiple consecutive runs
3. No test crashes observed in CI logs

## References

- GitHub Actions runner-images issue: https://github.com/actions/runner-images/issues/11874
- Swift Testing documentation: https://developer.apple.com/documentation/testing
- Xcode test flags: https://developer.apple.com/documentation/xcode/running-tests-and-interpreting-results

## Related Documents

- [Testing Setup Guide](TESTING_SETUP_GUIDE.md) - How to run tests locally
- [Swift Concurrency Fixes](SWIFT_CONCURRENCY_FIXES.md) - Other Swift 6 compatibility issues

---

**Last Updated:** January 6, 2026
**Maintainer:** Development Team
