// SQLBindValue.swift
// Neutral bind values for cell updates and staged row changes.
// PostgreSQL encoding stays in DatabaseConnectionManager+CellUpdate.

/// A bound parameter kept out of SQL text.
/// `.null` is SQL NULL. `.text` is untyped input text.
nonisolated enum SQLBindValue: Sendable, Equatable {
  case null
  case text(String)

  /// Nil text is `.null`. Any other string is `.text`.
  init(optionalText value: String?) {
    if let value {
      self = .text(value)
    } else {
      self = .null
    }
  }
}
