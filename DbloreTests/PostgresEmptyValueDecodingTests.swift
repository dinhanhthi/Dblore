// PostgresEmptyValueDecodingTests.swift
// PostgresNIO gives SQL NULL as nil bytes; a zero-length buffer is a real value. An empty text
// or bytea decodes to its empty value, never to NULL. A real decodes through its own shortest
// text, so 1.1 shows as 1.1, not as the widened 1.100000023841858.

import Foundation
import NIOCore
import PostgresNIO
import Testing

@testable import Dblore

@Suite struct PostgresEmptyValueDecodingTests {
  private static func cell(
    _ bytes: ByteBuffer?, _ dataType: PostgresDataType, format: PostgresFormat = .binary
  ) -> CellValue {
    DatabaseConnectionManager.parseCellValue(
      from: PostgresCell(
        bytes: bytes, dataType: dataType, format: format, columnName: "v", columnIndex: 0))
  }

  @MainActor @Test("An empty text, varchar or bytea is its empty value, not NULL")
  func emptyValueIsNotNull() {
    #expect(Self.cell(ByteBuffer(), .text) == .string(""))
    #expect(Self.cell(ByteBuffer(), .varchar) == .string(""))
    #expect(Self.cell(ByteBuffer(), .bytea) == .data(Data()))
  }

  @MainActor @Test("A real 1.1 decodes to the double 1.1")
  func realDecodesThroughItsShortestText() {
    // Binary float4 is the big-endian IEEE 754 bit pattern of Float(1.1)
    let value = Self.cell(ByteBuffer(bytes: [0x3F, 0x8C, 0xCC, 0xCD]), .float4)
    #expect(value == .double(1.1))
    #expect(value.displayString == "1.1")
  }

  @MainActor @Test("Nil bytes are NULL")
  func nilBytesAreNull() {
    #expect(Self.cell(nil, .text) == .null)
    #expect(Self.cell(nil, .bytea) == .null)
  }
}
