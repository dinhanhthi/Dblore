// AIAssistantViewModel+Tools.swift
// The tool loop of a turn: stream a reply, run the tools it calls through the workspace (the
// gate is asked on every call), send the results back and continue, at most `maxToolSteps`
// requests. Native tool calls where the wire has them, the text protocol otherwise. Each call
// becomes one chat entry; later turns replay it as labelled text and never run it again.

import Foundation

extension AIAssistantViewModel {
  /// Requests one turn sends at most; a reply that still calls tools after them ends the turn
  static let maxToolSteps = 10

  /// Calls of one step that run; the rest are answered with an error result
  static let maxToolCallsPerStep = 4

  /// `toolEndpoint` keys of local servers that answered HTTP 400 naming tools: they get the text
  /// protocol for the rest of the app session
  static var textToolEndpoints: Set<String> = []

  /// Why the tool loop ended without an answer
  enum ToolLoopError: LocalizedError {
    case cutOff
    case missingThoughtSignature
    case duplicateCallID
    case accessOff

    var errorDescription: String? {
      switch self {
      case .cutOff: "The answer ended before its tool call was complete."
      case .missingThoughtSignature:
        "The provider refused the tool call history (missing thought signature). "
          + "Start a new chat to continue."
      case .duplicateCallID: "The model sent two tool calls with the same id."
      case .accessOff: "AI access to this connection was turned off. The answer stopped."
      }
    }
  }

  private enum StepEnd {
    case finished(calls: [AIToolCall], stop: AIStopReason?)
    case failed(Error)
    case cancelled
  }

  /// Key of a local OpenAI-compatible server (provider and base URL); nil for hosted providers
  static func toolEndpoint(_ provider: AIProviderKind, _ config: AIProviderConfig) -> String? {
    guard [.ollama, .lmStudio, .mlxServer, .custom].contains(provider) else { return nil }
    return provider.rawValue + "|" + config.baseURL.trimmingCharacters(in: .whitespaces)
  }

  /// An HTTP 400 whose message names tools: the server does not take native tools
  static func refusesNativeTools(_ error: Error) -> Bool {
    guard case .http(400, let message)? = error as? AIClientError else { return false }
    let text = message.lowercased()
    return text.contains("tool") || text.contains("function")
  }

  /// Runs the turn's steps into `entryId` and the entries after it. `tools` is fixed for the
  /// turn: nothing a reply or a tool result says changes it. Ends on an answer without tool
  /// calls, an error, Stop, a stale `token` or the step limit.
  func runToolLoop(
    _ base: AIChatRequest, tools: [AIToolSpec], context: TurnContext, entryId: UUID, token: Int
  ) async {
    let names = Set(tools.map(\.name))
    var native =
      context.client.supportsNativeTools
      && !(context.toolEndpoint.map(Self.textToolEndpoints.contains) ?? false)
    var transcript = base.messages
    var seen: Set<String> = []
    var entryId = entryId
    var step = 1
    while !Task.isCancelled, token == generation {
      var request = base
      request.messages = transcript
      if native {
        request.tools = tools
      } else {
        request.system += "\n\n" + AITextToolProtocol.systemSection(tools: tools)
      }
      let streamed: [AIToolCall]
      let stop: AIStopReason?
      switch await streamStep(request, from: context.client, into: entryId) {
      case .cancelled:
        return
      case .failed(let error):
        if native, step == 1, let key = context.toolEndpoint, Self.refusesNativeTools(error),
          text(of: entryId).isEmpty
        {
          Self.textToolEndpoints.insert(key)
          native = false
          continue
        }
        markError(entryId, error)
        return
      case .finished(let calls, let reason):
        streamed = calls
        stop = reason
      }
      let reply = text(of: entryId)
      let calls: [AIToolCall]
      do {
        calls = try toolCalls(streamed, stop: stop, reply: reply, native: native, names: names)
      } catch {
        markError(entryId, error)
        return
      }
      guard !calls.isEmpty else { return }
      for call in calls where !seen.insert(call.id).inserted {
        markError(entryId, ToolLoopError.duplicateCallID)
        return
      }
      if !native { setText(Self.removingToolBlock(reply), of: entryId) }
      // A step that only called tools would show "Thinking…" above its tool entries
      messages.removeAll { $0.id == entryId && $0.text.isEmpty }
      guard step < Self.maxToolSteps else {
        messages.append(
          AIChatEntry(
            id: UUID(), role: .assistant, text: AIPrompts.toolStepLimit(steps: step),
            isError: false))
        return
      }
      var results: [AIToolResult] = []
      for (index, call) in calls.enumerated() {
        let result: AIToolResult?
        if index < Self.maxToolCallsPerStep {
          result = await runTool(call, context: context, names: names, token: token)
        } else {
          result = refuseTool(call, .tooManyCalls, context: context)
        }
        guard let result else { return }
        results.append(result)
      }
      // The results go back only while the gate still allows the connection
      guard aiAccessCheck().decision == .allowed else {
        messages.append(
          AIChatEntry(
            id: UUID(), role: .assistant,
            text: ToolLoopError.accessOff.localizedDescription, isError: true))
        return
      }
      if native {
        let text: [AIContentBlock] = reply.isEmpty ? [] : [.text(reply)]
        transcript.append(
          AIChatMessage(role: .assistant, blocks: text + calls.map(AIContentBlock.toolUse)))
        transcript.append(
          AIChatMessage(role: .user, blocks: results.map(AIContentBlock.toolResult)))
      } else {
        // The text protocol has one call per reply; the reply keeps its tool block
        transcript.append(AIChatMessage(role: .assistant, text: reply))
        transcript.append(
          AIChatMessage(
            role: .user,
            text: AIPrompts.toolResultText(name: calls[0].name, content: results[0].content)))
      }
      step += 1
      entryId = UUID()
      messages.append(AIChatEntry(id: entryId, role: .assistant, text: "", isError: false))
    }
  }

  /// The calls of a finished step. Native: the streamed calls, refused when one names a tool
  /// not offered, when the provider stopped for a missing thought signature, or when the stream
  /// ended without a stop event after a call (cut off). Text protocol: the reply's tool block.
  private func toolCalls(
    _ streamed: [AIToolCall], stop: AIStopReason?, reply: String, native: Bool,
    names: Set<String>
  ) throws -> [AIToolCall] {
    guard native else {
      return try AIMessageParser.toolCall(in: reply, toolNames: names).map { [$0] } ?? []
    }
    if stop == .other("MISSING_THOUGHT_SIGNATURE") { throw ToolLoopError.missingThoughtSignature }
    guard !streamed.isEmpty else { return [] }
    guard stop != nil else { throw ToolLoopError.cutOff }
    guard streamed.allSatisfy({ names.contains($0.name) }) else {
      throw AIStreamError.invalidToolCall("The model called a tool that was not offered.")
    }
    return streamed
  }

  /// Streams one step into entry `id`, collecting its tool calls and stop reason
  private func streamStep(
    _ request: AIChatRequest, from client: any AIChatClient, into id: UUID
  ) async -> StepEnd {
    var calls: [AIToolCall] = []
    var stop: AIStopReason?
    do {
      for try await event in client.stream(request) {
        guard !Task.isCancelled else { return .cancelled }
        switch event {
        case .text(let delta):
          isLoadingModel = false
          append(delta, to: id)
        case .loadingModel:
          isLoadingModel = true
        case .toolCall(let call):
          calls.append(call)
        case .stop(let reason):
          stop = reason
        }
      }
    } catch {
      return Task.isCancelled ? .cancelled : .failed(error)
    }
    return Task.isCancelled ? .cancelled : .finished(calls: calls, stop: stop)
  }

  /// Runs one call through `toolRunner` (a run_read_query behind a "Running query…"
  /// placeholder) and shows it as one entry. Settings are read now: run_read_query runs only
  /// while offered and "Run read-only queries" is still on. Nil once stopped or stale.
  private func runTool(
    _ call: AIToolCall, context: TurnContext, names: Set<String>, token: Int
  ) async -> AIToolResult? {
    let id = UUID()
    if call.name == AITools.runReadQuery {
      messages.append(
        AIChatEntry(id: id, role: .assistant, text: "", isError: false, isRunning: true))
    }
    let configuration = settings.configuration
    let outcome =
      await toolRunner?(
        call, context.dialect, context.sessionKey, context.mongoDatabase,
        names.contains(AITools.runReadQuery) && configuration.runsQueries,
        configuration.sendsResultRows)
      ?? WorkspaceManager.AIToolOutcome(
        result: AIToolResult(
          id: call.id, content: AITools.errorContent(.notConnected), isError: true))
    guard !Task.isCancelled, token == generation else { return nil }
    let entry = Self.toolEntry(
      call, outcome, id: id, dialect: context.dialect, sessionKey: context.sessionKey)
    if let index = messages.firstIndex(where: { $0.id == id }) {
      messages[index] = entry
    } else {
      messages.append(entry)
    }
    saveConversation()
    return outcome.result
  }

  /// A call the app does not run: shown as a failed tool entry, answered with `error`
  private func refuseTool(
    _ call: AIToolCall, _ error: AITools.ToolError, context: TurnContext
  ) -> AIToolResult {
    let outcome = WorkspaceManager.AIToolOutcome(
      result: AIToolResult(id: call.id, content: AITools.errorContent(error), isError: true))
    messages.append(
      Self.toolEntry(
        call, outcome, id: UUID(), dialect: context.dialect, sessionKey: context.sessionKey))
    saveConversation()
    return outcome.result
  }

  /// The chat entry of one call: the query result card, the failed query, the proposal, or a
  /// compact "Ran tool" line. `toolResults` holds what may be saved and replayed: a query's
  /// rows and server errors stay out of it (chats are saved as plain JSON). `sessionKey` is the
  /// connection the call ran on: later turns replay the entry only there.
  static func toolEntry(
    _ call: AIToolCall, _ outcome: WorkspaceManager.AIToolOutcome, id: UUID, dialect: SQLDialect,
    sessionKey: String?
  ) -> AIChatEntry {
    var saved = outcome.result
    if let rows = outcome.queryResult, !saved.isError {
      saved = AIToolResult(
        id: saved.id, content: AITools.dataBlock(rows, sendsRows: false), isError: false)
    } else if let failure = outcome.queryFailure, !failure.refused {
      saved = AIToolResult(
        id: saved.id,
        content: AITools.errorContent(AITools.ToolError(message: AIPrompts.queryFailedPlaceholder)),
        isError: true)
    }
    var entry = AIChatEntry(
      id: id, role: .assistant, text: "", isError: false, toolCalls: [call], toolResults: [saved],
      toolSessionKey: sessionKey)
    if let rows = outcome.queryResult {
      entry.queryResult = rows
    } else if let failure = outcome.queryFailure {
      entry.text = AIPrompts.queryFailure(sql: failure.sql, error: failure.message)
      entry.queryOutcome = failure.refused ? .refused : .failed
      entry.querySQL = failure.sql
    } else if let proposal = outcome.proposal {
      entry.proposal = AIProposal(
        sql: proposal.sql, reason: proposal.reason, sessionKey: proposal.sessionKey,
        database: proposal.database)
      entry.text = AIPrompts.proposal(sql: proposal.sql, reason: proposal.reason, dialect: dialect)
    } else if outcome.result.isError {
      // App text: `AITools.ToolError` never echoes model input
      let message =
        outcome.result.content.hasPrefix(AITools.errorPrefix)
        ? String(outcome.result.content.dropFirst(AITools.errorPrefix.count))
        : outcome.result.content
      entry.text = "Tool \(call.name) failed: \(message)"
    } else {
      entry.text = "Ran tool \(call.name)"
    }
    return entry
  }

  // MARK: - History

  /// A tool entry of an earlier answer as text: the call, then its saved result labelled as
  /// data. Saved fields are untrusted (chat JSON is a plain file), so an entry is dropped unless
  /// it holds exactly one call and its result, with an id of at most `maxToolIDBytes`, a name
  /// the app offers, and arguments that are one JSON object within `maxToolInputBytes` (the
  /// result's content too). An entry of another connection than `sessionKey` (or of none) is
  /// dropped too. A replayed call is never run.
  static func toolHistoryMessages(for entry: AIChatEntry, sessionKey: String?) -> [AIChatMessage] {
    guard let key = entry.toolSessionKey, key == sessionKey,
      let calls = entry.toolCalls, let results = entry.toolResults,
      calls.count == 1, results.count == 1, let call = calls.first, let result = results.first,
      isValidSavedCall(call), result.id == call.id,
      result.content.utf8.count <= AISSEParser.maxToolInputBytes
    else { return [] }
    return [
      AIChatMessage(
        role: .assistant, text: AIPrompts.toolCallText(name: call.name, inputJSON: call.inputJSON)),
      AIChatMessage(
        role: .user, text: AIPrompts.toolResultText(name: call.name, content: result.content)),
    ]
  }

  private static let offeredToolNames = Set(
    AITools.specs(runsQueries: true, isMongo: false).map(\.name))

  private static func isValidSavedCall(_ call: AIToolCall) -> Bool {
    guard !call.id.isEmpty, call.id.utf8.count <= AISSEParser.maxToolIDBytes,
      offeredToolNames.contains(call.name),
      call.inputJSON.utf8.count <= AISSEParser.maxToolInputBytes,
      case .object? = try? JSONDecoder().decode(JSONValue.self, from: Data(call.inputJSON.utf8))
    else { return false }
    return true
  }

  // MARK: - Helpers

  private func text(of id: UUID) -> String {
    messages.first(where: { $0.id == id })?.text ?? ""
  }

  private func setText(_ text: String, of id: UUID) {
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[index].text = text
  }

  /// `text` without its first closed ```tool block (the one `AIMessageParser.toolCall` reads),
  /// trimmed; the call shows as its own entry
  static func removingToolBlock(_ text: String) -> String {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var start: Int?
    var inCode = false
    for index in lines.indices {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if inCode {
        guard trimmed == "```" else { continue }
        if let start {
          lines.removeSubrange(start...index)
          return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        inCode = false
      } else if trimmed.hasPrefix("```") {
        inCode = true
        let language = trimmed.dropFirst(3).split(separator: " ").first
        if language?.lowercased() == AITextToolProtocol.fenceLanguage { start = index }
      }
    }
    return text
  }
}
