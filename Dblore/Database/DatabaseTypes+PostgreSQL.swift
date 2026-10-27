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

// MARK: - PostgreSQL table identity

extension TableRef {
  /// PostgreSQL table identity. The `pg:<oid>` string is built only here.
  nonisolated static func postgresql(oid: UInt32) -> TableRef {
    TableRef("pg:\(oid)")
  }

  /// OID from `postgresql(oid:)`. Nil for any other identity.
  nonisolated var postgresOID: UInt32? {
    let prefix = "pg:"
    guard identity.hasPrefix(prefix) else { return nil }
    return UInt32(identity.dropFirst(prefix.count))
  }
}

extension ColumnInfo {
  /// Row description: table OID becomes `TableRef`, attribute number becomes `columnOrdinal`.
  nonisolated init(name: String, type: String, origin: PostgresColumn?) {
    if let origin {
      self.init(
        name: name, type: type, tableOID: UInt32(bitPattern: origin.tableOID),
        attributeNumber: origin.columnAttributeNumber)
    } else {
      self.init(name: name, type: type, origin: nil as ColumnOrigin?)
    }
  }

  /// Same identity as a row description, for callers that already hold the OID and attribute number.
  nonisolated init(name: String, type: String, tableOID: UInt32?, attributeNumber: Int16?) {
    let columnOrigin: ColumnOrigin?
    if let tableOID, let attributeNumber {
      columnOrigin = ColumnOrigin(
        tableID: .postgresql(oid: tableOID), columnOrdinal: Int(attributeNumber))
    } else {
      columnOrigin = nil
    }
    self.init(name: name, type: type, origin: columnOrigin)
  }

  /// `origin` when the column was read from a table. Nil for an expression, which PostgreSQL
  /// describes with table OID 0.
  nonisolated var tableOrigin: ColumnOrigin? {
    origin?.tableID == .postgresql(oid: 0) ? nil : origin
  }
}

// MARK: - PostgreSQL Type Mapping & Parsing

extension DatabaseConnectionManager {
  /// Extension types the Cell Value viewers read, found by name and owned by an extension:
  /// their OIDs differ from one database to the next, so they are never hardcoded.
  nonisolated static let viewerExtensionTypesSQL = """
    SELECT t.oid::int8, t.typname::text FROM pg_type t
    WHERE t.typname IN ('geometry', 'geography', 'vector', 'halfvec', 'sparsevec')
      AND EXISTS (
        SELECT 1 FROM pg_depend d
        WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e')
    """

  /// Map PostgreSQL data type to display name. `extensionTypes` names extension types by OID
  /// (`viewerExtensionTypesSQL`), shown uppercased like the schema's `udt_name`.
  nonisolated static func postgresDataTypeName(
    _ dataType: PostgresDataType, extensionTypes: [UInt32: String] = [:]
  ) -> String {
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
      if let name = extensionTypes[dataType.rawValue] {
        return name.uppercased()
      }

      let typeName = "\(dataType)"

      // PostgresNIO names known array types "INTEGER[]", "TEXT[]", ...
      if typeName.hasSuffix("[]") {
        return typeName
      }

      // Handle pgvector extension types (case-insensitive check)
      if typeName.lowercased().contains("vector") {
        return "VECTOR"
      }

      // For other user-defined types, show "USER-DEFINED"
      return "USER-DEFINED"
    }
  }

  /// Parse a cell value from PostgresCell. `extensionTypes` as in `postgresDataTypeName`.
  nonisolated static func parseCellValue(
    from cell: PostgresCell, extensionTypes: [UInt32: String] = [:]
  ) -> CellValue {
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

    case .char, .varchar, .text, .name:
      if let value = try? cell.decode(String.self, context: .default) {
        return .string(value)
      }

    case .date:
      // No time and no time zone: the date text, never midnight UTC
      if cell.format == .text {
        if let value = try? cell.decode(String.self, context: .default) { return .string(value) }
      } else if var buffer = cell.bytes, buffer.readableBytes == 4,
        let days = buffer.readInteger(endianness: .big, as: Int32.self)
      {
        return .string(dateText(daysSince2000: days))
      }

    case .point:
      // point_send: x then y as big-endian float8; shown as point_out's text, `(1.5,-2)`
      if cell.format == .text {
        if let value = try? cell.decode(String.self, context: .default) { return .string(value) }
      } else {
        var buffer = bytes
        guard buffer.readableBytes == 16,
          let x = buffer.readInteger(endianness: .big, as: UInt64.self),
          let y = buffer.readInteger(endianness: .big, as: UInt64.self)
        else { return .data(Data(buffer: bytes)) }
        return .string(
          "(\(float8Text(Double(bitPattern: x))),\(float8Text(Double(bitPattern: y))))")
      }

    case .timestamp, .timestamptz:
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

    case .boolArray:
      if let value = arrayLiteral(cell, Bool.self, { $0 ? "t" : "f" }) { return value }

    case .int2Array:
      if let value = arrayLiteral(cell, Int16.self, { String($0) }) { return value }

    case .int4Array:
      if let value = arrayLiteral(cell, Int32.self, { String($0) }) { return value }

    case .int8Array:
      if let value = arrayLiteral(cell, Int64.self, { String($0) }) { return value }

    case .float4Array:
      if let value = arrayLiteral(cell, Float.self, { String($0) }) { return value }

    case .float8Array:
      if let value = arrayLiteral(cell, Double.self, { String($0) }) { return value }

    case .uuidArray:
      if let value = arrayLiteral(cell, UUID.self, { $0.uuidString }) { return value }

    case .textArray, .varcharArray:
      if let value = arrayLiteral(cell, String.self, quoteArrayElement) { return value }

    default:
      // geometry_send / geography_send write EWKB, which the Cell Value viewer reads.
      // halfvec / sparsevec binary is not the float32 layout below: decoded to their text
      // form, or else kept as bytes, never misread as a vector.
      if let name = extensionTypes[cell.dataType.rawValue],
        ["geometry", "geography", "halfvec", "sparsevec"].contains(name)
      {
        if cell.format == .binary, name == "halfvec", let text = halfvecText(from: bytes) {
          return .string(text)
        }
        if cell.format == .binary, name == "sparsevec", let text = sparsevecText(from: bytes) {
          return .string(text)
        }
        return .data(Data(buffer: bytes))
      }

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

  /// date_send's days since 2000-01-01 as the server's ISO text: `2025-01-01`, `0044-03-15 BC`,
  /// `infinity` / `-infinity`.
  private nonisolated static func dateText(daysSince2000 days: Int32) -> String {
    if days == Int32.max { return "infinity" }
    if days == Int32.min { return "-infinity" }
    return CivilDate.text(daysSince1970: Int(days) + 10_957, bcSuffix: " BC")
  }

  /// float8out's text: the shortest round-trip digits, fixed for decimal exponents -4...14
  /// (`0.0001`, `100000000000000`), else scientific with a signed two-digit-minimum exponent
  /// (`1e-05`, `1e+15`); `-0`, `NaN`, `Infinity`, `-Infinity`.
  private nonisolated static func float8Text(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
    let sign = value.sign == .minus ? "-" : ""
    if value == 0 { return sign + "0" }
    // Swift's description has the same shortest digits; only its layout differs.
    let parts = value.magnitude.description.split(separator: "e")
    let mantissa = parts[0]
    var exponent =
      (mantissa.firstIndex(of: ".").map { mantissa[..<$0].count } ?? mantissa.count) - 1
    if parts.count == 2, let shift = Int(parts[1]) { exponent += shift }
    var digits = mantissa.filter { $0 != "." }
    while digits.first == "0" {
      digits.removeFirst()
      exponent -= 1
    }
    while digits.last == "0" { digits.removeLast() }
    guard (-4...14).contains(exponent) else {
      let fraction = digits.dropFirst()
      let power = String(abs(exponent))
      return sign + digits.prefix(1) + (fraction.isEmpty ? "" : "." + fraction) + "e"
        + (exponent < 0 ? "-" : "+") + (power.count < 2 ? "0" : "") + power
    }
    if exponent < 0 { return sign + "0." + String(repeating: "0", count: -exponent - 1) + digits }
    if digits.count <= exponent + 1 {
      return sign + digits + String(repeating: "0", count: exponent + 1 - digits.count)
    }
    return sign + digits.prefix(exponent + 1) + "." + digits.dropFirst(exponent + 1)
  }

  /// halfvec_send: dim (UInt16), unused (UInt16), then dim IEEE half floats, all big-endian.
  /// `[1, 2, 3]`; nil unless the bytes are exactly that long and dim is within
  /// `VectorValue.maxDimensions`.
  private nonisolated static func halfvecText(from buffer: ByteBuffer) -> String? {
    var buffer = buffer
    guard let dimension = buffer.readInteger(endianness: .big, as: UInt16.self),
      buffer.readInteger(endianness: .big, as: UInt16.self) != nil,
      (1...VectorValue.maxDimensions).contains(Int(dimension)),
      buffer.readableBytes == Int(dimension) * 2
    else { return nil }
    var values: [String] = []
    for _ in 0..<dimension {
      guard let bits = buffer.readInteger(endianness: .big, as: UInt16.self) else { return nil }
      values.append(String(format: "%.9g", Float(Float16(bitPattern: bits))))
    }
    return "[" + values.joined(separator: ", ") + "]"
  }

  /// sparsevec_send: dim, nnz, unused (Int32 each), then nnz 0-based indices (Int32) and nnz
  /// values (Float32), all big-endian. pgvector's text form `{1:0.5,3:2}/5`, indices 1-based;
  /// nil unless the bytes are exactly that long and nnz <= dim <= `VectorValue.maxDimensions`.
  private nonisolated static func sparsevecText(from buffer: ByteBuffer) -> String? {
    var buffer = buffer
    guard let dimension = buffer.readInteger(endianness: .big, as: Int32.self),
      let count = buffer.readInteger(endianness: .big, as: Int32.self),
      buffer.readInteger(endianness: .big, as: Int32.self) != nil,
      (1...VectorValue.maxDimensions).contains(Int(dimension)),
      (0...dimension).contains(count),
      buffer.readableBytes == Int(count) * 8
    else { return nil }
    var indices: [Int] = []
    for _ in 0..<count {
      guard let index = buffer.readInteger(endianness: .big, as: Int32.self) else { return nil }
      indices.append(Int(index) + 1)
    }
    var entries: [String] = []
    for index in indices {
      guard let bits = buffer.readInteger(endianness: .big, as: UInt32.self) else { return nil }
      entries.append("\(index):" + String(format: "%.9g", Float(bitPattern: bits)))
    }
    return "{" + entries.joined(separator: ",") + "}/\(dimension)"
  }

  /// Decode a one-dimensional array cell and render it as a PostgreSQL array literal, `{1,2}`.
  /// nil when the cell has NULL elements or more dimensions, which PostgresNIO cannot decode.
  private nonisolated static func arrayLiteral<Element: PostgresArrayDecodable>(
    _ cell: PostgresCell, _ element: Element.Type, _ format: (Element) -> String
  ) -> CellValue?
  where Element == Element._DecodableType {
    guard let values = try? cell.decode([Element].self, context: .default) else { return nil }
    return .string("{" + values.map(format).joined(separator: ",") + "}")
  }

  /// Quote a text element the way array output does: only when it would be ambiguous.
  private nonisolated static func quoteArrayElement(_ text: String) -> String {
    let needsQuotes =
      text.isEmpty || text.caseInsensitiveCompare("NULL") == .orderedSame
      || text.contains(where: {
        $0 == "," || $0 == "\"" || $0 == "\\" || $0 == "{" || $0 == "}" || $0.isWhitespace
      })
    guard needsQuotes else { return text }
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"" + escaped + "\""
  }

  /// Parse pgvector binary format into readable string representation.
  ///
  /// pgvector stores vectors in binary format for efficiency:
  /// - Bytes 0-1: dimension (UInt16, big-endian); bytes 2-3: unused (0)
  /// - Bytes 4+: Float32 values (4 bytes each, **BIG-ENDIAN**)
  ///
  /// The dimension must equal (total_bytes - 4) / 4
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
  private nonisolated static func parseVectorValue(from buffer: ByteBuffer) -> CellValue? {
    var buffer = buffer

    // Check minimum size (4 bytes for dimension)
    guard buffer.readableBytes >= 4 else {
      return nil
    }

    // Header (vector_send): the dimension as a big-endian UInt16, then an unused UInt16 (0).
    // Both must match the payload, so other bytes (an enum label such as "refunded") are not
    // read as a vector.
    guard let declared = buffer.readInteger(endianness: .big, as: UInt16.self),
      buffer.readInteger(endianness: .big, as: UInt16.self) == 0
    else { return nil }

    // After the header, all remaining bytes are Float32 values
    let remainingBytes = buffer.readableBytes
    guard remainingBytes % 4 == 0, remainingBytes / 4 == Int(declared) else {
      return nil
    }

    let dimension = remainingBytes / 4

    // Sanity check: within what VectorValue reads (the UInt16 header already caps it at 65,535)
    guard dimension > 0 && dimension <= VectorValue.maxDimensions else {
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
