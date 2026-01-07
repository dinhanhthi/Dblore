# Logging System Implementation (Phase 4.12)

## Problem
No centralized logging mechanism for debugging. Print statements scattered across codebase without thread-safety guarantees. Users cannot export logs for troubleshooting or bug reports.

## Solution
Implemented actor-based thread-safe logging system with dual-channel output (OSLog + File + Memory) and simple "Export Logs" button in Settings.

### Key Changes
- `SQLNotebook/Utilities/AppLogger.swift` - Actor-based logger with OSLog + File + Memory (1000 entry limit, ISO8601 timestamps)
- `SQLNotebookTests/AppLoggerTests.swift` - Unit tests for LogLevel, LogEntry, basic logging
- `SQLNotebook/Views/Sidebars/SettingsContent.swift:228-254` - Added "Export Logs" button + LogDocument
- `SQLNotebook/Database/DatabaseConnectionManager+QueryExecution.swift:30,102` - DEBUG logs for query execution
- `SQLNotebook/ViewModels/NotebookViewModel+Execution.swift:68` - INFO log for query execution
- `SQLNotebook/ViewModels/NotebookViewModel+Connection.swift:74,77` - INFO/WARNING logs for connection
- `SQLNotebook/ViewModels/NotebookViewModel+Sidebar.swift:112,118` - WARNING/ERROR logs for schema loading
- `SQLNotebook/Utilities/SQLAutocompleteProvider.swift:137,143` - WARNING/ERROR logs for autocomplete

## Already Tried
- ❌ Full log viewer UI with filtering/search - Rejected as too complex, chose simple export button instead

## Testing
- ✅ Unit tests pass for LogLevel comparison, LogEntry formatting, basic logging, file URL
- ✅ Actor pattern ensures thread safety
- ✅ Async file I/O prevents blocking main thread
- ✅ Logs exported to `sqlnotebook-logs-YYYY-MM-DD-HHMM.txt`

## Notes
- Uses `actor AppLogger` for Swift 6 thread safety (not `@Observable` + DispatchQueue)
- Global convenience functions: `logDebug()`, `logInfo()`, `logWarning()`, `logError()`
- Log format: `[timestamp] [level] [category] message — file:line function()`
- Files stored in `~/Library/Application Support/SQLNotebook/Logs/`
- Memory limit: 1000 entries (FIFO), file logs persist across sessions
- Simplified UI: export-only, no real-time viewer (can use Console.app instead)

## Security: Sensitive Data Protection (2026-01-07)

### Problem
Log files could contain sensitive information that users might export and share with developers:
- Database credentials (host, username, password)
- SQL queries with PII data in WHERE clauses or INSERT VALUES
- Connection strings with production database information

### Solution Implemented
Added comprehensive data sanitization to prevent sensitive information leakage:

#### 1. Connection Config Sanitization
- Added `ConnectionConfig.safeDisplayString` property that redacts host information
- Examples:
  - `db.example.com` → `db.*****.com`
  - `192.168.1.100` → `192.168.***.***`
  - `localhost` → `localhost` (safe for debugging)
- Updated `NotebookViewModel+Connection.swift:74` to use `safeDisplayString` instead of `displayString`

#### 2. SQL Query Sanitization
- Added `AppLogger.sanitizeQuery(_ query: String)` method
- Redacts:
  - String literals: `WHERE email='user@example.com'` → `WHERE email='[REDACTED]'`
  - Numeric values after `=`: `WHERE id=12345` → `WHERE id=[REDACTED]`
  - IN clauses: `IN (1, 2, 3)` → `IN ([REDACTED])`
- Updated all query logging calls:
  - `DatabaseConnectionManager+QueryExecution.swift:30,103`
  - `NotebookViewModel+Execution.swift:68`

#### 3. Connection Logging
- Added logging for database connect/disconnect operations with sanitized config:
  - `DatabaseConnectionManager.swift:119,158,161,237`
- Logs connection attempts, success, and failures with safe display strings

### Security Best Practices
- ✅ Never log passwords, tokens, or credentials
- ✅ Redact database hosts for production environments
- ✅ Sanitize SQL queries to prevent PII leakage
- ✅ Keep localhost unredacted for local development
- ✅ Use `safeDisplayString` for all connection-related logs

### Files Modified (Security)
- `SQLNotebook/Models/ConnectionConfig.swift` - Added `safeDisplayString` and `redactHost()` helper
- `SQLNotebook/Utilities/AppLogger.swift` - Added `sanitizeQuery()` method
- `SQLNotebook/ViewModels/NotebookViewModel+Connection.swift` - Use sanitized config in logs
- `SQLNotebook/Database/DatabaseConnectionManager+QueryExecution.swift` - Sanitize queries before logging
- `SQLNotebook/ViewModels/NotebookViewModel+Execution.swift` - Sanitize cell queries before logging
- `SQLNotebook/Database/DatabaseConnectionManager.swift` - Added connection/disconnection logging

---

## Log File Rotation & Retention (2026-01-07)

### Problem
Log files could accumulate indefinitely on user's disk, causing:
- Excessive disk space usage (potentially hundreds of MB over time)
- Large exported log files that are hard to share with developers
- Performance degradation when reading/exporting logs
- No automatic cleanup of old debugging data

### Solution Implemented
Added automatic log rotation with **7-day retention policy** and per-file size limits to keep disk usage under control.

#### 1. Daily Log Files
- **One file per day**: `sqlnotebook-YYYY-MM-DD.log` (e.g., `sqlnotebook-2026-01-07.log`)
- Files stored in `~/Library/Application Support/SQLNotebook/Logs/`
- Automatic rollover at midnight (new file created next day)
- Current day's logs go to today's file

#### 2. Automatic Cleanup (7-Day Retention)
- **Auto-deletes** log files older than 7 days on app startup
- Based on file **creation date**, not modification date
- Runs via `cleanupOldLogFiles()` in `AppLogger` initializer
- Console output: `"Cleaned up X old log file(s), freed Y.YY MB"`
- Silent if no files to delete

#### 3. File Size Protection
- **Maximum per-file size: 20 MB**
- Prevents runaway disk usage from excessive logging
- Stops writing to file if limit exceeded (prints warning to console)
- In-memory logs (1000 entries) continue working even if file writing stops
- Typical daily usage: 1-5 MB (20 MB is safety limit)

#### 4. Multi-File Export
- `getAllLogsText()` now **combines ALL log files** (not just today's)
- Includes all logs within retention period (up to 7 days)
- Files sorted **newest first** for easier debugging
- Each file section marked with `=== filename ===` header separator
- Export format:
  ```
  === sqlnotebook-2026-01-07.log ===
  [2026-01-07T10:30:00.123Z] [INFO] [Connection] Connected to database
  ...

  === sqlnotebook-2026-01-06.log ===
  [2026-01-06T14:20:15.456Z] [ERROR] [Database] Query failed
  ...
  ```

#### 5. Log Statistics API
New `getLogStatistics()` method for UI display:
```swift
let (fileCount, totalSize, oldestDate, newestDate) = await logger.getLogStatistics()
// Returns: (7 files, 15728640 bytes, 2026-01-01, 2026-01-07)
```

### Configuration Constants

Check the settings in @AppLogger.swift

### Disk Usage Analysis
- **Maximum total size**: ~140 MB (7 days × 20 MB/day worst case)
- **Typical total size**: 7-35 MB (7 days × 1-5 MB/day average)
- **Per-file limit**: 20 MB (safety cap)
- **Auto-cleanup**: Runs every app launch
- **Storage location**: `~/Library/Application Support/SQLNotebook/Logs/`

### Benefits
✅ **Controlled disk usage** - Maximum ~140 MB total (vs. unlimited before)
✅ **Automatic cleanup** - No manual intervention needed
✅ **Multi-day history** - Export last 7 days for comprehensive debugging
✅ **Performance protected** - Size limits prevent file I/O slowdowns
✅ **User-friendly** - Silent operation, no config needed
✅ **Developer-friendly** - Easy to request "export last 7 days of logs"

### Implementation Details
- Cleanup runs in `Task` during `AppLogger.shared` initialization
- Uses `FileManager.attributesOfItem()` for creation date and file size
- File age calculated via `Calendar.current.date(byAdding: .day, value: -7)`
- Deletes files via `FileManager.removeItem(at:)`
- Thread-safe (actor-based)

### Files Modified (Log Rotation)
- `SQLNotebook/Utilities/AppLogger.swift:115-118,137-143,190-264,292-397` - Added rotation, cleanup, statistics
