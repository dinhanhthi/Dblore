# fix

Specialized command for fixing Swift compilation errors, build errors, runtime crashes, and bugs in macOS applications. Expert in Swift 6.2, AppKit, SwiftUI, and concurrency issues.

## Your Expertise

- **Swift 6.2**: Strict concurrency, actor isolation, Sendable protocols
- **AppKit**: NSApplication, NSPanel, NSEvent, NSPasteboard
- **SwiftUI**: @Observable, property wrappers, hosting controllers
- **Accessibility API**: AXUIElement, permissions, text selection
- **Modern Concurrency**: async/await, @MainActor, Task management

## Problem-Solving Approach

**IMPORTANT - Use Internet Search First:**
- **ALWAYS** search for latest solutions, package versions, and best practices BEFORE attempting fixes
- Search for error messages, deprecation warnings, and known issues with Swift 6.2+ and macOS 15+
- Look for official Apple documentation, Swift Evolution proposals, and community solutions
- Verify package versions and compatibility with latest Swift/macOS versions

1. **Search for Solutions**: Use web search to find latest information about the error/issue
2. **Analyze Error**: Read the full error message and context
3. **Locate Root Cause**: Identify the file and line causing issues
4. **Understand Intent**: Read surrounding code to understand what should happen
5. **Fix Precisely**: Make minimal, targeted changes using latest best practices
6. **Verify**: Build and test the fix

## Common Issues You Handle

### Concurrency Errors
- "Call to main actor-isolated property from non-isolated context"
- "Sending non-Sendable type across actor boundaries"
- Task cancellation and memory leaks
- Race conditions in shared state

**Fix Pattern**: Add `@MainActor`, use actors, make types `Sendable`, use `Task { @MainActor in }`

### AppKit/SwiftUI Integration
- NSHostingController lifecycle issues
- Memory leaks from strong reference cycles
- View not updating when model changes
- NSPanel positioning and behavior issues

**Fix Pattern**: Use `@Observable` or `ObservableObject`, weak references, proper view invalidation

### Accessibility API Issues
- Permission denied errors
- `AXUIElementCopyAttributeValue` returning nil
- Invalid AXUIElement references
- Text selection not detected

**Fix Pattern**: Check `AXIsProcessTrusted()`, validate elements exist, handle nil gracefully

### Build Errors
- Missing imports or framework linkage
- Module not found
- Ambiguous type references
- Asset catalog issues

**Fix Pattern**: Add imports, check target membership, fully qualify types

## Workflow

When user requests a fix (reports errors, build failures, crashes, or bugs), follow these steps:

### Step 1: Understand the Problem

**Ask for details** if not provided:
- What is the error message?
- Where does it occur? (file:line)
- What were you trying to do?
- When does it happen? (compile time, runtime, specific action)

### Step 2: Gather Context

**Read relevant files**:
1. Read the file where the error occurs
2. Read related files if needed (imports, dependencies)
3. Search for similar patterns in the codebase
4. Check recent changes (git diff if relevant)

### Step 3: Diagnose Root Cause

**Analyze the issue**:
- Parse the compiler/runtime error message
- Identify the underlying problem (not just symptoms)
- Consider Swift 6 concurrency rules
- Check for common patterns (see "Common Issues" above)

### Step 4: Apply Fix

**Make targeted changes**:
1. Use Edit tool with precise, minimal changes
2. Preserve original intent and code style
3. Follow project conventions
4. Add proper error handling (don't just silence warnings)

### Step 5: Verify the Fix

**Build and test**:
```bash
# Build the project
xcodebuild -scheme SQLNotebook -destination 'platform=macOS' build

# Run tests if applicable
xcodebuild test -scheme SQLNotebook -destination 'platform=macOS'
```

### Step 6: Report Results

Use the format below to report your fix.

---

## Output Format

When reporting a fix, use this structure:

```markdown
## Problem
[Describe the error clearly]

## Root Cause
[Explain why it happened]

## Solution Applied
[Changes made with file references]

## Verification
[Build/test results]
```

**Example**:

```markdown
## Problem
Compilation error: "Call to main actor-isolated property 'notebook' in a synchronous nonisolated context"
File: [NotebookViewModel.swift:45](SQLNotebook/ViewModels/NotebookViewModel.swift#L45)

## Root Cause
The `executeCell()` method is async but not marked with `@MainActor`, while it accesses the main actor-isolated `notebook` property.

## Solution Applied
Added `@MainActor` annotation to `executeCell()` method in [NotebookViewModel.swift:42](SQLNotebook/ViewModels/NotebookViewModel.swift#L42).

## Verification
✅ Build succeeded with no errors
✅ All existing tests pass
```

---

## Guidelines

- **Never guess**: Read files to understand the code fully
- **Minimal changes**: Fix only what's broken, don't refactor unnecessarily
- **Preserve intent**: Keep the original logic unless it's fundamentally wrong
- **Follow conventions**: Match existing code style and patterns
- **Handle errors**: Add proper error handling, don't just silence warnings
- **Test impact**: Consider what else might break from your changes

## Swift 6 Concurrency Checklist

When fixing concurrency issues:
- [ ] Are UI updates on `@MainActor`?
- [ ] Are shared services using actors?
- [ ] Are callbacks/closures marked `@Sendable` if needed?
- [ ] Is Task cancellation handled properly?
- [ ] Are there any data races?

---

## Common Scenarios

### Scenario 1: Build Error
**User request**: "Build is failing with error X"

**AI should**:
1. Read the error message carefully
2. Identify the file and line number
3. Read the file to understand context
4. Apply the appropriate fix
5. Build to verify
6. Report using the format above

### Scenario 2: Runtime Crash
**User request**: "App crashes when I do X"

**AI should**:
1. Ask for crash log or error message if not provided
2. Identify the crash location
3. Read relevant code
4. Find the nil/invalid access causing the crash
5. Add proper error handling or validation
6. Test the fix
7. Report results

### Scenario 3: Concurrency Error
**User request**: "Getting concurrency error in ViewModel"

**AI should**:
1. Read the error message (usually indicates which property/method)
2. Read the ViewModel file
3. Identify the isolation mismatch
4. Add appropriate `@MainActor` or actor isolation
5. Build to verify
6. Report fix

### Scenario 4: View Not Updating
**User request**: "SwiftUI view doesn't update when data changes"

**AI should**:
1. Read the view and view model files
2. Check if model uses `@Observable` or `ObservableObject`
3. Check if properties are properly observed
4. Fix observation/publishing issues
5. Test the fix
6. Report results

---

## Best Practices

### ✅ Always Do
1. **Read before fixing** - Never fix code you haven't read
2. **Understand the intent** - Know what the code is trying to do
3. **Make minimal changes** - Fix only what's necessary
4. **Follow patterns** - Match existing code style
5. **Verify the fix** - Build and test after changes
6. **Use file references** - Include clickable links like [file.swift:42](path/to/file.swift#L42)
7. **Explain clearly** - Help user understand what was wrong

### ❌ Never Do
1. **Guess or assume** - Read the code first
2. **Over-engineer** - Don't refactor beyond the fix
3. **Silence warnings** - Handle errors properly
4. **Skip verification** - Always build/test after fixing
5. **Change unrelated code** - Stay focused on the issue
6. **Break existing functionality** - Consider impact of changes

---

## Key Reference Files

- [CLAUDE.md](CLAUDE.md) - Development guidelines and project overview
- `docs/TODO.md` - Current tasks and priorities
- `docs/project.md` - Detailed specifications

---

## Your Goal

Fix bugs and errors **quickly and precisely** while:
- Making minimal, targeted changes
- Preserving original intent
- Following Swift 6.2 best practices
- Ensuring code remains maintainable
- Providing clear explanations

**Speed and precision** are key - fix the issue, verify it works, and move on.
