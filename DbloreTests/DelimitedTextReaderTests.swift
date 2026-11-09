// DelimitedTextReaderTests.swift
// RFC 4180 preview: quotes, CRLF, delimiter choice, header toggle, encodings, row cap.

import Foundation
import Testing

@testable import Dblore

@Suite("Delimited text reader")
struct DelimitedTextReaderTests {
  @Test("Quotes, doubled quotes, CRLF, and a quoted line break stay one record")
  func quotedCRLF() throws {
    let csv = "name,note\r\n\"doe, jane\",\"say \"\"hi\"\"\r\nstill\"\r\n bob ,x\r\n"
    let table = try DelimitedTextReader.read(Data(csv.utf8))
    #expect(table.delimiter == ",")
    #expect(table.columns == ["name", "note"])
    #expect(table.rows == [["doe, jane", "say \"hi\"\r\nstill"], [" bob ", "x"]])
  }

  @Test(
    "Delimiter is chosen from comma, semicolon, tab, and pipe",
    arguments: [
      ("name,amount\nbob,1", ",", ["name", "amount"], ["bob", "1"]),
      ("name;amount\nalice;1,23", ";", ["name", "amount"], ["alice", "1,23"]),
      ("name\tamount\nbob\t2", "\t", ["name", "amount"], ["bob", "2"]),
      ("name|amount\nbob|2", "|", ["name", "amount"], ["bob", "2"]),
      ("only\nvalue", ",", ["only"], ["value"]),
    ] as [(String, String, [String], [String])]
  )
  func detectsDelimiter(
    sample: String, delimiter: String, columns: [String], row: [String]
  ) throws {
    let table = try DelimitedTextReader.read(Data(sample.utf8))
    #expect(String(table.delimiter) == delimiter)
    #expect(table.columns == columns)
    #expect(table.rows == [row])
  }

  @Test("An explicit delimiter wins when comma and pipe score the same")
  func explicitDelimiter() throws {
    let sample = Data("a|b,c\nd|e,f\n".utf8)
    let automatic = try DelimitedTextReader.read(sample)
    #expect(automatic.delimiter == ",")
    #expect(automatic.columns == ["a|b", "c"])
    let forced = try DelimitedTextReader.read(sample, options: .init(delimiter: "|"))
    #expect(forced.delimiter == "|")
    #expect(forced.columns == ["a", "b,c"])
    #expect(forced.rows == [["d", "e,f"]])
  }

  @Test("The header toggle names columns column1 onward when the first row is data")
  func headerToggle() throws {
    let sample = Data("a,b\nc,d\n".utf8)
    let withHeader = try DelimitedTextReader.read(sample)
    #expect(withHeader.columns == ["a", "b"])
    #expect(withHeader.rows == [["c", "d"]])
    let without = try DelimitedTextReader.read(sample, options: .init(hasHeader: false))
    #expect(without.columns == ["column1", "column2"])
    #expect(without.rows == [["a", "b"], ["c", "d"]])
  }

  @Test("A short row is padded and a wider row adds columnN")
  func raggedRows() throws {
    let table = try DelimitedTextReader.read(Data("a,b\n1\n2,3,4\n".utf8))
    #expect(table.columns == ["a", "b", "column3"])
    #expect(table.rows == [["1", "", ""], ["2", "3", "4"]])
  }

  @Test("Ragged rows stop before padding exceeds the cell budget")
  func raggedCellBudget() {
    let narrowRows = Array(repeating: "x", count: 1000).joined(separator: "\n")
    let wideRow = Array(repeating: "x", count: 1001).joined(separator: ",")
    let csv = "value\n" + narrowRows + "\n" + wideRow + "\n"
    #expect(throws: DelimitedTextError.cellLimitExceeded) {
      try DelimitedTextReader.read(Data(csv.utf8), options: .init(delimiter: ","))
    }
  }

  @Test("Raw CSV row and field budgets stop parsing before rows accumulate")
  func rawRecordBudgets() throws {
    #expect(throws: DelimitedTextError.rowLimitExceeded) {
      try DelimitedTextReader.read(
        Data("h\na\nb\nc\n".utf8), options: .init(maxRows: 2))
    }
    #expect(throws: DelimitedTextError.cellLimitExceeded) {
      try DelimitedTextReader.read(
        Data("a,b,c,d,e\n".utf8), options: .init(delimiter: ",", maxCells: 4))
    }
    #expect(throws: DelimitedTextError.fieldLimitExceeded) {
      try DelimitedTextReader.read(
        Data("abcdef\n".utf8), options: .init(maxFieldCharacters: 4))
    }
    let preview = try DelimitedTextReader.read(
      Data("h\na\nb\n".utf8), options: .init(rowLimit: 1, maxRows: 1))
    #expect(preview.rows == [["a"]])
  }

  @Test("UTF-8 is kept, a leading BOM is ignored, and invalid UTF-8 falls back to Latin-1")
  func encodings() throws {
    let utf8 = try DelimitedTextReader.read(Data("caf\u{00e9},x\n1,2\n".utf8))
    #expect(utf8.columns == ["café", "x"])
    #expect(utf8.rows == [["1", "2"]])

    var bom = Data([0xEF, 0xBB, 0xBF])
    bom.append(Data("a,b\n1,2\n".utf8))
    let bomTable = try DelimitedTextReader.read(bom)
    #expect(bomTable.columns == ["a", "b"])
    #expect(bomTable.rows == [["1", "2"]])

    let latin1 = Data([0x63, 0x61, 0x66, 0xE9, 0x2C, 0x78, 0x0A, 0x31, 0x2C, 0x32, 0x0A])
    let latin = try DelimitedTextReader.read(latin1)
    #expect(latin.columns == ["café", "x"])
    #expect(latin.rows == [["1", "2"]])

    // A Latin-1 preview pins the full parse to Latin-1 even when the bytes are valid UTF-8
    let pinned = try DelimitedTextReader.read(
      Data("caf\u{00e9},x\n1,2\n".utf8), options: .init(encoding: .isoLatin1))
    #expect(pinned.columns == ["caf\u{00c3}\u{00a9}", "x"])
    #expect(pinned.encoding == .isoLatin1)
  }

  @Test("An unclosed quote is an error")
  func unclosedQuote() {
    #expect(throws: DelimitedTextError.unclosedQuote) {
      try DelimitedTextReader.read(Data("\"abc".utf8))
    }
  }
}

@Suite("Delimited text record stream")
struct DelimitedTextRecordStreamTests {
  /// `text` cut into pieces of `size` Unicode scalars, so a CR LF pair can fall across two pieces
  static func chunks(_ text: String, size: Int) -> [Substring] {
    let scalars = text.unicodeScalars
    var pieces: [Substring] = []
    var start = scalars.startIndex
    while start < scalars.endIndex {
      let end =
        scalars.index(start, offsetBy: size, limitedBy: scalars.endIndex) ?? scalars.endIndex
      pieces.append(Substring(scalars[start..<end]))
      start = end
    }
    return pieces
  }

  @Test(
    "Records fed at every chunk size equal the whole read",
    arguments: [
      "name,note\r\n\"doe, jane\",\"say \"\"hi\"\"\r\nstill\"\r\n bob ,x\r\n",
      "name;amount\nalice;1,23\n\n;\n\"\";\"x\"",
      "a\tb\r\n\t\r\nc\t\"d\"\"\"\r\n",
      "h1,h2,h3\n1\n\"x\ny\",,\"\"\nlast,row,caf\u{00e9}",
    ])
  func matchesWholeRead(csv: String) throws {
    let table = try DelimitedTextReader.read(Data(csv.utf8))
    let expected = [table.columns] + table.rows
    for size in 1...64 {
      var stream = DelimitedTextReader.RecordStream(
        delimiter: table.delimiter, columns: table.columns.count)
      var records: [[String]] = []
      for chunk in Self.chunks(csv, size: size) {
        records += try stream.feed(chunk)
      }
      records += try stream.finish()
      #expect(records == expected, "chunk size \(size)")
    }
  }

  @Test("A record over the byte cap or wider than the header is refused")
  func boundedRecords() throws {
    var unclosed = DelimitedTextReader.RecordStream(
      delimiter: ",", columns: 2, maxRecordBytes: 16)
    _ = try unclosed.feed("a,b\n\"never")
    #expect(throws: DelimitedTextError.recordLimitExceeded(row: 2)) {
      for _ in 0..<4 { _ = try unclosed.feed(" closed") }
    }

    var wide = DelimitedTextReader.RecordStream(delimiter: ",", columns: 2)
    #expect(try wide.feed("a,b\n1,2\n") == [["a", "b"], ["1", "2"]])
    #expect(throws: DelimitedTextError.tooManyFields(row: 3)) {
      _ = try wide.feed("3,4,5\n")
    }

    var damaged = DelimitedTextReader.RecordStream(delimiter: ",", columns: 1)
    _ = try damaged.feed("\"open")
    #expect(throws: DelimitedTextError.unclosedQuote) { _ = try damaged.finish() }
  }
}
