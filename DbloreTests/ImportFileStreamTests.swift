// ImportFileStreamTests.swift
// An import file read in chunks gives the whole read's rows in blocks of 1,000 with stable
// digests, refuses a changed encoding or columns, and pass 1 keeps the mapping's kinds

import CryptoKit
import Foundation
import Testing

@testable import Dblore

@Suite("Import File Stream")
struct ImportFileStreamTests {

  // MARK: - Helpers

  private static func file(_ bytes: [UInt8]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-import-\(UUID().uuidString).txt")
    try Data(bytes).write(to: url)
    return url
  }

  private static func blocks(
    _ url: URL, _ layout: ImportFileStream.Layout, columns: [String],
    encoding: String.Encoding = .utf8, chunkSize: Int = ImportFileStream.chunkSize
  ) throws -> [ImportFileStream.Block] {
    var stream = try ImportFileStream(
      url: url, layout: layout, encoding: encoding, columns: columns, chunkSize: chunkSize)
    var blocks: [ImportFileStream.Block] = []
    while let block = try stream.nextBlock() { blocks.append(block) }
    return blocks
  }

  private static func mappings(
    _ columns: [String], kinds: [ImportTypeInference.Kind]
  ) -> [TableImportColumnMapping] {
    zip(columns, kinds).map { TableImportColumnMapping(sourceName: $0, targetName: $0, kind: $1) }
  }

  private static func isColumnsChanged(_ error: TableImportError?) -> Bool {
    if case .columnsChanged = error { return true }
    return false
  }

  /// A header, then `rows` CSV rows with multi-byte text; `changedRow` (1-based) differs
  private static func csv(rows: Int, changedRow: Int? = nil) -> [UInt8] {
    var text = "id,price,label\n"
    for row in 1...rows {
      let label = row == changedRow ? "changed" : "é😀 \(row)"
      text += "\(row),\(row).5,\(label)\n"
    }
    return Array(text.utf8)
  }

  // MARK: - Tests

  @Test("Rows equal the whole read in blocks of 1,000, with digests at any chunk size")
  func equalsWholeRead() throws {
    // BOM, a header shorter than the rows, quotes, an embedded newline, CRLF, empty fields,
    // a short row and a last record without a line end
    var text = "\u{FEFF}id,text\r\n"
    for row in 1...2_500 {
      switch row {
      case 5: text += "\"multi\nline, \"\"q\"\"\",x\r\n"
      case 7: text += ",,\n"
      case 2_500: text += "\(row),列 \(row),😀"
      default: text += "\(row),\"é, \(row)\",列\n"
      }
    }
    let data = Data(text.utf8)
    let url = try Self.file(Array(data))
    defer { try? FileManager.default.removeItem(at: url) }
    let whole = try DelimitedTextReader.read(data, options: .init(delimiter: ","))
    #expect(whole.columns == ["id", "text", "column3"])

    var digests: [[SHA256Digest]] = []
    for chunkSize in [1, 7, 64, ImportFileStream.chunkSize] {
      let blocks = try Self.blocks(
        url, .delimited(",", hasHeader: true), columns: whole.columns, chunkSize: chunkSize)
      #expect(blocks.map(\.firstRow) == [1, 1_001, 2_001], "chunk \(chunkSize)")
      #expect(blocks.flatMap(\.rows) == whole.rows.map { $0.map(Optional.some) })
      digests.append(blocks.map(\.digest))
    }
    #expect(digests.allSatisfy { $0 == digests[0] })
  }

  /// A wide header then many one-field lines: the rows waiting for a block stay unpadded and
  /// fed a slice at a time, so their cells follow a block and a slice, not a chunk × columns
  @Test("Short lines under a wide header keep the pending rows small")
  func shortLinesStayBounded() throws {
    let columns = (1...200).map { "c\($0)" }
    let lines = 50_000
    let url = try Self.file(
      Array((columns.joined(separator: ",") + "\n" + String(repeating: "a\n", count: lines)).utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    var stream = try ImportFileStream(
      url: url, layout: .delimited(",", hasHeader: true), encoding: .utf8, columns: columns)
    let row: [String?] = ["a"] + Array(repeating: "", count: columns.count - 1)
    let digest = ImportFileStream.digest(
      Array(repeating: row, count: ImportFileStream.rowsPerBlock))
    var count = 0
    while let block = try stream.nextBlock() {
      #expect(block.firstRow == count * ImportFileStream.rowsPerBlock + 1)
      #expect(block.digest == digest)
      if count == 0 { #expect(block.rows.allSatisfy { $0 == row }) }
      count += 1
    }
    #expect(count == lines / ImportFileStream.rowsPerBlock)
    // Cells allocated, one per short line: a block's rows plus one slice's, never padded
    #expect(
      stream.maxPendingCells
        <= ImportFileStream.rowsPerBlock + ImportFileStream.sliceScalars / 2 + 1,
      "\(stream.maxPendingCells)")
  }

  @Test("Latin-1 decodes byte for byte")
  func latin1() throws {
    // "café" and "ÿ" in Latin-1, each a single byte
    let url = try Self.file(Array("id,name\n1,caf".utf8) + [0xE9, 0x0A, 0x32, 0x2C, 0xFF])
    defer { try? FileManager.default.removeItem(at: url) }
    let blocks = try Self.blocks(
      url, .delimited(",", hasHeader: true), columns: ["id", "name"], encoding: .isoLatin1,
      chunkSize: 1)
    #expect(blocks.flatMap(\.rows) == [["1", "café"], ["2", "ÿ"]])
  }

  @Test("Invalid UTF-8 after a UTF-8 preview is refused, also a code point cut by the file end")
  func invalidUTF8() throws {
    let invalid: [[UInt8]] = [
      Array("id\n1\n".utf8) + [0xE9, 0x0A],
      Array("id\n1\n".utf8) + [0xC3],
    ]
    for bytes in invalid {
      let url = try Self.file(bytes)
      defer { try? FileManager.default.removeItem(at: url) }
      #expect(throws: DelimitedTextError.encodingChanged) {
        try Self.blocks(url, .delimited(",", hasHeader: true), columns: ["id"], chunkSize: 3)
      }
    }
  }

  @Test("Block digests repeat across reads, and only a changed row's block differs")
  func blockDigests() throws {
    let mappings = Self.mappings(["id", "price", "label"], kinds: [.integer, .decimal, .text])
    let layout = ImportFileStream.Layout.delimited(",", hasHeader: true)
    let url = try Self.file(Self.csv(rows: 2_500))
    defer { try? FileManager.default.removeItem(at: url) }
    let first = try ImportFileSummary(
      url: url, layout: layout, encoding: .utf8, mappings: mappings, measuresDecimals: false,
      chunkSize: 64)
    let second = try ImportFileSummary(
      url: url, layout: layout, encoding: .utf8, mappings: mappings, measuresDecimals: false)
    #expect(first == second)
    #expect(first.rowCount == 2_500)
    #expect(first.digests.count == 3)
    // Pass 2 reads the same digests from its own stream
    #expect(
      try Self.blocks(url, layout, columns: mappings.map(\.sourceName)).map(\.digest)
        == first.digests)

    let changedURL = try Self.file(Self.csv(rows: 2_500, changedRow: 1_500))
    defer { try? FileManager.default.removeItem(at: changedURL) }
    let changed = try ImportFileSummary(
      url: changedURL, layout: layout, encoding: .utf8, mappings: mappings,
      measuresDecimals: false)
    #expect(changed.digests[0] == first.digests[0])
    #expect(changed.digests[1] != first.digests[1])
    #expect(changed.digests[2] == first.digests[2])
  }

  @Test("NDJSON rows follow the key order, and a key after the preview changes the columns")
  func ndjsonKeys() throws {
    let text = "{\"a\":1,\"b\":\"é😀\"}\r\n\n{\"a\":2}\n{\"b\":null,\"a\":3}"
    let url = try Self.file(Array(text.utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    let whole = try JSONRowsReader.read(Data(text.utf8))
    #expect(whole.columns == ["a", "b"])
    for chunkSize in [1, 5, ImportFileStream.chunkSize] {
      #expect(
        try Self.blocks(url, .ndjson, columns: whole.columns, chunkSize: chunkSize)
          .flatMap(\.rows) == whole.rows)
    }

    let late = try Self.file(Array((text + "\n{\"a\":4,\"c\":5}\n").utf8))
    defer { try? FileManager.default.removeItem(at: late) }
    let error = #expect(throws: TableImportError.self) {
      try ImportFileSummary(
        url: late, layout: .ndjson, encoding: .utf8,
        mappings: Self.mappings(["a", "b"], kinds: [.integer, .text]), measuresDecimals: true)
    }
    #expect(Self.isColumnsChanged(error))
  }

  @Test("The header is checked as the whole read names it")
  func headerCheck() throws {
    // A header shorter than its rows: the whole read names the third column `column3`
    let columns = ["a", "b", "column3"]
    let short = try Self.file(Array("a,b\n1,2,3\n".utf8))
    defer { try? FileManager.default.removeItem(at: short) }
    #expect(
      try Self.blocks(short, .delimited(",", hasHeader: true), columns: columns)
        .flatMap(\.rows) == [["1", "2", "3"]])

    for header in ["a,x,c", "a,b,c,d", ""] {
      let url = try Self.file(Array("\(header)\n1,2,3\n".utf8))
      defer { try? FileManager.default.removeItem(at: url) }
      let error = #expect(throws: TableImportError.self, "\(header)") {
        try Self.blocks(url, .delimited(",", hasHeader: true), columns: columns)
      }
      #expect(Self.isColumnsChanged(error), "\(header)")
    }
  }

  /// Kinds come from the mapping the user saw; only decimal digits are read from every row
  @Test("Pass 1 keeps the mapping's kinds and measures decimals over every row")
  func decimalDigitsOverEveryRow() throws {
    var text = "price,qty,code,skipped\n"
    for row in 1...2_500 {
      let price = row == 2_400 ? "12345.678" : "\(row % 10).5"
      text += "\(price),\(row),\(row).25,1.5\n"
    }
    let data = Data(text.utf8)
    let url = try Self.file(Array(data))
    defer { try? FileManager.default.removeItem(at: url) }
    // qty was inferred integer and set to decimal; code inferred decimal and set to text
    var mappings = Self.mappings(
      ["price", "qty", "code", "skipped"], kinds: [.decimal, .decimal, .text, .decimal])
    mappings[3].included = false
    let summary = try ImportFileSummary(
      url: url, layout: .delimited(",", hasHeader: true), encoding: .utf8, mappings: mappings,
      measuresDecimals: true, chunkSize: 4_096)

    let included = mappings.filter(\.included)
    let columns = included.map { ImportSQLBuilder.Column(name: $0.targetName, kind: $0.kind) }
    let rows = try DelimitedTextReader.read(data, options: .init(delimiter: ",")).rows
      .map { Array($0.prefix(3)).map(Optional.some) }
    let measured = summary.withDecimalDigits(columns)
    #expect(measured == TableImportModel.withDecimalDigits(columns, rows: rows))
    #expect(measured.map(\.kind) == [.decimal, .decimal, .text])
    #expect(measured[0].precisionScale == .init(precision: 8, scale: 3))
    #expect(measured[1].precisionScale == .init(precision: 4, scale: 0))
    #expect(measured[2].precisionScale == nil)
  }
}
