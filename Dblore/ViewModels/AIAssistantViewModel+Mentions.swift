// AIAssistantViewModel+Mentions.swift
// Resolves the @mentions of a question when it is sent, after the gate allowed the connection:
// each becomes a labelled data block added to this turn's question only. The chat keeps the
// question as typed, so saved chats and later turns never hold the resolved text.

import Foundation

extension AIAssistantViewModel {
  /// What `@query` and `@results` read from the active tab when the question was sent
  struct MentionTab {
    var query: String?
    var result: AIQueryResult?
  }

  /// The tab parts of `mentions`, read from the active tab only while it is on the connection
  /// `sessionKey` (nil never matches): `aiCurrentSQL` (nil on a read-only source or Markdown
  /// tab) and `aiCurrentResult`
  func mentionTab(for mentions: [AIMention], sessionKey: String?) -> MentionTab {
    let readsQuery = mentions.contains(.query)
    let readsResult = mentions.contains(.results)
    guard readsQuery || readsResult, let sessionKey, let tab = activeTabSource(),
      tab.aiSessionKey == sessionKey
    else { return MentionTab() }
    return MentionTab(
      query: readsQuery ? tab.aiCurrentSQL : nil,
      result: readsResult ? tab.aiCurrentResult : nil)
  }

  /// The labelled blocks of `mentions` (`AIMention.render`), "" when none resolves. Call it only
  /// once the gate allows the connection. `@table` reads the catalog of the connection
  /// `sessionKey`; `@results` sends rows only with "Send result rows" on (the tool data block);
  /// an unknown table or favorite resolves to nothing. Everything is dropped when the
  /// connection or its AI access changed meanwhile. Throws only once cancelled.
  func mentionContext(
    _ mentions: [AIMention], tab: MentionTab, sessionKey: String?
  ) async throws -> String {
    guard !mentions.isEmpty else { return "" }
    var blocks: [AIMention.Block] = []
    for mention in mentions {
      let text: String?
      switch mention {
      case .table(let name):
        text = await tableStructureSource?(name, sessionKey)
      case .query:
        text = tab.query
      case .results:
        text = tab.result.map {
          AITools.dataBlock($0, sendsRows: settings.configuration.sendsResultRows)
        }
      case .favorite(let name):
        text = AIMention.favorite(named: name, in: favoritesSource())?.sql
      }
      try Task.checkCancellation()
      if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        blocks.append(AIMention.Block(mention: mention, text: text))
      }
    }
    let check = aiAccessCheck()
    guard check.decision == .allowed,
      check.context.map({ AIAccessGate.sessionKey(for: $0.config) }) == sessionKey
    else { return "" }
    return AIMention.render(blocks)
  }

  /// `history` with `mentions` added to its last message, the question of this turn
  static func attaching(_ mentions: String, to history: [AIChatMessage]) -> [AIChatMessage] {
    guard !mentions.isEmpty, let last = history.last, last.role == .user else { return history }
    return history.dropLast() + [AIChatMessage(role: .user, text: last.text + "\n\n" + mentions)]
  }
}
