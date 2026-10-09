//
//  ConnectionImportModel.swift
//  Dblore
//
//  Preview and selection state for importing connections from other tools. Imported files are
//  external input: parsing runs off the main actor, and errors, rows and the summary never carry
//  file content or secrets.
//

import Foundation
import Observation

/// Why a preview row is not selected by default.
nonisolated enum ImportDuplicateReason: Equatable, Sendable {
  /// Its Keychain key is already in the saved connections.
  case alreadySaved
  /// An earlier row in this import has the same Keychain key.
  case duplicateInFile
}

/// One connection in the import preview. Display fields hold no secrets.
nonisolated struct ImportRow: Identifiable, Equatable, Sendable {
  let id: Int
  let name: String
  /// "host:port/database"
  let address: String
  let user: String
  let engine: String
  let hasPassword: Bool
  let hasSSH: Bool
  /// A key-based SSH tunnel whose key was not imported.
  let sshNeedsKey: Bool
  let duplicateReason: ImportDuplicateReason?
  let warnings: [String]
  var isSelected: Bool

  var isDuplicate: Bool { duplicateReason != nil }
  /// Saving skips an already saved row, so it cannot be selected.
  var isSelectable: Bool { duplicateReason != .alreadySaved }
}

@MainActor
@Observable
final class ConnectionImportModel {
  typealias ImportResult = (connections: [ImportedConnection], warnings: [String])

  var source: ImportSource = .pgpass
  private(set) var rows: [ImportRow] = []
  /// File-level warnings (skipped entries, unreadable secrets).
  private(set) var warnings: [String] = []
  private(set) var isLoading = false
  private(set) var errorMessage: String?
  /// History slots left before the saved-connection limit.
  private(set) var freeSlots = SessionManager.maxConnectionHistorySize

  var selectedCount: Int { rows.count { $0.isSelected } }
  var overLimit: Bool { selectedCount > freeSlots }

  private var connections: [ImportedConnection] = []
  private var loadGeneration = 0

  private let importFile: @Sendable (ImportSource, URL) throws -> ImportResult
  private let importText: @Sendable (ImportSource, String) throws -> ImportResult
  private let loadHistory: @MainActor () -> [ConnectionHistoryEntry]
  private let loadSavedKeys: @MainActor () -> Set<String>
  private let save: @MainActor ([ImportedConnection]) -> BulkSaveReport

  init(
    importFile: @escaping @Sendable (ImportSource, URL) throws -> ImportResult =
      ConnectionImportModel.readFile,
    importText: @escaping @Sendable (ImportSource, String) throws -> ImportResult =
      ConnectionImportModel.readText,
    loadHistory: @escaping @MainActor () -> [ConnectionHistoryEntry] = {
      // Keys only: no Keychain reads for the preview.
      SessionManager.loadHistory(passwords: NoPasswordStore())
    },
    loadSavedKeys: @escaping @MainActor () -> Set<String> = {
      SessionManager.savedConnectionKeys()
    },
    save: @escaping @MainActor ([ImportedConnection]) -> BulkSaveReport = {
      SessionManager.saveConnections($0)
    }
  ) {
    self.importFile = importFile
    self.importText = importText
    self.loadHistory = loadHistory
    self.loadSavedKeys = loadSavedKeys
    self.save = save
    freeSlots = Self.freeSlots(historyCount: loadHistory().count)
  }

  private static func freeSlots(historyCount: Int) -> Int {
    max(0, SessionManager.maxConnectionHistorySize - historyCount)
  }

  /// Clears the preview and drops any load still in flight, e.g. when the source changes.
  func reset() {
    loadGeneration += 1
    isLoading = false
    errorMessage = nil
    connections = []
    warnings = []
    rows = []
  }

  // MARK: - Loading

  /// Reads a file (.pgpass, TablePlus) or folder (DBeaver `.dbeaver`, DataGrip `.idea`).
  func load(url: URL) async {
    let source = source
    let importFile = importFile
    await run { try importFile(source, url) }
  }

  /// Parses pasted .pgpass or URI text.
  func loadText(_ text: String) async {
    let source = source
    let importText = importText
    await run { try importText(source, text) }
  }

  private func run(_ work: @escaping @Sendable () throws -> ImportResult) async {
    loadGeneration += 1
    let generation = loadGeneration
    isLoading = true
    errorMessage = nil
    let task = Task.detached(priority: .userInitiated) {
      try PerfSignpost.interval("connections.import.parse") { try work() }
    }
    let result = await task.result
    guard generation == loadGeneration else { return }
    isLoading = false
    switch result {
    case .success(let value):
      apply(value)
    case .failure(let error):
      apply(([], []))
      errorMessage = Self.message(for: error)
    }
  }

  private func apply(_ result: ImportResult) {
    freeSlots = Self.freeSlots(historyCount: loadHistory().count)
    // The same keys `SessionManager.saveConnections` skips, undecodable rows included.
    let savedKeys = loadSavedKeys()
    var seen: Set<String> = []
    connections = result.connections
    warnings = result.warnings
    rows = result.connections.enumerated().map { index, item in
      let config = item.config
      let key = ConnectionHistoryEntry(config: config).keychainKey
      let reason: ImportDuplicateReason? =
        savedKeys.contains(key)
        ? .alreadySaved : (seen.insert(key).inserted ? nil : .duplicateInFile)
      return ImportRow(
        id: index,
        name: config.name.isEmpty
          ? ImportedConnection.defaultName(
            username: config.username, host: config.host, database: config.database)
          : config.name,
        address: "\(config.host):\(config.port)/\(config.database)",
        user: config.username,
        engine: config.databaseType.displayName,
        hasPassword: item.password != nil,
        hasSSH: config.sshTunnel != nil,
        sshNeedsKey: config.sshTunnel?.authMethod == .privateKey && item.sshCredential == nil,
        duplicateReason: reason,
        warnings: item.warnings,
        isSelected: reason == nil)
    }
  }

  // MARK: - Selection

  func selectAll() {
    for index in rows.indices where rows[index].isSelectable { rows[index].isSelected = true }
  }

  func deselectAll() {
    for index in rows.indices { rows[index].isSelected = false }
  }

  func toggle(_ id: ImportRow.ID) {
    guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].isSelectable else {
      return
    }
    rows[index].isSelected.toggle()
  }

  // MARK: - Import

  /// Saves the selected rows. SessionManager is main-actor isolated, so its Keychain writes run here.
  func importSelected() async -> BulkSaveReport {
    let selected = rows.filter(\.isSelected).map { connections[$0.id] }
    return PerfSignpost.interval("connections.import.save") { save(selected) }
  }

  /// One-line toast text, e.g. "Imported 5 connections · 2 duplicates skipped".
  func summary(_ report: BulkSaveReport) -> String {
    var parts = ["Imported \(Self.count(report.added, "connection"))"]
    if !report.skippedDuplicates.isEmpty {
      parts.append("\(Self.count(report.skippedDuplicates.count, "duplicate")) skipped")
    }
    if report.droppedByLimit > 0 {
      parts.append(
        "\(report.droppedByLimit) over the \(SessionManager.maxConnectionHistorySize)-connection limit"
      )
    }
    if !report.failed.isEmpty {
      parts.append("\(report.failed.count) failed")
    }
    return parts.joined(separator: " · ")
  }

  private static func count(_ value: Int, _ noun: String) -> String {
    "\(value) \(noun)\(value == 1 ? "" : "s")"
  }

  // MARK: - Production importers

  /// Largest .pgpass file read.
  nonisolated static let maxPgpassSize = 1024 * 1024

  private enum ReadError: Error {
    case unreadable
    case tooLarge
    case unsupportedSource
  }

  nonisolated private static func readFile(
    _ source: ImportSource, _ url: URL
  ) throws
    -> ImportResult
  {
    switch source {
    case .dbeaver: return try DBeaverImporter.importConnections(fromWorkspaceFolder: url)
    case .tablePlus: return try TablePlusImporter.importConnections(fromFile: url)
    case .dataGrip: return try DataGripImporter.importConnections(fromIdeaFolder: url)
    case .pgpass: return PgpassParser.parse(try readPgpass(url))
    case .uri: throw ReadError.unsupportedSource
    }
  }

  nonisolated private static func readText(
    _ source: ImportSource, _ text: String
  ) throws
    -> ImportResult
  {
    switch source {
    case .pgpass: return PgpassParser.parse(text)
    case .uri: return ([try PostgresURIParser.parse(text)], [])
    case .dbeaver, .tablePlus, .dataGrip: throw ReadError.unsupportedSource
    }
  }

  /// Reads a regular, non-symlinked UTF-8 file of bounded size.
  nonisolated private static func readPgpass(_ url: URL) throws -> String {
    let values = try? url.resourceValues(forKeys: [
      .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
    ])
    guard let values, values.isSymbolicLink != true, values.isRegularFile == true else {
      throw ReadError.unreadable
    }
    guard (values.fileSize ?? 0) <= maxPgpassSize else { throw ReadError.tooLarge }
    guard let data = try? Data(contentsOf: url) else { throw ReadError.unreadable }
    guard data.count <= maxPgpassSize else { throw ReadError.tooLarge }
    guard let text = String(data: data, encoding: .utf8) else { throw ReadError.unreadable }
    return text
  }

  // MARK: - Errors

  /// Fixed sentences only: never the file content, the path or the parsed text.
  nonisolated static func message(for error: any Error) -> String {
    switch error {
    case let error as DBeaverImporter.ImportError:
      switch error {
      case .dataSourcesNotFound: return "No data-sources.json was found in this DBeaver folder."
      case .fileTooLarge: return "The DBeaver file is too large to import."
      case .malformedDataSources: return "The DBeaver data-sources.json could not be read."
      }
    case let error as TablePlusImporter.ImportError:
      switch error {
      case .fileNotFound: return "The TablePlus file was not found."
      case .fileTooLarge: return "The TablePlus file is too large to import."
      case .malformedConnections: return "The TablePlus file could not be read."
      case .encryptedExportNotSupported:
        return "Encrypted TablePlus exports are not supported. Pick the connections plist."
      }
    case let error as DataGripImporter.ImportError:
      switch error {
      case .dataSourcesNotFound: return "No dataSources.xml was found in this DataGrip folder."
      case .fileTooLarge: return "The DataGrip file is too large to import."
      case .malformedDataSources: return "The DataGrip dataSources.xml could not be read."
      }
    case let error as PostgresURIParser.ParseError:
      switch error {
      case .unsupportedScheme: return "Only postgresql:// and postgres:// URIs are supported."
      case .invalidPort: return "The connection string has an invalid port."
      case .missingHost: return "The connection string has no host."
      case .multipleHostsNotSupported:
        return "Connection strings with several hosts are not supported."
      case .unixSocketNotSupported: return "Unix socket connections are not supported."
      case .hostParameterNotSupported: return "A host query parameter is not supported."
      case .invalidFormat, .invalidPercentEncoding:
        return "The connection string could not be read."
      }
    case ReadError.tooLarge:
      return "The file is too large to import."
    case ReadError.unsupportedSource:
      return "This source cannot be imported this way."
    default:
      return "The file could not be read."
    }
  }
}

/// Returns no passwords, so loading history for the preview reads nothing from the Keychain.
private struct NoPasswordStore: ConnectionPasswordStore {
  func savePassword(_ password: String, forKey key: String) {}
  func loadPassword(forKey key: String) -> String? { nil }
  func deletePassword(forKey key: String) {}
}
