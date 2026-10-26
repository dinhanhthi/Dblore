// CellValuePreviewTests.swift
// Which Cell Value viewer a value gets: geometry bytes by column type or WKB header, vector
// text only for a vector column or one of unknown type, so a JSON array in TEXT stays text.
// Format JSON sizes its output, not its input, before anything is highlighted.

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

  /// The read-only view lays out a long line all at once, so a large value shows a prefix cut
  /// on a character boundary: never half of a flag (two 4-byte scalars).
  @Test(arguments: [
    ("abc", 3, "abc"),
    ("aaa\u{1F1EB}\u{1F1F7}b", 7, "aaa"),
    ("aaa\u{1F1EB}\u{1F1F7}b", 11, "aaa\u{1F1EB}\u{1F1F7}"),
  ])
  func largeValueShowsAPrefixOnACharacterBoundary(text: String, maxBytes: Int, shown: String) {
    #expect(CellInfoContent.displayText(text, maxBytes: maxBytes) == shown)
  }

  /// The note under a cut value says which text it measures: binary shows base64, Format JSON
  /// its output, while Copy always copies the whole original value.
  @Test(arguments: [
    (false, false, "", "Copy copies the whole value."),
    (true, false, " of base64 text.", "Copy copies the whole value."),
    (false, true, " of formatted JSON.", "Copy copies the whole original value."),
  ])
  func truncationNoteNamesWhatItMeasures(
    isBinary: Bool, isFormatted: Bool, kind: String, copy: String
  ) {
    let note = CellInfoContent.truncationNote(
      shownBytes: 64 * 1024, totalBytes: 12_000_000, isBinary: isBinary, isFormatted: isFormatted)
    #expect(note.hasPrefix("Showing the first "))
    #expect(note.hasSuffix(copy))
    #expect(note.contains("base64") == isBinary)
    #expect(note.contains("formatted JSON") == isFormatted)
    if !kind.isEmpty { #expect(note.contains(kind)) }
  }

  private static func nestedArray(depth: Int, elements: Int) -> String {
    String(repeating: "[", count: depth)
      + Array(repeating: "1", count: elements).joined(separator: ",")
      + String(repeating: "]", count: depth)
  }

  /// Pretty-printing indents every element by its depth: a 61 KB array nested 512 deep grows to
  /// 30 MB. Formatting gives up before writing that, so the main actor never highlights it.
  @Test(arguments: [
    (512, 30_000, CellInfoContent.maxHighlightedPrettyBytes),
    (100, 30_000, CellInfoContent.maxHighlightedPrettyBytes),
    (512, 40_000, CellInfoContent.maxFormattedBytes),
  ])
  func deeplyNestedArrayIsTooLargeToFormat(depth: Int, elements: Int, maxOutputBytes: Int) {
    let json = Self.nestedArray(depth: depth, elements: elements)
    #expect(
      CellInfoContent.prettyPrintedJSON(json, maxOutputBytes: maxOutputBytes) == .tooLarge)
  }

  @Test func ordinaryJSONFormatsWhole() throws {
    let json = #"{"a":[1,{"b":"c\/d","e":[]}],"f":null}"#
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let pretty = try JSONSerialization.data(withJSONObject: object, options: .prettyPrinted)
    // The size check is a lower bound: it never refuses JSON whose output fits
    #expect(CellInfoContent.prettyPrintedLowerBound(object) <= pretty.count)
    #expect(
      CellInfoContent.prettyPrintedJSON(
        json, maxOutputBytes: CellInfoContent.maxHighlightedPrettyBytes)
        == .formatted(text: String(decoding: pretty, as: UTF8.self), totalBytes: pretty.count))
    #expect(CellInfoContent.prettyPrintedJSON("{", maxOutputBytes: 1024) == .invalid)
  }

  /// A large output decodes only its first bytes, still cut on a character boundary
  @Test(arguments: [
    (5, "aaa"),
    (10, "aaa"),
    (11, "aaa\u{1F1EB}\u{1F1F7}"),
  ])
  func outputPrefixEndsOnACharacterBoundary(maxBytes: Int, shown: String) {
    let data = Data("aaa\u{1F1EB}\u{1F1F7}b".utf8)
    #expect(CellInfoContent.prefixText(data, maxBytes: maxBytes) == shown)
  }
}
