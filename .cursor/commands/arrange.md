# arrange

Manages project structure and architecture - organizes files, enforces tiered file size limits, ensures proper folder placement.

## Tiered File Size Guidelines

| File Type | Max Lines | Strictness |
|-----------|-----------|------------|
| **Logic files** | 400 | **STRICT** (Models, ViewModels, Managers, Utilities) |
| **Simple Views** | 400 | Recommended (Small components, forms) |
| **Complex Views** | 600 | Acceptable (Tables, editors, multi-section) |
| **Test files** | 800 | Acceptable (Integration tests) |

## Quick Commands

### Scan all files
```bash
find SQLNotebook -name "*.swift" -type f -exec wc -l {} + | sort -rn
```

### Find files over limits
```bash
# Logic files over 400 (STRICT)
find SQLNotebook/{Database,Models,ViewModels,Utilities,Services} -name "*.swift" -type f 2>/dev/null | while read f; do
  lines=$(wc -l < "$f")
  if [ $lines -gt 400 ]; then echo "❌ STRICT: $lines $f"; fi
done

# Views over 600
find SQLNotebook/Views -name "*.swift" -type f 2>/dev/null | while read f; do
  lines=$(wc -l < "$f")
  if [ $lines -gt 600 ]; then
    echo "⚠️  COMPLEX: $lines $f"
  elif [ $lines -gt 400 ]; then
    echo "ℹ️  SIMPLE (>400): $lines $f"
  fi
done
```

## Critical Rules

### 1. SwiftUI Previews (CRITICAL)
```swift
// ✅ CORRECT: Preview in same file
struct MyView: View {
    var body: some View { Text("Hello") }
}
#Preview { MyView() }

// ❌ WRONG: Never create MyView+Preview.swift
```
**Why:** Xcode Canvas needs previews in same file for live updates.

### 2. Project Structure
```
SQLNotebook/
├── Database/       # Managers, executors
├── Models/         # Data models
├── ViewModels/     # @Observable + extensions
├── Views/
│   ├── Components/ # Reusable UI
│   └── Screens/    # Full screens
├── Utilities/      # Helpers, extensions
└── Services/       # External integrations
```

### 3. Naming
- ViewModels: `FeatureViewModel.swift`
- Extensions: `Type+Category.swift`
- Previews: **ALWAYS** in same file

## Splitting Large Files

### Logic Files (400 STRICT)
```swift
// NotebookViewModel.swift (600 lines) → Split:

// NotebookViewModel.swift (200 lines)
@Observable class NotebookViewModel {
    // Core properties, init only
}

// NotebookViewModel+CellManagement.swift (150 lines)
extension NotebookViewModel {
    func addCell() { }
}

// NotebookViewModel+Execution.swift (150 lines)
extension NotebookViewModel {
    func executeCell() async { }
}
```

### Views (Keep Previews!)
```swift
// MyComplexView.swift (500 lines) → Split:

// MyComplexView.swift (200 lines)
struct MyComplexView: View {
    var body: some View {
        VStack { HeaderSection(); BodySection() }
    }
}
#Preview { MyComplexView() } // Keep here!

// HeaderSection.swift (100 lines)
struct HeaderSection: View {
    var body: some View { /* ... */ }
}
#Preview { HeaderSection() } // Own preview!
```

## When to Refactor

✅ **Do refactor:**
- Logic files > 400 lines
- Can split into focused modules
- View can be decomposed into reusable components

❌ **Don't refactor:**
- Creates 10+ parameters
- Helper views only used once
- Makes code harder to understand

## Report Format

```markdown
## 📊 Overview
- Total: X files
- Over limits: Y files

## ❌ Logic Files Over 400 (STRICT - Must Fix)
- `File.swift` (500 lines) - Split into extensions

## ⚠️ Simple Views Over 400 (Recommended)
- `View.swift` (475 lines) - Extract sections

## ℹ️ Complex Views Over 600
- `TableView.swift` (650 lines) - Consider refactor

## 💡 Suggestions
[Actionable items]
```

## Priority Order

1. **HIGH**: Logic files > 400 (STRICT)
2. **MEDIUM**: Simple Views > 400
3. **LOW**: Complex Views > 600
4. **OPTIONAL**: Tests > 800

