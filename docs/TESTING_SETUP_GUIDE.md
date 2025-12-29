# Testing Setup Guide - SQLNotebook

This guide provides step-by-step instructions for setting up the testing infrastructure for the SQLNotebook macOS application using XCTest framework.

**Target Xcode Version:** Xcode 26+ on macOS 16+
**Last Updated:** December 2025

---

## Overview

We'll create two test targets:
1. **SQLNotebookTests** - Unit tests and integration tests
2. **SQLNotebookUITests** - UI/end-to-end tests

---

## Method 1: Using Xcode UI (Recommended)

### Step 1: Open Project in Xcode

1. Open `/Users/thi/git/SQLNotebook/SQLNotebook.xcodeproj` in Xcode
2. Wait for indexing to complete

### Step 2: Add Unit Test Target

#### Option A: Using File Menu
1. Go to **File** → **New** → **Target...**
2. In the template chooser:
   - Select **macOS** tab at the top
   - Scroll down to **Testing** section
   - Select **Unit Testing Bundle** (or **Test Bundle** in newer Xcode versions)
   - Click **Next**

#### Option B: Using Project Navigator
1. Click on the **SQLNotebook** project file in the Project Navigator (left sidebar)
2. You'll see the project and targets list in the main editor
3. At the bottom of the targets list, click the **"+"** button
4. Follow same template selection as Option A above

#### Configure Unit Test Target
- **Product Name:** `SQLNotebookTests`
- **Team:** Select your development team
- **Organization Identifier:** Use the same as your main app (check SQLNotebook target)
- **Language:** Swift
- **Project:** SQLNotebook
- **Embed in Application:** SQLNotebook (or **Host Application:** SQLNotebook)
- Click **Finish**

### Step 3: Add UI Test Target

1. Repeat Step 2, but this time:
   - Select **UI Testing Bundle** from the Testing section
   - **Product Name:** `SQLNotebookUITests`
   - **Target to be Tested:** SQLNotebook
   - Click **Finish**

### Step 4: Verify Test Targets Created

1. In Project Navigator, you should now see two new folders:
   - `SQLNotebookTests/` (with `SQLNotebookTests.swift` file)
   - `SQLNotebookUITests/` (with `SQLNotebookUITests.swift` file)

2. In the Project/Targets list, you should see:
   - SQLNotebook (main app)
   - SQLNotebookTests
   - SQLNotebookUITests

### Step 5: Configure Test Schemes

1. Click the **Scheme** dropdown menu (next to the Run/Stop buttons, top-left)
2. Select **Edit Scheme...**
3. In the left sidebar, click **Test**
4. You should see **Test Plans** section with "SQLNotebook" test plan

**For Xcode 26+:** Tests are organized into Test Plans instead of individual test bundles:
- You'll see **"SQLNotebook"** test plan with **(2 targets)** or similar
- Click the ▶ arrow next to the test plan to expand it
- Verify both test targets are included:
  - ✅ SQLNotebookTests
  - ✅ SQLNotebookUITests
- Make sure both are **checked** (enabled)

**Alternative:** If you want to see individual test targets:
- Click the **test plan name** to expand it
- Or look for **"Info"** tab to see which targets are included

5. Click **Close**

### Step 6: Configure Build Settings (Important!)

**How to access Build Settings:**
1. Click on the **SQLNotebook project file** in Project Navigator (left sidebar, top item with blue icon)
2. In the main editor area, you'll see two sections:
   - **PROJECT** (left side): SQLNotebook
   - **TARGETS** (left side): SQLNotebook, SQLNotebookTests, SQLNotebookUITests
3. Click on a target name to select it
4. At the top of the editor, you'll see tabs: **General**, **Signing & Capabilities**, **Resource Tags**, **Info**, **Build Settings**, **Build Phases**, **Build Rules**
5. Click **Build Settings** tab

**Visual Guide:**
```
Project Navigator          Editor Area
┌─────────────────┐       ┌──────────────────────────────┐
│ 📘 SQLNotebook  │  →    │ TARGETS:                     │
│   ├─ Models/    │       │  - SQLNotebook               │ ← Click a target
│   ├─ Views/     │       │  - SQLNotebookTests          │
│   └─ ...        │       │  - SQLNotebookUITests        │
└─────────────────┘       │                              │
                          │ Tabs: General | Build Settings│ ← Click this tab
                          │ [Search box here]            │
                          └──────────────────────────────┘
```

#### For SQLNotebookTests:
1. Click **SQLNotebook project** in Project Navigator (top, blue icon)
2. In TARGETS section (left side of editor), click **SQLNotebookTests**
3. Click **Build Settings** tab (top of editor)
4. Use the **search box** (top-right of Build Settings) to find settings:
   - Search for **"Test Host"**
   - Verify value: `$(BUILT_PRODUCTS_DIR)/SQLNotebook.app/Contents/MacOS/SQLNotebook`
5. Search for **"Bundle Loader"**
   - Verify value: `$(TEST_HOST)`
6. Search for **"Runpath Search Paths"**
   - Should include: `@loader_path/../Frameworks`

**Note:** These settings are usually configured correctly by Xcode automatically. Only check if tests fail to run.

#### For SQLNotebookUITests:

**Xcode 26+ Note:** UI test configuration has changed significantly. "Test Target Name" setting no longer exists in Build Settings.

**How to verify UI test target configuration:**

1. Select **SQLNotebookUITests** target
2. Go to **General** tab (NOT Build Settings)
3. Look for **"Target Application"** or **"Testing"** section
4. Should show target app: **SQLNotebook** ✅

**If you don't see "Target Application" section:**
- This is **NORMAL** in Xcode 26
- Target is configured automatically through:
  - Test Plan (Edit Scheme → Test)
  - Target dependencies (automatic detection)

**💡 Tip:** Skip this entire step for Xcode 26! UI test targets are auto-configured. Only check if UI tests fail to run.

### Step 7: Add Test Dependencies (PostgresNIO)

Since our app uses PostgresNIO for database connectivity, we need to make it available to tests:

1. Select the **SQLNotebook** project (not target) in Project Navigator
2. Go to **Package Dependencies** tab
3. Verify `postgres-nio` package is listed
4. Click on **SQLNotebookTests** target
5. Go to **General** tab
6. Scroll to **Frameworks and Libraries** section
7. Click **"+"** button
8. Add `PostgresNIO` library (if needed for integration tests)

**Note:** For unit tests that use mocks, you may not need PostgresNIO dependency. Add it only when writing integration tests.

### Step 8: Verify Test Plan Configuration (Xcode 26+)

**Understanding Test Plans:**
- Xcode 26 uses **Test Plans** to organize multiple test targets
- A test plan is like a container that groups test targets together
- Your "SQLNotebook" test plan should automatically include both test targets

**To verify Test Plan includes your targets:**
1. In Project Navigator, look for **SQLNotebook.xctestplan** file (may be hidden)
2. Or in Edit Scheme → Test, expand the test plan
3. Both `SQLNotebookTests` and `SQLNotebookUITests` should be listed

**If test targets are missing from the plan:**
1. Edit Scheme → Test
2. Click **"+"** button at bottom-left
3. Select your test targets to add them to the plan

### Step 9: Run Initial Tests

1. Press **Cmd+U** to run all tests
2. Or click **Product** → **Test**
3. You should see default test cases pass (they do nothing yet)
4. Check **Test Navigator** (Cmd+6) to see test results

---

## Method 2: Using Command Line (Alternative)

If the Xcode UI method doesn't work, you can manually create test targets:

### Step 1: Create Test Directories

```bash
# From project root
mkdir -p SQLNotebookTests
mkdir -p SQLNotebookUITests
```

### Step 2: Create Test Files

Create `SQLNotebookTests/SQLNotebookTests.swift`:
```swift
import XCTest

final class SQLNotebookTests: XCTestCase {
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        XCTAssertTrue(true)
    }
}
```

Create `SQLNotebookUITests/SQLNotebookUITests.swift`:
```swift
import XCTest

final class SQLNotebookUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // Put teardown code here.
    }

    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
```

### Step 3: Add Targets to Xcode Project Manually

This requires editing `project.pbxproj` file directly, which is complex and error-prone. **We recommend using Xcode UI instead.**

If you must use command line, consider using `xcodegen` or `tuist` tools to generate project files.

---

## Troubleshooting

### Issue: "No such module 'XCTest'"
**Solution:** Make sure you're running tests from the correct scheme. Check that test targets are included in the test action of your scheme.

### Issue: "Host application not found"
**Solution:**
1. Select test target
2. Build Settings → Test Host
3. Verify path points to: `$(BUILT_PRODUCTS_DIR)/SQLNotebook.app/Contents/MacOS/SQLNotebook`

### Issue: Tests don't appear in Test Navigator
**Solution:**
1. Clean build folder (Cmd+Shift+K)
2. Rebuild (Cmd+B)
3. Close and reopen Xcode
4. Check that test files have target membership set correctly

### Issue: Test Plan shows "(2 targets)" but tests don't run
**Solution (Xcode 26+):**
1. Edit Scheme → Test
2. Click the ▶ arrow to expand the Test Plan
3. Verify both test targets are **checked** (enabled)
4. If unchecked, click the checkbox next to each target
5. If targets are missing:
   - Click **"+"** button
   - Select `SQLNotebookTests` and `SQLNotebookUITests`
   - Click **Add**

### Issue: "No such test plan" or test plan file not found
**Solution:**
1. Xcode should auto-create `SQLNotebook.xctestplan` file
2. If missing, create manually:
   - File → New → File
   - Select **"Test Plan"** template
   - Name it `SQLNotebook`
   - Save in project root
3. Add test targets to the plan:
   - Edit Scheme → Test → "+" → Select targets

### Issue: "Testing Bundle" template not found in Xcode 26
**Solution:**
In Xcode 26, the template might be named:
- **"Test"** (generic test bundle)
- **"Unit Test Bundle"**
- **"UI Test Bundle"**

Look under the **Testing** section in template chooser. If still not found:
1. Try File → New → Target → macOS → scroll through all categories
2. Or use the search box in template chooser, type "test"

---

## Verification Checklist

After setup, verify the following:

- [ ] `SQLNotebookTests` folder exists in Project Navigator
- [ ] `SQLNotebookUITests` folder exists in Project Navigator
- [ ] Both test targets appear in target list
- [ ] **Xcode 26+:** Test Plan shows both targets (Edit Scheme → Test → expand plan)
- [ ] **OR:** Both test targets are checked in scheme's Test action
- [ ] SQLNotebook.xctestplan file exists (may be auto-generated)
- [ ] Can build tests successfully (Cmd+Shift+U)
- [ ] Can run tests successfully (Cmd+U)
- [ ] Test Navigator shows test classes (Cmd+6)
- [ ] Test results appear in Report Navigator (Cmd+9)
- [ ] No build errors or warnings in test targets

---

## Next Steps

Once test targets are set up, proceed to:

1. **Create Test Helpers** - Mock objects and utilities
2. **Write Data Model Tests** - Test `SQLNotebook`, `NotebookCell`, `CellValue` encoding/decoding
3. **Write Utility Tests** - Test `SQLSyntaxHighlighter` tokenizer
4. **Write ViewModel Tests** - Test `NotebookViewModel` logic
5. **Write Integration Tests** - Test `DatabaseConnectionManager`
6. **Write UI Tests** - Test critical user flows

See `docs/TODO.md` Phase 6 for detailed test implementation plan.

---

## Additional Resources

- [Apple Documentation: Testing with Xcode](https://developer.apple.com/documentation/xcode/testing-your-apps-in-xcode)
- [XCTest Framework Reference](https://developer.apple.com/documentation/xctest)
- [Writing Testable Code in Swift](https://developer.apple.com/videos/play/wwdc2017/414/)

---

## Notes

- Test files should have `@testable import SQLNotebook` to access internal types
- Integration tests may require a test database setup/teardown
- UI tests run slower than unit tests - keep them focused on critical flows
- Aim for **70%+ code coverage** for core functionality
- Use mocks/stubs for database operations in unit tests
- Use real database for integration tests (consider SQLite in-memory for speed)

---

**Status:** Ready for implementation
**Prerequisites:** Xcode 16+, macOS 16+, SQLNotebook project open
**Estimated Time:** 15-30 minutes for initial setup
