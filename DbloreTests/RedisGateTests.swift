// RedisGateTests.swift
// `executeGatedRedisCommand` on fake sessions: every Redis command passes the lock, the
// connection epoch, the db range, the editor refusals, the protection policy and the destructive
// confirmation before anything is sent, and the bytes sent are the bytes classified. Also
// `RedisReply` rebuilt from the plugin's `[path, type, value]` rows, and a source scan that keeps
// `RedisCommandSending` reachable only through the gate.

import Foundation
import Testing

@testable import Dblore

@Suite("Redis command gate")
struct RedisGateTests {
  private let open = ProtectionPolicy(protectionLevel: .none)

  private static func command(_ words: String..., db: Int = 0) -> RedisCommand {
    RedisCommand(args: words.map { Data($0.utf8) }, db: db)
  }

  private func connect(
    level: ConnectionProtectionLevel = .none, lockSource: LockRegistry = LockRegistry()
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.redis.capabilities)
    let manager = DatabaseConnectionManager(sessionFactory: factory, lockSource: lockSource)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .redis, host: "fake", port: 6379, database: "0", username: "",
        sslMode: .disable, protectionLevel: level, safeMode: .silent))
    return (manager, factory)
  }

  /// Runs `command` and returns the error it throws, or nil when it was sent.
  private func refusal(
    _ manager: DatabaseConnectionManager, _ command: RedisCommand,
    policy: ProtectionPolicy? = nil, epoch: UInt64? = nil, userInitiated: Bool = true,
    confirmed: Bool = false
  ) async -> Error? {
    let current = await manager.connectionEpoch
    do {
      _ = try await manager.executeGatedRedisCommand(
        command, policy: policy ?? open, connectionEpoch: epoch ?? current,
        userInitiated: userInitiated, confirmed: confirmed)
      return nil
    } catch {
      return error
    }
  }

  private func blockedKind(_ error: Error?) -> StatementKind? {
    guard case .blockedByProtection(0, let kind, _)? = error as? DatabaseError else { return nil }
    return kind
  }

  @Test("A relock, a stale epoch and a db out of range are refused before anything is sent")
  func refusedBeforeSending() async throws {
    let registry = LockRegistry()
    let (manager, factory) = try await connect(lockSource: registry)
    let epoch = await manager.connectionEpoch
    let stale = await refusal(manager, Self.command("GET", "k"), epoch: epoch &+ 1)
    guard case .sessionChanged? = stale as? DatabaseError else {
      Issue.record("Expected sessionChanged, got \(String(describing: stale))")
      return
    }
    let negative = await refusal(manager, Self.command("GET", "k", db: -1))
    #expect(negative is RedisCommandRefusal)

    registry.setLockedConnections([LockIdentity(try #require(await manager.config))])
    let locked = await refusal(manager, Self.command("GET", "k"))
    guard case .connectionLocked? = locked as? DatabaseError else {
      Issue.record("Expected connectionLocked, got \(String(describing: locked))")
      return
    }
    #expect(factory.redisCommands.isEmpty)
  }

  @Test("Read-only and Protected mode refuse SET; read-only sends INFO keyspace")
  func readOnly() async throws {
    let (manager, factory) = try await connect(level: .readOnly)
    #expect(blockedKind(await refusal(manager, Self.command("SET", "k", "v"))) == .dml)
    #expect(factory.redisCommands.isEmpty)
    // Protected mode: the gate's Redis arm refuses the write before anything else could
    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    let (open, openFactory) = try await connect()
    #expect(
      blockedKind(await refusal(open, Self.command("SET", "k", "v"), policy: protected)) == .dml)
    #expect(openFactory.redisCommands.isEmpty)
    let info = Self.command("INFO", "keyspace")
    #expect(await refusal(manager, info) == nil)
    #expect(factory.redisCommands == [info])
  }

  @Test(
    "Schema-only blocks admin, destructive, script and unknown commands and sends HSET and EVAL_RO")
  func schemaOnly() async throws {
    let (manager, factory) = try await connect(level: .schemaOnly)
    let blocked: [(RedisCommand, StatementKind)] = [
      (Self.command("FLUSHDB"), .utility),
      // Admin without the destructive flag: the shared policy blocks `.utility` on its own
      (Self.command("INFO", "all"), .utility),
      (Self.command("EVAL", "return 1", "0"), .unknown),
      (Self.command("NOTACOMMAND", "x"), .unknown),
    ]
    for (command, kind) in blocked {
      // Confirmed, so only the policy can refuse it
      #expect(blockedKind(await refusal(manager, command, confirmed: true)) == kind)
    }
    #expect(factory.redisCommands.isEmpty)
    let allowed = [
      Self.command("HSET", "h", "f", "v"), Self.command("EVAL_RO", "return 1", "0"),
    ]
    for command in allowed {
      #expect(await refusal(manager, command) == nil)
    }
    #expect(factory.redisCommands == allowed)
  }

  @Test("A destructive command needs confirmed; an editor-refused command is never sent")
  func confirmationAndEditorRefusal() async throws {
    let (manager, factory) = try await connect()
    let flush = Self.command("FLUSHDB")
    #expect(blockedKind(await refusal(manager, flush)) == .utility)
    let select = await refusal(manager, Self.command("SELECT", "1"), confirmed: true)
    let expected = try #require(
      RedisCommandClassifier.classify(Self.command("SELECT", "1").args).refusal)
    guard case .blockedByProtection(0, .unknown, let reason)? = select as? DatabaseError else {
      Issue.record("Expected blockedByProtection, got \(String(describing: select))")
      return
    }
    #expect(reason == expected)
    #expect(factory.redisCommands.isEmpty)

    #expect(await refusal(manager, flush, confirmed: true) == nil)
    #expect(factory.redisCommands == [flush])
  }

  @Test("The arguments sent are the classified ones, byte for byte, with their db")
  func bytesSentAsClassified() async throws {
    let (manager, factory) = try await connect()
    let key = Data([0x6B, 0x0D, 0x0A, 0xFF, 0x00])
    let value = Data([0xFF, 0xFE, 0x0D, 0x0A])
    let command = RedisCommand(args: [Data("SET".utf8), key, value], db: 3)
    #expect(RedisCommandClassifier.classify(command.args).statement.kind == .dml)
    #expect(await refusal(manager, command) == nil)
    #expect(factory.redisCommands == [command])
    #expect(factory.redisCommands.first?.args == [Data("SET".utf8), key, value])
    #expect(factory.redisCommands.first?.db == 3)
  }

  @Test("A server error never carries the arguments it echoes")
  func errorEchoStripped() async throws {
    let (manager, factory) = try await connect()
    let session = try #require(factory.sessions.first)
    // The server's own echo, in any case: the plugin strips it too, this is the app's own cut
    session.failNextRedisSend(
      with: EnginePluginError.server(
        EngineEvent.Failure(
          code: .query, message: "ERR unknown command 'FOO', With Args Beginning With: 's3cret' ",
          serverCode: "ERR")))
    let error = await refusal(manager, Self.command("FOO", "s3cret"))
    guard case .queryFailed(let message, _)? = error as? DatabaseError else {
      Issue.record("Expected queryFailed, got \(String(describing: error))")
      return
    }
    #expect(message == "ERR unknown command 'FOO'")
  }

  @Test("A command holding a password never shows the server's error text")
  func secretCommandErrorHidden() async throws {
    let (manager, factory) = try await connect()
    let session = try #require(factory.sessions.first)
    let command = Self.command("ACL", "SETUSER", "u", "<s3cret")
    #expect(RedisCommandClassifier.classify(command.args).refusal == nil)
    // The server echoes the mistyped rule, password included, without "with args"
    session.failNextRedisSend(
      with: EnginePluginError.server(
        EngineEvent.Failure(
          code: .query, message: "ERR Error in ACL SETUSER modifier '<s3cret': Syntax error",
          serverCode: "ERR")))
    let error = await refusal(manager, command, confirmed: true)
    guard case .queryFailed(let message, _)? = error as? DatabaseError else {
      Issue.record("Expected queryFailed, got \(String(describing: error))")
      return
    }
    #expect(
      message
        == "The server refused the command. Its message is hidden because the command holds a "
        + "password.")

    // A lost or failed connection reported during the send keeps its case, never the text
    let failures: [DatabaseError] = [
      .connectionLost("Connection closed after ACL SETUSER u <s3cret"),
      .connectionFailed("Could not send ACL SETUSER u <s3cret"),
    ]
    for failure in failures {
      session.failNextRedisSend(with: failure)
      let error = await refusal(manager, command, confirmed: true)
      switch (failure, error as? DatabaseError) {
      case (.connectionLost, .connectionLost(let text)?),
        (.connectionFailed, .connectionFailed(let text)?):
        #expect(!text.contains("s3cret"), "\(text)")
      default:
        Issue.record("Expected the same case, got \(String(describing: error))")
      }
    }
  }

  @Test("A reply of more rows than the cap is refused, not collected")
  func replyRowCap() async throws {
    let (manager, factory) = try await connect()
    let session = try #require(factory.sessions.first)
    let leaf: [CellValue] = [.string("0.0"), .string("integer"), .int(0)]
    session.answerRedisSends(with: Array(repeating: leaf, count: 100_001))
    let error = await refusal(manager, Self.command("LRANGE", "k", "0", "-1"))
    guard case .queryFailed? = error as? DatabaseError else {
      Issue.record("Expected queryFailed, got \(String(describing: error))")
      return
    }
    session.answerRedisSends(with: Array(repeating: leaf, count: 100_000))
    #expect(await refusal(manager, Self.command("LRANGE", "k", "0", "-1")) == nil)
  }

  @Test("Only a user-initiated command counts as in flight", .timeLimit(.minutes(1)))
  func inFlightOnlyWhenUserInitiated() async throws {
    let (manager, factory) = try await connect()
    let session = try #require(factory.sessions.first)
    for userInitiated in [true, false] {
      session.holdNextRedisSend()
      let running = Task {
        await refusal(manager, Self.command("GET", "k"), userInitiated: userInitiated)
      }
      let held = await boundedWait("Redis send held") {
        while session.heldRedisSendCount == 0, !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(5))
        }
        return true
      }
      #expect(held == true)
      #expect(await manager.runningStatementStatus().inFlight == userInitiated)
      session.releaseHeldRedisSends()
      #expect(await running.value == nil)
      #expect(await manager.runningStatementStatus().inFlight == false)
    }
  }
}

// Nested, so `-only-testing:DbloreTests/RedisGateTests` runs them too
extension RedisGateTests {
  /// Every safety gate given `.redis` answers with `RedisCommandClassifier`, never with the SQL
  /// classifier or the SQL text matchers
  @Suite("Redis safety gate arms")
  struct GateArms {
    private static func classify(_ text: String) -> [ClassifiedStatement] {
      SQLStatementClassifier.classify(text, dialect: .redis)
    }

    @Test("Redis text is classified by the Redis classifier, untokenizable text fails closed")
    func classifierArm() {
      // SQL would read `SET` as a session setting and `SELECT 1` as a read
      #expect(Self.classify("SET k v").map(\.kind) == [.dml])
      #expect(Self.classify("SELECT 1").map(\.kind) == [.unknown])
      #expect(Self.classify("GET k\nFLUSHALL").map(\.kind) == [.read, .utility])
      #expect(Self.classify("GET \"k").map(\.kind) == [.unknown])
      #expect(
        SQLStatementClassifier.classifyStatement("SET k v", dialect: .redis)?.kind == .dml)
      #expect(
        SQLStatementClassifier.classifyStatement("GET a\nGET b", dialect: .redis)?.kind
          == .unknown)
    }

    @Test("A Redis secret skips history; untokenizable text counts as one")
    func passwordLiteral() {
      #expect(SQLStatementClassifier.containsPasswordLiteral("AUTH x", dialect: .redis))
      #expect(SQLStatementClassifier.containsPasswordLiteral("GET k\nAUTH x", dialect: .redis))
      #expect(SQLStatementClassifier.containsPasswordLiteral("AUTH \"x", dialect: .redis))
      #expect(!SQLStatementClassifier.containsPasswordLiteral("GET k", dialect: .redis))
    }

    @Test("FLUSHALL needs its name typed; SQL DROP text is not destructive on Redis")
    func destructiveRule() throws {
      let flush = try #require(Self.classify("FLUSHALL").first)
      #expect(DestructiveStatementRule.evaluate(flush, dialect: .redis) == .confirm("FLUSHALL"))
      let drop = try #require(Self.classify("DROP TABLE t").first)
      #expect(DestructiveStatementRule.evaluate(drop, dialect: .redis) == .none)
    }

    @Test("The read-only guard passes GET and refuses SET and read-only scripts")
    func readOnlyGuard() throws {
      #expect(try ReadOnlyQueryGuard.check("GET k", dialect: .redis).map(\.kind) == [.read])
      for command in [
        "SET k v", "EVAL_RO \"return 1\" 0", "EVALSHA_RO abc123 0", "FCALL_RO myfunc 0",
      ] {
        #expect(throws: ReadOnlyQueryGuard.Refusal.notRead) {
          try ReadOnlyQueryGuard.check(command, dialect: .redis)
        }
      }
      // The scripts classify as reads: the guard's script list refuses them, not their kind
      for script in ["EVAL_RO \"return 1\" 0", "EVALSHA_RO abc123 0", "FCALL_RO myfunc 0"] {
        #expect(Self.classify(script).map(\.kind) == [.read], "\(script)")
      }
    }

    @Test("The Protected mode backstop flags every Redis write and lets reads through")
    func protectedBackstop() {
      let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
      let write = DatabaseConnectionManager.evaluate(
        Self.classify("SET k v"), policy: protected, dialect: .redis)
      guard case .blocked(0, .dml, _) = write else {
        Issue.record("Expected SET blocked, got \(write)")
        return
      }
      #expect(
        DatabaseConnectionManager.evaluate(
          Self.classify("GET k"), policy: protected, dialect: .redis) == .allowed)
    }

    @Test("The MCP write check refuses Redis")
    func mcpWriteRefused() {
      #expect(throws: MCPConnectionError.engineNotSupported(.redis)) {
        try MCPToolService.checkWrite(
          "SET k v", statements: Self.classify("SET k v"), dialect: .redis, scope: .schema,
          database: "0")
      }
    }
  }

  /// Helpers that branch on the dialect never read Redis text as SQL: no `:name` binds, no LIKE
  /// check, no written tables, no literal exception for invisible characters, no split at `;`,
  /// and a redacted History row keeps none of the text
  @Suite("Redis text never takes a SQL arm")
  struct NonSQLArms {
    /// A write whose text reads as SQL: binds, a LIKE and a table on the SQL arm
    private static let sqlShaped = ClassifiedStatement(
      text: "DELETE FROM t WHERE a LIKE :p", kind: .dml, hasReturning: false,
      hasTopLevelReturning: false, affectsAllRows: false, nonTransactional: false,
      resetsSessionBrakes: false, changesPrivileges: false, createsTable: false)

    @Test("No :name binds or placeholders, no rewrite")
    func parameters() {
      for text in ["GET :a", "GET ?"] {
        let rewritten = SQLParameterRewriter.rewrite(statement: text, dialect: .redis)
        #expect(rewritten.text == text && rewritten.names.isEmpty, "\(text)")
        #expect(SQLParameterRewriter.parameterNames(in: text, dialect: .redis).isEmpty)
        #expect(!SQLParameterRewriter.containsPositionalPlaceholder(in: text, dialect: .redis))
      }
    }

    @Test("The confirmation shows the text, with no parameter note and no LIKE check")
    func confirmation() throws {
      let parameters: [String: SQLBindValue] = ["p": .text("%")]
      #expect(
        !NotebookViewModel.scriptMatchesAllRowsByLike(
          [Self.sqlShaped], parameters: parameters, dialect: .redis))
      let listed = try #require(
        NotebookViewModel.statementsNeedingConfirmation(
          [Self.sqlShaped], commitStyle: .confirm, parameters: parameters, dialect: .redis))
      #expect(listed.map(\.preview) == ["DELETE FROM t WHERE a LIKE :p"])
      #expect(listed.first?.parameterNote == nil)
      #expect(listed.first?.likePatternAffectsAllRows == false)
    }

    @Test("No written tables or transaction boundaries")
    func writtenRelations() async {
      #expect(
        WrittenRelations.relations(
          writtenBy: "DELETE FROM t", dialect: .redis, defaultSchema: "public"
        ).isEmpty)
      #expect(
        await WrittenRelations.steps(
          of: ["DELETE FROM t", "COMMIT"], dialect: .redis, defaultSchema: "public"
        ).isEmpty)
    }

    @Test("An invisible character counts anywhere, also inside quotes")
    func hiddenCharacters() {
      #expect(HiddenCharacterRule.hasHiddenCharacters("SET k 'a\u{200D}b'", dialect: .redis))
      #expect(!HiddenCharacterRule.hasHiddenCharacters("SET k 'ab'", dialect: .redis))
    }

    @Test("The SQL tokenizer reads Redis text as one opaque piece")
    func tokenizer() {
      let tokenizer = SQLTokenizer(dialect: .redis)
      #expect(tokenizer.splitStatements("GET a; GET b") == ["GET a; GET b"])
      #expect(tokenizer.splitStatements("  \n ").isEmpty)
      #expect(tokenizer.tokens("SET k v").map(\.kind) == [.string])
      #expect(tokenizer.tokens("SET k v").allSatisfy { $0.keyword == nil })
      // Fail safe: a capped read never runs Redis text through a cursor and drains it
      #expect(SQLStatementClassifier.mayCallFunctions("GET k", dialect: .redis))
    }

    @Test("A redacted History row keeps none of the Redis text")
    func historyRedaction() {
      let redacted = MCPToolService.redactingStrings("AUTH s3cret", dialect: .redis)
      #expect(!redacted.contains("s3cret"))
      #expect(redacted == "(Redis command not recorded)")
    }
  }

  /// MCP's tools refuse a Redis connection before History, so no Redis text (an `AUTH` password
  /// the SQL redaction would keep) is ever recorded, and nothing is read, approved or sent
  @MainActor
  @Suite("Redis MCP tools")
  struct MCPTools {
    private let history = RedisRecordedHistory()
    private let reads = RedisReadSourceProbe()
    private let approver = RedisApproverProbe()

    private func service() -> (MCPToolService, UUID) {
      let config = ConnectionConfig(
        databaseType: .redis, host: "fake", port: 6379, database: "0", username: "",
        sslMode: .disable, protectionLevel: .none, name: "Cache", safeMode: .silent,
        protectedMode: false)
      let entry = ConnectionHistoryEntry(config: config)
      let id = entry.id
      let service = MCPToolService(
        connections: { [entry] }, allowlist: { [id] }, aiSettings: { .empty },
        source: reads, recorder: history, historyEnabled: { true }, gate: AIAccessGate(),
        writes: MCPWriteAccess(
          enabled: { true }, scopes: { [id: .schema] }, defaultCommitStyle: { .immediate },
          approver: approver, source: RedisWriteSourceProbe()))
      return (service, id)
    }

    @Test("run_query and execute_write refuse Redis and record nothing")
    func refusedBeforeHistory() async {
      let (service, id) = service()
      for tool in ["run_query", "execute_write"] {
        let result = await service.call(
          tool, arguments: ["connection_id": .string(id.uuidString), "sql": .string("AUTH s3cret")])
        #expect(result.isError)
        #expect(result.text == MCPConnectionError.engineNotSupported(.redis).localizedDescription)
      }
      #expect(history.entries.isEmpty)
      #expect(reads.count == 0)
      #expect(approver.count == 0)
    }
  }

  /// The app's SQL entry points refuse or hide a Redis connection
  @MainActor
  @Suite("Redis entry points")
  struct EntryPoints {
    private static let redis = ConnectionConfig(
      databaseType: .redis, host: "fake", port: 6379, database: "0", username: "",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)

    @Test("The AI assistant never runs queries, opens or builds a schema prompt on Redis")
    func assistantUnavailable() {
      #expect(!AIAssistantViewModel.runsReadQueries(.redis))
      let defaults = UserDefaults(suiteName: "redis-assistant-\(UUID().uuidString)")!
      let assistant = AIAssistantViewModel(
        settings: AISettings(defaults: defaults, keyStore: InMemoryAIKeyStore()))
      var dialect = SQLDialect.postgresql
      assistant.dialectSource = { dialect }
      assistant.toggleVisibility(defaultMode: .sidebar)
      #expect(assistant.showsSidebarPanel)
      // Opened on PostgreSQL, then the workspace is on Redis: hidden, and the toggle is refused
      dialect = .redis
      #expect(!assistant.showsSidebarPanel)
      assistant.togglePresentation()
      #expect(!assistant.showsBubble)
      assistant.hide()
      for mode in [AIPanelMode.sidebar, .bubble] {
        assistant.toggleVisibility(defaultMode: mode)
        #expect(!assistant.isVisible)
      }
      let prompt = AIPrompts.system(
        databaseName: "0", schema: "user:42", dialect: .redis, runsQueries: true,
        review: "plan", rules: "my rules")
      for text in ["user:42", "plan", "my rules", "SQL"] {
        #expect(!prompt.contains(text))
      }
    }

    @Test("Send and Retry on Redis build no client and leave the draft and messages as they are")
    func assistantSendsNothing() {
      let defaults = UserDefaults(suiteName: "redis-assistant-send-\(UUID().uuidString)")!
      let settings = AISettings(defaults: defaults, keyStore: InMemoryAIKeyStore())
      settings.configuration = AIConfiguration(
        activeProvider: .ollama,
        configs: [.ollama: AIProviderConfig(baseURL: "http://127.0.0.1:11434/v1", model: "m1")])
      var clientsBuilt = 0
      let assistant = AIAssistantViewModel(
        settings: settings,
        makeClient: { _, _, _ in
          clientsBuilt += 1
          throw AIClientError.missingModel
        })
      assistant.dialectSource = { .redis }
      let question = AIChatEntry(id: UUID(), role: .user, text: "KEYS user:*", isError: false)
      assistant.messages = [question]
      assistant.draft = "GET user:42"
      assistant.send()
      #expect(!assistant.retry(from: question.id))
      #expect(clientsBuilt == 0)
      #expect(assistant.draft == "GET user:42")
      #expect(assistant.messages == [question])
    }

    @Test("SQLDialect.redis builds no SQL: quoting throws notSQL, every builder its marker")
    func redisDialectBuildsNoSQL() {
      let dialect = SQLDialect.redis
      #expect(throws: SQLDialectError.notSQL) { try dialect.quoteIdentifier("k") }
      #expect(throws: SQLDialectError.notSQL) { try dialect.quoteIdentifierIfNeeded("k") }
      #expect(throws: SQLDialectError.notSQL) { try dialect.qualified(schema: "s", name: "k") }
      let fragments: [String?] = [
        dialect.literal(.int(1)), dialect.literal(.null), dialect.literal(.string("it's")),
        dialect.literal(.bool(true), wallClock: true), dialect.placeholder(1),
        dialect.placeholder(1, type: "Int64"), dialect.limitOffset(limit: 1, offset: 0),
        dialect.limit(1, ordered: false), dialect.savepointSQL("s"),
        dialect.rollbackToSavepointSQL("s"), dialect.releaseSavepointSQL("s"),
        dialect.explainPrefix(analyze: true, buffers: true, format: "json"),
        dialect.likeSubject("c"), dialect.caseInsensitiveLike(column: "c", pattern: "'%a%'"),
        dialect.comparison("c", .equal, "1"), dialect.comparison("c", .equal, "1", type: nil),
        dialect.inList("c", ["1"]), dialect.inList("c", ["1"], type: nil),
        dialect.like(column: "c", pattern: "'a'"), dialect.cast("c", to: "text"),
        dialect.function("lower", "c"), dialect.concatenation("a", "b"),
      ]
      for fragment in fragments {
        #expect(fragment == SQLDialect.notSQLMarker)
      }
      let parts = dialect.comparisonParts("c", .equal, type: nil)
      #expect(parts.lead == SQLDialect.notSQLMarker && parts.trail.isEmpty)
    }

    @Test("Join, Explain and the all-rows export refuse Redis")
    func joinExplainExportRefused() async throws {
      let workspace = WorkspaceManager(
        workspace: Workspace(connectionConfig: Self.redis), restoreTabs: false)
      workspace.connectionState = .connected
      workspace.schemaConnectionEpoch = 1
      #expect(!workspace.canBuildJoinQuery)

      let notebook = NotebookViewModel()
      notebook.notebook.connectionConfig = Self.redis
      #expect(notebook.explainUnavailableReason == "Explain is not available for Redis connections")

      let tab = FakeDatabaseSessionFactory(capabilities: DatabaseType.redis.capabilities)
      let export = FakeDatabaseSessionFactory(capabilities: DatabaseType.redis.capabilities)
      let runner = ResultExportRunner(
        tabManager: DatabaseConnectionManager(sessionFactory: tab), config: Self.redis,
        material: nil, sshCredential: nil, sessionFactory: export,
        temporaryDirectory: FileManager.default.temporaryDirectory)
      let request = ResultExportRequest(
        sql: "GET k", columns: [ColumnInfo(name: "value", type: "bulk")],
        format: .download(ExportOptions(format: .csv)))
      await #expect(throws: ResultExportError.unsupportedEngine(.redis)) {
        _ = try await runner.write(
          request,
          to: FileManager.default.temporaryDirectory.appendingPathComponent(
            "dblore-redis-\(UUID().uuidString).csv"),
          hasStagedChanges: false, mask: { $0 })
      }
      #expect(tab.sessions.isEmpty)
      #expect(export.sessions.isEmpty)
    }
  }

  @Suite("Redis reply tree")
  struct ReplyTree {
    private static func row(_ path: String, _ type: String, _ value: CellValue) -> [CellValue] {
      [.string(path), .string(type), value]
    }

    @Test("Nested map and array rows rebuild the tree, bytes included")
    func nested() throws {
      let rows = [
        Self.row("0", "map", .int(4)),
        Self.row("0.0", "bulk", .string("name")),
        Self.row("0.1", "bulk", .data(Data([0xFF, 0x00]))),
        Self.row("0.2", "simple", .string("list")),
        Self.row("0.3", "array", .int(3)),
        Self.row("0.3.0", "integer", .int(7)),
        Self.row("0.3.1", "null", .null),
        Self.row("0.3.2", "set", .int(1)),
        Self.row("0.3.2.0", "boolean", .string("true")),
      ]
      let reply = try RedisReply(rows: rows)
      #expect(
        reply
          == .map([
            RedisReplyPair(key: .bulk(.text("name")), value: .bulk(.bytes(Data([0xFF, 0x00])))),
            RedisReplyPair(
              key: .simple(.text("list")),
              value: .array([.integer(7), .null, .set([.boolean(true)])])),
          ]))
      #expect(
        try RedisReply(rows: [Self.row("0", "error", .string("ERR no"))]) == .error(.text("ERR no"))
      )
    }

    @Test("Malformed rows throw, never a guessed tree")
    func malformed() {
      let cases: [[[CellValue]]] = [
        [],
        // A child missing
        [Self.row("0", "array", .int(2)), Self.row("0.0", "integer", .int(1))],
        // A child at the wrong path
        [Self.row("0", "array", .int(1)), Self.row("0.1", "integer", .int(1))],
        // A row after the reply ended
        [Self.row("0", "integer", .int(1)), Self.row("1", "integer", .int(2))],
        // A map with an odd child count
        [Self.row("0", "map", .int(1)), Self.row("0.0", "bulk", .string("k"))],
        // An unknown type, a wrong value type, a missing cell
        [Self.row("0", "stream", .string("x"))],
        [Self.row("0", "integer", .string("seven"))],
        [[.string("0"), .string("bulk")]],
        // A negative child count
        [Self.row("0", "array", .int(-1))],
      ]
      for rows in cases {
        #expect(throws: RedisReplyDecodingError.self) { try RedisReply(rows: rows) }
      }
    }

    @Test("A reply past the node cap is refused, 100,000 nodes by default")
    func nodeCap() throws {
      let rows =
        [Self.row("0", "array", .int(3))]
        + (0..<3).map { Self.row("0.\($0)", "integer", .int($0)) }
      #expect(
        try RedisReply(rows: rows, maxNodes: 4) == .array([.integer(0), .integer(1), .integer(2)]))
      #expect(throws: RedisReplyDecodingError.self) { try RedisReply(rows: rows, maxNodes: 3) }

      func flat(_ children: Int) -> [[CellValue]] {
        [Self.row("0", "array", .int(children))]
          + (0..<children).map { Self.row("0.\($0)", "null", .null) }
      }
      #expect(throws: Never.self) { try RedisReply(rows: flat(99_999)) }
      #expect(throws: RedisReplyDecodingError.self) { try RedisReply(rows: flat(100_000)) }
    }

    @Test("Aggregates nested 128 levels deep are read, 129 are refused")
    func depthCap() throws {
      /// `levels` arrays of one child each, the innermost holding an integer
      func nested(_ levels: Int) -> [[CellValue]] {
        var rows: [[CellValue]] = []
        var path = "0"
        for _ in 0..<levels {
          rows.append(Self.row(path, "array", .int(1)))
          path += ".0"
        }
        return rows + [Self.row(path, "integer", .int(1))]
      }
      #expect(throws: Never.self) { try RedisReply(rows: nested(128)) }
      #expect(throws: RedisReplyDecodingError.self) { try RedisReply(rows: nested(129)) }
    }
  }

  @Suite("Redis send seam source scan")
  struct SendSeamScan {
    /// The gate: the only file that may cast a session to `RedisCommandSending` and send
    private static let gate = "Dblore/Database/DatabaseConnectionManager+RedisCommands.swift"
    /// Holds the Test Connection probe (`func probe(`), whose `PING` on its own session is the
    /// documented bypass added in task 8.1: allowed inside that function only, not yet used
    private static let probeFile = "Dblore/Database/DatabaseConnectionManager.swift"
    private static let probeStart = "  private func probe(_ config: ConnectionConfig)"
    /// The protocol's declaration
    private static let declaration = "Dblore/Database/Redis/RedisCommandSending.swift"

    @Test(
      "RedisCommandSending is named only by the gate's two casts, its declaration and conformances")
    func onlyThroughTheGate() throws {
      let mention = try Regex(#"\bRedisCommandSending\b"#)
      // A type declaring its conformance (`final class RedisSession: …, RedisCommandSending`)
      let conformance = try Regex(
        #"^(?:(?:public|internal|private|fileprivate|final|nonisolated)\s+)*(?:class|struct|actor|enum|extension)\s+\w+[^{]*:[^{]*\bRedisCommandSending\b"#
      )
      // A type declaration whose inheritance list goes on past the line's `:` or `,`
      let openDeclaration = try Regex(
        #"^(?:(?:public|internal|private|fileprivate|final|nonisolated)\s+)*(?:class|struct|actor|enum|extension)\s+\w+[^{]*[:,]$"#
      )
      // A wrapped line of that inheritance list (bare type names and commas only)
      let inheritanceLine = try Regex(#"^(?:@\w+\s+)?\w+(?:\s*,\s*(?:@\w+\s+)?\w+)*\s*,?\s*\{?$"#)
      // The gate's casts: `is any RedisCommandSending`, `as? any RedisCommandSending`
      let cast = try Regex(#"\b(?:is|as[?!]?)\s+(?:any\s+)?RedisCommandSending\b"#)
      let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
      let sources = root.appendingPathComponent("Dblore")
      let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
        .filter { $0.hasSuffix(".swift") }
      // Guards a vacuous pass: the scan must have read the app's sources
      #expect(files.count > 300)
      var gateCasts = 0
      var violations: [String] = []
      for relative in files {
        let path = "Dblore/" + relative
        let text = try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let probe = Self.probeLines(lines, in: path)
        // The previous code line left a type's inheritance list open
        var inInheritanceList = false
        for (index, line) in lines.enumerated() {
          let code = Self.code(line)
          if code.isEmpty || code.hasPrefix("//") || code.hasPrefix("*") || code.hasPrefix("/*") {
            continue
          }
          let continuesList = inInheritanceList && code.wholeMatch(of: inheritanceLine) != nil
          inInheritanceList =
            code.wholeMatch(of: openDeclaration) != nil || (continuesList && code.hasSuffix(","))
          guard code.contains(mention) else { continue }
          if path == Self.gate {
            if code.contains(cast) {
              gateCasts += 1
              continue
            }
          } else if path == Self.declaration || probe.contains(index) || continuesList
            || code.contains(conformance)
          {
            continue
          }
          violations.append("\(path):\(index + 1): \(code)")
        }
      }
      #expect(gateCasts == 2, "the gate checks the session's type, then casts it to send")
      #expect(violations.isEmpty, "RedisCommandSending outside the gate: \(violations)")
    }

    /// `line` trimmed, without the `/* … */` comments it starts with
    private static func code(_ line: Substring) -> String {
      var code = line.trimmingCharacters(in: .whitespaces)
      while code.hasPrefix("/*"), let end = code.dropFirst(2).range(of: "*/") {
        code = code[end.upperBound...].trimmingCharacters(in: .whitespaces)
      }
      return code
    }

    /// The line indexes of the Test Connection probe's body (empty in any other file)
    private static func probeLines(_ lines: [Substring], in path: String) -> Range<Int> {
      guard path == probeFile, let start = lines.firstIndex(where: { $0.hasPrefix(probeStart) }),
        let end = lines[start...].firstIndex(where: { $0 == "  }" })
      else { return 0..<0 }
      return start..<end
    }
  }
}

/// History rows MCP recorded
private final class RedisRecordedHistory: QueryHistoryRecording, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [QueryHistoryEntry] = []

  var entries: [QueryHistoryEntry] { lock.withLock { recorded } }

  func record(_ entry: QueryHistoryEntry) async {
    lock.withLock { recorded.append(entry) }
  }
}

/// Counts the reads that reached it
private final class RedisReadSourceProbe: MCPReadSource, @unchecked Sendable {
  private let lock = NSLock()
  private var reads = 0

  var count: Int { lock.withLock { reads } }

  func listTables(connectionID: UUID, schema: String?) async throws -> [MCPTableName] { [] }

  func describeTable(
    connectionID: UUID, schema: String?, table: String
  ) async throws -> [MCPColumnDescription] { [] }

  func runRead(_ request: MCPReadRequest) async throws -> MCPReadResult {
    lock.withLock { reads += 1 }
    return MCPReadResult(columns: [], rows: [], rowsTruncated: false)
  }
}

/// Counts the approvals asked, and denies them
private final class RedisApproverProbe: MCPWriteApproving, @unchecked Sendable {
  private let lock = NSLock()
  private var asked = 0

  var count: Int { lock.withLock { asked } }

  func approve(_ request: MCPWriteApprovalRequest) async throws -> Bool {
    lock.withLock { asked += 1 }
    return false
  }

  func denyWaiting(connections: Set<UUID>) async {}
  func denyAllWaiting() async {}
}

/// A write source no Redis call may reach
private struct RedisWriteSourceProbe: MCPWriteSource {
  func runWrite(_ request: MCPWriteRequest) async throws -> MCPWriteResult {
    Issue.record("A Redis write reached the write source")
    return MCPWriteResult(affectedRows: 0)
  }
}
