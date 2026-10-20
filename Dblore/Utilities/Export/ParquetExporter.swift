// ParquetExporter.swift
// Writes one result to a Parquet file through an in-memory DuckDB opened with the plugin's
// library. The session may write only one file: `<temp>/dblore-parquet-<uuid>/export.parquet`
// (its realpath is the session's only `allowed_paths` entry, spike 2.3: a folder grants
// nothing). Rows go in as 1,000-row INSERTs of binds in one transaction, COPY writes the file,
// then it replaces the destination. The temporary folder is removed on success, failure and
// cancel. This database belongs to the exporter, not to a connection, so its statements do not
// go through the connection gate.

import Foundation

nonisolated struct ParquetExporter: Sendable {
  let loadLibrary: @Sendable () throws -> DuckDBLibrary
  var temporaryDirectory: URL = FileManager.default.temporaryDirectory

  /// Writes `result` to `destination` (an existing file is replaced) off the main actor
  /// (`@concurrent` leaves it). `progress` gets the rows written so far after each INSERT, on
  /// that same executor.
  /// - Throws: `ParquetExport.Failure`, DuckDB and file errors, `CancellationError` when the task
  ///   is cancelled. The destination is untouched then.
  @concurrent func export(
    _ result: CellResult, to destination: URL,
    progress: @escaping @Sendable (Int) -> Void = { _ in }
  ) async throws {
    let columns = ParquetExport.columns(result.columns, rows: result.rows)
    let createTable = try ParquetExport.createTableSQL(columns)
    let root = try DuckDBFileQuery.canonicalPath(of: temporaryDirectory)
    let output = ParquetExport.outputPath(temporaryRoot: root, id: UUID())
    let copy = try ParquetExport.copySQL(outputPath: output, temporaryRoot: root)
    let outputURL = URL(fileURLWithPath: output)
    let folder = outputURL.deletingLastPathComponent()
    let files = FileManager.default
    try files.createDirectory(
      at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: folder) }

    let session = DuckDBSession(
      config: ConnectionConfig(
        databaseType: .duckdb, database: DuckDBSession.inMemoryPath, sslMode: .disable),
      extraAllowedPaths: [output], loadLibrary: loadLibrary)
    do {
      try await session.open()
      _ = try await session.command(createTable, binds: [])
      try await insert(result.rows, columns: columns, into: session, progress: progress)
      try Task.checkCancellation()
      // COPY is the one long statement: Cancel interrupts it.
      try await withTaskCancellationHandler {
        _ = try await session.command(copy, binds: [])
      } onCancel: {
        Task { await session.interrupt() }
      }
      await session.close()
    } catch {
      await session.close()
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
    try Task.checkCancellation()
    if files.fileExists(atPath: destination.path) {
      // An atomic swap: the old file stays until the new one takes its place.
      _ = try files.replaceItemAt(destination, withItemAt: outputURL)
    } else {
      try files.moveItem(at: outputURL, to: destination)
    }
  }

  private func insert(
    _ rows: [[CellValue]], columns: [ParquetExport.Column], into session: DuckDBSession,
    progress: @Sendable (Int) -> Void
  ) async throws {
    let fullBatch = try ParquetExport.insertSQL(
      columns: columns, rowCount: ParquetExport.rowsPerStatement)
    _ = try await session.command("BEGIN TRANSACTION", binds: [])
    for batch in ParquetExport.batches(rowCount: rows.count) {
      try Task.checkCancellation()
      let sql =
        batch.count == ParquetExport.rowsPerStatement
        ? fullBatch : try ParquetExport.insertSQL(columns: columns, rowCount: batch.count)
      let binds = rows[batch].flatMap { ParquetExport.binds($0, columns: columns) }
      _ = try await session.command(sql, binds: binds)
      progress(batch.upperBound)
    }
    _ = try await session.command("COMMIT", binds: [])
  }
}
