//
//  DatabaseTypes+ErrorFormatting.swift
//  SQLNotebook
//
//  Error formatting utilities for database errors
//

import Foundation
import PostgresNIO

// MARK: - Error Formatting

extension DatabaseConnectionManager {
  /// Convert error code to user-friendly message
  /// - Parameter errorCode: The error code string
  /// - Returns: Human-readable error message
  func humanReadableErrorMessage(for errorCode: String) -> String? {
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

  /// Format a PostgreSQL error with detailed information
  /// - Parameters:
  ///   - error: The PostgreSQL error
  ///   - query: The SQL query that caused the error (optional, for better position reporting)
  func formatPostgresError(_ error: PSQLError, query: String? = nil) -> String {
    var message = ""

    // Get the main error message
    if let serverInfo = error.serverInfo {
      // Extract message from server info
      if let errorMessage = serverInfo[.message] {
        message = errorMessage
      } else if let severity = serverInfo[.severity] {
        // Try to get human-readable message first
        if let friendlyMessage = humanReadableErrorMessage(for: error.code.description) {
          message = "\(severity): \(friendlyMessage)"
        } else {
          message = "\(severity): \(error.code.description)"
        }
      } else {
        // Try to get human-readable message first
        message = humanReadableErrorMessage(for: error.code.description) ?? error.code.description
      }

      // Add detail if available
      if let detail = serverInfo[.detail] {
        message += "\n\nDetail: \(detail)"
      }

      // Add hint if available
      if let hint = serverInfo[.hint] {
        message += "\n\nHint: \(hint)"
      }

      // Add position if available (where in the query the error occurred)
      if let positionStr = serverInfo[.position],
        let position = Int(positionStr)
      {
        // If we have the query text, extract the problematic keyword/text
        if let query = query, position > 0 && position <= query.count {
          let errorContext = extractErrorContext(from: query, at: position)
          message += "\n\nNear: \"\(errorContext)\""
        } else {
          // Fallback to position number
          message += "\n\nPosition: \(positionStr)"
        }
      }
    } else {
      // Fallback to human-readable message or basic error description
      message = humanReadableErrorMessage(for: error.code.description) ?? error.code.description
    }

    return message
  }

  /// Extract the problematic keyword or context from query at the given position
  /// - Parameters:
  ///   - query: The SQL query text
  ///   - position: Character position in the query (1-indexed)
  /// - Returns: The word/keyword at the position or surrounding context
  func extractErrorContext(from query: String, at position: Int) -> String {
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
