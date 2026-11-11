// SQLServerDialectTests.swift
// SQL Server (T-SQL) quoting, literals, placeholders and paging, read back scalar by scalar as
// the server lexes them (T-SQL docs: delimited identifiers, constants, ORDER BY OFFSET-FETCH)

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("SQL Server dialect")
struct SQLServerDialectTests {

  private static let dialect = SQLDialect.sqlserver

  // MARK: - Scalar readers (the server's view of the text)

  /// The name a `[…]` identifier holds (`]]` is one `]`), nil unless `text` is exactly one
  /// bracket identifier with nothing after it
  private static func readBracketIdentifier(_ text: String) -> String? {
    let scalars = Array(text.unicodeScalars)
    guard scalars.first == "[" else { return nil }
    var name = String.UnicodeScalarView()
    var index = 1
    while index < scalars.count {
      if scalars[index] == "]" {
        if index + 1 < scalars.count, scalars[index + 1] == "]" {
          name.append("]")
          index += 2
          continue
        }
        return index == scalars.count - 1 ? String(name) : nil
      }
      name.append(scalars[index])
      index += 1
    }
    return nil
  }

  /// One `N'…'` literal starting at `index`, as the server reads it: `''` is one `'`, and a `\`
  /// right before CR, LF or CRLF is dropped with the break. Returns the value and the offset
  /// after the closing quote.
  private static func readLiteral(
    _ scalars: [Unicode.Scalar], at index: Int
  ) -> (value: String, end: Int)? {
    guard index + 1 < scalars.count, scalars[index] == "N", scalars[index + 1] == "'" else {
      return nil
    }
    var value = String.UnicodeScalarView()
    var cursor = index + 2
    while cursor < scalars.count {
      let scalar = scalars[cursor]
      if scalar == "'" {
        if cursor + 1 < scalars.count, scalars[cursor + 1] == "'" {
          value.append("'")
          cursor += 2
          continue
        }
        return (String(value), cursor + 1)
      }
      if scalar == "\\", cursor + 1 < scalars.count,
        scalars[cursor + 1] == "\n" || scalars[cursor + 1] == "\r"
      {
        let crlf =
          scalars[cursor + 1] == "\r" && cursor + 2 < scalars.count && scalars[cursor + 2] == "\n"
        cursor += crlf ? 3 : 2
        continue
      }
      value.append(scalar)
      cursor += 1
    }
    return nil
  }

  /// The value of `N'…'` or `CAST(N'…' AS nvarchar(max)) + N'…' + …`, nil unless `text` is
  /// exactly that expression (a quote that escaped the literal leaves text over)
  private static func readStringExpression(_ text: String) -> String? {
    let scalars = Array(text.unicodeScalars)
    let castOpen = Array("CAST(".unicodeScalars)
    let castClose = Array(" AS nvarchar(max))".unicodeScalars)
    let plus = Array(" + ".unicodeScalars)
    func matches(_ word: [Unicode.Scalar], at index: Int) -> Bool {
      index + word.count <= scalars.count && Array(scalars[index..<index + word.count]) == word
    }
    guard matches(castOpen, at: 0) else {
      guard let only = readLiteral(scalars, at: 0), only.end == scalars.count else { return nil }
      return only.value
    }
    guard let first = readLiteral(scalars, at: castOpen.count),
      matches(castClose, at: first.end)
    else { return nil }
    var value = first.value
    var cursor = first.end + castClose.count
    guard cursor < scalars.count else { return nil }
    while cursor < scalars.count {
      guard matches(plus, at: cursor), let next = readLiteral(scalars, at: cursor + plus.count)
      else { return nil }
      value += next.value
      cursor = next.end
    }
    return value
  }

  // MARK: - Quoting cannot escape

  /// Names holding `]` (alone, doubled, before a combining mark, before a statement) and other
  /// quote characters
  nonisolated static let hostileNames = [
    "a]b", "]", "]]", "a]\u{301}b", "]\u{301}; DROP TABLE t; --", "a]; DROP TABLE t; --",
    "[a", "a'b", "a\"b", #"a\b"#, "a\nb",
  ]

  @Test("A bracket identifier reads back as the same name", arguments: hostileNames)
  func identifierReadsBack(_ name: String) throws {
    let quoted = try Self.dialect.quoteIdentifier(name)
    #expect(Self.readBracketIdentifier(quoted) == name)
    let statements = SQLStatementClassifier.classify(
      "SELECT * FROM \(quoted)", dialect: Self.dialect)
    #expect(statements.count == 1)
    #expect(statements.first?.kind == .read)
  }

  @Test("] is doubled per scalar, also before a combining mark; NUL is refused")
  func identifierEscapes() throws {
    #expect(try Self.dialect.quoteIdentifier("a]b") == "[a]]b]")
    #expect(try Self.dialect.quoteIdentifier("a]\u{301}") == "[a]]\u{301}]")
    #expect(throws: SQLDialectError.nulInIdentifier) { try Self.dialect.quoteIdentifier("a\0b") }
    #expect(try Self.dialect.quoteIdentifierIfNeeded("id") == "[id]")
  }

  @Test("qualified keeps every schema, dbo too")
  func qualifiedKeepsSchema() throws {
    #expect(try Self.dialect.qualified(schema: "dbo", name: "t") == "[dbo].[t]")
    #expect(try Self.dialect.qualified(schema: nil, name: "t") == "[t]")
  }

  /// Values holding `'` (alone, before a combining mark, before a statement) and backslashes
  nonisolated static let hostileValues = [
    "it's", "'", "''", "a'\u{301}b", "'\u{301}; DROP TABLE t; --", "a'; DROP TABLE t; --",
    #"a\'; DROP TABLE t; --"#, #"tail\"#, "a\\\nb", "a\\\rb", "a\\\r\nb", "\\\n'; DROP TABLE t; --",
  ]

  @Test("A string literal reads back as the same value", arguments: hostileValues)
  func literalReadsBack(_ value: String) {
    let literal = Self.dialect.literal(.string(value))
    #expect(Self.readStringExpression(literal) == value)
    let statements = SQLStatementClassifier.classify("SELECT \(literal)", dialect: Self.dialect)
    #expect(statements.count == 1)
    #expect(statements.first?.kind == .read)
  }

  @Test("Literals are N'…' with ' doubled per scalar and a backslash kept single")
  func literalEscapes() {
    #expect(Self.dialect.literal(.string("it's")) == "N'it''s'")
    #expect(Self.dialect.literal(.string("a'\u{301}")) == "N'a''\u{301}'")
    #expect(Self.dialect.literal(.string(#"a\b"#)) == #"N'a\b'"#)
    #expect(Self.dialect.literal(.string(#"tail\"#)) == #"N'tail\'"#)
    #expect(Self.dialect.literal(.json("{}")) == "N'{}'")
  }

  /// Input and the exact literal: a piece ends after each `\` directly before CR or LF
  nonisolated static let splitCases: [(String, String)] = [
    ("a\\\nb", "CAST(N'a\\' AS nvarchar(max)) + N'\nb'"),
    ("a\\\rb", "CAST(N'a\\' AS nvarchar(max)) + N'\rb'"),
    ("a\\\r\nb", "CAST(N'a\\' AS nvarchar(max)) + N'\r\nb'"),
    ("\\\n\\\n", "CAST(N'\\' AS nvarchar(max)) + N'\n\\' + N'\n'"),
    // A combining mark between them: the backslash is not directly before the break
    ("a\\\u{301}\nb", "N'a\\\u{301}\nb'"),
  ]

  @Test("A backslash right before CR, LF or CRLF ends a piece, so the server keeps both")
  func backslashBeforeLineBreakIsSplit() {
    for (value, expected) in Self.splitCases {
      let literal = Self.dialect.literal(.string(value))
      #expect(literal == expected)
    }
  }

  // MARK: - Other literals

  @Test("A bool literal is 1 or 0, bytes a 0x binary constant")
  func boolAndBytesLiterals() {
    #expect(Self.dialect.literal(.bool(true)) == "1")
    #expect(Self.dialect.literal(.bool(false)) == "0")
    #expect(Self.dialect.literal(.data(Data([0x01, 0xAB]))) == "0x01AB")
  }

  // MARK: - Placeholders

  @Test("Placeholders are @p1…@pN in bind order")
  func placeholders() {
    #expect(Self.dialect.placeholder(1) == "@p1")
    #expect(Self.dialect.placeholder(12) == "@p12")
    #expect(Self.dialect.placeholder(3, type: "int") == "@p3")
    let rewritten = SQLParameterRewriter.rewrite(
      statement: "SELECT * FROM t WHERE a = :a AND b = :b OR a = :a", dialect: Self.dialect)
    #expect(rewritten.text == "SELECT * FROM t WHERE a = @p1 AND b = @p2 OR a = @p1")
    #expect(rewritten.names == ["a", "b"])
  }

  // MARK: - Paging

  @Test("OFFSET / FETCH, with ORDER BY (SELECT NULL) only when unordered")
  func limitOffset() {
    #expect(
      Self.dialect.limitOffset(limit: 50, offset: 100, ordered: false)
        == "ORDER BY (SELECT NULL) OFFSET 100 ROWS FETCH NEXT 50 ROWS ONLY")
    #expect(
      Self.dialect.limitOffset(limit: 50, offset: 100)
        == "OFFSET 100 ROWS FETCH NEXT 50 ROWS ONLY")
    #expect(
      Self.dialect.limit(2, ordered: false)
        == "ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 2 ROWS ONLY")
    #expect(Self.dialect.limit(2, ordered: true) == "OFFSET 0 ROWS FETCH NEXT 2 ROWS ONLY")
  }

  @Test("limit(_:ordered:) is exactly LIMIT n on every other engine")
  func limitOnOtherEngines() {
    for dialect in [SQLDialect.postgresql, .mysql, .sqlite, .duckdb, .clickhouse] {
      for ordered in [false, true] {
        #expect(dialect.limit(7, ordered: ordered) == "LIMIT 7", "\(dialect.promptName)")
      }
      #expect(dialect.limitOffset(limit: 7, offset: 3, ordered: false) == "LIMIT 7 OFFSET 3")
    }
  }

  private func viewer(orderColumns: [String] = [], page: Int = 1) -> DataViewerState {
    var state = DataViewerState(schema: "dbo", name: "t", orderColumns: orderColumns)
    state.databaseType = .sqlserver
    state.page = page
    state.pageSize = 50
    return state
  }

  @Test("Data viewer pages, page 1 included, never write LIMIT")
  func dataViewerPages() {
    #expect(
      viewer().pageSQL
        == "SELECT * FROM [dbo].[t] ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 50 ROWS ONLY")
    #expect(
      viewer(page: 3).pageSQL
        == "SELECT * FROM [dbo].[t] ORDER BY (SELECT NULL) OFFSET 100 ROWS FETCH NEXT 50 ROWS ONLY"
    )
    #expect(
      viewer(orderColumns: ["id"]).pageSQL
        == "SELECT * FROM [dbo].[t] ORDER BY [id] OFFSET 0 ROWS FETCH NEXT 50 ROWS ONLY")
    #expect(
      viewer(orderColumns: ["id"], page: 2).pageSQL
        == "SELECT * FROM [dbo].[t] ORDER BY [id] OFFSET 50 ROWS FETCH NEXT 50 ROWS ONLY")
    for state in [viewer(), viewer(page: 2), viewer(orderColumns: ["id"])] {
      #expect(!state.pageSQL.contains("LIMIT"))
    }
  }

  @Test("The foreign-key lookup reads at most two rows without LIMIT")
  func foreignKeyLookup() {
    let key = ForeignKey(
      constraintName: "fk", sourceSchema: "dbo", sourceTable: "orders", sourceColumns: ["user_id"],
      targetSchema: "dbo", targetTable: "users", targetColumns: ["id"])
    let query = ForeignKeyLookup.lookupSQL(
      for: key, values: ["user_id": .int(1)], dialect: Self.dialect)
    #expect(
      query?.sql
        == "SELECT * FROM [dbo].[users] WHERE [id] = :fk1"
        + " ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 2 ROWS ONLY")
  }

  // MARK: - LIKE

  private func filterSQL(_ op: FilterOperator, escape: String? = nil) -> String? {
    TableFilter(conditions: [
      FilterCondition(column: "c", op: op, value: "%A%", likeEscape: escape)
    ]).whereClause(dialect: Self.dialect)
  }

  @Test("LIKE filters cast to NVARCHAR(MAX); case-insensitive ones lower both sides, never ILIKE")
  func likeFilters() {
    #expect(filterSQL(.like) == "CAST([c] AS NVARCHAR(MAX)) LIKE N'%A%'")
    #expect(filterSQL(.notLike) == "CAST([c] AS NVARCHAR(MAX)) NOT LIKE N'%A%'")
    #expect(filterSQL(.ilike) == "LOWER(CAST([c] AS NVARCHAR(MAX))) LIKE LOWER(N'%A%')")
    #expect(filterSQL(.notIlike) == "LOWER(CAST([c] AS NVARCHAR(MAX))) NOT LIKE LOWER(N'%A%')")
    #expect(
      filterSQL(.notIlike, escape: "!")
        == "LOWER(CAST([c] AS NVARCHAR(MAX))) NOT LIKE LOWER(N'%A%') ESCAPE N'!'")
    for op in [FilterOperator.like, .notLike, .ilike, .notIlike] {
      #expect(filterSQL(op)?.contains("ILIKE") == false)
    }
  }

  // MARK: - Transactions and savepoints (fake session)

  private let open = ProtectionPolicy(protectionLevel: .none)

  /// A SQL Server connection on a fake session, Protected mode off
  private func connect() async throws -> (DatabaseConnectionManager, FakeDatabaseSession) {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .sqlserver, host: "fake", port: 1433, database: "db", username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false))
    return (manager, try #require(factory.sessions.first))
  }

  private func edit() throws -> CellUpdateStatement {
    try CellUpdateStatement.make(
      qualifiedName: "[dbo].[t]", columnName: "v", newValue: "2", primaryKeyColumns: ["id"],
      rowData: ["id": .int(1), "v": .int(1)], dialect: .sqlserver)
  }

  /// The statements sent since `count`
  private func sent(_ session: FakeDatabaseSession, since count: Int) -> [String] {
    Array(session.statements.dropFirst(count))
  }

  @Test("An inline edit in a transaction uses SAVE / ROLLBACK TRANSACTION, never RELEASE")
  func inlineEditSavepoints() async throws {
    let (manager, session) = try await connect()
    _ = try await manager.execute(userSQL: "BEGIN TRANSACTION", policy: open)
    var before = session.statements.count
    // The Protected-mode edit adopts the open transaction (the gate keeps SQL Server
    // unprotected until row edits are on, so the edit path is called directly)
    _ = try await manager.runProtectedEdit(try edit(), classified: nil, caller: nil)
    let saved = sent(session, since: before)
    #expect(saved.first == "SAVE TRANSACTION dblore_edit")
    #expect(saved.count == 2)

    before = session.statements.count
    session.failNextCommand(containing: "UPDATE")
    await #expect(throws: (any Error).self) {
      try await manager.runProtectedEdit(try edit(), classified: nil, caller: nil)
    }
    let undone = sent(session, since: before)
    #expect(undone.first == "SAVE TRANSACTION dblore_edit")
    #expect(undone.last == "ROLLBACK TRANSACTION dblore_edit")
    #expect(!session.statements.contains { $0.contains("RELEASE") || $0.contains("SAVEPOINT") })
  }

  @Test("A staged batch in the user's transaction uses SAVE / ROLLBACK TRANSACTION")
  func stagedBatchSavepoints() async throws {
    let (manager, session) = try await connect()
    _ = try await manager.execute(userSQL: "BEGIN TRANSACTION", policy: open)
    let batch = [BoundStatement(sql: "UPDATE t SET a = 1", values: [])]
    var before = session.statements.count
    _ = try await manager.runStagedBatch(
      batch, caller: nil, protectedMode: false,
      cancellationGeneration: await manager.batchCancellationGeneration)
    #expect(
      sent(session, since: before) == ["SAVE TRANSACTION dblore_batch", "UPDATE t SET a = 1"])

    before = session.statements.count
    session.failNextCommand(containing: "UPDATE")
    await #expect(throws: (any Error).self) {
      try await manager.runStagedBatch(
        batch, caller: nil, protectedMode: false,
        cancellationGeneration: await manager.batchCancellationGeneration)
    }
    #expect(
      sent(session, since: before) == [
        "SAVE TRANSACTION dblore_batch", "UPDATE t SET a = 1",
        "ROLLBACK TRANSACTION dblore_batch",
      ])
    #expect(!session.statements.contains { $0.contains("RELEASE") || $0.contains("SAVEPOINT") })
  }

  @Test("Without a server answer a COMMIT never closes the tracked transaction")
  func unansweredCommitKeepsTransaction() async throws {
    let (manager, session) = try await connect()
    session.reportAfterInterrupt { nil }
    _ = try await manager.execute(userSQL: "BEGIN TRAN", policy: open)
    #expect(await manager.userTxOpen)
    // A nested COMMIT may only lower @@TRANCOUNT
    _ = try await manager.execute(userSQL: "BEGIN TRAN; COMMIT", policy: open)
    #expect(await manager.userTxOpen)
    session.failNextCommand(containing: "COMMIT")
    await #expect(throws: (any Error).self) {
      try await manager.execute(userSQL: "COMMIT", policy: open)
    }
    #expect(await manager.userTxOpen)
    // An unnamed ROLLBACK ends every nesting level
    _ = try await manager.execute(userSQL: "ROLLBACK", policy: open)
    #expect(await !manager.userTxOpen)
  }

  /// Scripted `transactionState` answers, one per ask; nil once they run out
  private actor ServerAnswers {
    private var answers: [Bool?]
    init(_ answers: [Bool?]) { self.answers = answers }
    func next() -> Bool? { answers.isEmpty ? nil : answers.removeFirst() }
  }

  @Test("The app's COMMIT is not reported done while the server keeps a transaction open")
  func appCommitChecksServer() async throws {
    let (manager, session) = try await connect()
    session.reportAfterInterrupt { true }
    _ = try await manager.execute(userSQL: "BEGIN TRANSACTION", policy: open)
    // The edit adopts the user's transaction: the app's transaction is pending
    _ = try await manager.runProtectedEdit(try edit(), classified: nil, caller: nil)
    let generation = await manager.transactionStatus().generation
    await #expect(throws: DatabaseError.self) {
      try await manager.commitAppTransaction(expectedGeneration: generation)
    }
    #expect(await !manager.transactionSnapshot().isIdle)
    // The server cannot tell: the commit is not verified, the changes stay pending
    session.reportAfterInterrupt { nil }
    await #expect(throws: DatabaseError.self) {
      try await manager.commitAppTransaction(
        expectedGeneration: await manager.transactionStatus().generation)
    }
    #expect(await !manager.transactionSnapshot().isIdle)
    session.reportAfterInterrupt { false }
    try await manager.commitAppTransaction(
      expectedGeneration: await manager.transactionStatus().generation)
    #expect(await manager.transactionSnapshot().isIdle)
  }

  /// The message of a `DatabaseError.transactionAborted` thrown by `body`, nil for any other
  private func abortMessage(_ body: () async throws -> Void) async -> String? {
    do {
      try await body()
    } catch DatabaseError.transactionAborted(let message) {
      return message
    } catch {}
    return nil
  }

  /// Holds a `transactionState` answer until released
  private actor ProbeGate {
    private(set) var arrived = false
    private var waiting: CheckedContinuation<Void, Never>?
    func hold() async {
      arrived = true
      await withCheckedContinuation { waiting = $0 }
    }
    func release() { waiting?.resume() }
  }

  /// A pending app transaction (a user transaction an edit adopted) on a fresh connection
  private func pendingAppTransaction() async throws -> (
    DatabaseConnectionManager, FakeDatabaseSession
  ) {
    let (manager, session) = try await connect()
    session.reportAfterInterrupt { true }
    _ = try await manager.execute(userSQL: "BEGIN TRANSACTION", policy: open)
    _ = try await manager.runProtectedEdit(try edit(), classified: nil, caller: nil)
    return (manager, session)
  }

  private func commit(_ manager: DatabaseConnectionManager) async throws {
    try await manager.commitAppTransaction(
      expectedGeneration: await manager.transactionStatus().generation)
  }

  @Test("A disconnect while the server is asked about the commit leaves no transaction behind")
  func disconnectDuringCommitCheck() async throws {
    for unverifiedFirst in [false, true] {
      let (manager, session) = try await pendingAppTransaction()
      if unverifiedFirst {
        session.reportAfterInterrupt { nil }
        await #expect(throws: DatabaseError.self) { try await commit(manager) }
      }
      let gate = ProbeGate()
      session.reportAfterInterrupt {
        await gate.hold()
        return true
      }
      let committing = Task { try await commit(manager) }
      for _ in 0..<1_000 where !(await gate.arrived) { try await Task.sleep(for: .milliseconds(5)) }
      await manager.disconnect()
      await gate.release()
      await #expect(throws: DatabaseError.self) { try await committing.value }
      #expect(await manager.transactionSnapshot().isIdle, "unverified first: \(unverifiedFirst)")
    }
  }

  private func isAborted(_ manager: DatabaseConnectionManager) async -> Bool {
    if case .aborted = await manager.transactionSnapshot() { return true }
    return false
  }

  @Test("A transaction the server already ended does not stay aborted")
  func serverEndedTransaction() async throws {
    // The edit fails and its savepoint undo fails too (Msg 3903): the server ended it
    let (ended, endedSession) = try await pendingAppTransaction()
    endedSession.failCommands(containing: ["UPDATE", "ROLLBACK TRANSACTION"])
    endedSession.reportAfterInterrupt { false }
    await #expect(throws: (any Error).self) {
      try await ended.runProtectedEdit(try edit(), classified: nil, caller: nil)
    }
    #expect(await ended.transactionSnapshot().isIdle)

    for answer in [false, nil] as [Bool?] {
      let (manager, session) = try await pendingAppTransaction()
      session.failCommands(containing: ["UPDATE", "ROLLBACK TRANSACTION"])
      session.reportAfterInterrupt { true }
      await #expect(throws: (any Error).self) {
        try await manager.runProtectedEdit(try edit(), classified: nil, caller: nil)
      }
      #expect(await isAborted(manager))
      session.failNextCommand(containing: "ROLLBACK")
      session.reportAfterInterrupt { answer }
      if answer == false {
        try await manager.rollbackAppTransaction()
        #expect(await manager.transactionSnapshot().isIdle)
      } else {
        await #expect(throws: DatabaseError.self) { try await manager.rollbackAppTransaction() }
        #expect(await isAborted(manager))
      }
    }
  }

  @Test("While a commit is unverified, statements are refused until it is settled")
  func unverifiedCommitRefusesStatements() async throws {
    let (manager, session) = try await pendingAppTransaction()
    session.reportAfterInterrupt { nil }
    await #expect(throws: DatabaseError.self) { try await commit(manager) }
    let before = session.statements.count
    let refused = await abortMessage {
      _ = try await manager.execute(userSQL: "UPDATE t SET a = 1 WHERE id = 1", policy: open)
    }
    #expect(refused?.contains("Settle the earlier commit first") == true)
    #expect(session.statements.count == before)
    session.reportAfterInterrupt { false }
    try await commit(manager)
    #expect(await manager.transactionSnapshot().isIdle)
    #expect(session.statements.count == before)
  }

  @Test("After an unverified commit, Commit and Rollback ask the server before sending anything")
  func unverifiedCommitIsSettledFirst() async throws {
    let (manager, session) = try await connect()
    func pendingEdit() async throws {
      session.reportAfterInterrupt { true }
      _ = try await manager.execute(userSQL: "BEGIN TRANSACTION", policy: open)
      _ = try await manager.runProtectedEdit(try edit(), classified: nil, caller: nil)
      session.reportAfterInterrupt { nil }
      let first = await abortMessage {
        try await manager.commitAppTransaction(
          expectedGeneration: await manager.transactionStatus().generation)
      }
      #expect(first?.contains("may already be done") == true)
    }
    func commits() -> Int { session.statements.filter { $0 == "COMMIT" }.count }

    try await pendingEdit()
    // Still unknown: nothing is sent, and nothing claims a rollback
    session.failNextCommand(containing: "COMMIT")
    var before = commits()
    let unknown = await abortMessage {
      try await manager.commitAppTransaction(
        expectedGeneration: await manager.transactionStatus().generation)
    }
    #expect(unknown?.contains("unknown") == true)
    #expect(unknown?.contains("rolled back") == false)
    #expect(commits() == before)
    // Disarm the failure: no COMMIT reached the session
    session.failNextCommand(containing: "never sent")
    // The server says closed: the earlier commit completed
    session.reportAfterInterrupt { false }
    before = commits()
    try await manager.commitAppTransaction(
      expectedGeneration: await manager.transactionStatus().generation)
    #expect(await manager.transactionSnapshot().isIdle)
    #expect(commits() == before)

    // Rollback after an unverified commit that had completed: nothing to roll back
    try await pendingEdit()
    session.reportAfterInterrupt { false }
    let rollback = await abortMessage { try await manager.rollbackAppTransaction() }
    #expect(rollback?.contains("committed") == true)
    #expect(await manager.transactionSnapshot().isIdle)
    #expect(!session.statements.contains("ROLLBACK"))
  }

  @Test(
    "The app's own BEGIN refuses an untracked server transaction; an unfinished COMMIT rolls back")
  func ownTransactionChecksServer() async throws {
    let (manager, session) = try await connect()
    // An untracked transaction, or no answer: the app does not BEGIN
    var before = session.statements.count
    for answer in [true, nil] as [Bool?] {
      session.reportAfterInterrupt { answer }
      await #expect(throws: DatabaseError.self) {
        try await manager.runUnprotectedEdit(try edit())
      }
    }
    #expect(sent(session, since: before).isEmpty)

    // Implicit transactions on an idle session: COMMIT leaves @@TRANCOUNT at 1
    let implicit = ServerAnswers([false, true])
    session.reportAfterInterrupt { await implicit.next() }
    before = session.statements.count
    await #expect(throws: DatabaseError.self) { try await manager.runUnprotectedEdit(try edit()) }
    let undone = sent(session, since: before)
    #expect(undone.first == "BEGIN TRANSACTION")
    #expect(Array(undone.suffix(2)) == ["COMMIT", "ROLLBACK"])

    // No answer after COMMIT: not verified, rolled back
    let unverified = ServerAnswers([false, nil])
    session.reportAfterInterrupt { await unverified.next() }
    before = session.statements.count
    await #expect(throws: DatabaseError.self) { try await manager.runUnprotectedEdit(try edit()) }
    #expect(Array(sent(session, since: before).suffix(2)) == ["COMMIT", "ROLLBACK"])

    let committed = ServerAnswers([false, false])
    session.reportAfterInterrupt { await committed.next() }
    before = session.statements.count
    #expect(try await manager.runUnprotectedEdit(try edit()) == 1)
    #expect(sent(session, since: before).last == "COMMIT")
  }

  @Test("User transaction tracking follows the server's answer")
  func userTransactionAsksServer() async throws {
    // Implicit transactions: a plain INSERT opens one, which only the server knows
    let (implicit, implicitSession) = try await connect()
    implicitSession.reportAfterInterrupt { false }
    _ = try await implicit.execute(userSQL: "SET IMPLICIT_TRANSACTIONS ON", policy: open)
    #expect(await !implicit.userTxOpen)
    implicitSession.reportAfterInterrupt { true }
    _ = try await implicit.execute(userSQL: "INSERT INTO t VALUES (1)", policy: open)
    #expect(await implicit.userTxOpen)

    let (manager, session) = try await connect()
    session.reportAfterInterrupt { true }
    // A nested COMMIT only lowers @@TRANCOUNT: still open
    _ = try await manager.execute(
      userSQL: "BEGIN TRAN; BEGIN TRAN; COMMIT", policy: open)
    #expect(await manager.userTxOpen)

    session.reportAfterInterrupt { false }
    _ = try await manager.execute(userSQL: "COMMIT", policy: open)
    #expect(await !manager.userTxOpen)

    session.reportAfterInterrupt { true }
    _ = try await manager.execute(
      userSQL: "BEGIN TRAN; SAVE TRAN sp1; ROLLBACK TRAN sp1", policy: open)
    #expect(await manager.userTxOpen)

    // ROLLBACK TRAN <name> naming the outer transaction ends it: the text reads it as open
    session.reportAfterInterrupt { false }
    _ = try await manager.execute(userSQL: "ROLLBACK TRAN t1", policy: open)
    #expect(await !manager.userTxOpen)
  }

  // MARK: - Parameters and classifier

  private static func classify(_ sql: String) -> [ClassifiedStatement] {
    SQLStatementClassifier.classify(sql, dialect: dialect)
  }

  private static func refused(_ sql: String, on level: ConnectionProtectionLevel) -> Bool {
    DatabaseConnectionManager.evaluate(
      classify(sql), policy: ProtectionPolicy(protectionLevel: level), dialect: dialect)
      != .allowed
  }

  @Test("T-SQL variables and money are no placeholders; a written @pN takes a bind")
  func variablesAreNoParameters() {
    let sql = "SELECT @x, @@ROWCOUNT, @@p1, $1.00 FROM t WHERE a = :a AND b = @y"
    #expect(!SQLParameterRewriter.containsPositionalPlaceholder(in: sql, dialect: Self.dialect))
    #expect(
      SQLParameterRewriter.rewrite(statement: sql, dialect: Self.dialect).text
        == "SELECT @x, @@ROWCOUNT, @@p1, $1.00 FROM t WHERE a = @p1 AND b = @y")
    for collides in ["SELECT @p1 WHERE a = :a", "SELECT @P12 WHERE a = :a"] {
      #expect(
        SQLParameterRewriter.containsPositionalPlaceholder(in: collides, dialect: Self.dialect),
        "\(collides)")
    }
  }

  /// Statements read-only refuses: the server runs a write the splitter or scanner could hide
  nonisolated static let hiddenWrites = [
    "SELECT [--], 1; DELETE FROM t",
    "SELECT E'x\\'; DELETE FROM t; --'",
    "SELECT 1 DELETE FROM t",
    // A server that ends `--` only at LF reads the DROP; the scanner ends it at the CR
    "SELECT 1 --x\r' \n DROP TABLE t --'",
    "SELECT * FROM OPENQUERY(s, 'DELETE FROM t')",
    "select * from openrowset('SQLNCLI', 'Server=x;', 'DELETE FROM t')",
    "SELECT * FROM OPENDATASOURCE('SQLNCLI', 'Data Source=x').db.dbo.t",
    "EXEC sp_x", "EXECUTE ('DROP TABLE t')", "EXEC('DROP TABLE t')",
    "SELECT 1 rows FETCH NEXT FROM c",
    "SELECT a\u{2061}DELETE FROM t", "SELECT a\u{180E}DELETE FROM t",
    "SELECT 1\nGO\nSELECT 2", "SELECT 1\n  go 5 -- again\nSELECT 2",
  ]

  @Test("Hidden or remote writes are refused on a read-only connection", arguments: hiddenWrites)
  func hiddenWriteRefused(_ sql: String) {
    #expect(Self.refused(sql, on: .readOnly))
  }

  @Test("EXEC / EXECUTE is a utility outside any transaction; EXECUTE AS switches privileges")
  func execIsUtility() throws {
    for sql in ["EXEC sp_x 1", "EXECUTE sp_x @a = 1", "EXEC('DROP TABLE t')"] {
      let statement = try #require(Self.classify(sql).first)
      #expect(statement.kind == .utility, "\(sql)")
      #expect(statement.nonTransactional, "\(sql)")
      #expect(Self.refused(sql, on: .schemaOnly), "\(sql)")
    }
    #expect(Self.classify("EXECUTE AS USER = 'u'").first?.changesPrivileges == true)
    #expect(Self.classify("EXEC AS LOGIN = 'sa'").first?.changesPrivileges == true)
  }

  @Test("OPENQUERY and its kin make a read, write or SET a utility")
  func remoteRowsetsAreUtilities() {
    #expect(Self.classify("SELECT * FROM OPENQUERY(s, 'SELECT 1')").map(\.kind) == [.utility])
    #expect(
      Self.classify("INSERT INTO t SELECT * FROM OPENQUERY(s, 'SELECT 1')").map(\.kind)
        == [.utility])
    #expect(Self.refused("INSERT INTO t SELECT * FROM OPENQUERY(s, 'SELECT 1')", on: .schemaOnly))
    #expect(Self.classify("SELECT 'OPENQUERY(s, x)' AS q -- OPENROWSET(").map(\.kind) == [.read])
  }

  @Test("SET XACT_ABORT is a utility outside any transaction")
  func xactAbort() throws {
    let statement = try #require(Self.classify("SET XACT_ABORT ON").first)
    #expect(statement.kind == .utility)
    #expect(statement.nonTransactional)
  }

  @Test("Unknown statements, GO lines and BEGIN blocks cannot run in the app's transaction")
  func unknownIsNonTransactional() throws {
    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    for sql in ["PRINT 'x'", "SELECT 1\nGO\nSELECT 2", "BEGIN DELETE FROM t WHERE id = 1 END"] {
      let statements = Self.classify(sql)
      #expect(statements.map(\.kind) == [.unknown], "\(sql)")
      #expect(statements.first?.nonTransactional == true, "\(sql)")
      #expect(
        DatabaseConnectionManager.evaluate(statements, policy: protected, dialect: Self.dialect)
          != .allowed, "\(sql)")
    }
  }

  @Test("BEGIN blocks stay unknown: blocked on schema-only, all-rows writes warn")
  func beginBlocks() throws {
    #expect(Self.refused("BEGIN DROP TABLE t END", on: .schemaOnly))
    let delete = try #require(Self.classify("BEGIN DELETE FROM t END").first)
    #expect(delete.kind == .unknown)
    #expect(delete.affectsAllRows)
    #expect(Self.classify("BEGIN DELETE FROM t WHERE id = 1 END").first?.affectsAllRows == false)
    for warns in [
      "SELECT 1 AS after DELETE FROM t", "SELECT a AS after UPDATE t SET c = 0",
      "SELECT a, b FROM s DELETE FROM t", "SELECT 1 AS of DELETE FROM t",
      "GRANT SELECT ON t TO u WITH GRANT OPTION DELETE FROM t",
      "IF 1 = 1 GRANT SELECT ON t TO u WITH GRANT OPTION DELETE FROM t",
      "BEGIN GRANT SELECT ON t TO u WITH GRANT OPTION; DELETE FROM t; END",
    ] {
      #expect(Self.classify(warns).first?.affectsAllRows == true, "\(warns)")
    }
    for quiet in [
      "SELECT 1 GRANT DELETE ON t TO u", "BEGIN GRANT UPDATE, DELETE ON t TO u END",
      "GRANT UPDATE, DELETE ON t TO u", "GRANT UPDATE (a, b) ON t TO u", "DENY DELETE ON t TO u",
      "REVOKE GRANT OPTION FOR DELETE ON t FROM u",
      "BEGIN REVOKE GRANT OPTION FOR UPDATE, DELETE ON t FROM u END",
      "BEGIN CREATE TABLE c (p int REFERENCES p (id) ON DELETE CASCADE ON UPDATE NO ACTION) END",
      "BEGIN ALTER TABLE c ADD FOREIGN KEY (p) REFERENCES p (id) ON DELETE SET NULL END",
      "BEGIN MERGE t USING s ON t.id = s.id WHEN MATCHED THEN DELETE END",
      "BEGIN CREATE TRIGGER tr ON t AFTER INSERT, DELETE AS SELECT 1 END",
      "BEGIN IF UPDATE(a) SELECT 1 END",
    ] {
      #expect(Self.classify(quiet).first?.affectsAllRows == false, "\(quiet)")
    }
    #expect(
      Self.classify("BEGIN UPDATE t SET a = 1 WHERE id = 1 UPDATE s SET b = 2 END").first?
        .affectsAllRows == true)
  }

  @Test("Statements split at a top-level ; only outside BEGIN … END blocks")
  func blockSplitting() {
    func split(_ sql: String) -> [String] { SQLTokenizer.splitStatements(sql, dialect: .sqlserver) }
    #expect(
      split("CREATE PROCEDURE p AS BEGIN SELECT 1; UPDATE t SET a = 1; END").count == 1)
    #expect(split("BEGIN TRAN; SELECT 1") == ["BEGIN TRAN", "SELECT 1"])
    #expect(split("BEGIN DISTRIBUTED TRANSACTION; SELECT 1").count == 2)
    #expect(
      split("BEGIN TRY SELECT 1; END TRY BEGIN CATCH SELECT 2; END CATCH; SELECT 3")
        == ["BEGIN TRY SELECT 1; END TRY BEGIN CATCH SELECT 2; END CATCH", "SELECT 3"])
    #expect(
      split("BEGIN SELECT CASE WHEN a = 1 THEN 1 END FROM t; SELECT 2; END; SELECT 3").count == 2)
    #expect(split("BEGIN DIALOG @h FROM SERVICE s TO SERVICE 't'; SELECT 1").count == 2)
    #expect(split("END CONVERSATION @h; SELECT 1").count == 2)
    #expect(split("SELECT '; BEGIN', [BEGIN]; SELECT 2 -- BEGIN").count == 2)
  }

  @Test("Every chunk size gives the whole SQL Server split")
  func chunkedSplit() {
    let tokenizer = SQLTokenizer(dialect: .sqlserver)
    for sql in [
      "CREATE PROCEDURE p AS BEGIN SELECT CASE WHEN a = 1 THEN 1 END; END; SELECT 2",
      "BEGIN TRAN; BEGIN TRY DELETE FROM t; END TRY BEGIN CATCH SELECT 1; END CATCH; COMMIT",
      "BEGIN DIALOG @h FROM SERVICE s; END CONVERSATION @h; BEGIN /* c */ SELECT 1; END; SELECT 3",
    ] {
      let scalars = Array(sql.unicodeScalars)
      let whole = tokenizer.splitStatements(sql)
      for size in 1...scalars.count {
        var state = SQLTokenizer.SplitState()
        var buffer: [Unicode.Scalar] = []
        var statements: [String] = []
        var offset = 0
        while offset < scalars.count {
          buffer += scalars[offset..<min(offset + size, scalars.count)]
          offset += size
          let part = tokenizer.splitStatements(
            scalars: buffer, isFinal: offset >= scalars.count, state: &state)
          statements += part.statements
          buffer.removeFirst(part.consumed)
        }
        #expect(statements == whole, "chunk \(size): \(sql.prefix(30))")
      }
    }
  }

  @Test("Reads with UNION, WITH, CASE, join hints, paging and table hints stay reads")
  @MainActor
  func readsStayReads() throws {
    var page = DataViewerState(schema: "dbo", name: "t", orderColumns: [])
    page.databaseType = .sqlserver
    let firstPage = page.pageSQL
    page.page = 2
    for sql in [
      "SELECT 1 UNION ALL SELECT 2", "WITH c AS (SELECT 1 AS x) SELECT x FROM c",
      "SELECT CASE WHEN a = 1 THEN 'x' END FROM t", "SELECT start, comment FROM t",
      "SELECT * FROM a INNER MERGE JOIN b ON a.id = b.id", "SELECT * FROM t WITH (NOLOCK)",
      "SELECT a FROM t ORDER BY a OFFSET @n ROWS FETCH NEXT 5 ROWS ONLY",
      "SELECT a FROM t ORDER BY a OFFSET (10) ROWS FETCH NEXT 5 ROWS ONLY",
      "SELECT café, 名前 FROM t", firstPage, page.pageSQL,
    ] {
      let statements = try ReadOnlyQueryGuard.check(sql, dialect: Self.dialect)
      #expect(statements.map(\.kind) == [.read], "\(sql)")
    }
  }

  // MARK: - Edits

  @Test("Edit targets are [schema].[table]; data viewer pages stay editable")
  func editTargetNames() {
    for name in ["[dbo].[t]", "[d]]b].[t x]"] {
      #expect(CellUpdateStatement.isServerQualifiedName(name, dialect: .sqlserver), "\(name)")
    }
    for name in ["dbo.t", "[dbo].[t", "[dbo]].[t]", "[].[t]", "[dbo].[t] x", "\"dbo\".\"t\""] {
      #expect(!CellUpdateStatement.isServerQualifiedName(name, dialect: .sqlserver), "\(name)")
    }
    let page =
      "SELECT * FROM [dbo].[t] ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 50 ROWS ONLY"
    #expect(CellUpdateStatement.singleRelation(in: page, dialect: .sqlserver) == "[dbo].[t]")
    #expect(
      CellUpdateStatement.singleRelation(
        in: "SELECT * FROM t WHERE a IN (SELECT NULL)", dialect: .sqlserver) == nil)
    #expect(
      CellUpdateStatement.singleRelation(
        in: "SELECT * FROM t ORDER BY (SELECT NULL)", dialect: .postgresql) == nil)
  }

  @Test("An edit binds bools as 1/0, writes bytes as 0x and keys by primary key only")
  func cellEdit() throws {
    let blob = Data([0x01, 0xAB]).base64EncodedString()
    let edit = try CellUpdateStatement.make(
      qualifiedName: "[dbo].[t]", assignments: [("flag", "1"), ("blob", blob)],
      primaryKeyColumns: ["id"],
      rowData: ["id": .bool(true), "flag": .bool(false), "blob": .data(Data())],
      dialect: .sqlserver)
    #expect(edit.sql == "UPDATE [dbo].[t] SET [flag] = @p1, [blob] = 0x01AB WHERE [id] = @p3")
    #expect(edit.values == ["1", "0x01AB", "1"])
    #expect(edit.rowCheck == nil)
    #expect(CellUpdateStatement.quoteIdentifier("a]\0", dialect: .sqlserver) == "[a]]\0]")
  }
}
