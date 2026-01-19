# Code Organization Plan

## Overview

This document outlines the file size analysis and refactoring plan for SQLNotebook codebase.

**Goal:** Apply tiered file size guidelines to improve code maintainability while respecting the nature of different file types.

---

## File Size Guidelines (from CLAUDE.md)

| File Type | Max Lines | Strictness |
|-----------|-----------|------------|
| Logic files (Models, ViewModels, Managers) | 400 | Strict |
| Simple Views | 400 | Recommended |
| Complex Views | 600 | Acceptable |
| Test files | 800 | Acceptable |

---

## Current Status

### Files Exceeding Guidelines

**Production Code (14 files):**

| File | Lines | Type | Status | Action |
|------|-------|------|--------|--------|
| ResultTableView.swift | 779 | Complex View | ⚠️ Over 600 | Consider ViewModel refactor |
| SQLTextView.swift | 740 | Complex View | ⚠️ Over 600 | Split logic from UI |
| DatabaseConnectionManager+QueryExecution.swift | 643 | Logic | ❌ Over 400 | **Must split** |
| NotebookContentView.swift | 637 | Complex View | ✅ Under 600 | Acceptable |
| ConnectionFormContent.swift | 579 | Simple View | ⚠️ Over 400 | Extract form sections |
| AppLogger.swift | 559 | Utility | ❌ Over 400 | **Split by log category** |
| DesignSystem.swift | 503 | Utility | ❌ Over 400 | **Split into theme files** |
| CellInfoContent.swift | 482 | Simple View | ⚠️ Over 400 | Extract sections |
| SQLNotebookApp.swift | 448 | App Entry | ⚠️ Over 400 | Extract menu builders |
| SettingsContent.swift | 441 | Simple View | ⚠️ Over 400 | Extract setting groups |
| DatabaseTypes.swift | 430 | Model | ❌ Over 400 | **Split by database type** |
| HighlightedTextEditor.swift | 421 | Complex View | ✅ Under 600 | Acceptable |
| SQLAutocompleteProvider.swift | 412 | Logic | ❌ Over 400 | **Split by autocomplete type** |
| SQLNotebookDocument.swift | 407 | Model | ❌ Over 400 | **Extract file I/O logic** |

**Test Files (3 files):**

| File | Lines | Type | Status |
|------|-------|------|--------|
| DatabaseIntegrationTests.swift | 897 | Integration Tests | ⚠️ Over 800 |
| ViewModelTests.swift | 840 | Unit Tests | ⚠️ Over 800 |
| DatabaseQueryWrappingTests.swift | 558 | Unit Tests | ✅ Under 800 |

---

## Refactoring Priority

### Priority 1: Logic Files (Must Fix - Over 400 lines)

#### 1. DatabaseConnectionManager+QueryExecution.swift (643 lines)
**Action:** Split into focused extensions

```
- DatabaseConnectionManager+QueryExecution.swift (250 lines)
  - Core query execution logic
  - Error handling

- DatabaseConnectionManager+QueryParsing.swift (200 lines)
  - Query parsing helpers
  - SQL statement detection

- DatabaseConnectionManager+ColumnEnrichment.swift (193 lines)
  - Column metadata enrichment
  - Primary key detection
```

#### 2. AppLogger.swift (559 lines)
**Action:** Split by logging category

```
- AppLogger.swift (200 lines)
  - Core logger setup
  - Log level management

- AppLogger+Database.swift (150 lines)
  - Database-specific logging

- AppLogger+UI.swift (150 lines)
  - UI event logging
```

#### 3. DesignSystem.swift (503 lines)
**Action:** Split into theme components

```
- DesignSystem+Colors.swift (150 lines)
  - Color definitions

- DesignSystem+Spacing.swift (100 lines)
  - Spacing constants

- DesignSystem+Typography.swift (150 lines)
  - Font styles

- DesignSystem+Components.swift (100 lines)
  - Corner radius, shadows, etc.
```

#### 4. DatabaseTypes.swift (430 lines)
**Action:** Split by database vendor

```
- DatabaseTypes.swift (150 lines)
  - Core types and protocols

- PostgreSQLTypes.swift (140 lines)
  - PostgreSQL-specific types

- SQLiteTypes.swift (140 lines)
  - SQLite-specific types
```

#### 5. SQLAutocompleteProvider.swift (412 lines)
**Action:** Split by autocomplete category

```
- SQLAutocompleteProvider.swift (200 lines)
  - Core provider logic

- SQLKeywordCompletion.swift (120 lines)
  - SQL keyword suggestions

- SchemaCompletion.swift (92 lines)
  - Table/column suggestions
```

#### 6. SQLNotebookDocument.swift (407 lines)
**Action:** Extract file operations

```
- SQLNotebookDocument.swift (250 lines)
  - Core document management

- SQLNotebookDocument+FileIO.swift (157 lines)
  - File read/write operations
  - JSON encoding/decoding
```

### Priority 2: Views (Recommended to Fix)

#### 7. SQLTextView.swift (740 lines)
**Action:** Separate UI from logic

```
- SQLTextView.swift (350 lines)
  - Core NSTextView subclass
  - Basic text handling

- SQLTextView+KeyboardHandling.swift (200 lines)
  - Keyboard shortcuts
  - Event handling

- SQLTextView+Autocomplete.swift (190 lines)
  - Autocomplete popup
  - Completion UI
```

#### 8. ConnectionFormContent.swift (579 lines)
**Action:** Extract reusable form sections

```
- ConnectionFormContent.swift (250 lines)
  - Main layout
  - Form state management

- DatabaseFormFields.swift (180 lines)
  - Host, port, database fields
  - Reusable text fields

- SSLConfigSection.swift (149 lines)
  - SSL mode selection
  - Certificate configuration
```

### Priority 3: Acceptable (No Action Needed)

✅ **ResultTableView.swift** (779 lines) - Complex table view, acceptable for now
✅ **NotebookContentView.swift** (637 lines) - Main coordinator view, under 600 limit
✅ **HighlightedTextEditor.swift** (421 lines) - Complex editor, acceptable

---

## Test File Refactoring (Optional)

### DatabaseIntegrationTests.swift (897 lines)
Split by test category:

```
- DatabaseIntegrationTests+Connection.swift (200 lines)
- DatabaseIntegrationTests+QueryExecution.swift (250 lines)
- DatabaseIntegrationTests+DataTypes.swift (250 lines)
- DatabaseIntegrationTests+ColumnEnrichment.swift (197 lines)
```

### ViewModelTests.swift (840 lines)
Split by feature:

```
- ViewModelTests+CellManagement.swift (250 lines)
- ViewModelTests+QueryExecution.swift (300 lines)
- ViewModelTests+ReadOnlyMode.swift (290 lines)
```

---

## Implementation Checklist

### Phase 1: Critical Logic Files (Week 1)
- [ ] Split DatabaseConnectionManager+QueryExecution.swift
- [ ] Split AppLogger.swift
- [ ] Split DesignSystem.swift
- [ ] Verify build passes
- [ ] Run all tests

### Phase 2: Secondary Logic Files (Week 2)
- [ ] Split DatabaseTypes.swift
- [ ] Split SQLAutocompleteProvider.swift
- [ ] Split SQLNotebookDocument.swift
- [ ] Verify build passes
- [ ] Run all tests

### Phase 3: View Files (Week 3)
- [ ] Split SQLTextView.swift
- [ ] Split ConnectionFormContent.swift
- [ ] Extract form components
- [ ] Verify UI works correctly
- [ ] Manual testing

### Phase 4: Test Files (Optional)
- [ ] Split DatabaseIntegrationTests.swift
- [ ] Split ViewModelTests.swift
- [ ] Verify all tests still pass

---

## Success Metrics

**After refactoring:**
- ✅ All logic files under 400 lines (strict)
- ✅ Simple views under 400 lines (recommended)
- ✅ Complex views under 600 lines (acceptable)
- ✅ Test files under 800 lines (acceptable)
- ✅ No compilation errors
- ✅ All tests passing
- ✅ Code more maintainable and focused

---

## Notes

- Extensions must be in same module (no imports needed)
- Keep related functionality together
- Avoid over-splitting (each file should be meaningful)
- Follow existing patterns in codebase
- Update this document as work progresses
