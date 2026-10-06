//
//  DatabaseTypes+ErrorFormatting.swift
//  Dblore
//
//  Error formatting utilities for database errors
//

import Foundation
import PostgresNIO

// MARK: - Error Formatting

extension PostgresSession {
  static func formatPostgresError(
    _ error: PSQLError, query: String?, statementTimeoutSeconds: Int
  ) -> String {
    if let timeout = statementTimeoutMessage(
      error, statementTimeoutSeconds: statementTimeoutSeconds)
    {
      return timeout
    }
    var message = ""

    if let serverInfo = error.serverInfo {
      if let errorMessage = serverInfo[.message] {
        message = errorMessage
      } else if let severity = serverInfo[.severity] {
        if let friendlyMessage = humanReadableErrorMessage(for: error.code.description) {
          message = "\(severity): \(friendlyMessage)"
        } else {
          message = "\(severity): \(error.code.description)"
        }
      } else {
        message = humanReadableErrorMessage(for: error.code.description) ?? error.code.description
      }

      if let detail = serverInfo[.detail] {
        message += "\n\nDetail: \(detail)"
      }

      if let hint = serverInfo[.hint] {
        message += "\n\nHint: \(hint)"
      } else if ["42P08", "42P18"].contains(serverInfo[.sqlState]) {
        // Bound :name values are untyped; PostgreSQL types a parameter from its first use,
        // and `:name IS NULL` gives it none (42P08 on Parse, 42P18 from PREPARE).
        message +=
          "\n\nHint: Cast the parameter where it is first used, e.g. :name::integer IS NULL"
      }

      if let positionStr = serverInfo[.position],
        let position = Int(positionStr)
      {
        if let query, position > 0 && position <= query.count {
          let errorContext = extractErrorContext(from: query, at: position)
          message += "\n\nNear: \"\(errorContext)\""
        } else {
          message += "\n\nPosition: \(positionStr)"
        }
      }
    } else {
      message = humanReadableErrorMessage(for: error.code.description) ?? error.code.description
    }

    return message
  }

  /// The server brake `statement_timeout` (applied on connect) stopped the statement: SQLSTATE
  /// 57014 "canceling statement due to statement timeout" (57014 is also an administrator's
  /// `pg_cancel_backend`, which keeps the server message). Nil for any other error.
  static func statementTimeoutMessage(_ error: PSQLError, statementTimeoutSeconds: Int) -> String? {
    guard let info = error.serverInfo, info[.sqlState] == "57014",
      info[.message]?.contains("statement timeout") == true
    else { return nil }
    let seconds = SessionBrakeLimits.clampStatementTimeout(statementTimeoutSeconds)
    return "Statement timed out after \(seconds)s (statement_timeout, SQLSTATE 57014) — change it "
      + "in the connection's Safety settings"
  }

  /// Convert error code to user-friendly message
  static func humanReadableErrorMessage(for errorCode: String) -> String? {
    // Map common error codes to friendly messages
    switch errorCode {
    case "sslUnsupported":
      return "SSL is not supported by the server"
    case "invalidAuthorizationSpecification":
      return "Invalid username or password"
    case "invalidPassword":
      return "Invalid password"
    case "connectionException":
      return "Failed to connect to the database server"
    case "connectionDoesNotExist":
      return "Connection does not exist"
    case "connectionFailure":
      return "Connection failed"
    case "clientCannotConnect":
      return "Cannot connect to the database server"
    case "serverNotListening":
      return "Database server is not listening"
    case "serverNotReady":
      return "Database server is not ready"
    default:
      return nil
    }
  }

  /// Extract the problematic keyword or context from query at the given position
  /// - Parameters:
  ///   - query: The SQL query text
  ///   - position: Character position in the query (1-indexed)
  /// - Returns: The word/keyword at the position or surrounding context
  static func extractErrorContext(from query: String, at position: Int) -> String {
    // Convert to 0-indexed
    let index = position - 1

    guard index >= 0 && index < query.count else {
      return "..."
    }

    // Get string index
    let stringIndex = query.index(query.startIndex, offsetBy: index)

    // Define word boundary characters (whitespace, punctuation, operators)
    let boundaries = CharacterSet.whitespacesAndNewlines
      .union(CharacterSet(charactersIn: "(),;=<>!+-*/[]{}"))

    // Find start of word (go backward from position)
    var startIndex = stringIndex
    while startIndex > query.startIndex {
      let prevIndex = query.index(before: startIndex)
      let char = query[prevIndex]
      if char.unicodeScalars.allSatisfy({ boundaries.contains($0) }) {
        break
      }
      startIndex = prevIndex
    }

    // Find end of word (go forward from position)
    var endIndex = stringIndex
    while endIndex < query.endIndex {
      let char = query[endIndex]
      if char.unicodeScalars.allSatisfy({ boundaries.contains($0) }) {
        break
      }
      endIndex = query.index(after: endIndex)
    }

    // Extract the word
    let word = String(query[startIndex..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)

    // If word is empty or very short, provide more context (5 chars before and after)
    if word.count < 2 {
      let contextStart =
        query.index(stringIndex, offsetBy: -5, limitedBy: query.startIndex) ?? query.startIndex
      let contextEnd =
        query.index(stringIndex, offsetBy: 5, limitedBy: query.endIndex) ?? query.endIndex
      let context = String(query[contextStart..<contextEnd]).trimmingCharacters(
        in: .whitespacesAndNewlines)
      return context.isEmpty ? "..." : context
    }

    return word
  }
}

extension DatabaseConnectionManager {
  /// Postgres error text. Uses the live session when one is published.
  func formatPostgresError(_ error: PSQLError, query: String? = nil) -> String {
    if let postgresSession {
      return postgresSession.formatPostgresError(error, query: query)
    }
    return PostgresSession.formatPostgresError(
      error, query: query,
      statementTimeoutSeconds: config?.statementTimeoutSeconds
        ?? SessionBrakeLimits.defaultStatementTimeout)
  }
}
