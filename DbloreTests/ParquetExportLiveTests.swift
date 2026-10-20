// ParquetExportLiveTests.swift
// Parquet export through the dev DuckDB plugin: a 10,000-row result goes to a Parquet file
// and reads back through `read_parquet` with its row count, types, NULLs and text intact;
// dates beyond Int64 microseconds read back as infinity; a cancelled export leaves neither the
// temporary folder nor the destination.

import Foundation
import Testing

@testable import Dblore

@Suite("Parquet export live", .requiresDuckDBPlugin, .serialized)
struct ParquetExportLiveTests {
  private static let rowCount = 10_000
  /// 2026-01-02 03:04:05 UTC
  private static let base = 1_767_323_045.0

  @Test("10,000 rows round-trip through read_parquet with types, NULLs and unicode")
  func roundTrip() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let destination = folder.appendingPathComponent("result.parquet")
    try Data("old file".utf8).write(to: destination)
    let leftovers = try Self.exportFolders()
    let reports = Reports()

    try await DataExporter.exportParquet(
      result: Self.result(), to: destination,
      loadLibrary: { { try DuckDBTestPlugin.library() } },
      progress: { reports.append($0) })

    #expect(reports.values.last == Self.rowCount)
    #expect(reports.values == reports.values.sorted())
    #expect(try Self.exportFolders() == leftovers)

    let path = try DuckDBFileQuery.canonicalPath(of: destination)
    let file = "read_parquet(\(SQLDialect.duckdb.literal(.string(path))))"
    try await withSession(extraAllowedPaths: [path]) { session in
      let count = try await collect(session, "SELECT count(*) FROM \(file)")
      #expect(count == [[.int(Self.rowCount)]])

      let described = try await collect(session, "DESCRIBE SELECT * FROM \(file)")
      #expect(
        described.map { [$0[0], $0[1]] } == [
          [.string("id"), .string("BIGINT")], [.string("ratio"), .string("DOUBLE")],
          [.string("flag"), .string("BOOLEAN")], [.string("created"), .string("TIMESTAMP")],
          [.string("payload"), .string("BLOB")], [.string("doc"), .string("JSON")],
          [.string("amount"), .string("DECIMAL(38,10)")], [.string("label"), .string("VARCHAR")],
          [.string("label_2"), .string("VARCHAR")],
        ])

      let nulls = try await collect(
        session,
        "SELECT count(*) - count(ratio), count(*) - count(flag), count(*) - count(created),"
          + " count(*) - count(payload), count(*) - count(doc), count(*) - count(amount),"
          + " count(*) - count(label), count(*) - count(label_2) FROM \(file)")
      let expectedNulls = (0..<8).map { column in
        CellValue.int((0..<Self.rowCount).filter { ($0 + column) % 7 == 0 }.count)
      }
      #expect(nulls == [expectedNulls])

      for id in [1, 1_234, 9_999] {
        let row = try await collect(
          session,
          "SELECT ratio::VARCHAR, flag::VARCHAR, created::VARCHAR, hex(payload), doc::VARCHAR,"
            + " amount::VARCHAR, label, label_2 FROM \(file) WHERE id = \(id)")
        #expect(row == [Self.expectedText(id)], "row \(id)")
      }
    }
  }

  @Test("Dates beyond Int64 microseconds read back as infinity and -infinity")
  func infiniteTimestamps() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let destination = folder.appendingPathComponent("infinity.parquet")
    // PostgresNIO decodes timestamp infinity as Int64.max microseconds and date -infinity as
    // Int32.min days after 2000-01-01.
    let postgresEpoch = Date(timeIntervalSince1970: 946_684_800)
    let result = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "INTEGER"), ColumnInfo(name: "created", type: "TIMESTAMP"),
      ],
      rows: [
        [.int(1), .date(postgresEpoch.addingTimeInterval(Double(Int64.max) / 1_000_000))],
        [.int(2), .date(postgresEpoch.addingTimeInterval(Double(Int32.min) * 86_400))],
        [.int(3), .date(Date(timeIntervalSince1970: Self.base))],
      ], rowCount: 3)

    try await DataExporter.exportParquet(
      result: result, to: destination, loadLibrary: { { try DuckDBTestPlugin.library() } })

    let path = try DuckDBFileQuery.canonicalPath(of: destination)
    let file = "read_parquet(\(SQLDialect.duckdb.literal(.string(path))))"
    try await withSession(extraAllowedPaths: [path]) { session in
      let rows = try await collect(session, "SELECT created::VARCHAR FROM \(file) ORDER BY id")
      #expect(
        rows == [[.string("infinity")], [.string("-infinity")], [.string("2026-01-02 03:04:05")]])
    }
  }

  @Test("Cancel after the first batch removes the temporary folder and writes nothing")
  func cancelCleansUp() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let temp = folder.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    let destination = folder.appendingPathComponent("result.parquet")
    let exporter = ParquetExporter(
      loadLibrary: { try DuckDBTestPlugin.library() }, temporaryDirectory: temp)
    let reports = Reports()

    // Its own task: cancelling the test's task would cancel the test.
    let export = Task {
      try await exporter.export(Self.result(), to: destination) { rows in
        reports.append(rows)
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }
    await #expect(throws: CancellationError.self) {
      try await export.value
    }
    #expect(reports.values == [ParquetExport.rowsPerStatement])
    #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  // MARK: - Fixture

  /// Every 7th row (offset per column) is NULL in every column but `id`. `label` and the
  /// duplicate `label` (exported as `label_2`) carry quotes, backslashes and non-ASCII text.
  private static func result() -> CellResult {
    let columns = [
      ColumnInfo(name: "id", type: "INTEGER"), ColumnInfo(name: "ratio", type: "DOUBLE PRECISION"),
      ColumnInfo(name: "flag", type: "BOOLEAN"), ColumnInfo(name: "created", type: "TIMESTAMP"),
      ColumnInfo(name: "payload", type: "BYTEA"), ColumnInfo(name: "doc", type: "JSON"),
      ColumnInfo(name: "amount", type: "DECIMAL(38,10)"), ColumnInfo(name: "label", type: "TEXT"),
      ColumnInfo(name: "label", type: "TEXT"),
    ]
    let rows: [[CellValue]] = (0..<rowCount).map { i in
      let values: [CellValue] = [
        .double(Double(i) / 8), .bool(i % 2 == 0),
        .date(Date(timeIntervalSince1970: base + Double(i) + Double(i % 1000) / 1_000_000)),
        .data(Data([0xDE, 0xAD, UInt8(i % 256), 0x00])), .json("{\"n\":\(i),\"s\":\"é\"}"),
        .string("\(i).0123456789"), .string("héllo ✓ 日本 🦆 'q' \\b \(i)"),
        .string("second \(i)"),
      ]
      let cells = values.enumerated().map { column, value in
        (i + column) % 7 == 0 ? CellValue.null : value
      }
      return [.int(i)] + cells
    }
    return CellResult(columns: columns, rows: rows, rowCount: rows.count)
  }

  private static func expectedText(_ i: Int) -> [CellValue] {
    let micros = String(format: "%06d", i % 1000)
    let created = Date(timeIntervalSince1970: base + Double(i))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: created)
    let timestamp = String(
      format: "%04d-%02d-%02d %02d:%02d:%02d.%@", parts.year!, parts.month!, parts.day!,
      parts.hour!, parts.minute!, parts.second!, micros)
    let values: [CellValue] = [
      .string(String(Double(i) / 8)), .string(i % 2 == 0 ? "true" : "false"), .string(timestamp),
      .string(String(format: "DEAD%02X00", i % 256)), .string("{\"n\":\(i),\"s\":\"é\"}"),
      .string("\(i).0123456789"), .string("héllo ✓ 日本 🦆 'q' \\b \(i)"),
      .string("second \(i)"),
    ]
    return values.enumerated().map { column, value in
      (i + column) % 7 == 0 ? CellValue.null : value
    }
  }

  // MARK: - Helpers

  /// Progress reports, collected from the exporter's task.
  private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []

    var values: [Int] { lock.withLock { stored } }

    func append(_ value: Int) { lock.withLock { stored.append(value) } }
  }

  /// `dblore-parquet-*` folders in the process temporary directory.
  private static func exportFolders() throws -> Set<String> {
    let names = try FileManager.default.contentsOfDirectory(
      atPath: FileManager.default.temporaryDirectory.path)
    return Set(names.filter { $0.hasPrefix(ParquetExport.directoryPrefix) })
  }

  private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-pqlive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func withSession(
    extraAllowedPaths: [String], _ body: (DuckDBSession) async throws -> Void
  ) async throws {
    let session = DuckDBSession(
      config: ConnectionConfig(
        databaseType: .duckdb, database: DuckDBSession.inMemoryPath, sslMode: .disable,
        statementTimeoutSeconds: 60),
      extraAllowedPaths: extraAllowedPaths
    ) { try DuckDBTestPlugin.library() }
    try await session.open()
    do {
      try await body(session)
      await session.close()
    } catch {
      await session.close()
      throw error
    }
  }

  private func collect(_ session: DuckDBSession, _ sql: String) async throws -> [[CellValue]] {
    let source = try await session.query(sql, binds: [])
    var rows: [[CellValue]] = []
    for try await row in source.rows { rows.append(row) }
    return rows
  }
}
