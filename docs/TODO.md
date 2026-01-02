# TODO.md - SQL Notebook Implementation Tasks

## Current Status Overview

- ✅ **Phase 1: Core Structure** - COMPLETE
- ✅ **Phase 2: Cell Editor** - COMPLETE
- ✅ **Phase 3: Database Integration** - COMPLETE
- ⏳ **Phase 4: Polish** - MOSTLY COMPLETE (9 of 13 sections)
- ⏳ **Phase 5: Advanced Features** - NOT STARTED
- 🔒 **Phase 6: Security & Safety** - PARTIAL (Some key features complete, some in-progress)
- ✅ **Phase 7: Testing Suite** - MOSTLY COMPLETE (CI/CD setup done, test coverage partial)
- 🎯 **Phase 8: Editor Mode** - NOT STARTED (Last phase)

---

## Phase 4: Polish (MOSTLY COMPLETE)

### 4.2 Header Actions - PARTIAL
- [x] Wire up "+ Code" button
- [x] Implement "Run All" functionality
- [x] Implement "Clear All Outputs"
- [x] Button icons using SF Symbols
- [x] Add confirmation dialog for Run All
- [ ] **Implement cell execution queue system**
  - [ ] Queue management for multiple cells
  - [ ] Visual indicator for queued cells
  - [ ] Queue state for cells
  - [ ] Queue position indicator
  - [ ] Add individual cells to queue
  - [ ] Cancel queued cells

### 4.4 Drag and Drop - NOT STARTED
- [ ] Add drag handle to cell left sidebar
- [ ] Implement `onMove` modifier for cell reordering
- [ ] Add visual feedback during drag
- [ ] Update cell order in notebook model

### 4.6 Global Keyboard Shortcuts - PARTIAL
- [x] All basic shortcuts implemented (`Cmd+N`, `Cmd+O`, `Cmd+S`, `Cmd+Shift+Enter`, etc.)
- [x] Settings panel with keyboard shortcuts
- [ ] `Cmd+/` for comment/uncomment SQL line

### 4.7 Auto-save & Document State - PARTIAL
- [x] Implement auto-save on changes (debounced)
- [x] Track document dirty state
- [x] Show unsaved indicator in footer
- [ ] Prompt to save on close if unsaved

### 4.8 Result Display Controls - NOT STARTED
- [ ] Add show/hide toggle button in cell sidebar
- [ ] Implement collapse/expand animation
- [ ] Persist result visibility state per cell
- [ ] Visual indicator (chevron icon) for collapsed state

### 4.11 File Optimization - NOT STARTED
- [ ] Detect large file size (> 10MB)
- [ ] Implement compression option
- [ ] Add option to remove old results automatically
- [ ] Use compact JSON format for large files
- [ ] Add file size indicator in footer

### 4.12 Logging System - NOT STARTED
- [ ] Create `AppLogger` utility class
- [ ] Replace `print()` statements with logging calls
- [ ] Add log levels (debug, info, warning, error)
- [ ] Implement log capture and export system

### 4.13 Theme Toggle (Dark/Light Mode) - NOT STARTED
- [ ] Add theme preference to `AppSettings`
- [ ] Store theme preference in UserDefaults
- [ ] Update `DesignSystem.swift` for light/dark modes
- [ ] Create light mode color variants
- [ ] Use `@Environment(\.colorScheme)` for dynamic colors
- [ ] Add theme toggle control to Settings panel

---

## Phase 5: Advanced Features (NOT STARTED)

### 5.1 Query History
- [ ] Store executed queries with timestamps
- [ ] Create query history view/panel
- [ ] Allow re-running queries from history

### 5.2 Export Results
- [ ] Implement "Export to CSV" for result tables
- [ ] Add export button to result metadata bar

### 5.3 Multiple Database Support
- [ ] Abstract database connection interface
- [ ] Add SQLite support
- [ ] Add MySQL support (optional)

### 5.4 Query Autocomplete (Optional)
- [ ] Implement autocomplete popup for table/column names
- [ ] Implement SQL keyword autocomplete

### 5.5 Tabs Support - Multiple Database Connections
- [ ] Create tab management system
- [ ] Implement tab bar UI component
- [ ] Add "New Tab" button
- [ ] Handle tab switching and persistence
- [ ] Add keyboard shortcuts: `Cmd+T`, `Cmd+W`, `Cmd+1-9`

### 5.6 AI-Powered Natural Language Query (Local Model Only)
- [ ] Select local LLM framework
- [ ] Integrate local model into app
- [ ] Implement prompt engineering for natural language → SQL
- [ ] Create UI component for AI query input

### 5.7 Schema Visualizer
- [ ] Query foreign key relationships
- [ ] Build relationship graph
- [ ] Create visual graph component
- [ ] Implement pan and zoom functionality

---

## Phase 6: Security & Safety Features (PARTIAL)

### 6.0.2 Connection Security - PARTIAL
- [x] Support SSL/TLS connection modes (all 6 PostgreSQL modes)
- [x] Smart cloud database detection
- [ ] Fix certificate verification for `.require` mode
- [ ] Add connection timeout configuration
- [ ] Add connection retry logic with exponential backoff

### 6.0.3 Query Execution Security - PARTIAL
- [x] Enforce row limits to prevent memory exhaustion
- [x] Detect modification queries
- [ ] Add confirmation dialogs for destructive operations
- [ ] Add read-only mode option
- [ ] Add transaction management

### 6.0.4 Data Modification Safety - MOSTLY COMPLETE
- [x] Use primary key columns for UPDATE WHERE clause
- [x] Use ctid (PostgreSQL) for row identification
- [x] Boolean toggle UI for value editing ✅
- [ ] **Value Format Validation** - Validate integer, uuid, jsonb, date, timestamp types
  - [ ] Check modified value format matches cell type when in edit mode
  - [ ] Display validation error/warning in footer sidebar
  - [ ] Disable "save" button when validation fails
- [ ] Add confirmation for inline cell editing
- [ ] Add transaction support for inline edits

### 6.0.5 & 6.0.6 Audit & User Education - NOT STARTED
- [ ] Query execution logging and audit trail
- [ ] Security warnings and tips in UI
- [ ] Connection security indicator

---

## Phase 7: Testing Suite (MOSTLY COMPLETE)

### Test Infrastructure - MOSTLY COMPLETE
- [x] Unit Test target setup
- [x] UI Test target setup
- [x] GitHub Actions CI/CD workflow configured
- [x] Docker PostgreSQL test database setup
- [x] Test database initialization script
- [x] CI/CD workflow for automated testing

### Unit Tests - MOSTLY COMPLETE
- [x] Data model serialization tests (`SQLNotebook`, `NotebookCell`, `CellValue`, etc.)
- [x] SQL syntax highlighter tests
- [x] ViewModel logic tests
- [ ] Document operations tests (round-trip)
- [ ] `CellResult` and `DatabaseSchema` model tests

### Integration Tests - PARTIAL
- [ ] `DatabaseConnectionManager` connection tests
- [ ] Query execution tests (SELECT, INSERT/UPDATE/DELETE)
- [ ] Schema loading tests
- [ ] Type mapping tests (JSON/JSONB, DATE, TIMESTAMP)

### UI Tests - NOT STARTED
- [ ] Basic workflow tests (create, open, save notebook)
- [ ] Query execution flow tests
- [ ] Connection flow tests
- [ ] Document persistence tests

---

## Phase 8: Editor Mode (NOT STARTED - LAST PHASE)

A traditional SQL editor mode with single editor and result panel below.

### 8.1 Core Editor Mode Implementation
- [ ] Add `ViewMode` enum (`.notebook`, `.editor`)
- [ ] Create `EditorModeView` component
- [ ] Single SQL editor with syntax highlighting
- [ ] Single result panel below editor

### 8.2 Execution Features
- [ ] Implement "Run Selection" functionality
- [ ] Implement "Run All" functionality
- [ ] Add execution buttons

### 8.3 Mode Switching UI
- [ ] Add mode toggle button in header
- [ ] Add keyboard shortcut to toggle mode
- [ ] Persist view mode preference

### 8.4-8.6 Sidebar Integration, Data Conversion & Testing
- [ ] Preserve sidebars in editor mode
- [ ] Handle data conversion between modes
- [ ] Test mode switching and keyboard shortcuts

---

## Recent Completions

### Boolean Toggle UI for Value Editing ✅ (Phase 6.0.4)
Toggle slider for boolean value editing in right sidebar. User clicks toggle instead of typing "true"/"false". Implemented in [CellInfoContent.swift](SQLNotebook/Views/Sidebars/CellInfoContent.swift).

### Left Sidebar - Database Structure ✅
Tree view showing database tables, columns, row counts, and primary keys. Click to insert table/column names into editor. Auto-loads schema on connection.

### SSL Connection Enhancement ✅
Connection string input mode with auto-parsing. Smart cloud database detection (Supabase, AWS, Azure, GCP). SSL mode picker and fixed certificate verification.

---

## Next Priorities

### CURRENT: Complete Phase 4 Polish (Medium Effort)
Priority UI enhancements:

1. **Theme Toggle (4.13)** - Dark/light mode preference
2. **Result Show/Hide (4.8)** - Collapse/expand results per cell
3. **Comment/Uncomment (4.6)** - `Cmd+/` shortcut
4. **Drag and Drop (4.4)** - Reorder cells
5. **Save Prompt (4.7)** - Warn before closing unsaved
6. **Cell Execution Queue (4.2)** - Visual queue for batch execution

### THEN: Complete Phase 6 Security (High Priority)
1. **Value Format Validation (6.0.4)** - Validate integer, uuid, jsonb, etc.
2. **Confirmation Dialogs (6.0.3)** - Warn before DELETE/UPDATE
3. **Read-Only Mode** - Prevent accidental modifications
4. **Connection Retry Logic (6.0.2)** - Exponential backoff

### THEN: Phase 7 Integration Tests & Phase 8 Editor Mode
Complete test coverage and implement the final editor mode phase.

### LATER: Phase 5 Advanced Features
Schema visualizer, AI queries, tabs, query history, export to CSV, multiple DB support.

---

## Definition of Done

Each task is complete when:
1. Feature is implemented according to specifications
2. Code follows Swift/SwiftUI best practices
3. Relevant tests are written and passing
4. Feature works in both light and dark mode
5. No compiler warnings or runtime errors
6. Code is reviewed and committed
