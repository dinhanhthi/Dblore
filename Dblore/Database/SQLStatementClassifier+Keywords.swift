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

  /// DuckDB pragmas (uppercase) that only read the catalog or the version. `PRAGMA name` or
  /// `PRAGMA name(...)` of one of them is a read; every other PRAGMA stays a utility.
  static let duckdbReadPragmas: Set<String> = [
    "TABLE_INFO", "VERSION", "DATABASE_LIST", "SHOW_TABLES",
  ]

  /// MySQL commands whose effects are not visible from the text: handlers, kills, flushes, file
  /// loads (`LOAD DATA`, `LOAD XML`, `LOAD INDEX`), table maintenance, replication control and
  /// plugin installs. `DO`, `CALL`, `LOCK`, `GRANT`, `REVOKE` and `ANALYZE` are already on
  /// `utilityKeywords`. `RESET` (`RESET MASTER`, `RESET REPLICA`, `RESET PERSIST`) changes
  /// server state, not a session setting.
  static let mysqlUtilityKeywords: Set<String> = [
    "HANDLER", "KILL", "FLUSH", "LOAD", "UNLOCK", "OPTIMIZE", "REPAIR", "CHECK", "STOP",
    "CHANGE", "RESET", "CACHE", "INSTALL", "UNINSTALL",
  ]

  /// Leading MySQL keywords that commit the open transaction implicitly (besides DDL, which
  /// `mysqlAdjusted` checks by kind, and the `SET` / `START` / `LOAD` / `RESET` forms).
  /// `CALL`, `EXECUTE` and `PREPARE` run SQL the text does not show (a procedure body or a
  /// prepared DDL commits), so they fail closed; `DEALLOCATE`, `CLONE`, `IMPORT` (TABLE),
  /// `BINLOG` and `SHUTDOWN` too. All but `CALL` are also unrecognized (`.unknown`).
  static let mysqlImplicitCommitKeywords: Set<String> = [
    "LOCK", "UNLOCK", "GRANT", "REVOKE", "ANALYZE", "OPTIMIZE", "REPAIR", "CHECK", "FLUSH",
    "STOP", "CHANGE", "CACHE", "INSTALL", "UNINSTALL", "CALL", "EXECUTE", "PREPARE",
    "DEALLOCATE", "CLONE", "IMPORT", "BINLOG", "SHUTDOWN",
  ]

  /// MySQL / MariaDB functions a read must not call (compared uppercased): `LOAD_FILE` reads a
  /// server file, `GET_LOCK` / `RELEASE_LOCK` / `RELEASE_ALL_LOCKS` take or drop user locks,
  /// `SLEEP`, `BENCHMARK` and the replication waits stall the session, `SYS_EXEC` /
  /// `SYS_EVAL` / `SYS_BIN_EVAL` run shell commands and `SYS_GET` / `SYS_SET` read or set
  /// environment variables (lib_mysqludf_sys), and MariaDB `NEXTVAL` / `SETVAL` advance a
  /// sequence. `IS_FREE_LOCK`, `IS_USED_LOCK` and `LASTVAL` only read. Checked in every
  /// statement but a plain EXPLAIN (data changes too, which schema protection allows).
  static let mysqlSideEffectFunctions: Set<String> = [
    "LOAD_FILE", "GET_LOCK", "RELEASE_LOCK", "RELEASE_ALL_LOCKS", "SLEEP", "BENCHMARK",
    "MASTER_POS_WAIT", "SOURCE_POS_WAIT", "WAIT_FOR_EXECUTED_GTID_SET", "MASTER_GTID_WAIT",
    "WAIT_UNTIL_SQL_THREAD_AFTER_GTIDS", "SYS_EXEC", "SYS_EVAL", "SYS_BIN_EVAL", "SYS_GET",
    "SYS_SET", "NEXTVAL", "SETVAL",
  ]

  /// Name prefixes (uppercase) of MySQL functions a read must not call: group replication and
  /// connection failover control, keyring keys, audit log filters, version tokens and Spider
  /// storage engine remote SQL.
  static let mysqlSideEffectFunctionPrefixes: [String] = [
    "GROUP_REPLICATION_", "ASYNCHRONOUS_CONNECTION_FAILOVER_", "KEYRING_", "AUDIT_LOG_",
    "VERSION_TOKENS_", "SPIDER_",
  ]

  /// MySQL / MariaDB session variables (lowercase) that act as safety brakes: statement and
  /// lock timeouts, idle timeouts and the transaction read-only flag.
  static let mysqlBrakeSettings: Set<String> = [
    "max_execution_time", "max_statement_time", "innodb_lock_wait_timeout", "lock_wait_timeout",
    "wait_timeout", "interactive_timeout", "net_read_timeout", "net_write_timeout",
    "transaction_read_only", "tx_read_only",
  ]

  /// MySQL `SET` targets (lowercase) that change how the server lexes SQL text: the SQL mode
  /// and the connection charset (`SET NAMES`, `SET CHARSET`; `SET CHARACTER SET` is matched
  /// as two words).
  static let mysqlLexerSensitiveVariables: Set<String> = [
    "sql_mode", "names", "charset", "character_set_client", "character_set_connection",
    "character_set_results", "collation_connection",
  ]

  /// Words after MySQL `DESCRIBE` / `DESC` that make it an EXPLAIN (or not a table name).
  static let mysqlExplainableKeywords: Set<String> = [
    "SELECT", "TABLE", "WITH", "VALUES", "INSERT", "UPDATE", "DELETE", "REPLACE", "FORMAT",
    "ANALYZE", "EXTENDED", "PARTITIONS", "FOR",
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
  /// `ICEBERG_SCAN`, `ICEBERG_METADATA`, `ICEBERG_SNAPSHOTS`, `DELTA_SCAN`, ...). `JSON_EXECUTE`
  /// (`JSON_EXECUTE_SERIALIZED_SQL`) runs SQL serialized into a string, which the classifier
  /// cannot see either.
  static let duckdbSideEffectFunctionPrefixes: [String] = [
    "POSTGRES_", "MYSQL_", "SQLITE_", "ICEBERG_", "DELTA_", "JSON_EXECUTE",
  ]

  /// Restore only (`SQLRestorePlan.isDumpSchema`), on top of `duckdbSideEffectFunctions` and
  /// its prefixes: DuckDB functions a restored table, index or view may not call (uppercase).
  /// A view runs its body at restore and on every later read, so its text must not run SQL
  /// from a string (`QUERY`, `QUERY_TABLE`, `JSON_EXECUTE_SERIALIZED_SQL`), read files (`READ_*`,
  /// `GLOB`, `SNIFF_CSV`, `PARQUET_*`, `*_SCAN`), settings, pragmas or secrets (`PRAGMA_*`,
  /// `DUCKDB_*`, `*SECRET*`), change logging (`ENABLE_LOGGING`, `WRITE_LOG`,
  /// `TRUNCATE_DUCKDB_LOGS`) or the random seed (`SETSEED`), run plans or generated SQL
  /// (`FROM_SUBSTRAIT*`, `SQLSMITH`, `FUZZYDUCK`, `REDUCE_SQL_STATEMENT`), read other formats
  /// (`SCAN_*`, `ST_READ*`) or reach other catalogs (`DUCKLAKE_*`, `MD_*`). Names, then
  /// prefixes, then names containing a piece. Only calls in the object's body are checked.
  static let duckdbRestoreRefusedFunctions: Set<String> = [
    "GLOB", "SNIFF_CSV", "WRITE_LOG", "ENABLE_LOGGING", "DISABLE_LOGGING", "SQLSMITH",
    "FUZZYDUCK", "REDUCE_SQL_STATEMENT", "SETSEED",
  ]

  static let duckdbRestoreRefusedFunctionPrefixes: [String] = [
    "QUERY", "PRAGMA_", "READ_", "PARQUET_", "JSON_EXECUTE", "SCAN_", "ST_READ", "FROM_SUBSTRAIT",
    "DUCKLAKE_", "MD_",
  ]

  static let duckdbRestoreRefusedFunctionInfixes: [String] = [
    "EXECUTE", "SECRET", "LOGGING", "DUCKDB", "_SCAN",
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
