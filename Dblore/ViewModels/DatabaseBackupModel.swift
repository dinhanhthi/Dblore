// DatabaseBackupModel.swift
// Drives the SQL dump, SQLite file copy and restore sheets for the active tab. The dump opens
// its own connection (`SQLDumpWriter`) from the tab manager's in-memory config, unremembered
// certificate and SSH secret, and host-key prompt; the restore reads and plans the file off the
// main actor, then runs it on the tab's connection through the gate (`executeGatedRestore`)
// after the Safe Mode confirmation. Progress callbacks arrive off the main actor and hop back
// here. One History row per dump and per restore (success, failure, cancel) when History is on.

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

nonisolated enum DatabaseBackupError: LocalizedError, Equatable, Sendable {
  case notUTF8

  var errorDescription: String? {
    switch self {
    case .notUTF8:
      "This file is not UTF-8 text, so it is not a Dblore SQL dump. Nothing was executed."
    }
  }
}

@Observable
@MainActor
final class DatabaseBackupModel {
  enum Activity: Equatable {
    case dumping
    case copying
    case reading
    case restoring
  }

  /// Panels, the dump connection and the file copy; tests replace them
  struct Environment {
    /// Save panel with a suggested name and file extension; nil when cancelled
    var chooseSaveURL: @MainActor (_ suggestedName: String, _ fileExtension: String) async -> URL?
    /// Open panel for a dump file; nil when cancelled
    var chooseOpenURL: @MainActor () async -> URL?
    /// The tab's in-memory config, the tab manager's unremembered certificate and SSH secret,
    /// and the host-key prompt the tab's manager was built with
    var makeDumpWriter:
      @MainActor (
        ConnectionConfig, ClientCertificateStoreFactory.ConnectionMaterial?,
        SSHCredentialStoreFactory.ConnectionCredential?, any SSHHostKeyPrompt
      ) -> SQLDumpWriter
    var copyDatabase:
      @Sendable (URL, URL, @escaping @Sendable (SQLiteFileBackup.Progress) -> Void) async throws
        -> SQLiteFileBackup.Progress
    /// The tab's commit style (Safe Mode), as the query confirmation reads it
    var commitStyle: @MainActor (NotebookViewModel) -> CommitStyle
    /// Reads and plans a restore file (`readPlan`), run off the main actor
    var readRestorePlan: @Sendable (URL, DatabaseType) async throws -> (SQLRestorePlan, Int)

    static let live = Environment(
      chooseSaveURL: { await DatabaseBackupModel.showSavePanel(name: $0, fileExtension: $1) },
      chooseOpenURL: { await DatabaseBackupModel.showOpenPanel() },
      makeDumpWriter: { config, material, credential, prompt in
        SQLDumpWriter(
          config: config, material: material, sshCredential: credential, sshHostKeyPrompt: prompt)
      },
      copyDatabase: { source, destination, progress in
        try await SQLiteFileBackup.copy(from: source, to: destination, progress: progress)
      },
      commitStyle: { viewModel in
        viewModel.notebook.connectionConfig?.resolvedCommitStyle(
          fallback: AppSettings.shared.commitStyle) ?? AppSettings.shared.commitStyle
      },
      readRestorePlan: { try DatabaseBackupModel.readPlan(url: $0, engine: $1) })
  }

  /// The active tab: its connection, protection policy, History and notebook id (`caller`)
  let viewModel: NotebookViewModel
  @ObservationIgnored private let environment: Environment

  private(set) var activity: Activity?
  private(set) var dumpProgress: SQLDumpProgress?
  private(set) var copyProgress: SQLiteFileBackup.Progress?
  private(set) var restoreProgress: SQLRestoreProgress?
  private(set) var restoreFileName: String?
  private(set) var restoreFileSize: Int?
  private(set) var restorePlan: SQLRestorePlan?
  /// Why the gate would refuse the loaded restore, shown before any confirmation
  private(set) var restoreBlockedReason: String?
  /// Safe Mode asks before the restore runs
  private(set) var isConfirmingRestore = false
  private(set) var confirmationRequiresPassword = false
  /// What Safe Mode shows while it asks: every statement but the rows (`restoreConfirmation`)
  private(set) var restoreConfirmation: [StatementConfirmation] = []
  /// The loaded plan ran to the end (running it again would restore twice)
  private(set) var restoreCompleted = false
  private(set) var errorMessage: String?
  /// What the last finished operation did
  private(set) var resultMessage: String?

  /// Stops the running dump, copy or file read (a restore stops through the connection)
  @ObservationIgnored private var cancelWork: (() -> Void)?
  /// Changes with every operation, so late progress of an earlier one is dropped
  @ObservationIgnored private var operationID = UUID()
  /// Connection the restore plan was read for (`executeGatedRestore` refuses another)
  @ObservationIgnored private var planEpoch: UInt64?
  /// The restore's own batch is running (`executeGatedRestore` has not returned). The connection
  /// is shared by every tab: once the batch returned, whatever runs there belongs to another tab,
  /// so Cancel (or the sheet going away) must not stop it.
  @ObservationIgnored private var restoreBatchInFlight = false

  init(viewModel: NotebookViewModel, environment: Environment = .live) {
    self.viewModel = viewModel
    self.environment = environment
  }

  var isBusy: Bool { activity != nil }

  // MARK: - Dump

  /// Asks where to save, then dumps. A destination that is the open SQLite file or one of its
  /// journal files is refused before any connection is made.
  func exportDump(options: SQLDumpOptions) async {
    guard activity == nil else { return }
    clearMessages()
    guard let manager = viewModel.connectionManager, let config = await manager.config else {
      errorMessage = "No database connection available"
      return
    }
    guard
      let destination = await environment.chooseSaveURL(Self.baseName(config) + ".sql", "sql")
    else { return }
    if SQLDumpWriter.isConnectedDatabaseFile(destination, config: config) {
      errorMessage = SQLDumpError.destinationIsDatabase.localizedDescription
      return
    }
    let writer = environment.makeDumpWriter(
      config, await manager.activeUnrememberedCertificate,
      await manager.activeUnrememberedSSHCredential, manager.sshHostKeyPolicy.prompt)
    let id = begin(.dumping)
    dumpProgress = SQLDumpProgress(tablesDone: 0, tableCount: 0, rowsWritten: 0)
    let started = ContinuousClock.now
    let report = reporter(id, .dumping) { $0.dumpProgress = $1 }
    let work = Task { try await writer.write(to: destination, options: options, progress: report) }
    cancelWork = { work.cancel() }
    let status: QueryHistoryEntry.Status
    var failure: String?
    do {
      let final = try await work.value
      dumpProgress = final
      status = .success
      resultMessage =
        "Saved \(destination.lastPathComponent): \(Self.counted(final.tablesDone, "table")), "
        + "\(Self.counted(final.rowsWritten, "row"))."
    } catch {
      status = Self.historyStatus(for: error)
      failure = error.localizedDescription
      if status == .cancelled {
        resultMessage = "Dump cancelled. Nothing was saved."
      } else {
        errorMessage = failure
      }
    }
    let progress = dumpProgress ?? SQLDumpProgress(tablesDone: 0, tableCount: 0, rowsWritten: 0)
    await recordHistory(started: started) { workspaceID, workspaceName, duration in
      QueryHistoryEntry.dumpSummary(
        progress, config: config, workspaceID: workspaceID, workspaceName: workspaceName,
        durationMs: duration, status: status, errorMessage: failure)
    }
    end(id)
  }

  /// SQLite only: asks where to save, then copies the database file (`sqlite3_backup`)
  func copyDatabaseFile() async {
    guard activity == nil else { return }
    clearMessages()
    guard let manager = viewModel.connectionManager, let config = await manager.config,
      config.databaseType == .sqlite
    else {
      errorMessage = "No SQLite database is open"
      return
    }
    guard
      let destination = await environment.chooseSaveURL(
        Self.baseName(config) + " copy.sqlite", "sqlite")
    else { return }
    if SQLDumpWriter.isConnectedDatabaseFile(destination, config: config) {
      errorMessage = SQLiteFileBackupError.destinationIsDatabase.localizedDescription
      return
    }
    let id = begin(.copying)
    copyProgress = nil
    let source = URL(fileURLWithPath: config.database)
    let copy = environment.copyDatabase
    let report = reporter(id, .copying) { $0.copyProgress = $1 }
    let work = Task { try await copy(source, destination, report) }
    cancelWork = { work.cancel() }
    do {
      copyProgress = try await work.value
      resultMessage = "Saved \(destination.lastPathComponent)."
    } catch {
      if Self.historyStatus(for: error) == .cancelled {
        resultMessage = "Copy cancelled. Nothing was saved."
      } else {
        errorMessage = error.localizedDescription
      }
    }
    end(id)
  }

  /// The chosen tables as dump options: nil tables when every listed table is chosen, so the
  /// dump also keeps tables the sidebar does not list
  static func dumpOptions(
    selected: Set<SQLDumpDDL.ObjectName>, from tables: [DatabaseTable], includeData: Bool
  ) -> SQLDumpOptions {
    let all = Set(tables.map { SQLDumpDDL.ObjectName(schema: $0.schema, name: $0.name) })
    return SQLDumpOptions(
      tables: all.isSubset(of: selected) ? nil : selected, includeData: includeData)
  }

  // MARK: - Restore

  func chooseRestoreFile() async {
    guard activity == nil, let url = await environment.chooseOpenURL() else { return }
    await loadRestore(from: url)
  }

  /// Reads and plans `url` off the main actor (the size is checked before reading), for the
  /// connected engine and connection
  func loadRestore(from url: URL) async {
    guard activity == nil else { return }
    clearMessages()
    restorePlan = nil
    restoreBlockedReason = nil
    restoreProgress = nil
    isConfirmingRestore = false
    restoreCompleted = false
    restoreFileName = url.lastPathComponent
    restoreFileSize = nil
    guard let manager = viewModel.connectionManager, let engine = await manager.databaseType else {
      errorMessage = "No database connection available"
      return
    }
    let epoch = await manager.connectionEpoch
    let id = begin(.reading)
    let read = environment.readRestorePlan
    let work = Task.detached(priority: .userInitiated) {
      try await read(url, engine)
    }
    cancelWork = { work.cancel() }
    do {
      let (plan, size) = try await work.value
      if operationID == id {
        restorePlan = plan
        restoreFileSize = size
        planEpoch = epoch
        restoreBlockedReason = Self.restoreBlockReason(plan, policy: viewModel.protectionPolicy)
      }
    } catch {
      if operationID == id, Self.historyStatus(for: error) != .cancelled {
        errorMessage = error.localizedDescription
      }
    }
    end(id)
  }

  /// Checks the gate's answer, then asks Safe Mode when the commit style confirms writes (Confirm
  /// and Password ask for every non-empty restore: a restore always writes, even one of only
  /// sequence values or session settings), or runs the restore at once
  func restore() async {
    guard activity == nil, !isConfirmingRestore, !restoreCompleted, let plan = restorePlan else {
      return
    }
    clearMessages()
    restoreBlockedReason = Self.restoreBlockReason(plan, policy: viewModel.protectionPolicy)
    guard restoreBlockedReason == nil else { return }
    let style = environment.commitStyle(viewModel)
    if !plan.statements.isEmpty, style == .confirm || style == .password {
      confirmationRequiresPassword = style.requiresPassword
      restoreConfirmation = Self.restoreConfirmation(plan)
      isConfirmingRestore = true
      return
    }
    await runRestore(plan)
  }

  /// Safe Mode said yes (the confirmation panel checked Touch ID or the password)
  func confirmRestore() async {
    guard isConfirmingRestore, activity == nil, let plan = restorePlan else { return }
    cancelRestoreConfirmation()
    await runRestore(plan)
  }

  func cancelRestoreConfirmation() {
    isConfirmingRestore = false
    confirmationRequiresPassword = false
    restoreConfirmation = []
  }

  /// The Safe Mode list of a restore: every statement but the rows (schema, triggers, sequence
  /// values, session settings), each with its text on one line (comments dropped, whitespace
  /// runs collapsed), cut as the query confirmation cuts it. A cut row and every trigger also
  /// carry their whole text (`fullText`, behind "Show full statement") and a note: how much the
  /// preview leaves out, and for a trigger the table whose writes run its body. INSERTs (and
  /// SQLite's `DELETE FROM sqlite_sequence`) stay a count.
  nonisolated static func restoreConfirmation(_ plan: SQLRestorePlan) -> [StatementConfirmation] {
    let dialect = plan.engine.dialect
    return zip(plan.statements, plan.kinds).enumerated().compactMap { index, pair in
      let (statement, kind) = pair
      let label: String
      switch kind {
      case .data: return nil
      case .schema: label = "Schema"
      case .trigger: label = "Trigger"
      case .sequenceValue: label = "Sequence value"
      case .sessionSetting: label = "Session setting"
      }
      let line = NotebookViewModel.collapsedLine(statement.text, dialect: dialect)
      let omitted = NotebookViewModel.previewOmittedCount(line)
      var notes: [String] = []
      if kind == .trigger {
        let table = SQLRestorePlan.triggerTable(statement.text) ?? "its table"
        notes.append("Trigger body runs on every later write to \(table)")
      }
      if omitted > 0 {
        notes.append("Statement continues for \(omitted.formatted()) more characters")
      }
      var row = StatementConfirmation(
        index: index, preview: NotebookViewModel.oneLinePreview(statement.text, dialect: dialect),
        kindLabel: label, affectsAllRows: statement.affectsAllRows,
        touchesBrake: statement.resetsSessionBrakes,
        changesPrivileges: statement.changesPrivileges)
      row.isTruncated = omitted > 0
      if !notes.isEmpty {
        row.fullText = statement.text
        row.fullTextNotes = notes
      }
      return row
    }
  }

  /// Why the gate would refuse `plan` under `policy` (the connection's own policy; the
  /// connection still decides when it runs), or nil
  nonisolated static func restoreBlockReason(
    _ plan: SQLRestorePlan, policy: ProtectionPolicy
  ) -> String? {
    if policy.protectionLevel == .readOnly {
      return "This connection is read-only: restoring a SQL dump is not allowed."
    }
    if plan.engine == .mysql, policy.protectedMode {
      return "Turn Protected mode off for this connection to restore a MySQL dump: MySQL commits "
        + "each schema change at once, so the restore cannot wait for Commit."
    }
    if case .blocked(let index, _, let reason) = DatabaseConnectionManager.evaluate(
      plan.statements, policy: policy, dialect: plan.engine.dialect)
    {
      return "Statement \(index + 1): \(reason)"
    }
    return nil
  }

  private func runRestore(_ plan: SQLRestorePlan) async {
    guard let manager = viewModel.connectionManager, let epoch = planEpoch,
      let config = await manager.config
    else {
      errorMessage = "No database connection available"
      return
    }
    let id = begin(.restoring)
    restoreProgress = SQLRestoreProgress(
      statementsDone: 0, statementCount: plan.summary.statementCount)
    let started = ContinuousClock.now
    var summary = plan.summary
    let status: QueryHistoryEntry.Status
    var failure: String?
    do {
      restoreBatchInFlight = true
      defer { restoreBatchInFlight = false }
      summary = try await manager.executeGatedRestore(
        plan, policy: viewModel.protectionPolicy, connectionEpoch: epoch, caller: viewModel.id,
        progress: reporter(id, .restoring) { $0.restoreProgress = $1 })
      status = .success
      restoreCompleted = true
      restoreProgress = SQLRestoreProgress(
        statementsDone: summary.statementsRun, statementCount: summary.statementCount)
      resultMessage = Self.restoredMessage(summary)
    } catch {
      status = Self.historyStatus(for: error)
      failure = error.localizedDescription
      if status == .cancelled {
        resultMessage = "Restore cancelled."
      } else {
        errorMessage = failure
      }
    }
    await recordHistory(started: started) { workspaceID, workspaceName, duration in
      QueryHistoryEntry.restoreSummary(
        summary, config: config, workspaceID: workspaceID, workspaceName: workspaceName,
        durationMs: duration, status: status, errorMessage: failure)
    }
    // Pending transaction banner and the sidebar's tables
    await viewModel.onStatementsExecuted?()
    end(id)
  }

  private static func restoredMessage(_ summary: SQLRestoreSummary) -> String {
    let count = counted(summary.statementsRun, "statement")
    if summary.pending {
      return "Restored \(count) into the pending transaction: Commit to keep them or Roll Back."
    }
    if summary.insideUserTransaction {
      return "Restored \(count) inside your open transaction: they stay only if you commit it."
    }
    return "Restored \(count)."
  }

  /// The file's text, planned for `engine`. Throws `SQLRestoreError.tooLarge` before reading a
  /// file over the limit.
  nonisolated static func readPlan(
    url: URL, engine: DatabaseType
  ) throws -> (SQLRestorePlan, Int) {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let limit = SQLRestorePlan.maxScriptBytes
    let size = try handle.seekToEnd()
    guard size <= UInt64(limit) else { throw SQLRestoreError.tooLarge(bytes: Int(clamping: size)) }
    try handle.seek(toOffset: 0)
    var data = Data()
    data.reserveCapacity(Int(size))
    while true {
      try Task.checkCancellation()
      let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
      if chunk.isEmpty { break }
      data.append(chunk)
      // The file grew after the size check
      guard data.count <= limit else { throw SQLRestoreError.tooLarge(bytes: data.count) }
    }
    guard let script = String(data: data, encoding: .utf8) else {
      throw DatabaseBackupError.notUTF8
    }
    try Task.checkCancellation()
    let plan = try PerfSignpost.interval("restore.plan") {
      try SQLRestorePlan(script: script, engine: engine)
    }
    return (plan, data.count)
  }

  // MARK: - Cancel

  /// The sheet went away (closed, or its tab closed while it worked): a late Safe Mode answer
  /// restores nothing, and the running dump, copy, read or restore stops (a read at once)
  func sheetDisappeared() {
    cancelRestoreConfirmation()
    switch activity {
    case .reading: stopReading()
    case nil: break
    case .dumping, .copying, .restoring: Task { await cancel() }
    }
  }

  /// Stops the running operation: a dump, copy or read by task cancellation, a restore through
  /// the connection (as Stop does for a running statement), only while the restore's own batch
  /// runs (afterwards it only records History and refreshes the tab). A cancelled read ends at
  /// once: its plan, if planning still finishes, is dropped.
  func cancel() async {
    switch activity {
    case .restoring:
      guard restoreBatchInFlight else { return }
      _ = await viewModel.cancelRunningStatement(cancelQueue: false)
    case .reading:
      stopReading()
    case .dumping, .copying:
      cancelWork?()
    case nil:
      break
    }
  }

  private func stopReading() {
    cancelWork?()
    cancelWork = nil
    operationID = UUID()
    activity = nil
  }

  // MARK: - Private

  private func begin(_ activity: Activity) -> UUID {
    let id = UUID()
    operationID = id
    self.activity = activity
    return id
  }

  /// A progress callback (called off the main actor) that hops back here, dropped once the
  /// operation `id` is over
  private func reporter<Progress: Sendable>(
    _ id: UUID, _ activity: Activity,
    _ apply: @escaping @MainActor (DatabaseBackupModel, Progress) -> Void
  ) -> @Sendable (Progress) -> Void {
    { [weak self] progress in
      Task { @MainActor in
        guard let self, self.operationID == id, self.activity == activity else { return }
        apply(self, progress)
      }
    }
  }

  private func end(_ id: UUID) {
    guard operationID == id else { return }
    activity = nil
    cancelWork = nil
  }

  private func clearMessages() {
    errorMessage = nil
    resultMessage = nil
  }

  /// Records as the AI queries do: only with History on, on the tab's recorder, then the list
  /// reloads
  private func recordHistory(
    started: ContinuousClock.Instant,
    _ entry: (_ workspaceID: UUID?, _ workspaceName: String?, _ durationMs: Int) ->
      QueryHistoryEntry
  ) async {
    guard viewModel.historySettings.historyEnabled else { return }
    let workspace = viewModel.historyWorkspace()
    let duration = Int(((ContinuousClock.now - started) / .milliseconds(1)).rounded())
    await viewModel.historyRecorder.record(entry(workspace?.id, workspace?.name, duration))
    viewModel.onHistoryRecorded?()
  }

  nonisolated static func historyStatus(for error: Error) -> QueryHistoryEntry.Status {
    if error is CancellationError { return .cancelled }
    switch error as? DatabaseError {
    case .queryCancelled, .batchCancelled: return .cancelled
    default: return .error
    }
  }

  private static func counted(_ count: Int, _ noun: String) -> String {
    "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
  }

  /// The database name, or the SQLite file name without its extension
  private static func baseName(_ config: ConnectionConfig) -> String {
    let name =
      config.databaseType == .sqlite
      ? URL(fileURLWithPath: config.database).deletingPathExtension().lastPathComponent
      : config.database
    return name.isEmpty ? "dump" : name
  }

  private static func showSavePanel(name: String, fileExtension: String) async -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    panel.allowedContentTypes = UTType(filenameExtension: fileExtension).map { [$0] } ?? []
    // A database copy may be named .db or .bak. A dump keeps .sql, also when the whole name is
    // retyped: Restore's open panel lists only .sql and plain text files
    panel.allowsOtherFileTypes = fileExtension != "sql"
    panel.canCreateDirectories = true
    return await withCheckedContinuation { continuation in
      panel.begin { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
    }
  }

  private static func showOpenPanel() async -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.sql, .plainText]
    return await withCheckedContinuation { continuation in
      panel.begin { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
    }
  }
}
