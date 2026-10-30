// AppleIntelligencePromptBudget.swift
// Fits a request into Apple Intelligence's context: the response reserve, the system prompt, the
// history and the schema block, counted in tokens

import Foundation

nonisolated enum AppleIntelligencePromptBudget {
  /// Tokens kept free for the answer of a chat turn and of a ghost text request
  static let chatReserve = 512
  static let inlineReserve = AIInlineCompletion.maxTokens
  /// Allowance per message (the system prompt and each history message) for the markers the
  /// framework wraps around it, which a count of the bare text leaves out
  static let messageOverhead = 8
  /// Characters per token of the estimate, margin included. Measured on the system model:
  /// 12,312 characters of DDL were 3,763 tokens (~3.3 per token).
  static let charsPerToken = 3
  /// Schema renders tried before the schema is left out
  private static let maxSchemaAttempts = 8
  /// Largest schema budget: the prompts cut a schema past `AIPrompts.maxInputChars` mid-table,
  /// and `AISchemaContext.render` adds its "… and N more tables" line past the budget, so the
  /// budget leaves room for that line with any N
  static let maxSchemaChars =
    AIPrompts.maxInputChars - ("\n-- … and \(Int.max) more tables").count

  /// `AISchemaContext.render` within `chars`, never past `maxSchemaChars`: the prompt keeps the
  /// whole render, its last table and its "more tables" line included
  static func renderSchema(
    tables: [DatabaseTable], foreignKeys: [ForeignKey], chars: Int
  ) -> String {
    AISchemaContext.render(
      tables: tables, foreignKeys: foreignKeys, budgetChars: min(chars, maxSchemaChars))
  }

  struct Fitted: Equatable, Sendable {
    /// The system prompt with the schema block that fits
    var system: String
    /// The newest history messages that fit, starting with a user message
    var messages: [AIChatMessage]
    /// The rendered schema block `system` was built around;
    /// empty when none fits
    var schema: String
  }

  enum BudgetError: LocalizedError, Equatable, Sendable {
    /// The system prompt and the newest message alone leave no room for the answer
    case tooLong

    var errorDescription: String? {
      "This request is too long for Apple Intelligence. Shorten it or start a new chat."
    }
  }

  /// Token estimate where `tokenCount(for:)` is missing (below macOS 26.4): a token per
  /// `charsPerToken` characters, rounded up
  static func estimatedTokens(_ text: String) -> Int {
    (text.count + charsPerToken - 1) / charsPerToken
  }

  /// Fits a request into `contextSize` tokens with `reserve` tokens left for the answer.
  /// `system` builds the whole system prompt around a schema block, `renderSchema` renders the
  /// schema within a character budget (`AISchemaContext.render(budgetChars:)`, which cuts whole
  /// tables and notes the rest) and `tokenCount` counts a text.
  ///
  /// The system prompt without the schema comes first; history keeps its newest messages, oldest
  /// dropped first, within half of the room that leaves (the newest message may use all of it),
  /// so a long conversation cannot crowd out the schema; the schema takes the rest, rendered
  /// smaller until the counted prompt fits, and is left out when nothing fits. Throws
  /// `BudgetError.tooLong` when the system prompt alone, or with the newest message, leaves no
  /// room: a request is never sent past the context.
  @concurrent static func fit(
    contextSize: Int, reserve: Int, history: [AIChatMessage],
    system: @escaping @Sendable (String) -> String,
    renderSchema: @escaping @Sendable (Int) -> String,
    tokenCount: @escaping @Sendable (String) async throws -> Int
  ) async throws -> Fitted {
    let bare = system("")
    let room = contextSize - reserve - (try await tokenCount(bare) + messageOverhead)
    guard room > 0 else { throw BudgetError.tooLong }

    var kept: [(message: AIChatMessage, cost: Int)] = []
    var used = 0
    for message in history.reversed() {
      let cost = try await tokenCount(message.text) + messageOverhead
      guard used + cost <= (kept.isEmpty ? room : room / 2) else { break }
      kept.insert((message, cost), at: 0)
      used += cost
    }
    if !history.isEmpty && kept.isEmpty { throw BudgetError.tooLong }
    // A conversation starts with the user
    while let first = kept.first, first.message.role == .assistant {
      used -= first.cost
      kept.removeFirst()
    }
    let messages = kept.map(\.message)

    let schemaRoom = room - used
    var chars = schemaRoom * charsPerToken
    for _ in 0..<maxSchemaAttempts where chars > 0 {
      let schema = renderSchema(chars)
      let prompt = system(schema)
      let over = try await tokenCount(prompt) + messageOverhead + used + reserve - contextSize
      if over <= 0 { return Fitted(system: prompt, messages: messages, schema: schema) }
      chars = min(chars * 3 / 4, chars - over * charsPerToken)
    }
    return Fitted(system: bare, messages: messages, schema: "")
  }
}
