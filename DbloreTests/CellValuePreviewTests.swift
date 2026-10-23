// CellValuePreviewTests.swift
// Which Cell Value viewer a value gets: geometry bytes by column type or WKB header, vector
// text only for a vector column or one of unknown type, so a JSON array in TEXT stays text.

import Foundation
import Testing

@testable import Dblore

@Suite struct CellValuePreviewTests {
  private static func isVector(_ preview: CellValuePreview?) -> Bool {
    if case .vector = preview { return true }
    return false
  }

  private static func isGeometry(_ preview: CellValuePreview?) -> Bool {
    if case .geometry = preview { return true }
    return false
  }

  @Test(arguments: ["TEXT", "JSON", "varchar(255)"])
  func numberArrayInATextColumnStaysText(_ columnType: String) async {
    #expect(await CellValuePreview.make(value: .string("[1,2]"), columnType: columnType) == nil)
  }

  @Test(arguments: ["VECTOR", "USER-DEFINED"])
  func numberArrayInAVectorColumnIsAVector(_ columnType: String) async {
    let preview = await CellValuePreview.make(value: .string("[1,2]"), columnType: columnType)
    #expect(Self.isVector(preview))
  }

  @Test func unrelatedBytesHaveNoViewer() async {
    // A PNG signature, then zeros.
    let bytes: [UInt8] =
      [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0, count: 24)
    #expect(await CellValuePreview.make(value: .data(Data(bytes)), columnType: "BYTEA") == nil)
  }

  @Test func mySQLGeometryBytesAreAGeometry() async {
    // Little-endian SRID 4326, then WKB POINT (1 2).
    let bytes: [UInt8] =
      [0xE6, 0x10, 0, 0, 1, 1, 0, 0, 0]
      + [1.0, 2.0].flatMap { withUnsafeBytes(of: $0.bitPattern.littleEndian) { Array($0) } }
    let preview = await CellValuePreview.make(value: .data(Data(bytes)), columnType: "GEOMETRY")
    #expect(Self.isGeometry(preview))
  }
}
