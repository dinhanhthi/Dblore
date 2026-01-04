//
//  DatabaseTypes.swift
//  SQLNotebook
//
//  Supporting types and utilities for database operations
//

import Foundation
import NIOCore
import NIOFoundationCompat
import PostgresNIO

// MARK: - Supporting Types

/// Result of a query execution
struct QueryResult: Sendable {
  nonisolated let columns: [ColumnInfo]
  nonisolated let rows: [[CellValue]]
  nonisolated let rowCount: Int
  nonisolated let executionTime: TimeInterval
  /// True if the result was limited due to reaching maxFetchRows
  nonisolated let wasLimited: Bool
  /// Row identifiers (ctid for PostgreSQL, rowid for SQLite) - one per row
  nonisolated let rowIdentifiers: [CellValue]
  /// True if user's LIMIT in query exceeded maxRows and was capped
  nonisolated let userLimitExceeded: Bool
  /// The original LIMIT value user specified (if any)
  nonisolated let userRequestedLimit: Int?
  /// Number of rows affected by UPDATE/DELETE/INSERT (nil for SELECT queries)
  nonisolated let affectedRows: Int?

  nonisolated init(
    columns: [ColumnInfo], rows: [[CellValue]], rowCount: Int, executionTime: TimeInterval,
    wasLimited: Bool = false, rowIdentifiers: [CellValue] = [],
    userLimitExceeded: Bool = false, userRequestedLimit: Int? = nil,
    affectedRows: Int? = nil
  ) {
    self.columns = columns
    self.rows = rows
    self.rowCount = rowCount
    self.executionTime = executionTime
    self.wasLimited = wasLimited
    self.rowIdentifiers = rowIdentifiers
    self.userLimitExceeded = userLimitExceeded
    self.userRequestedLimit = userRequestedLimit
    self.affectedRows = affectedRows
  }
}

/// Database-specific errors
enum DatabaseError: LocalizedError {
  case notConnected
  case connectionFailed(String)
  case queryFailed(String, TimeInterval)
  case emptyQuery

  var errorDescription: String? {
    switch self {
    case .notConnected:
      return "Not connected to database"
    case .connectionFailed(let message):
      return "Connection failed: \(message)"
    case .queryFailed(let message, _):
      return "Query failed: \(message)"
    case .emptyQuery:
      return "Query is empty"
    }
  }

  var executionTime: TimeInterval? {
    if case .queryFailed(_, let time) = self {
      return time
    }
    return nil
  }
}

// MARK: - Type Mapping & Parsing

extension DatabaseConnectionManager {
  /// Map PostgreSQL data type to display name
  func postgresDataTypeName(_ dataType: PostgresDataType) -> String {
    switch dataType {
    case .bool:
      return "BOOLEAN"
    case .int2:
      return "SMALLINT"
    case .int4:
      return "INTEGER"
    case .int8:
      return "BIGINT"
    case .float4:
      return "REAL"
    case .float8:
      return "DOUBLE PRECISION"
    case .numeric:
      return "NUMERIC"
    case .money:
      return "MONEY"
    case .char:
      return "CHAR"
    case .varchar:
      return "VARCHAR"
    case .text:
      return "TEXT"
    case .bytea:
      return "BYTEA"
    case .date:
      return "DATE"
    case .timestamp:
      return "TIMESTAMP"
    case .timestamptz:
      return "TIMESTAMPTZ"
    case .time:
      return "TIME"
    case .timetz:
      return "TIMETZ"
    case .interval:
      return "INTERVAL"
    case .uuid:
      return "UUID"
    case .json:
      return "JSON"
    case .jsonb:
      return "JSONB"
    case .xml:
      return "XML"
    case .point:
      return "POINT"
    case .inet:
      return "INET"
    case .cidr:
      return "CIDR"
    case .macaddr:
      return "MACADDR"
    default:
      return "UNKNOWN"
    }
  }

  /// Parse a cell value from PostgresCell
  func parseCellValue(from cell: PostgresCell) -> CellValue {
    // Check for NULL first
    // PostgresNIO represents NULL as nil bytes
    guard let bytes = cell.bytes, bytes.readableBytes > 0 else {
      return .null
    }

    // Parse based on PostgreSQL data type
    switch cell.dataType {
    case .bool:
      if let value = try? cell.decode(Bool.self, context: .default) {
        return .bool(value)
      }

    case .int2:
      if let value = try? cell.decode(Int16.self, context: .default) {
        return .int(Int(value))
      }

    case .int4:
      if let value = try? cell.decode(Int32.self, context: .default) {
        return .int(Int(value))
      }

    case .int8:
      if let value = try? cell.decode(Int64.self, context: .default) {
        return .int(Int(value))
      }

    case .float4:
      if let value = try? cell.decode(Float.self, context: .default) {
        return .double(Double(value))
      }

    case .float8:
      if let value = try? cell.decode(Double.self, context: .default) {
        return .double(value)
      }

    case .numeric:
      // PostgresNIO returns NUMERIC as Decimal (Foundation.Decimal) in binary format
      // NOTE: cell.bytes != nil check above already handles NULL cases
      // So we only reach here if there's actual data to decode
      if let decimalValue = try? cell.decode(Decimal.self, context: .default) {
        // Check for NaN - this can happen with special values or edge cases
        // PostgreSQL NUMERIC type doesn't support NaN, but we check anyway
        if decimalValue.isNaN {
          return .null
        }
        // Convert Decimal to Double
        return .double(Double(truncating: decimalValue as NSDecimalNumber))
      }
      // Fallback to String decoding for text format
      if let value = try? cell.decode(String.self, context: .default) {
        if let doubleValue = Double(value) {
          return .double(doubleValue)
        }
        return .string(value)
      }
      // If decode fails and we reach here, it might be NULL
      // (though this should have been caught by bytes check above)
      return .null

    case .money:
      // Money type should be decoded as String first, then parsed
      if let value = try? cell.decode(String.self, context: .default) {
        // Remove currency symbols and parse
        let cleaned = value.replacingOccurrences(of: "$", with: "")
          .replacingOccurrences(of: ",", with: "")
        if let doubleValue = Double(cleaned) {
          return .double(doubleValue)
        }
        return .string(value)
      }

    case .char, .varchar, .text:
      if let value = try? cell.decode(String.self, context: .default) {
        return .string(value)
      }

    case .date, .timestamp, .timestamptz:
      if let value = try? cell.decode(Date.self, context: .default) {
        return .date(value)
      }

    case .uuid:
      if let value = try? cell.decode(UUID.self, context: .default) {
        return .string(value.uuidString)
      }

    case .json, .jsonb:
      if let value = try? cell.decode(String.self, context: .default) {
        return .json(value)
      }

    case .bytea:
      if let value = try? cell.decode(ByteBuffer.self, context: .default) {
        return .data(Data(buffer: value))
      }

    default:
      // Default: try to decode as string
      if let value = try? cell.decode(String.self, context: .default) {
        // Check if it looks like JSON
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespaces)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
          || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
        {
          return .json(value)
        }
        return .string(value)
      }
    }

    return .null
  }

  /// Convert CellValue to SQL literal string
  func cellValueToSQL(_ value: CellValue) -> String {
    switch value {
    case .null:
      return "NULL"
    case .int(let i):
      return String(i)
    case .double(let d):
      return String(d)
    case .bool(let b):
      return b ? "TRUE" : "FALSE"
    case .string(let s):
      // Escape single quotes by doubling them
      let escaped = s.replacingOccurrences(of: "'", with: "''")
      return "'\(escaped)'"
    case .json(let j):
      let escaped = j.replacingOccurrences(of: "'", with: "''")
      return "'\(escaped)'::jsonb"
    case .date(let d):
      let iso = ISO8601DateFormatter().string(from: d)
      return "'\(iso)'::timestamp"
    case .data(let data):
      // Convert to hex format for bytea
      let hex = data.map { String(format: "%02x", $0) }.joined()
      return "'\\x\(hex)'::bytea"
    }
  }

  // MARK: - Error Formatting

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
        message = "\(severity): \(error.code.description)"
      } else {
        message = error.code.description
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
      // Fallback to basic error description
      message = error.code.description
    }

    return message
  }

  /// Extract the problematic keyword or context from query at the given position
  /// - Parameters:
  ///   - query: The SQL query text
  ///   - position: Character position in the query (1-indexed)
  /// - Returns: The word/keyword at the position or surrounding context
  private func extractErrorContext(from query: String, at position: Int) -> String {
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
