// SQLStatementStreamTests.swift
// A dump file read in chunks gives the statements, digests and first line of the whole-text
// split, and refuses invalid UTF-8, NUL and statements over the cap

import CryptoKit
import Foundation
import Testing

@testable import Dblore

@Suite("SQL Statement Stream")
struct SQLStatementStreamTests {

  // MARK: - Fixtures

  private static func column(_ ordinal: Int, _ name: String) -> TableStructure.Column {
    TableStructure.Column(
      ordinal: ordinal, name: name, dataType: "text", isNullable: true, defaultExpression: nil,
      identity: nil, generated: nil, comment: nil, columnType: nil, extra: nil,
      characterSet: nil, collation: nil)
  }

  /// A Dblore dump of one table with multi-byte rows, plus `postData`
  private static func dblore(
    _ engine: DatabaseType, preData: [String], postData: [String]
  )
    throws -> String
  {
    let target = engine == .sqlite ? "\"t\"" : "\"s\".\"t\""
    let script = SQLDumpDDL.Script(
      comment: ["-- Not included: nothing; é 😀"], preData: preData,
      tables: [
        SQLDumpDDL.TableInsert(
          schema: "s", name: "t", target: target, columns: [column(1, "a"), column(2, "b")],
          overridingSystemValue: false, hasData: true)
      ],
      postData: postData)
    var assembler = SQLDumpAssembler(engine: engine, maxRows: 3)
    var text = assembler.opening(script, created: Date(timeIntervalSince1970: 1_760_000_000))
    try assembler.begin(script.tables[0])
    for row in 0..<8 {
      if let flushed = assembler.append(["\(row)", "'é😀;列🧪 \(row) it''s'"]) { text += flushed }
    }
    if let flushed = assembler.finish() { text += flushed }
    return text + assembler.closing(script)
  }

  private static func fixtures() throws -> [(DatabaseType, String)] {
    let postgres = try dblore(
      .postgresql, preData: ["CREATE TABLE \"s\".\"t\" (a int, b text);"],
      postData: [
        "CREATE FUNCTION s.f() RETURNS int AS $fn$ BEGIN RETURN 1; END; $fn$ LANGUAGE plpgsql;",
        "COMMENT ON TABLE s.t IS 'ü; /* x */';",
      ])
    let sqlite = try dblore(
      .sqlite, preData: ["CREATE TABLE t (a, b);"],
      postData: ["CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 'ß;'; SELECT 2; END;"])
    let duckdb = try dblore(
      .duckdb, preData: ["CREATE TABLE \"s\".\"t\" (a int, b text);"],
      postData: ["CREATE MACRO s.m(x) AS x || $$;😀$$;"])
    return [
      (.mysql, MySQLDumpFixtures.mysqlDump), (.mysql, MySQLDumpFixtures.mariaDBDump),
      (.postgresql, postgres), (.postgresql, "\u{FEFF}" + postgres), (.sqlite, sqlite),
      (.duckdb, duckdb),
    ]
  }

  // MARK: - Helpers

  private static func file(_ bytes: [UInt8]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-stream-\(UUID().uuidString).sql")
    try Data(bytes).write(to: url)
    return url
  }

  /// Every statement of the file at `url`
  private static func read(
    _ url: URL, _ engine: DatabaseType, chunkSize: Int, cap: Int = SQLRestorePlan.maxStatementBytes
  ) throws -> [SQLStatementStream.Statement] {
    var stream = try SQLStatementStream(
      url: url, engine: engine, chunkSize: chunkSize, maxStatementBytes: cap)
    var statements: [SQLStatementStream.Statement] = []
    while let statement = try stream.next() { statements.append(statement) }
    return statements
  }

  // MARK: - Tests

  @Test("Statements, ranges, digests and first line equal the whole-text split at any chunk size")
  func equalsWholeTextSplit() throws {
    for (engine, text) in try Self.fixtures() {
      let data = Data(text.utf8)
      let url = try Self.file(Array(data))
      defer { try? FileManager.default.removeItem(at: url) }
      // Today's whole-file path: `readScript` decodes, `SQLRestorePlan.init` strips and splits
      let whole = try #require(String(data: data, encoding: .utf8))
      let sandbox = engine == .mysql ? SQLRestorePlan.mariaDBSandboxPrefix(whole) : 0
      let scalars = Array(whole.unicodeScalars.dropFirst(sandbox))
      let expected = SQLTokenizer(dialect: engine.dialect).splitStatements(scalars: scalars)
      let firstLine = String(
        String.UnicodeScalarView(scalars.prefix { $0 != "\n" && $0 != "\r" }))
      #expect(expected.count > 3)
      for size in [1, 7, 64] {
        var stream = try SQLStatementStream(url: url, engine: engine, chunkSize: size)
        #expect(try stream.firstLine() == firstLine, "\(engine) chunk \(size)")
        var statements: [SQLStatementStream.Statement] = []
        while let statement = try stream.next() { statements.append(statement) }
        #expect(statements.map(\.text) == expected, "\(engine) chunk \(size)")
        #expect(stream.bytesRead == data.count)
        for statement in statements {
          #expect(Array(data[statement.byteRange]) == Array(statement.text.utf8))
          #expect(statement.digest == SHA256.hash(data: Data(statement.text.utf8)))
        }
      }
    }
  }

  private static let invalidUTF8Files: [[UInt8]] = [
    // A lead byte at the end of the first 7-byte chunk, then no continuation byte
    Array("SELECT".utf8) + [0xC3] + Array("x';".utf8),
    // A code point cut by the end of the file
    Array("SELECT 1;".utf8) + [0xE2, 0x82],
    // A surrogate
    Array("SELECT '".utf8) + [0xED, 0xA0, 0x80] + Array("';".utf8),
  ]

  @Test("Invalid UTF-8 is refused, also cut by a chunk end", arguments: invalidUTF8Files)
  func invalidUTF8(bytes: [UInt8]) throws {
    let url = try Self.file(bytes)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: DatabaseBackupError.notUTF8) {
      try Self.read(url, .postgresql, chunkSize: 7)
    }
  }

  @Test("A statement over the cap is refused with its index, one at the cap is read")
  func statementCap() throws {
    let cap = 200
    let atCap = "SELECT 'x" + String(repeating: "é", count: 95) + "'"
    #expect(atCap.utf8.count == cap)
    let over = "SELECT '" + String(repeating: "x", count: cap) + "'"
    let text = "SELECT 1;\n\(atCap);\n\(over);\nSELECT 2;\n"
    let url = try Self.file(Array(text.utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    for size in [7, 4_096] {
      var stream = try SQLStatementStream(
        url: url, engine: .postgresql, chunkSize: size, maxStatementBytes: cap)
      #expect(try stream.next()?.text == "SELECT 1")
      #expect(try stream.next()?.text == atCap)
      do {
        _ = try stream.next()
        Issue.record("the statement over the cap was not refused")
      } catch SQLRestoreError.statementTooLarge(let index, let bytes) {
        #expect(index == 2)
        // Small chunks refuse it while it is still open, with the bytes read of it
        #expect(size == 7 ? bytes > cap : bytes == over.utf8.count)
      }
    }
  }

  @Test("An unclosed quote is refused once the open statement passes the cap")
  func openStatementCap() throws {
    let text = "SELECT 1;\nSELECT 'open" + String(repeating: " x;", count: 2_000)
    let url = try Self.file(Array(text.utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    var stream = try SQLStatementStream(
      url: url, engine: .postgresql, chunkSize: 64, maxStatementBytes: 256)
    #expect(try stream.next()?.text == "SELECT 1")
    do {
      _ = try stream.next()
      Issue.record("the open statement was not refused")
    } catch SQLRestoreError.statementTooLarge(let index, let bytes) {
      #expect(index == 1)
      #expect(bytes > 256)
    }
    // Refused near the cap, without reading on through the file
    #expect(stream.bytesRead < 256 + 3 * 64)
  }

  @Test("Statements are located in order; the ranges stop at one not in the split text")
  func locate() {
    let buffer = Array("SELECT 'é';\nSELECT 2;\nSELECT 3".unicodeScalars)
    let found = SQLStatementStream.locate(
      ["SELECT 'é'", "SELECT 2", "SELECT 9"], in: buffer, before: buffer.count, offset: 3)
    #expect(found == [3..<14, 16..<24])
    // Text after `consumed` is not split yet: a statement there is not found either
    let open = SQLStatementStream.locate(["SELECT 3"], in: buffer, before: 21, offset: 0)
    #expect(open.isEmpty)
  }

  @Test(
    "NUL is refused on SQLite and DuckDB only",
    arguments: [(DatabaseType.sqlite, true), (.duckdb, true), (.postgresql, false)])
  func nul(engine: DatabaseType, refused: Bool) throws {
    let url = try Self.file(Array("SELECT 1;\nSELECT 'a\0b';\n".utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    if refused {
      #expect(throws: SQLRestoreError.containsNUL) {
        try Self.read(url, engine, chunkSize: 7)
      }
    } else {
      #expect(try Self.read(url, engine, chunkSize: 7).count == 2)
    }
  }
}
