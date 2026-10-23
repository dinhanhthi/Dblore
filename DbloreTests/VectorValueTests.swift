// VectorValueTests.swift
// pgvector text values: `vector` / `halfvec` '[1,2,3]' and `sparsevec` '{1:0.5,3:2}/5'
// (1-based indices, dimension after the slash) -> dimension, L2 norm, min, max, leading values.
// halfvec and sparsevec arrive in binary from PostgreSQL and are decoded to that text first.

import Foundation
import NIOCore
import PostgresNIO
import Testing

@testable import Dblore

@Suite struct VectorValueTests {
  @Test func denseVector() throws {
    let vector = try #require(VectorValue(text: " [1, 2,-2] "))
    #expect(vector.dimension == 3)
    #expect(vector.norm == 3)
    #expect(vector.minimum == -2)
    #expect(vector.maximum == 2)
    #expect(vector.leadingValues == [1, 2, -2])
    #expect(vector.nonZeroCount == nil)
  }

  @Test func sparseVector() throws {
    let vector = try #require(VectorValue(text: "{1:0.5,3:2}/5"))
    #expect(vector.dimension == 5)
    #expect(vector.norm == (4.25).squareRoot())
    #expect(vector.minimum == 0)
    #expect(vector.maximum == 2)
    #expect(vector.leadingValues == [0.5, 0, 2, 0, 0])
    #expect(vector.nonZeroCount == 2)
  }

  @Test func sparseVectorExpandsOnlyTheLeadingPositions() throws {
    let vector = try #require(VectorValue(text: "{2:-1,100000:3}/100000"))
    #expect(vector.leadingValues.count == VectorValue.previewCount)
    #expect(vector.leadingValues[1] == -1)
    #expect(vector.minimum == -1)
    #expect(vector.maximum == 3)
  }

  @Test(arguments: [
    "", "[]", "[1,a]", "[1,2", "1,2]", "[1,,2]", "[nan]", "[1e999]",
    "{3:1,2:1}/5", "{1:1,1:2}/5", "{6:1}/5", "{0:1}/5", "{1:x}/5", "{1:1}/0", "{1:1}/100001",
    "{1:1}", "{1:1}/5x",
    "[" + Array(repeating: "1", count: VectorValue.maxDimensions + 1).joined(separator: ",") + "]",
  ])
  func malformedReturnsNil(_ text: String) {
    #expect(VectorValue(text: text) == nil)
  }

  // MARK: - pgvector binary

  /// Any OID: extension types are named per database.
  private static let oid: UInt32 = 99_999

  private static func cell(_ bytes: [UInt8]) -> PostgresCell {
    PostgresCell(
      bytes: ByteBuffer(bytes: bytes), dataType: PostgresDataType(oid), format: .binary,
      columnName: "embedding", columnIndex: 0)
  }

  private static func parse(_ bytes: [UInt8], as name: String) -> CellValue {
    DatabaseConnectionManager.parseCellValue(from: cell(bytes), extensionTypes: [oid: name])
  }

  private static func bigEndian<T: FixedWidthInteger>(_ values: [T]) -> [UInt8] {
    values.flatMap { value in withUnsafeBytes(of: value.bigEndian) { Array($0) } }
  }

  @MainActor @Test func halfvecBinaryDecodesToText() {
    // dim 3, unused, then 1, 2, -2 as half floats.
    let bytes = Self.bigEndian([UInt16]([3, 0, 0x3C00, 0x4000, 0xC000]))
    let value = Self.parse(bytes, as: "halfvec")
    #expect(value == .string("[1, 2, -2]"))
    #expect(VectorValue(text: value.fullString)?.dimension == 3)
  }

  @MainActor @Test func sparsevecBinaryDecodesToOneBasedText() {
    // dim 5, nnz 2, unused, indices 0 and 2, values 0.5 and 2.
    let bytes =
      Self.bigEndian([Int32]([5, 2, 0, 0, 2]))
      + Self.bigEndian([Float(0.5), 2].map(\.bitPattern))
    let value = Self.parse(bytes, as: "sparsevec")
    #expect(value == .string("{1:0.5,3:2}/5"))
    #expect(VectorValue(text: value.fullString) == VectorValue(text: "{1:0.5,3:2}/5"))
  }

  private static let malformedBinary: [(String, [UInt8])] = [
    // halfvec declaring 3 values with 2 present, and 1 value with a byte too many.
    ("halfvec", bigEndian([UInt16]([3, 0, 0x3C00, 0x4000]))),
    ("halfvec", bigEndian([UInt16]([1, 0, 0x3C00])) + [0]),
    // sparsevec declaring 2 entries with 1 index, and nnz 0x7FFFFFFF.
    ("sparsevec", bigEndian([Int32]([5, 2, 0, 0]))),
    ("sparsevec", bigEndian([Int32]([5, Int32.max, 0]))),
    // Truncated header.
    ("sparsevec", [0, 0, 0, 5]),
  ]

  @MainActor @Test func geographyIsNamedAndGeometryStaysBytes() {
    #expect(
      DatabaseConnectionManager.postgresDataTypeName(
        PostgresDataType(Self.oid), extensionTypes: [Self.oid: "geography"]) == "GEOGRAPHY")
    let ewkb: [UInt8] = [1, 1, 0, 0, 0] + [UInt8](repeating: 0, count: 16)
    #expect(Self.parse(ewkb, as: "geometry") == .data(Data(ewkb)))
  }

  @MainActor @Test(arguments: malformedBinary)
  func malformedBinaryStaysBytes(_ name: String, _ bytes: [UInt8]) {
    #expect(Self.parse(bytes, as: name) == .data(Data(bytes)))
  }

  /// An enum label whose length is a multiple of 4 ("refunded") was read as a 1-dim vector:
  /// an unknown type is read as one only when the pgvector header matches its length.
  @MainActor @Test func enumLabelIsNotReadAsVector() {
    let label = Array("refunded".utf8)
    #expect(DatabaseConnectionManager.parseCellValue(from: Self.cell(label)) == .string("refunded"))
    let vector =
      Self.bigEndian([UInt16(2), 0]) + Self.bigEndian([Float(1).bitPattern, Float(2).bitPattern])
    #expect(DatabaseConnectionManager.parseCellValue(from: Self.cell(vector)) == .string("[1, 2]"))
  }
}
