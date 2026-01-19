---
description: Verify implementation status and update TODO.md - verification only, no implementation
argument-hint: [what to verify or update]
allowed-tools: Read, Write, Edit, Grep, Glob, TodoWrite, WebSearch
---

# Todo: $ARGUMENTS

## ⚠️ CRITICAL: VERIFICATION ONLY - DO NOT IMPLEMENT

You are **verifying task completion**, NOT implementing features.

- ❌ **NEVER IMPLEMENT FEATURES** - Your job is to verify, not to code
- ❌ **NEVER WRITE CODE** - Only read and analyze existing code
- ❌ **NEVER MODIFY SOURCE FILES** - Only update `docs/TODO.md`
- ✅ **ONLY VERIFY** what's already implemented in the codebase
- ✅ **ONLY UPDATE** `docs/TODO.md` status markers (checkboxes)
- ✅ **ONLY REPORT** findings and recommend next priorities

## Workflow

1. **Read TODO.md** (`docs/TODO.md`) to see current claimed status
2. **Search for implementation** using Grep (e.g., class/function names)
3. **Read actual code** to verify it matches the requirement
4. **Determine status**:
   - ✅ Complete: Implementation exists and works as specified
   - 🚧 In-progress: Partial implementation found
   - ❌ Not started: No implementation found
5. **Update TODO.md checkbox** accordingly
6. **Search for TODO/FIXME comments** in codebase (add to TODO.md if missing)
7. **Report findings** to user

## Task: $ARGUMENTS

### Verification Checklist

For each TODO item:
- [ ] Search for implementation using Grep
- [ ] Read actual Swift code to verify
- [ ] Check if implementation matches requirement
- [ ] Update TODO.md checkbox based on verification
- [ ] Search for `// TODO:` and `// FIXME:` comments
- [ ] Add newly discovered tasks to TODO.md

### Code Search Patterns

Search for these to verify completion:
- Class/struct definitions matching TODO requirements
- Function implementations matching TODO requirements
- `// TODO:` comments in Swift files
- `// FIXME:` comments in Swift files
- `// MARK: - TODO` sections
- Incomplete stubs with `fatalError()` or `// Implementation needed`

### Status Markers

- ✅ **Complete**: Implementation exists and works as specified
- 🚧 **In-Progress**: Partial implementation found
- ❌ **Not Started**: No implementation found
- 🆕 **Newly Discovered**: Found in code comments but not in TODO.md
- ⚠️ **Blocked**: Implementation issues or dependencies
- 🎯 **Recommended Next**: Suggested priority (but don't implement it!)

### Guidelines

- **Be thorough**: Actually read the code, don't just check if files exist
- **Be accurate**: Verify completion by reading implementation details
- **Be conservative**: If unsure, mark as in-progress
- **Be helpful**: Suggest next steps but **DO NOT implement them**
- **Be specific**: Reference exact files and line numbers (e.g., `FileName.swift:123`)

### Output Format

Provide structured report:

```
## Verification Results

### ✅ Verified Complete
- Task name - Implemented in `FileName.swift:123`

### 🚧 In-Progress
- Task name - Partial implementation in `FileName.swift:45`

### ❌ Not Started
- Task name - No implementation found

### 🆕 Newly Discovered
- TODO comment in `FileName.swift:78`: "Add feature X"

### 🎯 Recommended Next Priority
- Task name (but DO NOT implement it)

### 📋 TODO.md Updates
- Updated X tasks to completed
- Added Y new tasks from code comments
```
