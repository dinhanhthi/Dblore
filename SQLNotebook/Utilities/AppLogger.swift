//
//  AppLogger.swift
//  SQLNotebook
//

import Foundation
import OSLog

/// Log level for filtering and categorizing log messages
enum LogLevel: String, Comparable, CaseIterable, Codable, Sendable {
  case debug = "DEBUG"
  case info = "INFO"
  case warning = "WARNING"
  case error = "ERROR"

  /// OSLog type mapping
  nonisolated var osLogType: OSLogType {
    switch self {
    case .debug:
      return .debug
    case .info:
      return .info
    case .warning:
      return .default
    case .error:
      return .error
    }
  }

  /// Icon for UI display
  nonisolated var icon: String {
    switch self {
    case .debug:
      return "hammer"
    case .info:
      return "info.circle"
    case .warning:
      return "exclamationmark.triangle"
    case .error:
      return "xmark.octagon"
    }
  }

  nonisolated static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    let order: [LogLevel] = [.debug, .info, .warning, .error]
    guard let lhsIndex = order.firstIndex(of: lhs),
      let rhsIndex = order.firstIndex(of: rhs)
    else {
      return false
    }
    return lhsIndex < rhsIndex
  }
}

/// Individual log entry
@preconcurrency
struct LogEntry: Identifiable, Codable, Sendable {
  let id: UUID
  let timestamp: Date
  let level: LogLevel
  let category: String
  let message: String
  let file: String
  let function: String
  let line: Int

  nonisolated init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    level: LogLevel,
    category: String,
    message: String,
    file: String,
    function: String,
    line: Int
  ) {
    self.id = id
    self.timestamp = timestamp
    self.level = level
    self.category = category
    self.message = message
    self.file = file
    self.function = function
    self.line = line
  }

  /// Formatted log line for export
  nonisolated var formattedLine: String {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = dateFormatter.string(from: timestamp)
    let fileName = (file as NSString).lastPathComponent
    return "[\(timestamp)] [\(level.rawValue)] [\(category)] \(message) — \(fileName):\(line) \(function)"
  }
}

/// Thread-safe logger using actor pattern
actor AppLogger {
  /// Shared singleton instance
  static let shared = AppLogger()

  /// OSLog instance for system logging
  private let osLog = Logger(subsystem: "com.sqlnotebook.app", category: "app")

  /// In-memory log storage
  private var logEntries: [LogEntry] = []

  /// Maximum number of log entries to keep in memory
  private let maxLogEntries = 1000

  /// Minimum log level to capture (configurable)
  var minimumLogLevel: LogLevel = .debug

  /// Number of days to keep log files (older files will be deleted)
  private let logRetentionDays = 7

  /// Maximum size per log file (10MB) - if exceeded, stop writing to prevent disk issues
  private let maxLogFileSize: Int64 = 10 * 1024 * 1024  // 10MB

  /// Log file URL
  private let logFileURL: URL = {
    let fileManager = FileManager.default
    let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    let logDirectory = appSupportURL.appendingPathComponent("SQLNotebook/Logs", isDirectory: true)

    // Create logs directory if needed
    try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    let dateString = dateFormatter.string(from: Date())

    return logDirectory.appendingPathComponent("sqlnotebook-\(dateString).log")
  }()

  private init() {
    // Private initializer for singleton
    // Clean up old log files on startup
    Task {
      await cleanupOldLogFiles()
    }
  }

  /// Log a message with specified level
  func log(
    _ message: String,
    level: LogLevel,
    category: String = "General",
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    // Filter by minimum log level
    guard level >= minimumLogLevel else { return }

    // Create log entry
    let entry = LogEntry(
      level: level,
      category: category,
      message: message,
      file: file,
      function: function,
      line: line
    )

    // Store in memory
    logEntries.append(entry)

    // Trim old entries if needed
    if logEntries.count > maxLogEntries {
      logEntries.removeFirst(logEntries.count - maxLogEntries)
    }

    // Write to OSLog
    osLog.log(level: level.osLogType, "[\(category)] \(message)")

    // Write to file (async, non-blocking)
    Task.detached { [logFileURL] in
      await self.writeToFile(entry: entry, fileURL: logFileURL)
    }
  }

  /// Write log entry to file
  private func writeToFile(entry: LogEntry, fileURL: URL) async {
    let logLine = entry.formattedLine + "\n"

    guard let data = logLine.data(using: .utf8) else { return }

    // Check file size before writing to prevent disk issues
    if let currentSize = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 {
      if currentSize >= maxLogFileSize {
        // File is too large, skip writing
        print("Log file exceeded max size (\(maxLogFileSize) bytes), skipping write")
        return
      }
    }

    do {
      if FileManager.default.fileExists(atPath: fileURL.path) {
        // Append to existing file
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: data)
        try fileHandle.close()
      } else {
        // Create new file
        try data.write(to: fileURL)
      }
    } catch {
      // Fallback to print if file writing fails
      print("Failed to write log to file: \(error)")
    }
  }

  /// Clean up log files older than retention period (7 days)
  private func cleanupOldLogFiles() async {
    let fileManager = FileManager.default
    guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return
    }

    let logDirectory = appSupportURL.appendingPathComponent("SQLNotebook/Logs", isDirectory: true)

    // Get all log files in directory
    guard let files = try? fileManager.contentsOfDirectory(
      at: logDirectory,
      includingPropertiesForKeys: [.creationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      return
    }

    let cutoffDate = Calendar.current.date(byAdding: .day, value: -logRetentionDays, to: Date())!

    var deletedCount = 0
    var totalSizeFreed: Int64 = 0

    for fileURL in files {
      // Only process .log files
      guard fileURL.pathExtension == "log" else { continue }

      // Get file creation date
      guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
            let creationDate = attributes[.creationDate] as? Date else {
        continue
      }

      // Delete if older than retention period
      if creationDate < cutoffDate {
        if let fileSize = attributes[.size] as? Int64 {
          totalSizeFreed += fileSize
        }

        try? fileManager.removeItem(at: fileURL)
        deletedCount += 1
      }
    }

    if deletedCount > 0 {
      let sizeMB = Double(totalSizeFreed) / (1024 * 1024)
      print("Cleaned up \(deletedCount) old log file(s), freed \(String(format: "%.2f", sizeMB)) MB")
    }
  }

  /// Get all log entries
  func getAllLogs() -> [LogEntry] {
    return logEntries
  }

  /// Get filtered logs by level
  func getLogs(level: LogLevel) -> [LogEntry] {
    return logEntries.filter { $0.level == level }
  }

  /// Get filtered logs by category
  func getLogs(category: String) -> [LogEntry] {
    return logEntries.filter { $0.category == category }
  }

  /// Clear all in-memory logs
  func clearLogs() {
    logEntries.removeAll()
  }

  /// Export logs to a file
  func exportLogs(to url: URL) async throws {
    let allLogs = logEntries.map { $0.formattedLine }.joined(separator: "\n")
    try allLogs.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Get all logs as formatted text (for synchronous export)
  /// Combines all log files within retention period (7 days)
  nonisolated func getAllLogsText() -> String {
    let fileManager = FileManager.default
    guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return "No logs available"
    }

    let logDirectory = appSupportURL.appendingPathComponent("SQLNotebook/Logs", isDirectory: true)

    // Get all log files sorted by date (newest first)
    guard let files = try? fileManager.contentsOfDirectory(
      at: logDirectory,
      includingPropertiesForKeys: [.creationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      return "No logs available"
    }

    // Filter and sort log files by creation date (newest first)
    let logFiles = files
      .filter { $0.pathExtension == "log" }
      .sorted { file1, file2 in
        guard let date1 = try? fileManager.attributesOfItem(atPath: file1.path)[.creationDate] as? Date,
              let date2 = try? fileManager.attributesOfItem(atPath: file2.path)[.creationDate] as? Date else {
          return false
        }
        return date1 > date2  // Newest first
      }

    var combinedLogs = ""

    // Read and combine all log files
    for fileURL in logFiles {
      if let data = try? Data(contentsOf: fileURL),
         let content = String(data: data, encoding: .utf8) {
        let fileName = fileURL.lastPathComponent
        combinedLogs += "=== \(fileName) ===\n"
        combinedLogs += content
        if !content.hasSuffix("\n") {
          combinedLogs += "\n"
        }
        combinedLogs += "\n"
      }
    }

    return combinedLogs.isEmpty ? "No logs available" : combinedLogs
  }

  /// Get current log file URL
  func getLogFileURL() -> URL {
    return logFileURL
  }

  /// Get log file size
  func getLogFileSize() -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)
    else {
      return nil
    }
    return attributes[.size] as? Int64
  }

  /// Get statistics about all log files
  func getLogStatistics() -> (fileCount: Int, totalSize: Int64, oldestDate: Date?, newestDate: Date?) {
    let fileManager = FileManager.default
    guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return (0, 0, nil, nil)
    }

    let logDirectory = appSupportURL.appendingPathComponent("SQLNotebook/Logs", isDirectory: true)

    guard let files = try? fileManager.contentsOfDirectory(
      at: logDirectory,
      includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ) else {
      return (0, 0, nil, nil)
    }

    let logFiles = files.filter { $0.pathExtension == "log" }
    var totalSize: Int64 = 0
    var oldestDate: Date?
    var newestDate: Date?

    for fileURL in logFiles {
      if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path) {
        // Sum up file sizes
        if let fileSize = attributes[.size] as? Int64 {
          totalSize += fileSize
        }

        // Track oldest and newest dates
        if let creationDate = attributes[.creationDate] as? Date {
          if oldestDate == nil || creationDate < oldestDate! {
            oldestDate = creationDate
          }
          if newestDate == nil || creationDate > newestDate! {
            newestDate = creationDate
          }
        }
      }
    }

    return (logFiles.count, totalSize, oldestDate, newestDate)
  }
}

// MARK: - Query Sanitization

extension AppLogger {
  /// Sanitize SQL query for logging (redact sensitive values in WHERE clauses, INSERT VALUES, etc.)
  /// This prevents PII and sensitive data from being logged
  /// Examples:
  /// - "WHERE ssn='123-45-6789'" -> "WHERE ssn='[REDACTED]'"
  /// - "INSERT INTO users VALUES ('john@email.com', 'pass123')" -> "INSERT INTO users VALUES ('[REDACTED]', '[REDACTED]')"
  /// - "SELECT * FROM users" -> "SELECT * FROM users" (no changes)
  nonisolated func sanitizeQuery(_ query: String) -> String {
    var sanitized = query

    // Redact string literals in quotes (both single and double quotes)
    // Pattern: 'value' or "value" -> '[REDACTED]'
    // This catches most sensitive data in WHERE clauses and VALUES clauses
    let stringLiteralPattern = #"(['"])(?:(?=(\\?))\2.)*?\1"#
    if let regex = try? NSRegularExpression(pattern: stringLiteralPattern, options: []) {
      let range = NSRange(sanitized.startIndex..., in: sanitized)
      sanitized = regex.stringByReplacingMatches(
        in: sanitized,
        options: [],
        range: range,
        withTemplate: "'[REDACTED]'"
      )
    }

    // Redact numeric literals after = or IN (potential sensitive IDs)
    // Pattern: = 123456789 -> = [REDACTED]
    // Pattern: IN (1, 2, 3) -> IN ([REDACTED])
    let numericAfterEqualPattern = #"(=\s*)(\d+)"#
    if let regex = try? NSRegularExpression(pattern: numericAfterEqualPattern, options: [.caseInsensitive]) {
      let range = NSRange(sanitized.startIndex..., in: sanitized)
      sanitized = regex.stringByReplacingMatches(
        in: sanitized,
        options: [],
        range: range,
        withTemplate: "$1[REDACTED]"
      )
    }

    // Redact content inside IN (...) clauses
    let inClausePattern = #"IN\s*\([^)]+\)"#
    if let regex = try? NSRegularExpression(pattern: inClausePattern, options: [.caseInsensitive]) {
      let range = NSRange(sanitized.startIndex..., in: sanitized)
      sanitized = regex.stringByReplacingMatches(
        in: sanitized,
        options: [],
        range: range,
        withTemplate: "IN ([REDACTED])"
      )
    }

    return sanitized
  }
}

// MARK: - Convenience Extensions

extension AppLogger {
  /// Log debug message
  func debug(
    _ message: String,
    category: String = "General",
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    log(message, level: .debug, category: category, file: file, function: function, line: line)
  }

  /// Log info message
  func info(
    _ message: String,
    category: String = "General",
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    log(message, level: .info, category: category, file: file, function: function, line: line)
  }

  /// Log warning message
  func warning(
    _ message: String,
    category: String = "General",
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    log(message, level: .warning, category: category, file: file, function: function, line: line)
  }

  /// Log error message
  func error(
    _ message: String,
    category: String = "General",
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    log(message, level: .error, category: category, file: file, function: function, line: line)
  }
}

// MARK: - Global Convenience Functions

/// Global logger instance for easy access
let logger = AppLogger.shared

/// Log debug message (global convenience)
func logDebug(
  _ message: String,
  category: String = "General",
  file: String = #file,
  function: String = #function,
  line: Int = #line
) {
  Task {
    await logger.debug(message, category: category, file: file, function: function, line: line)
  }
}

/// Log info message (global convenience)
func logInfo(
  _ message: String,
  category: String = "General",
  file: String = #file,
  function: String = #function,
  line: Int = #line
) {
  Task {
    await logger.info(message, category: category, file: file, function: function, line: line)
  }
}

/// Log warning message (global convenience)
func logWarning(
  _ message: String,
  category: String = "General",
  file: String = #file,
  function: String = #function,
  line: Int = #line
) {
  Task {
    await logger.warning(message, category: category, file: file, function: function, line: line)
  }
}

/// Log error message (global convenience)
func logError(
  _ message: String,
  category: String = "General",
  file: String = #file,
  function: String = #function,
  line: Int = #line
) {
  Task {
    await logger.error(message, category: category, file: file, function: function, line: line)
  }
}
