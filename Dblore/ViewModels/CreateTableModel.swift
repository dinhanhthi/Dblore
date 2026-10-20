// CreateTableModel.swift
// The Create Table sheet's state: the table name, target schema, columns, unique and foreign key
// constraints and comment the user types, the exact DDL `CreateTableDDLBuilder` returns for them
// (the preview), and Create. It refuses up front where the structure editor would
// (`StructureEditorModel.disabledReason`: DuckDB, read-only or schema-only connections, MySQL
// under Protected mode or with a transaction open), asks Safe Mode before sending, and sends the
// previewed strings through `executeGatedSchemaChange` (which re-checks every refusal) on the
// tab's connection. History rows use source `.structure`. Under Protected mode the new table is
// pending until Commit.

import Foundation
import Observation

@MainActor
@Observable
final class CreateTableModel: Identifiable {
  struct ColumnRow: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var type = ""
    var isNullable = true
    /// Blank for no default
    var defaultExpression = ""
    var isPrimaryKey = false
  }

  /// Where the new table goes; `schemas` lists the choices (a picker when there are 2+)
  var schema: String
  let schemas: [String]
  var tableName = ""
  var columns: [ColumnRow] = [ColumnRow()]
  /// Unique and foreign key constraints
  var constraints: [TableStructure.Constraint] = []
  /// Blank for none. SQLite tables take no comment.
  var comment = ""

  /// The connection state is being read (the engine's DDL depends on it)
  private(set) var isLoading = true
  /// Why no table can be created on this connection, or nil
  private(set) var disabledReason: String?
  /// Statements Safe Mode asks about before Create sends anything; nil when not asking
  private(set) var pendingConfirmation: [StatementConfirmation]?
  private(set) var confirmationRequiresPassword = false
  private(set) var isCreating = false
  private(set) var applyError: String?
  /// The table was created (or is pending): the sheet closes
  private(set) var isFinished = false
  private(set) var resultMessage: String?
  /// Called once the CREATE reached the server (pending: waits for Commit), to reload the
  /// sidebar schema
  @ObservationIgnored var onApplied: (@MainActor (_ pending: Bool) async -> Void)?
  /// Toast for the outcome. The workspace routes it to the tab's toast; nothing by default.
  @ObservationIgnored var toastPresenter: @MainActor (String, ToastMessage.ToastType) -> Void = {
    _, _ in
  }

  @ObservationIgnored private let context: StructureEditorContext
  @ObservationIgnored private var connection = StructureEditorConnectionState()
  @ObservationIgnored private var confirmedStatements: [String]?

  init(schema: String, schemas: [String], context: StructureEditorContext) {
    self.schema = schema
    self.schemas = schemas.contains(schema) ? schemas : [schema] + schemas
    self.context = context
  }

  /// The sheet for `tab`'s connection. Nil when the tab is not connected.
  convenience init?(schema: String, schemas: [String], tab: NotebookViewModel) {
    guard let context = StructureEditorContext(tab: tab) else { return nil }
    self.init(schema: schema, schemas: schemas, context: context)
  }

  var databaseType: DatabaseType { context.databaseType }

  /// Under Protected mode the new table waits in the pending transaction until Commit
  var runsInPendingTransaction: Bool { context.policy.protectedMode }

  var supportsComment: Bool {
    switch context.databaseType {
    case .postgresql, .mysql: true
    case .sqlite, .duckdb, .mongodb: false
    }
  }

  /// Reads the connection state (on the connection's actor) and why nothing can be created
  func load() async {
    isLoading = true
    let state = await context.database.structureEditorState()
    connection = state
    disabledReason = StructureEditorModel.disabledReason(
      databaseType: context.databaseType, policy: context.policy, state: state)
    isLoading = false
  }

  // MARK: - Draft

  func addColumn() {
    columns.append(ColumnRow())
  }

  /// Removes the column and the constraints that name it
  func removeColumn(_ id: ColumnRow.ID) {
    guard let row = columns.first(where: { $0.id == id }) else { return }
    columns.removeAll { $0.id == id }
    let name = Self.trimmed(row.name)
    constraints.removeAll { $0.columns.contains(name) }
  }

  /// Column names a constraint may use, in order
  var columnNames: [String] {
    columns.map { Self.trimmed($0.name) }.filter { !$0.isEmpty }
  }

  /// What the fields say: names trimmed, a blank default or comment is none
  var draft: CreateTableDraft {
    CreateTableDraft(
      schema: schema, name: Self.trimmed(tableName),
      columns: columns.map { row in
        let defaultExpression = Self.trimmed(row.defaultExpression)
        return CreateTableDraft.Column(
          name: Self.trimmed(row.name), type: Self.trimmed(row.type), isNullable: row.isNullable,
          defaultExpression: defaultExpression.isEmpty ? nil : defaultExpression,
          isPrimaryKey: row.isPrimaryKey)
      },
      constraints: constraints, comment: comment)
  }

  /// Exactly the strings Create sends; empty while the draft cannot be built
  var previewStatements: [String] { preview.statements }

  /// Why the draft cannot be built (Create is disabled)
  var previewError: String? { preview.error }

  var canCreate: Bool {
    !isLoading && disabledReason == nil && !isCreating && !isFinished
      && !previewStatements.isEmpty
  }

  private var preview: (statements: [String], error: String?) {
    guard let engine else { return ([], nil) }
    do {
      return (try CreateTableDDLBuilder.build(draft, engine: engine), nil)
    } catch {
      return ([], error.localizedDescription)
    }
  }

  private var engine: StructureDDLBuilder.Engine? {
    switch context.databaseType {
    case .postgresql: .postgresql
    case .mysql: connection.mysqlServerInfo.map { .mysql($0) }
    case .sqlite: .sqlite(libraryVersion: SQLiteLibraryVersion.current)
    case .duckdb: .duckdb
    // No tables to create: no engine, so no preview and nothing to send
    case .mongodb: nil
    }
  }

  // MARK: - Create

  /// Asks Safe Mode first when the connection's commit style confirms writes (the sheet then
  /// verifies the password / Touch ID and calls `confirmCreate`); otherwise sends the preview.
  func create() async {
    guard canCreate else { return }
    let statements = previewStatements
    if askSafeMode(statements) { return }
    await send(statements)
  }

  /// Sends the statements Safe Mode showed, unless the preview changed meanwhile
  func confirmCreate() async {
    let statements = confirmedStatements
    cancelConfirmation()
    guard let statements, statements == previewStatements, canCreate else { return }
    await send(statements)
  }

  func cancelConfirmation() {
    pendingConfirmation = nil
    confirmedStatements = nil
    confirmationRequiresPassword = false
  }

  // MARK: - Private

  /// Arms the Safe Mode step for `statements` when the connection's commit style confirms
  /// writes. True when it asks (nothing is sent until `confirmCreate`).
  private func askSafeMode(_ statements: [String]) -> Bool {
    let dialect = context.databaseType.dialect
    let commitStyle = context.commitStyle()
    let classified = statements.flatMap { SQLStatementClassifier.classify($0, dialect: dialect) }
    guard
      let listed = NotebookViewModel.statementsNeedingConfirmation(
        classified, commitStyle: commitStyle, dialect: dialect)
    else { return false }
    confirmedStatements = statements
    confirmationRequiresPassword = commitStyle.requiresPassword
    pendingConfirmation = listed
    return true
  }

  private func send(_ statements: [String]) async {
    isCreating = true
    applyError = nil
    let sql = statements.joined(separator: ";\n")
    let started = Date()
    do {
      let result = try await context.database.executeGatedSchemaChange(
        statements, policy: context.policy, connectionEpoch: connection.connectionEpoch,
        caller: context.caller)
      await context.recordHistory([
        QueryHistoryOutcome(
          sql: sql, duration: result.duration, rowCount: nil, status: .success, errorMessage: nil)
      ])
      isCreating = false
      isFinished = true
      let message: String
      if result.pending {
        message = StructureEditorModel.pendingMessage
      } else if result.insideUserTransaction {
        message = StructureEditorModel.insideTransactionMessage
      } else {
        message = "Table created"
      }
      resultMessage = message
      toastPresenter(
        message, result.pending || result.insideUserTransaction ? .warning : .success)
      await onApplied?(result.pending)
    } catch {
      let message = error.localizedDescription
      await context.recordHistory([
        QueryHistoryOutcome(
          sql: sql, duration: Date().timeIntervalSince(started), rowCount: nil, status: .error,
          errorMessage: message)
      ])
      isCreating = false
      applyError = message
    }
  }

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
