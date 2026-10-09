// SQLStatementClassifier+Keywords.swift
// Keyword tables used by SQLStatementClassifier

import Foundation

nonisolated extension SQLStatementClassifier {

  static let readKeywords: Set<String> = ["SHOW"]

  static let dmlKeywords: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE"]

  /// CREATE/DROP/ALTER/TRUNCATE (the former prefix-based schema check) plus COMMENT ON,
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

  /// SQLite writes that do not start with a PostgreSQL DML verb. `INSERT OR …` and
  /// `ON CONFLICT … DO UPDATE` already start with INSERT.
  static let sqliteDmlKeywords: Set<String> = ["REPLACE"]

  /// SQLite commands that open or leave another database file. Effects are not visible from
  /// the text, so they are utilities. `VACUUM INTO` stays on `utilityKeywords` (`VACUUM`).
  static let sqliteUtilityKeywords: Set<String> = ["ATTACH", "DETACH"]

  /// DuckDB commands that install or load an extension, open or leave another database file,
  /// write or read files, flush the WAL, or change a setting (`FORCE` starts `FORCE INSTALL` and
  /// `FORCE CHECKPOINT`). `USE` switches the session's default database and schema.
  /// `COPY`, `CALL` and `CHECKPOINT` are already on `utilityKeywords`.
  static let duckdbUtilityKeywords: Set<String> = [
    "INSTALL", "LOAD", "ATTACH", "DETACH", "EXPORT", "IMPORT", "FORCE", "PRAGMA", "SET",
    "RESET", "USE",
  ]

  /// DuckDB functions a read must not call (compared uppercased): `GETENV` reads the app's
  /// environment, `CHECKPOINT` / `FORCE_CHECKPOINT` write the database file, `NEXTVAL` /
  /// `SETVAL` advance a sequence, `LOAD_AWS_CREDENTIALS` reads credentials into a secret,
  /// `QUERY` runs SQL text the classifier cannot see, `DUCKDB_SECRETS` / `WHICH_SECRET` expose
  /// secrets, and `CURRENT_SETTING` / `GETVARIABLE` read configuration or session variables.
  /// `CURRVAL` only reads. Best-effort: the phase-15 session hardening is the boundary.
  static let duckdbSideEffectFunctions: Set<String> = [
    "GETENV", "CHECKPOINT", "FORCE_CHECKPOINT", "NEXTVAL", "SETVAL", "LOAD_AWS_CREDENTIALS",
    "QUERY", "DUCKDB_SECRETS", "WHICH_SECRET", "CURRENT_SETTING", "GETVARIABLE",
  ]

  /// Name prefixes (uppercase) of DuckDB functions a read must not call: every function of the
  /// postgres and mysql extensions reaches a remote server (`POSTGRES_SCAN`,
  /// `POSTGRES_SCAN_PUSHDOWN`, `POSTGRES_QUERY`, `POSTGRES_EXECUTE`, `POSTGRES_ATTACH`,
  /// `MYSQL_SCAN`, `MYSQL_QUERY`, `MYSQL_EXECUTE`, ...), and the sqlite, iceberg and delta
  /// extensions open other databases or remote tables (`SQLITE_SCAN`, `SQLITE_ATTACH`,
  /// `ICEBERG_SCAN`, `ICEBERG_METADATA`, `ICEBERG_SNAPSHOTS`, `DELTA_SCAN`, ...).
  static let duckdbSideEffectFunctionPrefixes: [String] = [
    "POSTGRES_", "MYSQL_", "SQLITE_", "ICEBERG_", "DELTA_",
  ]

  /// URL schemes DuckDB (httpfs, azure, hf extensions) opens over the network (lowercase).
  /// A string or quoted identifier that starts with one makes a DuckDB read fail closed.
  static let duckdbRemoteSchemes: [String] = [
    "http://", "https://", "s3://", "s3a://", "s3n://", "gs://", "gcs://", "r2://", "az://",
    "azure://", "abfss://", "hf://", "ftp://",
  ]

  /// SQLite function that loads a native library. A call fails closed.
  static let sqliteLoadExtensionFunction = "LOAD_EXTENSION"

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
