// WorkspaceManager+DataDictionary.swift
// File > Export Data Dictionary... and the sidebar's Export Data Dictionary... on SQL engines.
// The sheet picks Markdown or HTML, then the structure of every sidebar table is read (four at a
// time, with progress and Cancel), then the save panel. A table whose read fails (dropped since
// the sidebar loaded) is left out and named in the document. The file is rendered and written
// off the main actor. More than `DataDictionaryExportModel.maxTables` tables are refused up front.

import AppKit
import Foundation

extension WorkspaceManager {
  /// Connected to a SQL engine, a schema read since the last connect, and the catalog not paused
  /// by a pending transaction (the structure reads would fail)
  var canExportDataDictionary: Bool {
    guard connectionState.isConnected, schemaConnectionEpoch != nil, !isSchemaPaused,
      let type = workspace.connectionConfig?.databaseType
    else { return false }
    return type.capabilities.queryLanguage == .sql
  }

  /// Opens the export sheet on the sidebar's tables, or refuses with an alert above the cap
  func openDataDictionaryExport() {
    guard canExportDataDictionary, dataDictionaryExport == nil else { return }
    let tables = databaseTables
    guard tables.count <= DataDictionaryExportModel.maxTables else {
      let alert = NSAlert()
      alert.messageText = "Too Many Tables"
      alert.informativeText =
        "This database has \(tables.count.formatted()) tables. A data dictionary covers at most "
        + "\(DataDictionaryExportModel.maxTables.formatted()) tables."
      alert.alertStyle = .warning
      alert.runModal()
      return
    }
    let model = DataDictionaryExportModel(
      tables: tables.map { .init(schema: $0.schema, name: $0.name) },
      databaseName: dataDictionaryDatabaseName, connectionManager: connectionManager)
    model.onClose = { [weak self, weak model] in
      if self?.dataDictionaryExport === model { self?.dataDictionaryExport = nil }
    }
    dataDictionaryExport = model
  }

  /// The file name for a file database, the database name otherwise, else the connection name
  private var dataDictionaryDatabaseName: String {
    guard let config = workspace.connectionConfig else { return "database" }
    let database =
      config.databaseType.capabilities.isFileBased
      ? URL(fileURLWithPath: config.database).lastPathComponent : config.database
    if !database.isEmpty { return database }
    return config.name.isEmpty ? "database" : config.name
  }
}

/// One data dictionary export: the format choice, the structure reads, then the save panel
@MainActor
@Observable
final class DataDictionaryExportModel: Identifiable {
  static let maxTables = 2_000
  /// Structure reads in flight at once
  static let concurrency = 4

  struct TableName: Sendable {
    let schema: String
    let name: String
  }

  let tables: [TableName]
  let databaseName: String
  var format: DataDictionaryRenderer.Format = .markdown
  /// Structures read so far; nil until Export
  private(set) var completed: Int?
  private(set) var isCancelling = false

  /// Hides the sheet
  @ObservationIgnored var onClose: () -> Void = {}
  @ObservationIgnored private let connectionManager: DatabaseConnectionManager
  @ObservationIgnored private var task: Task<Void, Never>?

  init(tables: [TableName], databaseName: String, connectionManager: DatabaseConnectionManager) {
    self.tables = tables
    self.databaseName = databaseName
    self.connectionManager = connectionManager
  }

  var isLoading: Bool { completed != nil }

  /// Reads every structure, closes the sheet, then asks where to save
  func start() {
    guard task == nil, !tables.isEmpty else { return }
    completed = 0
    let tables = tables
    let manager = connectionManager
    let format = format
    let databaseName = databaseName
    task = Task { [weak self] in
      do {
        let (structures, skipped) = try await Self.loadStructures(tables, from: manager) {
          self?.completed = $0
        }
        try Task.checkCancellation()
        let content = await Self.render(
          format, structures, databaseName: databaseName, generatedAt: Date(),
          skipped: skipped.map { $0.schema.isEmpty ? $0.name : "\($0.schema).\($0.name)" })
        try Task.checkCancellation()
        self?.onClose()
        DataExporter.saveFile(
          content: content, defaultFilename: Self.fileName(databaseName, format),
          allowedFileTypes: [format.fileExtension])
      } catch {
        // A cancelled read may fail as a wrapped query error: Cancel never shows an alert
        let cancelled = Task.isCancelled
        self?.onClose()
        guard !cancelled else { return }
        let alert = NSAlert()
        alert.messageText = "Export Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
      }
    }
  }

  /// Before Export: closes the sheet. While reading: stops after the reads in flight.
  func cancel() {
    guard let task else {
      onClose()
      return
    }
    isCancelling = true
    task.cancel()
  }

  /// The structures in `tables` order, at most `concurrency` reads at once, and the tables whose
  /// read failed. Cancellation aborts; so does every read failing (the first error is thrown).
  private static func loadStructures(
    _ tables: [TableName], from manager: DatabaseConnectionManager,
    progress: @escaping (Int) -> Void
  ) async throws -> (structures: [TableStructure], skipped: [TableName]) {
    try await withThrowingTaskGroup(of: (Int, Result<TableStructure, any Error>).self) { group in
      var results = [Result<TableStructure, any Error>?](repeating: nil, count: tables.count)
      var next = 0
      var done = 0
      func addNext() {
        let index = next
        let table = tables[index]
        next += 1
        group.addTask {
          do {
            return (
              index,
              .success(
                try await manager.fetchTableStructure(schema: table.schema, table: table.name))
            )
          } catch {
            // A cancelled read may fail as a wrapped query error: it aborts, never skips
            try Task.checkCancellation()
            return (index, .failure(error))
          }
        }
      }
      while next < min(concurrency, tables.count) { addNext() }
      while let (index, result) = try await group.next() {
        try Task.checkCancellation()
        results[index] = result
        done += 1
        progress(done)
        if next < tables.count { addNext() }
      }
      var structures: [TableStructure] = []
      var skipped: [TableName] = []
      var firstError: (any Error)?
      for (index, result) in results.enumerated() {
        switch result {
        case .success(let structure): structures.append(structure)
        case .failure(let error):
          skipped.append(tables[index])
          firstError = firstError ?? error
        case nil: break
        }
      }
      if structures.isEmpty, let firstError { throw firstError }
      return (structures, skipped)
    }
  }

  /// Off the main actor: 2,000 tables of text must not hold up the UI
  @concurrent nonisolated private static func render(
    _ format: DataDictionaryRenderer.Format, _ tables: [TableStructure], databaseName: String,
    generatedAt: Date, skipped: [String]
  ) async -> String {
    DataDictionaryRenderer.render(
      format, tables: tables, databaseName: databaseName, generatedAt: generatedAt,
      skipped: skipped)
  }

  private static func fileName(
    _ databaseName: String, _ format: DataDictionaryRenderer.Format
  )
    -> String
  {
    let base = URL(fileURLWithPath: databaseName).deletingPathExtension().lastPathComponent
      .replacingOccurrences(of: ":", with: "_")
    return "\(base.isEmpty ? "database" : base)_data_dictionary.\(format.fileExtension)"
  }
}
