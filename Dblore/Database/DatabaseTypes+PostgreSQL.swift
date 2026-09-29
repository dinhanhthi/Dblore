//
//  DatabaseTypes+PostgreSQL.swift
//  Dblore
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
      // Check if this is a user-defined type (e.g., pgvector's vector type)
      // PostgresNIO doesn't have built-in support for custom types, so we need to
      // identify them by their name
      let typeName = "\(dataType)"

      // Handle pgvector extension types (case-insensitive check)
      if typeName.lowercased().contains("vector") {
        return "VECTOR"
      }

      // For other user-defined types, show "USER-DEFINED"
      return "USER-DEFINED"
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
      // Check if this is a user-defined type (e.g., pgvector's vector type)
      let typeName = "\(cell.dataType)"

      // Handle pgvector extension types
      // PostgresNIO returns "UNKNOWN <OID>" for custom types like vector
      // We need to check if it's either:
      // 1. Contains "vector" in name (for enriched types)
      // 2. Starts with "UNKNOWN" (try to parse as potential vector)
      if typeName.lowercased().contains("vector") || typeName.uppercased().hasPrefix("UNKNOWN") {
        // Try to get raw bytes first
        if let bytes = cell.bytes {
          // Try to parse as pgvector binary format
          if let result = parseVectorValue(from: bytes) {
            return result
          }
        }

        // Fallback: try to decode as ByteBuffer (standard way)
        if let buffer = try? cell.decode(ByteBuffer.self, context: .default) {
          if let result = parseVectorValue(from: buffer) {
            return result
          }
        }

        // Last resort: try text format
        if let value = try? cell.decode(String.self, context: .default) {
          return .string(value)
        }
      }

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

  /// Parse pgvector binary format into readable string representation.
  ///
  /// pgvector stores vectors in binary format for efficiency:
  /// - Bytes 0-3: Header (4 bytes, format unclear - skipped)
  /// - Bytes 4+: Float32 values (4 bytes each, **BIG-ENDIAN**)
  ///
  /// The actual dimension is calculated from buffer size: (total_bytes - 4) / 4
  ///
  /// Example hex dump for vector with 1536 dimensions (6148 bytes total):
  /// ```
  /// 06 00 00 00 BD 7E 20 00 3B F4 80 00 3D 21 A0 00 ...
  /// └─header──┘ └──float1──┘ └──float2──┘ └──float3──┘
  ///  (skip 4)   (BE)         (BE)         (BE)
  ///
  /// 6148 bytes - 4 (header) = 6144 bytes for floats
  /// 6144 / 4 = 1536 floats (actual dimension)
  /// ```
  ///
  /// - Parameter buffer: Raw bytes from PostgreSQL containing pgvector binary data
  /// - Returns: CellValue.string containing formatted array like "[0.123, 0.456, 0.789]",
  ///            or nil if the data doesn't match pgvector format
  private func parseVectorValue(from buffer: ByteBuffer) -> CellValue? {
    var buffer = buffer

    // Check minimum size (4 bytes for dimension)
    guard buffer.readableBytes >= 4 else {
      return nil
    }

    // Read and skip the 4-byte header (format unclear, but we skip it)
    // The header seems to be: [xx 00 00 00] where xx is some metadata
    _ = buffer.readInteger(endianness: .little, as: UInt32.self)

    // Calculate actual dimension from remaining bytes
    // After skipping 4-byte header, all remaining bytes are Float32 values
    let remainingBytes = buffer.readableBytes
    guard remainingBytes % 4 == 0 else {
      return nil  // Must be multiple of 4 for Float32 array
    }

    let dimension = remainingBytes / 4

    // Sanity check: dimension should be reasonable (1-10000)
    // pgvector typically uses dimensions like 384, 768, 1536 for embeddings
    guard dimension > 0 && dimension <= 10000 else {
      return nil
    }

    // Read float values from remaining buffer
    // IMPORTANT: pgvector stores floats in BIG-ENDIAN format, not little-endian!
    var values: [Float] = []
    for _ in 0..<dimension {
      if let bits = buffer.readInteger(endianness: .big, as: UInt32.self) {
        // Convert UInt32 bits to Float32
        let floatValue = Float(bitPattern: bits)
        values.append(floatValue)
      } else {
        // Should not happen if our calculation is correct
        return nil
      }
    }

    // Format as readable string: [0.123, 0.456, 0.789]
    // Float32 has ~7 significant digits, use %.9g for best representation
    // %.9g automatically chooses between fixed and scientific notation
    let formattedValues = values.map { value in
      String(format: "%.9g", value)
    }.joined(separator: ", ")
    return .string("[\(formattedValues)]")
  }
}
