//
//  WorkspaceManager+AIProposal.swift
//  Dblore
//
//  Runs an AI proposal (propose_sql) the user approved with Run on its proposal card. It goes
//  through the active tab's user-SQL path, as typed SQL does; nothing runs it by itself.
//

import Foundation

/// What a proposal does, read locally from its text with the app's classifiers (never from the
/// model's words): the card's kind badge and the object name typed before a destructive one
/// runs. Saved chats are plain JSON, so the text is checked again every time.
nonisolated struct AIProposalCheck: Equatable {
  enum Kind: Int, Comparable {
    case read, write, schema, destructive

    var label: String {
      switch self {
      case .read: "Read"
      case .write: "Write"
      case .schema: "Schema"
      case .destructive: "Destructive"
      }
    }

    static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  /// The strongest kind of its statements
  let kind: Kind
  /// An UPDATE or DELETE without WHERE (MongoDB `updateMany` with an empty filter); Safe Mode
  /// warns about it too
  let affectsAllRows: Bool
  /// The object name typed before a destructive proposal runs; nil when not destructive or when
  /// no single name can be read
  let confirmName: String?
  /// Why Run is off for this text; nil when it may run
  let runRefusal: String?

  static let tooLongRefusal =
    "This proposal is longer than \(AITools.maxSQLCharacters.formatted()) characters and cannot run. Insert or copy it instead."
  static let emptyRefusal = "This proposal has nothing to run."
  static let noNameRefusal =
    "Run needs one object name to confirm and none could be read from this statement. Insert it into a tab to run it there."
  /// The no-name refusal of an UPDATE or DELETE without WHERE whose table cannot be read
  static let allRowsNoNameRefusal = "Name the table in a single-table statement, or add a WHERE."
  static let destructiveWithOthersRefusal =
    "A destructive statement runs only on its own. Ask for one statement at a time, or insert it into a tab to run it there."
  static let hiddenCharactersRefusal =
    "This proposal holds invisible or text-direction characters, so it may not run what it shows. Insert or copy it and check it first."

  /// SQL classified with `SQLStatementClassifier` for `dialect` (MongoDB with
  /// `MongoCommandClassifier`). Destructive: what `DestructiveStatementRule` marks `.confirm`
  /// (with that name) or `.unnamed` (no name; an UPDATE or DELETE without WHERE gets
  /// `allRowsNoNameRefusal`, any other `noNameRefusal`). `database` is the connection's, the
  /// target of `db.dropDatabase()` (on MongoDB the session's default name when the connection's
  /// is blank, `WorkspaceManager.mongoDatabaseName(of:)`). A destructive proposal needs
  /// exactly one statement, destructive with a readable name, else Run is off. Run is off too
  /// when the text holds characters that render other than they run
  /// (`HiddenCharacterRule.hasHiddenCharacters`, the rule MCP writes use).
  static func make(sql: String, dialect: SQLDialect, database: String?) -> AIProposalCheck {
    guard sql.count <= AITools.maxSQLCharacters else {
      return AIProposalCheck(
        kind: .write, affectsAllRows: false, confirmName: nil, runRefusal: tooLongRefusal)
    }
    let statements = SQLStatementClassifier.classify(sql, dialect: dialect)
    guard !statements.isEmpty else {
      return AIProposalCheck(
        kind: .write, affectsAllRows: false, confirmName: nil, runRefusal: emptyRefusal)
    }
    var kind = Kind.read
    var names: [String?] = []
    var allRowsUnnamed = false
    for statement in statements {
      switch DestructiveStatementRule.evaluate(statement, dialect: dialect, database: database) {
      case .none:
        kind = max(kind, plainKind(statement))
      case .confirm(let name):
        names.append(name)
        kind = .destructive
      case .unnamed:
        names.append(nil)
        kind = .destructive
        allRowsUnnamed = statement.kind == .dml && statement.affectsAllRows
      }
    }
    let name = names.count == 1 ? names[0] : nil
    let refusal: String?
    if HiddenCharacterRule.hasHiddenCharacters(sql, dialect: dialect) {
      refusal = hiddenCharactersRefusal
    } else if kind == .destructive, statements.count > 1 {
      refusal = destructiveWithOthersRefusal
    } else {
      refusal =
        kind == .destructive && name == nil
        ? (allRowsUnnamed ? allRowsNoNameRefusal : noNameRefusal) : nil
    }
    return AIProposalCheck(
      kind: kind, affectsAllRows: statements.contains(where: \.affectsAllRows),
      confirmName: name, runRefusal: refusal)
  }

  private static func plainKind(_ statement: ClassifiedStatement) -> Kind {
    if statement.isReadOnlySafe { return .read }
    return SQLStatementClassifier.effectiveKind(statement.kind) == .ddl ? .schema : .write
  }
}

extension WorkspaceManager {
  /// What Run did with a proposal
  enum AIProposalRunOutcome: Equatable {
    /// Handed to the active tab's user-SQL path, which may still ask for Safe Mode confirmation
    case ran(tabID: UUID)
    /// No query tab was open: a new query tab holds the proposal and runs it the same way
    case openedTab(UUID)
    /// Nothing was sent
    case refused(String)
  }

  static let proposalOtherConnectionRefusal =
    "This proposal was made for another connection. Insert or copy it instead."
  static let proposalOtherDatabaseRefusal =
    "This proposal was made for another database. Switch back to it, or insert or copy it instead."

  /// The MongoDB database a proposal's `database` names: blank reads the session's default, as
  /// `mongoDatabaseName(of:)` does
  static func aiProposalMongoDatabase(_ database: String) -> String {
    database.isEmpty ? MongoSession.defaultDatabase : database
  }

  /// Runs `proposal` because the user pressed Run on its card; rendering or receiving a
  /// proposal never calls this. It runs only on the connection it was proposed for, after the
  /// app's own check of the text (`AIProposalCheck`), and a destructive one only once
  /// `confirmedName` matches the object name; on MongoDB only on the database it was proposed
  /// for, and in a tab only when the tab is on that connection too. Then it goes through the
  /// user-SQL path of the active query tab, as typed SQL does: Protected mode and the
  /// protection level (refused here first), missing parameters, the Safe Mode confirmation and
  /// the execution gate. With no query tab active (none, a data viewer, a Markdown note, a
  /// read-only source), a new query tab holds the proposal and runs it, as the table import
  /// opens a tab. The AI access gate is not asked: the user runs this SQL and nothing is sent
  /// to the model.
  func runAIProposal(_ proposal: AIProposal, confirmedName: String?) -> AIProposalRunOutcome {
    guard connectionState.isConnected, let config = workspace.connectionConfig else {
      return .refused("Not connected to a database.")
    }
    guard let key = proposal.sessionKey, key == AIAccessGate.sessionKey(for: config) else {
      return .refused(Self.proposalOtherConnectionRefusal)
    }
    let dialect = config.databaseType.dialect
    // A database switch keeps the session key
    if dialect == .mongodb {
      guard let database = proposal.database,
        Self.aiProposalMongoDatabase(database) == Self.mongoDatabaseName(of: config)
      else { return .refused(Self.proposalOtherDatabaseRefusal) }
    }
    // Blank names the session's default database: `db.dropDatabase()` confirms that name
    let check = AIProposalCheck.make(
      sql: proposal.sql, dialect: dialect,
      database: dialect == .mongodb ? Self.mongoDatabaseName(of: config) : config.database)
    if let refusal = check.runRefusal { return .refused(refusal) }
    if check.kind == .destructive, let name = check.confirmName,
      !TypedNameConfirmation.matches(confirmedName ?? "", name: name)
    {
      return .refused("Type \(name) to run this statement.")
    }
    if let tabID = activeTabId, let tab = viewModel(for: tabID), Self.runsUserSQL(tab) {
      // The tab can lag behind a switch
      guard tab.aiSessionKey == key else { return .refused(Self.proposalOtherConnectionRefusal) }
      if let message = tab.protectionBlockMessage(for: proposal.sql) { return .refused(message) }
      if tab.viewMode == .editor, tab.isEditorQueryRunning {
        return .refused("A query is already running in this tab.")
      }
      Self.run(proposal.sql, in: tab)
      return .ran(tabID: tabID)
    }
    let decision = DatabaseConnectionManager.evaluate(
      SQLStatementClassifier.classify(proposal.sql, dialect: dialect),
      policy: ProtectionPolicy(config: config), dialect: dialect)
    if case .blocked(let index, let kind, let reason) = decision {
      return .refused(
        DatabaseError.blockedByProtection(statementIndex: index, kind: kind, reason: reason)
          .localizedDescription)
    }
    let tabID = newSQLFile(content: proposal.sql)
    guard let tab = viewModel(for: tabID) else { return .refused("The query tab did not open.") }
    Self.run(proposal.sql, in: tab)
    return .openedTab(tabID)
  }

  /// A tab where typed SQL runs: a notebook or a script editor, not a data viewer, a Markdown
  /// note or a read-only source
  private static func runsUserSQL(_ tab: NotebookViewModel) -> Bool {
    tab.dataViewer == nil && !tab.isReadOnlySource && tab.viewMode != .markdown
  }

  /// A notebook gets the proposal as a new cell and runs that cell; a script editor runs it as
  /// typed editor SQL, leaving the editor text as it is
  private static func run(_ sql: String, in tab: NotebookViewModel) {
    if tab.viewMode == .notebook {
      tab.insertAISQL(sql)
      guard let id = tab.selectedCellId else { return }
      tab.confirmAndRunCell(id: id)
    } else {
      Task { await tab.runUserEditorQuery(sql) }
    }
  }
}
