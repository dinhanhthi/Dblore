//
//  WorkspaceManager+AITools.swift
//  Dblore
//
//  Runs the tool calls of an AI chat turn on the workspace connection: catalog reads from the
//  loaded schema, guarded read-only queries through `runAIQuery`, and proposals that never run.
//

import Foundation

extension WorkspaceManager {
  /// What one tool call produced: the result sent back to the model, and what the chat shows
  struct AIToolOutcome {
    /// A run_read_query that did not return rows: its SQL, the full error for the user (never
    /// sent to the model unless rows may be), and whether the app refused it before the server
    struct QueryFailure: Equatable {
      let sql: String
      let message: String
      let refused: Bool
    }

    /// A propose_sql call: what the proposal card shows
    struct Proposal: Equatable {
      let sql: String
      let reason: String
      /// The connection it was proposed for (`AIProposal.sessionKey`, `database`)
      var sessionKey: String? = nil
      var database: String? = nil
    }

    let result: AIToolResult
    /// Rows of a run_read_query, shown to the user (at most `AITools.queryRowLimit`)
    var queryResult: AIQueryResult? = nil
    var queryFailure: QueryFailure? = nil
    var proposal: Proposal? = nil
  }

  /// Runs one tool call of a turn sent for `dialect` on the connection `sessionKey`
  /// (`AIAccessGate.sessionKey`). The AI access gate is asked first, on every call: anything but
  /// allowed is the error "AI access is off for this connection" and nothing is read (Ask is
  /// approved before the turn starts, so a call never waits for approval). Then the arguments
  /// are decoded strictly and the connection must still have `dialect` and `sessionKey` (nil
  /// never matches); a proposal is stamped with that key. On MongoDB the connection must still
  /// read `mongoDatabase`, the turn's database (blank: the session's default; nil never
  /// matches), since a database switch keeps the key; a proposal is stamped with it.
  /// `runsQueries` and `sendsResultRows` are the caller's settings read at call time;
  /// run_read_query is unknown unless `runsQueries` (offered this turn and still on). Never
  /// throws: refusals and failures are error results.
  func runAITool(
    _ call: AIToolCall, dialect: SQLDialect, sessionKey: String?, mongoDatabase: String? = nil,
    runsQueries: Bool, sendsResultRows: Bool
  ) async -> AIToolOutcome {
    func failure(_ error: AITools.ToolError) -> AIToolOutcome {
      AIToolOutcome(
        result: AIToolResult(id: call.id, content: AITools.errorContent(error), isError: true))
    }
    guard isAIAllowed() else { return failure(.accessOff) }
    let decoded: AITools.Call
    do {
      decoded = try AITools.decode(call, runsQueries: runsQueries)
    } catch {
      return failure(error as? AITools.ToolError ?? .invalidArguments)
    }
    guard connectionState.isConnected, let config = workspace.connectionConfig else {
      return failure(.notConnected)
    }
    guard config.databaseType.dialect == dialect,
      let sessionKey, AIAccessGate.sessionKey(for: config) == sessionKey
    else { return failure(.connectionChanged) }
    let isMongo = dialect == .mongodb
    if isMongo {
      guard let mongoDatabase,
        Self.aiProposalMongoDatabase(mongoDatabase) == Self.mongoDatabaseName(of: config)
      else { return failure(.connectionChanged) }
    }
    switch decoded {
    case .listTables:
      guard schemaConnectionEpoch != nil else { return failure(.schemaNotLoaded) }
      let content = AITools.tableList(
        tables: databaseTables.map { isMongo ? $0.name : "\($0.schema).\($0.name)" },
        views: databaseViews.map { isMongo ? $0.name : "\($0.schema).\($0.name)" },
        isMongo: isMongo)
      return AIToolOutcome(result: AIToolResult(id: call.id, content: content, isError: false))
    case .describeTable(let schema, let table):
      switch await describeForAI(schema: schema, table: table, config: config) {
      case .success(let text):
        return AIToolOutcome(
          result: AIToolResult(id: call.id, content: AITools.labelled(text), isError: false))
      case .failure(let error):
        return failure(error)
      }
    case .runReadQuery(let sql):
      return await runAIToolQuery(
        sql, id: call.id, config: config, sendsResultRows: sendsResultRows)
    case .proposeSQL(let sql, let reason):
      return AIToolOutcome(
        result: AIToolResult(id: call.id, content: AITools.proposalShown, isError: false),
        proposal: AIToolOutcome.Proposal(
          sql: sql, reason: reason, sessionKey: sessionKey,
          database: isMongo ? mongoDatabase : config.database))
    }
  }

  /// The structure of one loaded relation, never row counts or values. A SQL table is read with
  /// `fetchTableStructure` (columns, primary key, indexes, foreign keys); a view, a MongoDB
  /// collection (its sampled fields) or a table whose read failed renders the cached columns.
  /// The name resolves against the loaded schema only: exact first, then ignoring ASCII case,
  /// then as `schema.name` when no schema is given.
  private func describeForAI(
    schema: String?, table: String, config: ConnectionConfig
  ) async -> Result<String, AITools.ToolError> {
    guard let epoch = schemaConnectionEpoch else { return .failure(.schemaNotLoaded) }
    let tableCount = databaseTables.count
    let relations =
      databaseTables
      + databaseViews.map { DatabaseTable(schema: $0.schema, name: $0.name, columns: $0.columns) }
    func find(schema: String?, table: String) -> [Int] {
      func matching(_ same: (String, String) -> Bool) -> [Int] {
        relations.indices.filter { index in
          same(relations[index].name, table)
            && schema.map { same(relations[index].schema, $0) } ?? true
        }
      }
      let exact = matching(==)
      return exact.isEmpty
        ? matching { SQLTokenizer.asciiLowercased($0) == SQLTokenizer.asciiLowercased($1) }
        : exact
    }
    var found = find(schema: schema, table: table)
    // list_tables names SQL relations schema.name
    if found.isEmpty, schema == nil, let dot = table.lastIndex(of: ".") {
      found = find(
        schema: String(table[..<dot]), table: String(table[table.index(after: dot)...]))
    }
    guard found.count == 1, let index = found.first else {
      return .failure(found.isEmpty ? .tableNotFound : .ambiguousTable)
    }
    let relation = relations[index]
    if index < tableCount, config.databaseType.dialect != .mongodb,
      config.databaseType.capabilities.supportsStructure
    {
      let structure = try? await connectionManager.fetchTableStructure(
        schema: relation.schema, table: relation.name)
      guard schemaConnectionEpoch == epoch else { return .failure(.connectionChanged) }
      guard isAIAllowed() else { return .failure(.accessOff) }
      if let structure { return .success(AISchemaContext.render(structures: [structure])) }
    }
    return .success(AISchemaContext.render(tables: [relation], foreignKeys: databaseForeignKeys))
  }

  /// `runAIQuery` with the tool caps (it guards, asks the gate and records History as AI). The
  /// rows go to the user; the model gets `AITools.dataBlock`. A server error can echo row
  /// values, so the model gets its text only when `sendsResultRows` is on (scrubbed of the
  /// connection's names, on one line, capped; dropped when the SQL holds a password literal);
  /// app refusals are app text and go as they are.
  private func runAIToolQuery(
    _ sql: String, id: String, config: ConnectionConfig, sendsResultRows: Bool
  ) async -> AIToolOutcome {
    do {
      let result = try await runAIQuery(
        sql, maxRows: AITools.queryRowLimit, timeoutSeconds: AITools.queryTimeoutSeconds)
      let rows = AIQueryResult.make(from: result, maxRows: AITools.queryRowLimit)
      // Access may have been turned off while the query ran: the user still sees the rows
      let allowed = isAIAllowed()
      let content =
        allowed
        ? AITools.dataBlock(rows, sendsRows: sendsResultRows) : AITools.errorContent(.accessOff)
      return AIToolOutcome(
        result: AIToolResult(id: id, content: content, isError: !allowed), queryResult: rows)
    } catch {
      let refused = AIAssistantViewModel.isRefusedBeforeServer(error)
      let message: String
      if refused {
        message = error.localizedDescription
      } else if !sendsResultRows {
        message = "The query failed on the server. The error is shown to the user only."
      } else if SQLStatementClassifier.containsPasswordLiteral(
        sql, dialect: config.databaseType.dialect)
      {
        message = "The query failed on the server."
      } else {
        message = String(
          AISchemaContext.oneLine(MCPToolService.scrub(error.localizedDescription, config: config))
            .prefix(Self.aiToolErrorCharacters))
      }
      return AIToolOutcome(
        result: AIToolResult(
          id: id, content: AITools.errorContent(AITools.ToolError(message: message)),
          isError: true),
        queryFailure: AIToolOutcome.QueryFailure(
          sql: sql, message: error.localizedDescription, refused: refused))
    }
  }

  /// Longest server error text a tool result carries
  private static let aiToolErrorCharacters = 1_000
}
