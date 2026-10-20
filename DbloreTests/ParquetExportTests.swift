// ParquetExportTests.swift
// Parquet export without the plugin: result columns to DuckDB types, the CREATE TABLE, INSERT
// and COPY text, the bind text of each value, and the rule that COPY only writes the
// app-created temporary file.

import Foundation
import Testing

@testable import Dblore

@Suite("Parquet export mapping")
struct ParquetExportTests {
  private static let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
  private static let root = "/private/var/folders/xy/T"
  private static let folder = root + "/dblore-parquet-6F9619FF-8B86-D011-B42D-00C04FC964FF"
  private static let otherPaths: [String] = [
    folder + "/other.parquet",
    folder + "/sub/export.parquet",
    folder + "/../export.parquet",
    root + "/export.parquet",
    root + "/other-6F9619FF-8B86-D011-B42D-00C04FC964FF/export.parquet",
    root + "/dblore-parquet-not-a-uuid/export.parquet",
    root + "/dblore-parquet-/export.parquet",
    root + "/dblore-parquet-6f9619ff-8b86-d011-b42d-00c04fc964ff/export.parquet",
    "/Users/me/Desktop/dblore-parquet-6F9619FF-8B86-D011-B42D-00C04FC964FF/export.parquet",
    root + "/x/dblore-parquet-6F9619FF-8B86-D011-B42D-00C04FC964FF/export.parquet",
    "",
  ]
  private static let badRoots: [String] = [
    "", "relative/T", "/private/../T", "/private/./T", "/private//T", "/private/T/",
    "/private/T\nx", "/private/T\0x", "/",
  ]

  // MARK: - Column types

  @Test("Cell kinds pick BIGINT, DOUBLE, BOOLEAN, TIMESTAMP, BLOB, JSON and VARCHAR")
  func typesFromCellKinds() {
    let date = Date(timeIntervalSince1970: 0)
    #expect(Self.type([.int(1), .null, .int(2)]) == .bigint)
    #expect(Self.type([.double(1.5), .double(2)]) == .double)
    #expect(Self.type([.int(1), .double(2.5)]) == .double)
    #expect(Self.type([.bool(true), .null]) == .boolean)
    #expect(Self.type([.date(date)]) == .timestamp)
    #expect(Self.type([.data(Data([1, 2]))]) == .blob)
    #expect(Self.type([.json("{}"), .json("[1]")]) == .json)
    #expect(Self.type([.string("a")]) == .varchar)
  }

  @Test("Mixed kinds and all-NULL columns are VARCHAR")
  func mixedAndNullColumnsAreVarchar() {
    #expect(Self.type([.int(1), .string("a")]) == .varchar)
    #expect(Self.type([.bool(true), .int(1)]) == .varchar)
    #expect(Self.type([.json("{}"), .string("x")]) == .varchar)
    #expect(Self.type([.null, .null]) == .varchar)
    #expect(Self.type([]) == .varchar)
  }

  @Test("Numeric text is DECIMAL with the declared precision and scale when the values fit")
  func declaredDecimal() {
    #expect(
      Self.type([.string("12.345"), .string("-0.5")], source: "NUMERIC(12,3)")
        == .decimal(precision: 12, scale: 3))
    #expect(
      Self.type([.string("1.5")], source: "decimal(10, 2)") == .decimal(precision: 10, scale: 2))
    #expect(Self.type([.string("42")], source: "DECIMAL(10)") == .decimal(precision: 10, scale: 0))
  }

  @Test("Numeric text without a usable declaration takes precision 38 and the widest scale")
  func derivedDecimal() {
    #expect(
      Self.type([.string("123.4567"), .string("-1.5"), .null], source: "DECIMAL")
        == .decimal(precision: 38, scale: 4))
    #expect(Self.type([.string("7")], source: "NUMERIC") == .decimal(precision: 38, scale: 0))
    // The declared scale is too small for the values, or the precision is over DuckDB's 38.
    #expect(
      Self.type([.string("1.12345")], source: "NUMERIC(10,2)")
        == .decimal(precision: 38, scale: 5))
    #expect(
      Self.type([.string("1.5")], source: "NUMERIC(60,20)") == .decimal(precision: 38, scale: 1))
    #expect(
      Self.type([.string("0.0123456789")], source: "DECIMAL(38,10)")
        == .decimal(precision: 38, scale: 10))
  }

  @Test("Numeric text stays VARCHAR when the type is not numeric or a value does not fit")
  func decimalFallsBackToVarchar() {
    #expect(Self.type([.string("12.5")], source: "TEXT") == .varchar)
    #expect(Self.type([.string("12.5")], source: "") == .varchar)
    #expect(Self.type([.string("NaN")], source: "NUMERIC") == .varchar)
    #expect(Self.type([.string("1e5")], source: "NUMERIC") == .varchar)
    #expect(Self.type([.string("1.2.3")], source: "NUMERIC") == .varchar)
    #expect(Self.type([.string("")], source: "NUMERIC") == .varchar)
    #expect(Self.type([.string(String(repeating: "9", count: 39))], source: "NUMERIC") == .varchar)
    // A NUMERIC column decoded to doubles keeps DOUBLE.
    #expect(Self.type([.double(1.5)], source: "NUMERIC") == .double)
  }

  @Test("Type SQL")
  func typeSQL() {
    #expect(ParquetExport.ColumnType.bigint.sql == "BIGINT")
    #expect(ParquetExport.ColumnType.double.sql == "DOUBLE")
    #expect(ParquetExport.ColumnType.boolean.sql == "BOOLEAN")
    #expect(ParquetExport.ColumnType.timestamp.sql == "TIMESTAMP")
    #expect(ParquetExport.ColumnType.blob.sql == "BLOB")
    #expect(ParquetExport.ColumnType.json.sql == "JSON")
    #expect(ParquetExport.ColumnType.varchar.sql == "VARCHAR")
    #expect(ParquetExport.ColumnType.decimal(precision: 38, scale: 10).sql == "DECIMAL(38,10)")
  }

  // MARK: - Column names and statements

  @Test("Empty and duplicate names (case-insensitive) get unique names")
  func uniqueNames() {
    let columns = ParquetExport.columns(
      [
        ColumnInfo(name: "id", type: "INTEGER"), ColumnInfo(name: "", type: "TEXT"),
        ColumnInfo(name: "ID", type: "INTEGER"), ColumnInfo(name: "id_2", type: "TEXT"),
        ColumnInfo(name: "id", type: "INTEGER"),
      ],
      rows: [[.int(1), .string("a"), .int(2), .string("b"), .int(3)]])
    #expect(columns.map(\.name) == ["id", "column_2", "ID_2", "id_2_2", "id_3"])
    #expect(columns.map(\.type) == [.bigint, .varchar, .bigint, .varchar, .bigint])
  }

  @Test("CREATE TABLE quotes every identifier")
  func createTable() throws {
    let sql = try ParquetExport.createTableSQL([
      .init(name: "a\"b", type: .bigint),
      .init(name: "amount", type: .decimal(precision: 12, scale: 3)),
    ])
    #expect(sql == "CREATE TABLE \"export\" (\"a\"\"b\" BIGINT, \"amount\" DECIMAL(12,3))")
  }

  @Test("CREATE TABLE refuses no columns and a NUL in a name")
  func createTableRefusals() {
    #expect(throws: ParquetExport.Failure.noColumns) {
      try ParquetExport.createTableSQL([])
    }
    #expect(throws: SQLDialectError.nulInIdentifier) {
      try ParquetExport.createTableSQL([.init(name: "a\0b", type: .varchar)])
    }
  }

  @Test("INSERT lists the columns and numbers one placeholder per value, row by row")
  func insertText() throws {
    let columns: [ParquetExport.Column] = [
      .init(name: "a", type: .bigint), .init(name: "b", type: .varchar),
    ]
    #expect(
      try ParquetExport.insertSQL(columns: columns, rowCount: 2)
        == "INSERT INTO \"export\" (\"a\", \"b\") VALUES ($1, $2), ($3, $4)")
    #expect(throws: ParquetExport.Failure.noColumns) {
      try ParquetExport.insertSQL(columns: [], rowCount: 1)
    }
  }

  @Test("Batches hold 1,000 rows, the last one the remainder")
  func batches() {
    #expect(ParquetExport.rowsPerStatement == 1_000)
    #expect(ParquetExport.batches(rowCount: 2_500) == [0..<1_000, 1_000..<2_000, 2_000..<2_500])
    #expect(ParquetExport.batches(rowCount: 1_000) == [0..<1_000])
    #expect(ParquetExport.batches(rowCount: 0).isEmpty)
  }

  // MARK: - Bind text

  @Test("Values bind as the text DuckDB casts to the column type")
  func bindText() {
    #expect(ParquetExport.bind(.null, as: .bigint) == .null)
    #expect(ParquetExport.bind(.int(-42), as: .bigint) == .text("-42"))
    #expect(ParquetExport.bind(.int(3), as: .double) == .text("3"))
    #expect(ParquetExport.bind(.double(1.5), as: .double) == .text("1.5"))
    #expect(ParquetExport.bind(.double(.infinity), as: .double) == .text("Infinity"))
    #expect(ParquetExport.bind(.double(-.infinity), as: .double) == .text("-Infinity"))
    #expect(ParquetExport.bind(.double(.nan), as: .double) == .text("NaN"))
    #expect(ParquetExport.bind(.bool(false), as: .boolean) == .text("false"))
    #expect(ParquetExport.bind(.json("{\"a\":1}"), as: .json) == .text("{\"a\":1}"))
    #expect(
      ParquetExport.bind(.string("0.0123456789"), as: .decimal(precision: 38, scale: 10))
        == .text("0.0123456789"))
    #expect(ParquetExport.bind(.string("héllo ✓"), as: .varchar) == .text("héllo ✓"))
    #expect(ParquetExport.bind(.int(7), as: .varchar) == .text("7"))
  }

  @Test("Every BLOB byte is a \\xHH escape")
  func blobText() {
    #expect(
      ParquetExport.bind(.data(Data([0xDE, 0xAD, 0x41, 0x00, 0x5C])), as: .blob)
        == .text("\\xDE\\xAD\\x41\\x00\\x5C"))
    #expect(ParquetExport.bind(.data(Data()), as: .blob) == .text(""))
  }

  @Test("Timestamps are UTC with microseconds, proleptic Gregorian")
  func timestampText() {
    let base = 1_767_323_045.0  // 2026-01-02 03:04:05 UTC
    #expect(
      ParquetExport.bind(.date(Date(timeIntervalSince1970: base + 0.123456)), as: .timestamp)
        == .text("2026-01-02 03:04:05.123456"))
    #expect(
      ParquetExport.bind(.date(Date(timeIntervalSince1970: -1.5)), as: .timestamp)
        == .text("1969-12-31 23:59:58.500000"))
    #expect(
      ParquetExport.bind(.date(Date(timeIntervalSince1970: -12_219_292_800)), as: .timestamp)
        == .text("1582-10-15 00:00:00.000000"))
    #expect(
      ParquetExport.bind(.date(Date(timeIntervalSince1970: -12_219_379_200)), as: .timestamp)
        == .text("1582-10-14 00:00:00.000000"))
    #expect(
      ParquetExport.bind(.date(Date(timeIntervalSince1970: 951_782_400)), as: .timestamp)
        == .text("2000-02-29 00:00:00.000000"))
  }

  @Test("A date beyond Int64 microseconds binds as infinity or -infinity and does not trap")
  func timestampBeyondInt64() {
    // PostgresNIO decodes timestamp infinity as Int64.max microseconds and date -infinity as
    // Int32.min days after 2000-01-01.
    let postgresEpoch = Date(timeIntervalSince1970: 946_684_800)
    let infinity = postgresEpoch.addingTimeInterval(Double(Int64.max) / 1_000_000)
    let negativeInfinity = postgresEpoch.addingTimeInterval(Double(Int32.min) * 86_400)
    #expect(ParquetExport.bind(.date(infinity), as: .timestamp) == .text("infinity"))
    #expect(ParquetExport.bind(.date(negativeInfinity), as: .timestamp) == .text("-infinity"))
  }

  @Test("A row binds each value as its column's type")
  func rowBinds() {
    let columns: [ParquetExport.Column] = [
      .init(name: "a", type: .bigint), .init(name: "b", type: .varchar),
    ]
    #expect(
      ParquetExport.binds([.int(1), .null], columns: columns) == [.text("1"), .null])
  }

  // MARK: - COPY target

  @Test("The output path is <root>/dblore-parquet-<uuid>/export.parquet")
  func outputPath() {
    #expect(
      ParquetExport.outputPath(temporaryRoot: Self.root, id: Self.id)
        == Self.root + "/dblore-parquet-" + Self.id.uuidString + "/export.parquet")
  }

  @Test("COPY writes the app-created file, the path a quoted DuckDB literal")
  func copyText() throws {
    let path = ParquetExport.outputPath(temporaryRoot: Self.root, id: Self.id)
    #expect(
      try ParquetExport.copySQL(outputPath: path, temporaryRoot: Self.root)
        == "COPY \"export\" TO '\(path)' (FORMAT PARQUET)")
    let quoted = "/Users/o'neil/T"
    let quotedPath = ParquetExport.outputPath(temporaryRoot: quoted, id: Self.id)
    #expect(
      try ParquetExport.copySQL(outputPath: quotedPath, temporaryRoot: quoted)
        == "COPY \"export\" TO '/Users/o''neil/T/dblore-parquet-\(Self.id.uuidString)/export.parquet'"
        + " (FORMAT PARQUET)")
  }

  @Test("COPY refuses every other path", arguments: otherPaths)
  func copyRefusesOtherPaths(path: String) {
    #expect(throws: ParquetExport.Failure.refusedTarget) {
      try ParquetExport.copySQL(outputPath: path, temporaryRoot: Self.root)
    }
  }

  @Test("COPY refuses a root that is not a plain absolute path", arguments: badRoots)
  func copyRefusesBadRoots(root: String) {
    let path = ParquetExport.outputPath(temporaryRoot: root, id: Self.id)
    #expect(throws: ParquetExport.Failure.refusedTarget) {
      try ParquetExport.copySQL(outputPath: path, temporaryRoot: root)
    }
  }

  // MARK: - Exporter without the plugin

  @Test("A failed open removes the temporary folder and leaves the destination as it was")
  func failedOpenCleansUp() async throws {
    let root = try Self.makeFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("saved.parquet")
    try Data("old".utf8).write(to: destination)
    let temp = root.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    let exporter = ParquetExporter(
      loadLibrary: { throw DuckDBSessionError(message: "no plugin here") },
      temporaryDirectory: temp)

    // The session wraps the loader's error.
    await #expect(throws: DuckDBSessionError.self) {
      try await exporter.export(Self.sample, to: destination)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
    #expect(try Data(contentsOf: destination) == Data("old".utf8))
  }

  @Test("A result without columns is refused before any temporary folder")
  func noColumnsRefused() async throws {
    let temp = try Self.makeFolder()
    defer { try? FileManager.default.removeItem(at: temp) }
    let exporter = ParquetExporter(
      loadLibrary: { throw DuckDBSessionError(message: "not reached") }, temporaryDirectory: temp)

    await #expect(throws: ParquetExport.Failure.noColumns) {
      try await exporter.export(CellResult(), to: temp.appendingPathComponent("out.parquet"))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
  }

  @Test("Without the DuckDB plugin the export stops before anything is written")
  func pluginMissing() async throws {
    let temp = try Self.makeFolder()
    defer { try? FileManager.default.removeItem(at: temp) }
    let destination = temp.appendingPathComponent("out.parquet")

    await #expect(throws: ParquetExport.Failure.pluginMissing) {
      try await DataExporter.exportParquet(
        result: Self.sample, to: destination, loadLibrary: { nil })
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test("Parquet is its own format, needs the plugin, and has no text options")
  func parquetFormat() {
    let parquet = ExportFormat.parquet
    #expect(parquet.title == "Parquet")
    #expect(parquet.requiresDuckDBPlugin)
    #expect(ExportFormat.allCases.filter(\.requiresDuckDBPlugin) == [.parquet])
    #expect(!parquet.offersHeaderToggle && !parquet.offersNullAsEmpty && !parquet.offersEncoding)
    #expect(
      !parquet.offersLineBreakToSpace && !parquet.offersFormulaSanitize && !parquet.offersWrap)
  }

  @Test("SQL results offer Parquet, MongoDB results do not")
  @MainActor
  func parquetForSQLOnly() {
    #expect(ResultExportSheet.exportFormats(for: .sql).contains(.parquet))
    #expect(!ResultExportSheet.exportFormats(for: .mongosh).contains(.parquet))
  }

  // MARK: - Helpers

  private static let sample = CellResult(
    columns: [ColumnInfo(name: "id", type: "INTEGER")], rows: [[.int(1)]], rowCount: 1)

  private static func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-pqtest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private static func type(_ values: [CellValue], source: String = "") -> ParquetExport.ColumnType {
    ParquetExport.columns(
      [ColumnInfo(name: "c", type: source)], rows: values.map { [$0] }
    ).first!.type
  }
}
