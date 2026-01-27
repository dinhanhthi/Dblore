---
name: doc
description: Create clear documentation and implementation summaries for SQLNotebook
argument-hint: [what to document]
allowed-tools: Read, Write, Edit, Grep, Glob, WebSearch
disable-model-invocation: true
---

# Doc: $ARGUMENTS

## Documentation Task: $ARGUMENTS

## Critical Rules

1. **File Naming**: All files in `docs/implementation/` MUST use `snake_case.md` (e.g., `mode_switching.md`, `bug_fix_name.md`)
   - NEVER use SCREAMING_SNAKE_CASE or kebab-case
   - Use: `feature_name.md`, `bug_fix_description.md`

2. **File Organization**:
   - `docs/implementation/` - Implementation summaries, bug fixes, feature docs
   - `docs/` - Project overview, dependencies, keyboard shortcuts, testing plan, TODO

3. **Language**: Always write in **English**

4. **Use WebSearch**: Search for latest documentation standards and best practices from official sources (Swift docs, Apple Developer)

## Two Main Functions

### Function 1: Documentation Writing

Create comprehensive documentation for:
- **README.md** - Project overview, features, installation, usage
- **docs/project.md** - Architecture, technical details, design patterns
- **docs/dependencies.md** - Swift Package Manager dependencies
- **docs/keyboard_shortcuts.md** - All keyboard shortcuts
- **docs/testing_plan.md** - Testing strategy
- **docs/TODO.md** - Pending features and tasks
- **Inline code comments** - Using `///` for Swift documentation

### Function 2: Implementation Summaries

Create concise summaries (1-2 pages max) in `docs/implementation/`:

**Format Template:**
```markdown
# [Feature/Bug Name]

## Problem
[1-2 sentences describing what needed to be done or what was broken]

## Solution
[Brief description of the approach taken]

### Key Changes
- `path/to/file.swift:line` - What was changed
- `path/to/file.swift:line` - What was changed

## Already Tried (if applicable)
- Approach A - Why it didn't work
- Approach B - Why it didn't work

## Remaining Issues (if applicable)
- [ ] Issue 1 - Description
- [ ] Issue 2 - Description

## Testing
- Test case 1 passed
- Test case 2 passed

## Notes
[Any important context or decisions]
```

**What to Include:**
- Problem statement (brief)
- Solution approach (high-level)
- Key file changes with line numbers
- Failed approaches (helps avoid repeating mistakes)
- Remaining issues (what's not done yet)
- Test results

**What to Exclude:**
- Detailed code snippets (just reference files)
- Step-by-step debugging process
- Conversational details

## Code Documentation Standards

### Function Documentation (Swift)
```swift
/// Executes SQL query and returns results with metadata.
///
/// - Parameters:
///   - sql: The SQL query to execute
///   - limit: Optional row limit for results
///
/// - Returns: CellResult with columns, rows, and execution time
///
/// - Throws: DatabaseError if connection fails or query is invalid
func executeQuery(_ sql: String, limit: Int?) async throws -> CellResult
```

### Inline Comments (Swift)
```swift
// Execute SQL query with timeout to prevent long-running queries.
// Query executes on background actor to avoid blocking main thread.
// Results are paginated to limit memory usage for large result sets.
private func executeQuery(_ sql: String, limit: Int?) async throws -> CellResult {
    // Implementation
}
```

**Explain WHY, not just WHAT.**

## Style Guidelines

- **Code Comments**: Technical, precise, informative
- **Developer Docs**: Professional, detailed, example-rich
- **User Docs**: Friendly, clear, jargon-free
- Use markdown for all docs
- Include code blocks with syntax highlighting
- Add links for cross-references

## File Organization Structure

```
docs/
├── project.md                    # Project overview & architecture
├── dependencies.md               # Dependencies & SPM packages
├── keyboard_shortcuts.md         # Keyboard shortcuts reference
├── testing_plan.md               # Testing strategy
├── TODO.md                       # Task tracking & roadmap
└── implementation/               # Implementation summaries (snake_case.md)
    ├── feature_name.md
    ├── bug_fix_name.md
    └── performance_optimization.md
```

## Update Documentation When:
- New features are added
- APIs change
- Bugs are fixed
- Architecture changes
- Dependencies are added/removed
- Configuration options change

## Output Report

When done, report:
- What was documented
- File location (with proper snake_case naming)
- Documentation type (implementation summary vs general docs)
- Code examples included
- Links to related docs
