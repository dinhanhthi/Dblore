// AIAssistantViewModel+Review.swift
// Review and Optimize: fill the draft with a request about the tab's current SQL and remember
// what it was filled from, so the answer can be applied back. The statement's catalog-only
// context is read when the draft is sent and the gate allows the connection.

import Foundation

/// What a Review or Optimize answer reviewed and where Apply writes. Saved with the answer.
struct AIReviewRequest: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case review, optimize
  }

  let kind: Kind
  /// The SQL the draft was filled from; Apply is refused once the target no longer holds it
  let sourceSQL: String
  /// `NotebookViewModel.id` of the tab. Session-only: after a relaunch it matches no tab.
  let notebookId: UUID
  /// The SQL cell in notebook mode, nil for the editor
  let cellId: UUID?
  /// Range of `sourceSQL` in the editor when it was the editor selection, nil when it was the
  /// whole editor or a cell. Optional so answers saved without it still decode.
  var selection: NSRange? = nil
}

extension AIAssistantViewModel {
  /// A Review or Optimize request waiting in the draft
  struct PendingReview {
    let request: AIReviewRequest
    /// The EXPLAIN plan shown for the target when the draft was filled
    let plan: ExplainPlan?

    /// The draft `text` still holds the filled SQL: it was not rewritten into another question.
    /// Only the part a prompt holds is compared, so a request saved with a longer SQL still
    /// matches its own question.
    func isFilled(in text: String) -> Bool {
      text.contains(String(request.sourceSQL.prefix(AIPrompts.maxInputChars)))
    }
  }

  /// Review and Optimize read the quick actions' SQL (`aiCurrentSQL`: nil on a read-only source
  /// or Markdown tab) and need a SQL connection. SQL longer than a prompt holds is not offered:
  /// the model would see only its start, and Apply would replace all of it.
  static func offersReview(in tab: NotebookViewModel?, dialect: SQLDialect) -> Bool {
    guard let tab, dialect != .mongodb, tab.sqlDialect != .mongodb,
      let sql = tab.aiCurrentSQL
    else { return false }
    return sql.count <= AIPrompts.maxInputChars
  }

  /// Like Explain and Fix this only fills the draft (the query can hold row values); the gate
  /// applies when it is sent
  func review(_ kind: AIReviewRequest.Kind, in tab: NotebookViewModel) {
    guard Self.offersReview(in: tab, dialect: sqlDialect), let sql = tab.aiCurrentSQL else {
      return
    }
    let prompt = kind == .review ? AIPrompts.review(sql: sql) : AIPrompts.optimize(sql: sql)
    fillDraft(prompt, sessionKey: tab.aiSessionKey)
    pendingReview = PendingReview(
      request: AIReviewRequest(
        kind: kind, sourceSQL: sql, notebookId: tab.id,
        cellId: tab.viewMode == .editor ? nil : tab.selectedCellId,
        selection: tab.aiCurrentSelection),
      plan: tab.aiShownPlan(for: sql))
  }

  /// Context of a review turn: nil when the turn is no review; "" when the gate does not allow
  /// the connection, nothing is connected or the read failed. Throws only once cancelled.
  func reviewContext(_ review: PendingReview?, allowed: Bool) async throws -> String? {
    guard let review else { return nil }
    guard allowed, let queryContextSource else { return "" }
    let context = try? await queryContextSource(review.request.sourceSQL, review.plan)
    try Task.checkCancellation()
    return context ?? ""
  }
}
