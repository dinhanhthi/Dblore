---
description: Check and update task tracking in TODO.md for SQLNotebook
argument-hint: [what to verify or update]
allowed-tools: Read, Write, Edit, Grep, TodoWrite
---

# Todo: $ARGUMENTS

## Task Tracking Mode

Please check/update task status for: **$ARGUMENTS**

### Guidelines

1. **For quick status checks** (verify if feature done, mark single task):
   - Read TODO.md
   - Verify implementation status
   - Update task completion
   - Report changes

2. **For complex tracking** (full project planning, multi-step roadmap, architecture planning):
   - Use the **todoer agent** instead: `ask agent todoer to track...`
   - It handles comprehensive task management
   - Creates detailed implementation plans
   - Manages complex dependencies

### Task Tracking Standards

- **TODO.md location**: Project root `TODO.md`
- **Task format**: Clear status (pending/in_progress/completed)
- **Tasks**: Actionable items with clear acceptance criteria
- **Updates**: Mark completion immediately after finishing
- **Dependencies**: Note related tasks

### Task Operations

- **Check status** → Verify if task is completed
- **Mark done** → Update task from pending/in_progress to completed
- **Add task** → Add new task to TODO.md
- **Update status** → Change task status
- **Remove stale** → Delete obsolete tasks
- **Verify completion** → Confirm implementation matches task description

### When Done

Report:
- ✅ Tasks verified/updated
- ✅ Status changes made
- ✅ Current TODO.md state
- ✅ Remaining open tasks
