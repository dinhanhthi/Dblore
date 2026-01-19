//
//  AppLogger.swift
//  SQLNotebook
//
//  Thread-safe logging system using actor pattern
//
//  NOTE: This file has been split into focused modules:
//  - AppLogger+FileManagement.swift (file operations, cleanup, statistics)
//  - AppLogger+Convenience.swift (convenience methods and global functions)
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
    return
      "[\(timestamp)] [\(level.rawValue)] [\(category)] \(message) — \(fileName):\(line) \(function)"
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
    Task.detached {
      await self.writeToFile(entry: entry, fileURL: self.getLogFileURL())
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
}
