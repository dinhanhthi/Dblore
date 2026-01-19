//
//  DatabaseTypes+PostgreSQL.swift
//  SQLNotebook
//
//  PostgreSQL-specific type mapping and cell value parsing
//

import Foundation
import NIOCore
import NIOFoundationCompat
import PostgresNIO

// MARK: - PostgreSQL Type Mapping & Parsing

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
}
