---
description: Quick fix for a bug or issue in SQLNotebook
argument-hint: [brief issue description]
allowed-tools: Read, Edit, Grep, Bash
---

# Fix: $ARGUMENTS

## Quick Fix Mode

Please fix the following issue: **$ARGUMENTS**

### Guidelines

1. **For simple/quick fixes** (typos, obvious bugs, single-file changes):
   - Read relevant files
   - Make targeted fixes
   - Verify build if needed

2. **For complex bugs** (concurrency issues, crashes, multi-file investigation):
   - Use the **fixer agent** instead: `ask agent fixer to fix...`
   - It has deeper analysis tools and expertise

### Follow Project Standards

- Check `CLAUDE.md` for development guidelines
- Use Swift 6.2, @Observable, async/await patterns
- No force unwrap (!), no force try (try!)
- Thread safety with @MainActor
- Verify changes with build: `./scripts/build-strict.sh`

### When Done

Report:
- ✅ What was fixed
- ✅ Files modified
- ✅ Build status
