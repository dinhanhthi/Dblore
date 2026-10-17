// AIAssistantViewModel+Query.swift
// The turn of one question: stream a reply; when its ```sql run block passes the read-only
// guard, run it once on the connection and show the rows to the user. The model is not called
// again and never sees the rows.

import Foundation

extension AIAssistantViewModel {
  /// What the turn of one question is built from, read when the question is sent
  struct TurnContext {
    let client: any AIChatClient
    let model: String
    /// The question, which selects the tables
    let question: String
    let explicit: Set<String>
    let snapshot: AISchemaSnapshot
    let runsQueries: Bool
    /// The shorter system prompt, for the on-device model
    let compactPrompt: Bool
    /// Dialect at send time; a query runs only while the connection still has it
    let dialect: SQLDialect
    /// MongoDB collection screen shown at send time
    var screen: AIMongoAssist.Screen? = nil
  }

  /// Refused before the query reached the database: no `queryRunner` (the workspace has no
  /// connection), the connection's dialect is no longer the one the question was sent for, or
  /// the runner's read-only session could not open (the server's text is not passed on)
  enum QueryRunError: LocalizedError {
    case notConnected
    case connectionChanged
    case readSessionFailed

    var errorDescription: String? {
      switch self {
      case .notConnected: "Not connected to a database."
      case .connectionChanged:
        "The connection changed while answering. Nothing was sent to the database."
      case .readSessionFailed:
        "Could not open a read-only session to this connection. "
          + "Nothing was sent to the database."
      }
    }
  }

  /// Streams the reply into `entryId`; when "Run read-only queries" was on at send time and still
  /// is, runs the reply's ```sql run block once and stops, unless `token` went stale
  func runTurn(
    _ context: TurnContext, history: [AIChatMessage], entryId: UUID, token: Int
  ) async {
    let request = await Self.buildRequest(
      model: context.model, question: context.question, explicit: context.explicit,
      snapshot: context.snapshot, history: history, runsQueries: context.runsQueries,
      compactPrompt: context.compactPrompt, screen: context.screen)
    guard await streamReply(request, from: context.client, into: entryId),
      context.runsQueries, settings.configuration.runsQueries,
      let reply = messages.first(where: { $0.id == entryId })?.text,
      let sql = AIMessageParser.runQuery(in: reply, dialect: context.dialect)
    else { return }
    await runQuery(sql, context: context, token: token)
  }

  /// Rows and database errors can hold row values, so they never go to the model: a result entry
  /// is sent as a user message with only its row count, a query that could not run as a
  /// placeholder.
  static func historyMessage(for entry: AIChatEntry) -> AIChatMessage {
    if let result = entry.queryResult {
      return AIChatMessage(
        role: .user, text: AIPrompts.queryShownPlaceholder(rowCount: result.rowCount))
    }
    if entry.queryOutcome != nil {
      return AIChatMessage(role: .assistant, text: AIPrompts.queryFailedPlaceholder)
    }
    return AIChatMessage(role: entry.role, text: entry.text)
  }

  /// Streams `request` into entry `id`; false when it failed (error shown) or was cancelled
  private func streamReply(
    _ request: AIChatRequest, from client: any AIChatClient, into id: UUID
  ) async -> Bool {
    do {
      for try await event in client.stream(request) {
        guard !Task.isCancelled else { return false }
        switch event {
        case .text(let delta):
          isLoadingModel = false
          append(delta, to: id)
        case .loadingModel:
          isLoadingModel = true
        }
      }
    } catch {
      if !Task.isCancelled { markError(id, error) }
      return false
    }
    return !Task.isCancelled
  }

  /// Runs `sql` behind a "Running query…" placeholder, which then holds the result or, on
  /// failure (guard refusal, no connection, a connection changed to another dialect, database
  /// error), the error and the SQL. Once `token` went stale the entries are left untouched.
  private func runQuery(_ sql: String, context: TurnContext, token: Int) async {
    let id = UUID()
    messages.append(
      AIChatEntry(id: id, role: .assistant, text: "", isError: false, isRunning: true))
    var result: QueryResult?
    var failure: Error?
    do {
      let dialect = sqlDialect
      guard dialect == context.dialect else { throw QueryRunError.connectionChanged }
      _ = try ReadOnlyQueryGuard.check(sql, dialect: dialect, refuseFileAccess: true)
      guard let queryRunner else { throw QueryRunError.notConnected }
      result = try await queryRunner(sql)
    } catch {
      failure = error
    }
    guard !Task.isCancelled, token == generation,
      let index = messages.firstIndex(where: { $0.id == id })
    else { return }
    messages[index].isRunning = nil
    if let result {
      messages[index].queryResult = AIQueryResult.make(from: result, maxRows: Self.modelRowCap)
    } else {
      messages[index].text = AIPrompts.queryFailure(
        sql: sql, error: failure?.localizedDescription ?? "")
      messages[index].queryOutcome = Self.isRefusedBeforeServer(failure) ? .refused : .failed
      messages[index].querySQL = sql
    }
    saveConversation()
  }

  /// The app refused the query before it reached the server: the guard, no connection, another
  /// tab's pending transaction or the read-only gate
  private static func isRefusedBeforeServer(_ failure: Error?) -> Bool {
    guard let failure else { return false }
    switch failure {
    case is ReadOnlyQueryGuard.Refusal, is QueryRunError,
      DatabaseError.transactionPendingInAnotherTab, DatabaseError.blockedByProtection:
      return true
    default: return false
    }
  }
}
