---
description: Create or update documentation for SQLNotebook
argument-hint: [what to document]
allowed-tools: Read, Write, Edit, Grep, Glob
---

# Doc: $ARGUMENTS

## Documentation Mode

Please create or update documentation for: **$ARGUMENTS**

### Guidelines

1. **For quick/simple docs** (API docs, small guides, comments):
   - Read relevant source code
   - Write clear, concise documentation
   - Use examples where helpful
   - Add to appropriate location

2. **For comprehensive docs** (implementation guides, architecture, detailed specs):
   - Use the **docer agent** instead: `ask agent docer to write...`
   - It creates full-featured, well-structured documentation
   - Includes code examples, test plans, prevention guidelines

### Documentation Standards

- **File naming**: Use `snake_case.md` (e.g., `user_guide.md`, `api_reference.md`)
- **Location**: Place in `docs/` or `docs/implementation/` based on type
- **Language**: Vietnamese explanations + English technical terms
- **Format**: Clear headers, code blocks, tables, examples
- **Structure**: Introduction, main content, examples, related resources

### Documentation Types

- **Implementation docs** → `docs/implementation/feature_name.md`
- **User guides** → `docs/user_guide.md`
- **API references** → `docs/api_reference.md`
- **Architecture** → `docs/architecture.md`
- **Setup guides** → `docs/setup.md`

### When Done

Report:
- ✅ What was documented
- ✅ File location and structure
- ✅ Code examples included
- ✅ Links to related docs
