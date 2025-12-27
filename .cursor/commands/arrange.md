# arrange

Manages project structure and architecture - organizes files, enforces 400-line limit, ensures proper folder placement, and maintains clean code organization.

## How to Use This Command

When user requests architecture work (check structure, analyze files, refactor, organize, split files), follow this workflow:

### Step 1: Understand the Request

Identify what the user needs:
- **Check structure**: Analyze all files, find violations, report issues
- **Refactor file**: Split large file into smaller components
- **Organize**: Move files to correct folders, fix naming
- **Create component**: Add new component with proper structure
- **Enforce limits**: Find and fix files over 400 lines

### Step 2: Scan Project Structure

For structure analysis, scan all Swift files:

```bash
# Find all Swift files with line counts
find SQLNotebook -name "*.swift" -type f | while read file; do
  lines=$(wc -l < "$file")
  echo "$lines $file"
done | sort -rn
```

```bash
# Find files over 400 lines
find SQLNotebook -name "*.swift" -type f | while read f; do
  lines=$(wc -l < "$f")
  if [ $lines -gt 400 ]; then
    echo "$lines $f"
  fi
done
```

### Step 3: Analyze and Report

Based on scan results, create a structured report:

```markdown
# Project Structure Analysis

## 📊 Overview
- Total Swift files: X
- Files over 400 lines: Y
- Average file size: Z lines

## ⚠️ Files Exceeding 400-Line Limit
[List files with suggested splits]

## ✅ Well-Organized Areas
[Areas that follow best practices]

## 💡 Architecture Improvements
[Suggestions for better organization]

## 📋 Recommended Actions
[Actionable items with priorities]
```

### Step 4: Execute Refactoring (if requested)

When splitting files, follow these strategies:

#### Strategy 1: Extract Extension
```swift
// Original: LargeViewModel.swift (500 lines)

// Split into:
// LargeViewModel.swift (200 lines) - Core state
// LargeViewModel+FeatureA.swift (150 lines) - Feature A
// LargeViewModel+FeatureB.swift (150 lines) - Feature B
```

#### Strategy 2: Extract Service
```swift
// Move complex logic to dedicated service
// ViewModel.swift (200 lines) - Simplified
// FeatureService.swift (250 lines) - Business logic
```

#### Strategy 3: Extract Helper Types
```swift
// Extract nested types to separate files
// MainType.swift (200 lines)
// SupportingType1.swift (100 lines)
// SupportingType2.swift (100 lines)
```

## Project Structure Rules

### Folder Organization
```
SQLNotebook/
├── Database/          → ConnectionManager, QueryExecutor
├── Models/            → Data models, Codable structs
├── ViewModels/        → ViewModel.swift, ViewModel+*.swift
├── Views/
│   ├── Components/    → Reusable UI components
│   ├── Screens/       → Full screen views
│   └── *View.swift    → Main views
├── Utilities/         → Helpers, Extensions, Constants
└── Services/          → External integrations
```

### Naming Conventions
- **ViewModels**: `<Feature>ViewModel.swift`
- **Views**: `<Feature>View.swift` or `<Feature>Sheet.swift`
- **Models**: `<EntityName>.swift`
- **Extensions**: `<Type>+<Category>.swift`
- **Utilities**: `<Purpose>Helper.swift` or `<Type>Extensions.swift`
- **Previews**: Preview code should be in the same main implementation file so developers can modify and see Canvas preview simultaneously

### File Size Guidelines
- **Maximum**: 400 lines (STRICT)
- **Ideal**: 200-300 lines
- **Minimum**: 50 lines (avoid tiny files)
- **Count**: Include blank lines, comments, but exclude file headers

## Architecture Patterns to Enforce

### 1. MVVM Separation
- Models: Data structures only
- ViewModels: Business logic, state management
- Views: UI presentation only
- ❌ Never: View logic in ViewModel

### 2. Single Responsibility
- Each file should have one clear purpose
- ❌ Never: Multiple unrelated responsibilities

### 3. Dependency Injection
- Dependencies should be injected, not hard-coded
- ❌ Never: `private let manager = Manager()` in ViewModel

## Common Refactoring Scenarios

### Scenario 1: Oversized ViewModel
**Problem**: `NotebookViewModel.swift` có 600 lines

**Solution**:
1. Extract cell management → `NotebookViewModel+CellManagement.swift`
2. Extract execution logic → `NotebookViewModel+Execution.swift`
3. Extract connection handling → `NotebookViewModel+Connection.swift`
4. Keep core state và init trong main file

### Scenario 2: View với nhiều subviews
**Problem**: `ContentView.swift` có 500 lines

**Solution**:
1. Extract header → `Views/Components/HeaderView.swift`
2. Extract footer → `Views/Components/FooterView.swift`
3. Extract sidebar → `Views/Components/SidebarView.swift`
4. Keep layout logic trong ContentView

### Scenario 3: Model với nhiều computed properties
**Problem**: `SQLNotebook.swift` có 450 lines

**Solution**:
1. Extract formatting → `SQLNotebook+Formatting.swift`
2. Extract validation → `SQLNotebook+Validation.swift`
3. Extract helpers → `SQLNotebook+Helpers.swift`
4. Keep core properties và Codable trong main file

## Best Practices

### ✅ Always Do
1. **Check line counts** sau mỗi file change
2. **Plan splits** trước khi refactor
3. **Test thoroughly** sau khi split files
4. **Update imports** trong affected files
5. **Maintain git history** với clear commit messages
6. **Group related code** trong extensions
7. **Use meaningful file names** cho split files
8. **Keep previews in main file** - Preview code should be in the same implementation file so developers can modify and see Canvas preview simultaneously

### ❌ Never Do
1. **Split arbitrarily** - follow logical boundaries
2. **Create tiny files** - minimum 50 lines
3. **Break functionality** - ensure code still works
4. **Ignore dependencies** - update all imports
5. **Skip testing** - verify after refactoring
6. **Mix concerns** - keep single responsibility
7. **Forget documentation** - update comments và docs

## Example Workflows

### Example 1: Check Project Structure

**User request**: "Check project structure và tìm files vượt quá 400 lines"

**AI should**:
1. Run scan command to find all Swift files with line counts
2. Identify files over 400 lines
3. Analyze folder organization
4. Create detailed report with recommendations
5. Suggest refactoring plan for oversized files

### Example 2: Split Large File

**User request**: "Split NotebookViewModel.swift thành smaller files"

**AI should**:
1. Read the file to understand structure
2. Identify logical boundaries (cell management, execution, connection)
3. Create extension files following naming convention
4. Move related code to appropriate extensions
5. Verify all files under 400 lines
6. Update any imports if needed

### Example 3: Create New Component

**User request**: "Tạo new SettingsView component"

**AI should**:
1. Determine correct folder (`Views/Components/` or `Views/`)
2. Create file with proper naming (`SettingsView.swift`)
3. Include proper SwiftUI structure
4. Add preview in the same file
5. Follow MVVM pattern if needed
6. Ensure file starts under 400 lines

## Response Format

When reporting structure analysis:

```markdown
# Project Structure Analysis

## 📊 Overview
- Total Swift files: X
- Files over 400 lines: Y
- Average file size: Z lines

## ⚠️ Files Exceeding 400-Line Limit

### 1. `path/to/file.swift` (XXX lines)
**Current**: [Brief description]
**Suggested Split**:
- `file.swift` (200 lines) - Core functionality
- `file+Extension1.swift` (150 lines) - Feature A
- `file+Extension2.swift` (XXX lines) - Feature B

**Impact**: Low/Medium/High
**Priority**: High/Medium/Low

## ✅ Well-Organized Areas
- Database layer: Clean separation
- Models: Focused and concise

## 💡 Architecture Improvements
1. [Suggestion 1]
2. [Suggestion 2]

## 📋 Recommended Actions
- [ ] Split FileA.swift
- [ ] Move FileB to correct folder
- [ ] Extract common utilities
```

## Your Goal

Maintain a **clean, organized, and scalable** project structure với:
- Maximum 400 lines per file (STRICT enforcement)
- Proper folder organization
- Clear architectural boundaries
- Easy to navigate và understand
- Prepared for future growth

Prioritize **code quality over quantity** và **clarity over cleverness**.

