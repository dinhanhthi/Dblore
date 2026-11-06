// SQLRestorePlan+MySQLDump.swift
// mysqldump / mariadb-dump files on a MySQL / MariaDB connection. The file is untrusted, so every
// line it may hold beyond a Dblore dump's is one fixed shape, taken from real mysqldump 8.4 and
// mariadb-dump 11.4 output (`MySQLDumpFixtures`), and runs as the plain statement the server
// would run, written here (never the file's text). Every `/*!` version below is at most 50503,
// which every server Dblore connects to passes (the session pins utf8mb4, MySQL 5.5.3 and later):
// - the header and footer pairs: `/*!NNNNN SET @OLD_<X>=@@<X>[, <X>=<value>] */` saves a setting
//   (and changes it), `/*!NNNNN SET <X>=@OLD_<X> */` sets it back. A footer only after its
//   header, each once, and only footers after the first footer. `UNIQUE_CHECKS=0` is never run:
//   that header runs as its save alone, so the file cannot turn off InnoDB's unique checks
//   for rows that go into tables it does not create.
// - `SET NAMES` and the per-table `character_set_client` set with utf8 / utf8mb3 / utf8mb4, run
//   as utf8mb4 (the session's pinned set), the latter between its `@saved_cs_client` save and
//   restore; the session's time zone set to +00:00.
// - `LOCK TABLES <table> WRITE` ... `UNLOCK TABLES` and `/*!40000 ALTER TABLE <table> DISABLE
//   KEYS */` ... `ENABLE KEYS`, each pair on one table the file creates or inserts into.
// - mariadb-dump's `/*M!100616 ...*/` note_verbosity pair, sent only to MariaDB 10.6.16 or later
//   (a comment on any other server). Its leading `/*M!999999\- enable the sandbox mode */` line
//   (a mariadb client command, no `;`) is dropped as the file's exact first line.
// Lines of other mysqldump options are refused naming the option: GTID / binary log lines
// (`--set-gtid-purged=OFF`), triggers, routines and events (`--skip-triggers`, no `--routines`),
// `USE` / `CREATE DATABASE` (no `--databases`), and views (their DEFINER clause).
// The gate classifies each opened statement again like any other restore statement, with no tag
// or exemption: utilities and DDL are blocked only by Read-only and Schema-only, which already
// refuse a Dblore MySQL dump (its SET NAMES and CREATE TABLE), Protected mode refuses every MySQL
// restore, and Safe Mode confirms the whole restore once. The restore then resets every setting
// these lines touch (`resetRestoreSession`).

import Foundation

nonisolated extension SQLRestorePlan {
  /// mariadb-dump's first line, a client command the server reads as a comment
  static let mariaDBSandboxLine = "/*M!999999\\- enable the sandbox mode */"

  /// Why a binary log or GTID line is refused
  static let mysqlDumpGTIDRefusal =
    "a binary log or GTID setting (mysqldump writes it with --set-gtid-purged=ON or AUTO), "
    + "which a restore must not change: make the dump again with --set-gtid-purged=OFF"
  /// Why a `USE` or `CREATE DATABASE` line is refused
  static let mysqlDumpDatabasesRefusal =
    "a USE or CREATE DATABASE line (mysqldump writes them with --databases or --all-databases), "
    + "but a restore writes into the connected database: make the dump again without --databases"
  /// Why a trigger, routine or event line is refused
  static let mysqlDumpTriggersRefusal =
    "a trigger, routine or event as mysqldump writes it, which Dblore does not restore: make the "
    + "dump again with --skip-triggers and without --routines or --events"
  /// Why a view line is refused
  static let mysqlDumpViewsRefusal =
    "a view as mysqldump writes it (a stand-in table, then the view with its DEFINER clause), "
    + "which Dblore does not restore: make the dump again without the views "
    + "(--ignore-table=<database>.<view> for each) and create them afterwards"
  /// Why a version comment line other than the session lines of `mysqlDumpLine` is refused
  static let mysqlVersionCommentRefusal =
    "a MySQL version comment line (/*!...*/) other than the session settings mysqldump and "
    + "mariadb-dump write"
  /// Why a statement after the first footer line is refused
  static let mysqlDumpAfterFooterRefusal =
    "mysqldump sets its saved settings back only at the end of the file, after every table, and "
    + "this statement comes after the first of those lines"

  /// The user variables the session lines set, cleared after every MySQL restore
  static let mysqlDumpClearVariables =
    "SET "
    + ([
      "OLD_CHARACTER_SET_CLIENT", "OLD_CHARACTER_SET_RESULTS", "OLD_COLLATION_CONNECTION",
      "OLD_TIME_ZONE", "OLD_UNIQUE_CHECKS", "OLD_FOREIGN_KEY_CHECKS", "OLD_SQL_MODE",
      "OLD_SQL_NOTES", "OLD_NOTE_VERBOSITY", "saved_cs_client",
    ].map { "@\($0) = NULL" }.joined(separator: ", "))

  /// Why a `SET NAMES` other than utf8mb4, utf8 and utf8mb3 as a dump writes it is refused:
  /// `shown` is the statement's text without comments
  static func setNamesRefusalReason(_ shown: String) -> String {
    "\"\(shown)\" sets the connection's character set, but Dblore restores only SET NAMES "
      + "utf8mb4, utf8 or utf8mb3 as its own dumps and mysqldump write them (run as utf8mb4, the "
      + "character set of this session); for another character set, make the dump again with "
      + "--default-character-set=utf8mb4"
  }

  // MARK: - Header

  /// The scalars of mariadb-dump's sandbox line and its line end (an optional space, then LF or
  /// CRLF) when it is `script`'s exact first line, else 0
  static func mariaDBSandboxPrefix(_ script: String) -> Int {
    let line = mariaDBSandboxLine.unicodeScalars
    var rest = script.unicodeScalars[...]
    guard rest.starts(with: line) else { return 0 }
    rest = rest.dropFirst(line.count)
    var count = line.count
    if rest.first == " " {
      rest = rest.dropFirst()
      count += 1
    }
    if rest.first == "\n" { return count + 1 }
    return rest.starts(with: ["\r", "\n"]) ? count + 2 : 0
  }

  /// `-- MySQL dump <digits>.<digit>...` or `-- MariaDB dump <digits>.<digit>...`
  static func isMySQLDumpHeader(_ line: Substring.UnicodeScalarView) -> Bool {
    let isDigit = { (scalar: Unicode.Scalar) in ("0"..."9").contains(scalar) }
    for lead in ["-- MySQL dump ", "-- MariaDB dump "] {
      guard line.starts(with: lead.unicodeScalars) else { continue }
      let rest = line.dropFirst(lead.unicodeScalars.count)
      let major = rest.prefix(while: isDigit)
      let after = rest.dropFirst(major.count)
      return !major.isEmpty && after.first == "." && after.dropFirst().first.map(isDigit) == true
    }
    return false
  }

  // MARK: - Session lines

  /// What a mysqldump line does in the plan
  enum MySQLDumpRole: Equatable, Sendable {
    /// Saves the setting `name` to `@OLD_<name>` (header)
    case save(String)
    /// Sets `name` back from `@OLD_<name>` (footer)
    case restore(String)
    /// `SET NAMES`, `SET TIME_ZONE='+00:00'`
    case setting
    /// The per-table `@saved_cs_client` save, `character_set_client` set and restore
    case saveClient, setClient, restoreClient
    case lock(ObjectKey, name: String)
    case unlock
    case disableKeys(ObjectKey, name: String)
    case enableKeys(ObjectKey, name: String)
  }

  /// A mysqldump line the plan accepts, and the statement that runs for it
  struct MySQLDumpLine: Sendable {
    let role: MySQLDumpRole
    let executed: String
    /// A `/*M!100616 ...*/` line: sent only to MariaDB 10.6.16 or later
    let mariaDBOnly: Bool
  }

  /// An allowlisted line: its version comments (`40101`, `M100616` for `/*M!`, "" for a line
  /// without one), its content's tokens and what runs
  private struct AllowedLine {
    let versions: Set<String>
    let content: [SQLToken]
    let executed: String
    let role: MySQLDumpRole
  }

  /// Every versioned line of the real dumps (`MySQLDumpFixtures`), and nothing else
  private static let allowedLines: [AllowedLine] = {
    func line(
      _ versions: Set<String>, _ content: String, runs executed: String? = nil,
      _ role: MySQLDumpRole
    ) -> AllowedLine {
      AllowedLine(
        versions: versions, content: SQLTokenizer(dialect: .mysql).tokens(content),
        executed: executed ?? content, role: role)
    }
    // (version, setting, header, what the header runs when not itself)
    let pairs: [(String, String, String, String?)] = [
      (
        "40101", "CHARACTER_SET_CLIENT", "SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT", nil
      ),
      (
        "40101", "CHARACTER_SET_RESULTS", "SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS",
        nil
      ),
      (
        "40101", "COLLATION_CONNECTION", "SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION", nil
      ),
      ("40103", "TIME_ZONE", "SET @OLD_TIME_ZONE=@@TIME_ZONE", nil),
      (
        "40014", "UNIQUE_CHECKS", "SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0",
        "SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS"
      ),
      (
        "40014", "FOREIGN_KEY_CHECKS",
        "SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0", nil
      ),
      ("40101", "SQL_MODE", "SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO'", nil),
      ("40111", "SQL_NOTES", "SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0", nil),
      (
        "M100616", "NOTE_VERBOSITY", "SET @OLD_NOTE_VERBOSITY=@@NOTE_VERBOSITY, NOTE_VERBOSITY=0",
        nil
      ),
    ]
    var lines: [AllowedLine] = []
    for (version, name, header, executed) in pairs {
      lines.append(line([version], header, runs: executed, .save(name)))
      lines.append(line([version], "SET \(name)=@OLD_\(name)", .restore(name)))
    }
    lines.append(line(["40103"], "SET TIME_ZONE='+00:00'", .setting))
    for charset in ["utf8", "utf8mb3", "utf8mb4"] {
      lines.append(
        line(["", "40101", "50503"], "SET NAMES \(charset)", runs: "SET NAMES utf8mb4", .setting))
      lines.append(
        line(
          ["40101", "50503"], "SET character_set_client = \(charset)",
          runs: "SET character_set_client = utf8mb4", .setClient))
    }
    lines.append(line(["40101"], "SET @saved_cs_client = @@character_set_client", .saveClient))
    lines.append(line(["40101"], "SET character_set_client = @saved_cs_client", .restoreClient))
    return lines
  }()

  /// The mysqldump line `tokens` (a statement's, without its `;`) is, or nil: an allowlisted
  /// line (`allowedLines`), `LOCK TABLES <table> WRITE`, `UNLOCK TABLES`, or `/*!40000 ALTER
  /// TABLE <table> DISABLE | ENABLE KEYS */`, with `<table>` one backquoted name
  static func mysqlDumpLine(_ tokens: [SQLToken]) -> MySQLDumpLine? {
    guard let (version, content) = versionedContent(tokens) else { return nil }
    if let allowed = allowedLines.first(where: {
      $0.versions.contains(version) && sameTokens($0.content, content)
    }) {
      return MySQLDumpLine(
        role: allowed.role, executed: allowed.executed, mariaDBOnly: version.hasPrefix("M"))
    }
    func table(_ token: SQLToken) -> (key: ObjectKey, quoted: String)? {
      guard token.kind == .quotedIdentifier,
        let key = objectKey("TABLE", [token], engine: .mysql, creating: false),
        let quoted = try? SQLDialect.mysql.quoteIdentifier(token.text)
      else { return nil }
      return (key, quoted)
    }
    let words = content.map(\.keyword)
    if version.isEmpty, words == ["UNLOCK", "TABLES"] {
      return MySQLDumpLine(role: .unlock, executed: "UNLOCK TABLES", mariaDBOnly: false)
    }
    if version.isEmpty, content.count == 4, words[0] == "LOCK", words[1] == "TABLES",
      words[3] == "WRITE", let (key, quoted) = table(content[2])
    {
      return MySQLDumpLine(
        role: .lock(key, name: content[2].text), executed: "LOCK TABLES \(quoted) WRITE",
        mariaDBOnly: false)
    }
    if version == "40000", content.count == 5, words[0] == "ALTER", words[1] == "TABLE",
      words[4] == "KEYS", let (key, quoted) = table(content[2])
    {
      let name = content[2].text
      switch words[3] {
      case "DISABLE":
        return MySQLDumpLine(
          role: .disableKeys(key, name: name), executed: "ALTER TABLE \(quoted) DISABLE KEYS",
          mariaDBOnly: false)
      case "ENABLE":
        return MySQLDumpLine(
          role: .enableKeys(key, name: name), executed: "ALTER TABLE \(quoted) ENABLE KEYS",
          mariaDBOnly: false)
      default: return nil
      }
    }
    return nil
  }

  /// A statement with no version comment: ("", its tokens). A statement that is one version
  /// comment and nothing else, closed by `*/`: its version (`/*!40101` gives `40101`, `/*M!100616`
  /// `M100616`) and its content's tokens. Nil for anything else (a version comment beside other
  /// tokens).
  private static func versionedContent(_ tokens: [SQLToken]) -> (String, [SQLToken])? {
    guard tokens.contains(where: { $0.kind == .executableComment }) else { return ("", tokens) }
    guard tokens.count == 1 else { return nil }
    var text = tokens[0].text.unicodeScalars[...]
    let mariaDB = text.starts(with: "/*M!".unicodeScalars)
    text = text.dropFirst(mariaDB ? 4 : 3)
    let digits = text.prefix { ("0"..."9").contains($0) }
    let rest = text.dropFirst(digits.count)
    guard !digits.isEmpty, rest.count >= 2, rest.suffix(2).elementsEqual(["*", "/"]) else {
      return nil
    }
    let content = String(String.UnicodeScalarView(rest.dropLast(2)))
    let version = (mariaDB ? "M" : "") + String(String.UnicodeScalarView(digits))
    return (version, SQLTokenizer(dialect: .mysql).tokens(content))
  }

  /// The version numbers of a statement's version comments (`/*!50003` gives 50003)
  private static func commentVersions(_ tokens: [SQLToken]) -> Set<Int> {
    Set(
      tokens.filter { $0.kind == .executableComment }.compactMap { token in
        let text = token.text.unicodeScalars.drop { !("0"..."9").contains($0) }
        return Int(String(String.UnicodeScalarView(text.prefix { ("0"..."9").contains($0) })))
      })
  }

  /// Same kinds, depths and texts, scalar by scalar (no canonical equivalence)
  private static func sameTokens(_ a: [SQLToken], _ b: [SQLToken]) -> Bool {
    a.count == b.count
      && zip(a, b).allSatisfy {
        $0.kind == $1.kind && $0.depth == $1.depth
          && $0.text.unicodeScalars.elementsEqual($1.text.unicodeScalars)
      }
  }

  // MARK: - Refusals that name a mysqldump option

  /// Why a line of another mysqldump option is refused, or nil: `tokens` are the statement's,
  /// `opened` the same with every version comment replaced by its content. Only ever refuses.
  static func mysqlDumpOptionRefusal(_ tokens: [SQLToken], opened: [SQLToken]) -> String? {
    guard let first = opened.first else { return nil }
    let versions = commentVersions(tokens)
    if first.isWord("SET"),
      opened.contains(where: {
        guard let word = $0.keyword else { return false }
        return word.contains("GTID") || word == "SQL_LOG_BIN" || word == "MYSQLDUMP_TEMP_LOG_BIN"
      })
    {
      return mysqlDumpGTIDRefusal
    }
    if first.isWord("USE")
      || (first.isWord("CREATE") && opened.count > 1
        && (opened[1].isWord("DATABASE") || opened[1].isWord("SCHEMA")))
    {
      return mysqlDumpDatabasesRefusal
    }
    // 50003 / 50017 / 50020 wrap triggers and routines, 50106 events
    if !versions.isDisjoint(with: [50003, 50017, 50020, 50106]) {
      return mysqlDumpTriggersRefusal
    }
    // 50001 wraps a view's stand-in and the view, 50013 its DEFINER
    if !versions.isDisjoint(with: [50001, 50013]) { return mysqlDumpViewsRefusal }
    guard first.isWord("CREATE") else { return nil }
    let objects: Set<String> = ["TABLE", "VIEW", "TRIGGER", "PROCEDURE", "FUNCTION", "EVENT"]
    guard
      let object = opened.firstIndex(where: {
        $0.depth == 0 && objects.contains($0.keyword ?? "")
      })
    else { return nil }
    switch opened[object].keyword {
    case "TRIGGER", "PROCEDURE", "FUNCTION", "EVENT": return mysqlDumpTriggersRefusal
    case "VIEW":
      let definer = zip(opened[..<object], opened[..<object].dropFirst()).contains {
        $0.isWord("DEFINER") && $1.isSymbol("=")
      }
      return definer ? mysqlDumpViewsRefusal : nil
    default: return nil
    }
  }
}

/// What a MySQL plan has read of mysqldump's paired lines so far (`SQLRestorePlan.init`)
nonisolated struct MySQLDumpState: Sendable {
  /// The settings a header line saved, with its statement index
  private var saved: [String: Int] = [:]
  /// The settings a footer line set back
  private var restored: Set<String> = []
  /// A footer line was read: only footer lines may follow
  private(set) var inFooter = false
  /// The open `@saved_cs_client` save: its index, and whether its `character_set_client` set came
  private var client: (index: Int, set: Bool)?
  private var lock: (key: SQLRestorePlan.ObjectKey, index: Int)?
  private var keys: (key: SQLRestorePlan.ObjectKey, index: Int)?
  /// Every table a LOCK TABLES or DISABLE KEYS names, checked once the file is read
  private var lockedTables: [(index: Int, key: SQLRestorePlan.ObjectKey, name: String)] = []
  /// The tables the file's INSERTs write into
  var inserted: Set<SQLRestorePlan.ObjectKey> = []
  /// The statements of `/*M!100616 ...*/` lines
  private(set) var mariaDBOnly: Set<Int> = []

  private static func refusal(_ index: Int, _ reason: String) -> SQLRestoreError {
    .statementRefused(index: index, reason: reason)
  }

  /// Records `line`, statement `index`, or refuses it when out of its pair
  mutating func apply(_ line: SQLRestorePlan.MySQLDumpLine, index: Int) throws {
    if line.mariaDBOnly { mariaDBOnly.insert(index) }
    let triple =
      "mysqldump sets character_set_client around each CREATE TABLE in three lines (save to "
      + "@saved_cs_client, set, set back), and this line is out of that order"
    switch line.role {
    case .save(let name):
      guard saved[name] == nil else {
        throw Self.refusal(
          index,
          "mysqldump saves each setting once in its header, and this file saves \(name) again")
      }
      saved[name] = index
    case .restore(let name):
      guard saved[name] != nil else {
        throw Self.refusal(
          index,
          "a mysqldump footer line sets \(name) back to the value its header line saved, and this "
            + "file saves no \(name) before it")
      }
      guard restored.insert(name).inserted else {
        throw Self.refusal(
          index,
          "mysqldump sets each saved setting back once, and this file sets \(name) back again")
      }
      inFooter = true
    case .setting:
      break
    case .saveClient:
      guard client == nil else { throw Self.refusal(index, triple) }
      client = (index, false)
    case .setClient:
      guard let open = client, !open.set else { throw Self.refusal(index, triple) }
      client = (open.index, true)
    case .restoreClient:
      guard client?.set == true else { throw Self.refusal(index, triple) }
      client = nil
    case .lock(let key, let name):
      guard lock == nil else {
        throw Self.refusal(
          index,
          "mysqldump locks one table at a time, and this file locks \(name) before UNLOCK TABLES")
      }
      lock = (key, index)
      lockedTables.append((index, key, name))
    case .unlock:
      guard lock != nil else {
        throw Self.refusal(index, "an UNLOCK TABLES without the LOCK TABLES before it")
      }
      lock = nil
    case .disableKeys(let key, let name):
      guard keys == nil else {
        throw Self.refusal(
          index,
          "mysqldump disables the keys of one table at a time, and this file disables those of "
            + "\(name) before enabling the others")
      }
      keys = (key, index)
      lockedTables.append((index, key, name))
    case .enableKeys(let key, let name):
      guard keys?.key == key else {
        throw Self.refusal(index, "an ENABLE KEYS of \(name) without its DISABLE KEYS before it")
      }
      keys = nil
    }
  }

  /// Once the file is read: every saved setting set back, every save, lock and key switch
  /// closed, and every locked table one the file creates (`created`) or inserts into
  func finish(created: Set<SQLRestorePlan.ObjectKey>) throws {
    for (name, index) in saved.sorted(by: { $0.value < $1.value }) where !restored.contains(name) {
      throw Self.refusal(
        index,
        "a mysqldump header line saves and changes \(name), and this file never sets it back at "
          + "its end")
    }
    if let client {
      throw Self.refusal(
        client.index,
        "a @saved_cs_client save without the SET character_set_client = @saved_cs_client after it")
    }
    if let lock { throw Self.refusal(lock.index, "a LOCK TABLES without its UNLOCK TABLES") }
    if let keys { throw Self.refusal(keys.index, "a DISABLE KEYS without its ENABLE KEYS") }
    for table in lockedTables where !created.contains(table.key) && !inserted.contains(table.key) {
      throw Self.refusal(
        table.index,
        "mysqldump locks and disables keys only on a table the file creates or inserts into, and "
          + "this file does neither for \(table.name)")
    }
  }
}

extension DatabaseConnectionManager {
  /// App-owned read, on MariaDB 10.6.16 or later before a restore that runs mariadb-dump's
  /// `/*M!100616 ...*/` lines, of the setting they change
  static let restoreNoteVerbosityQuery = "SELECT @@SESSION.note_verbosity"
}
