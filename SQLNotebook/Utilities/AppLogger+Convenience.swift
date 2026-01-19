//
//  AppLogger+Convenience.swift
//  SQLNotebook
//
//  Convenience methods and global functions for logging
//

import Foundation

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
    if let regex = try? NSRegularExpression(
      pattern: numericAfterEqualPattern, options: [.caseInsensitive])
    {
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
