// LargeCatalogFixture.swift
// Deterministic SQLite catalog for LargeCatalogPerformanceTests: N tables t00000... of 6 columns
// (every 10th with a foreign key to the table before it, every 5th with a unique index on name)
// and one view per 50 tables, on 512-byte pages. Built through SQLiteHandle in the test
// process's temporary folder once per run and kept there, so VM QA can open the same file.

import Foundation

@testable import Dblore

@MainActor
enum LargeCatalogFixture {
  private static var built: [Int: URL] = [:]

  /// Table count: LARGE_CATALOG_TABLES (or the TEST_RUNNER_ form), else 50,000
  static var tableCount: Int {
    let values = ProcessInfo.processInfo.environment
    let text = values["LARGE_CATALOG_TABLES"] ?? values["TEST_RUNNER_LARGE_CATALOG_TABLES"]
    return text.flatMap(Int.init) ?? 50_000
  }

  static func tableName(_ index: Int) -> String { String(format: "t%05d", index) }

  /// The file for `tables` tables, built on first use in this process. Its path is recorded in
  /// a PERF line together with the build time.
  static func url(tables: Int) throws -> URL {
    if let url = built[tables] { return url }
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("dblore-large-catalog-\(tables).sqlite")
    let start = ContinuousClock.now
    try build(at: url, tables: tables)
    let elapsed = ContinuousClock.now - start
    PerfReport.record(
      "largeCatalog.fixtureBuild tables=\(tables) path=\(url.path)",
      ms: Double(elapsed.components.seconds) * 1000
        + Double(elapsed.components.attoseconds) / 1e15)
    built[tables] = url
    return url
  }

  private static func build(at url: URL, tables: Int) throws {
    for suffix in ["", "-wal", "-shm", "-journal"] {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
    let handle = try SQLiteHandle(url: url)
    // The handle opens in WAL, which fixes the page size: leave WAL, then rebuild the empty file
    try handle.execute("PRAGMA journal_mode = DELETE")
    try handle.execute("PRAGMA page_size = 512")
    try handle.execute("VACUUM")
    let pageSize = try handle.prepare("PRAGMA page_size")
    guard try pageSize.step(), pageSize.columnInt(0) == 512 else {
      throw SQLiteError(code: 1, message: "page_size is not 512")
    }
    try handle.transaction {
      for index in 0..<tables {
        let name = tableName(index)
        let parent = index % 10 == 9 ? " REFERENCES \(tableName(index - 1)) (id)" : ""
        try handle.execute(
          """
          CREATE TABLE \(name) (
            id INTEGER PRIMARY KEY, name TEXT NOT NULL, amount REAL, created_at TEXT,
            parent_id INTEGER\(parent), note TEXT)
          """)
        if index % 5 == 0 {
          try handle.execute("CREATE UNIQUE INDEX \(name)_name ON \(name) (name)")
        }
        if index % 50 == 0 {
          try handle.execute(
            "CREATE VIEW v\(String(format: "%05d", index / 50)) AS SELECT id, name, amount FROM \(name)"
          )
        }
      }
    }
  }
}
