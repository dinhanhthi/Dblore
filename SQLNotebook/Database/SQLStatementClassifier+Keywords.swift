// SQLStatementClassifier+Keywords.swift
// Keyword tables used by SQLStatementClassifier

import Foundation

nonisolated extension SQLStatementClassifier {

  static let readKeywords: Set<String> = ["SHOW"]

  static let dmlKeywords: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE"]

  /// Matches `isSchemaChangeQuery` (CREATE/DROP/ALTER/TRUNCATE) plus COMMENT ON,
  /// which persistently changes catalog object definitions.
  static let ddlKeywords: Set<String> = ["CREATE", "DROP", "ALTER", "TRUNCATE", "COMMENT"]

  /// PREPARE is handled separately (only PREPARE TRANSACTION is TCL).
  /// COMMIT/ROLLBACK PREPARED start with COMMIT/ROLLBACK.
  static let tclKeywords: Set<String> = [
    "BEGIN", "START", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE",
  ]

  static let utilityKeywords: Set<String> = [
    "COPY", "DO", "CALL", "VACUUM", "ANALYZE", "ANALYSE", "REINDEX", "CLUSTER", "LOCK",
    "GRANT", "REVOKE", "NOTIFY", "LISTEN", "UNLISTEN", "DISCARD", "CHECKPOINT", "REFRESH",
    "SECURITY",
  ]

  /// GUCs that the app uses as safety brakes (compared lowercased).
  static let brakeSettings: Set<String> = [
    "statement_timeout", "lock_timeout", "idle_in_transaction_session_timeout",
    "transaction_read_only", "default_transaction_read_only",
  ]

  /// GUCs that switch the privilege context (compared lowercased).
  static let privilegeSettings: Set<String> = ["role", "session_authorization"]

  /// Option names that can open an `EXPLAIN ( ... )` option list.
  static let explainOptions: Set<String> = [
    "ANALYZE", "ANALYSE", "VERBOSE", "COSTS", "SETTINGS", "GENERIC_PLAN", "BUFFERS",
    "SERIALIZE", "WAL", "TIMING", "SUMMARY", "MEMORY", "FORMAT",
  ]
}
