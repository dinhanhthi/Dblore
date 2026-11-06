// MySQLDumpRestorePlanTests.swift
// `SQLRestorePlan` on real mysqldump 8.4 and mariadb-dump 11.4 files (`MySQLDumpFixtures`): the
// unit fixture gate (each file plans with nothing refused), the session lines it runs (opened,
// never `UNIQUE_CHECKS=0`, utf8 run as utf8mb4), and the refusals of a file that is not a plain
// dump of the connected database's tables: GTID lines, unpaired header and footer lines, free
// SET lines, non-literal INSERT values, another character set, triggers, views and
// `--databases`.

import Foundation
import Testing

@testable import Dblore

@Suite("mysqldump restore plan")
struct MySQLDumpRestorePlanTests {
  private static func plan(_ script: String) throws -> SQLRestorePlan {
    try SQLRestorePlan(script: script, engine: .mysql)
  }

  private static func planError(
    _ script: String, engine: DatabaseType = .mysql
  ) -> SQLRestoreError? {
    do {
      _ = try SQLRestorePlan(script: script, engine: engine)
      return nil
    } catch let error as SQLRestoreError {
      return error
    } catch {
      Issue.record("Unexpected error \(error)")
      return nil
    }
  }

  /// The refusal of `script`: its statement index and reason
  private static func refusal(_ script: String) -> (index: Int, reason: String)? {
    guard case .statementRefused(let index, let reason)? = planError(script) else { return nil }
    return (index, reason)
  }

  /// `script` with the first occurrence of `line` (a whole line) replaced by `replacement`
  /// lines (none removes it)
  private static func replacing(
    _ line: String, with replacement: [String], in script: String
  ) -> String {
    var lines = script.components(separatedBy: "\n")
    guard let index = lines.firstIndex(of: line) else {
      Issue.record("The fixture has no line \(line)")
      return script
    }
    lines.replaceSubrange(index...index, with: replacement)
    return lines.joined(separator: "\n")
  }

  private static let fixtures = [
    ("mysqldump", MySQLDumpFixtures.mysqlDump), ("mariadb-dump", MySQLDumpFixtures.mariaDBDump),
  ]

  // MARK: - Unit fixture gate

  @Test("Each real dump plans with nothing refused", arguments: fixtures)
  func fixturePlans(name: String, script: String) throws {
    let plan = try Self.plan(script)
    #expect(plan.summary.count(.drop) == 2, "\(name)")
    #expect(plan.summary.count(.schema) == 2, "\(name)")
    #expect(plan.summary.count(.data) == 2, "\(name)")
    #expect(plan.summary.count(.sessionSetting) == plan.statements.count - 6, "\(name)")
  }

  @Test("Every session line runs opened, as a plain statement", arguments: fixtures)
  func sessionLinesOpened(name: String, script: String) throws {
    let plan = try Self.plan(script)
    for (statement, kind) in zip(plan.statements, plan.kinds) where kind == .sessionSetting {
      #expect(!statement.text.contains("/*"), "\(name): \(statement.text)")
      #expect(
        SQLStatementClassifier.classifyStatement(statement.text, dialect: .mysql)?.kind
          == statement.kind, "\(name): \(statement.text)")
    }
    let texts = plan.statements.map(\.text)
    #expect(texts.contains("SET NAMES utf8mb4"))
    #expect(texts.contains("SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT"))
    #expect(texts.contains("SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT"))
    #expect(texts.contains("SET @saved_cs_client = @@character_set_client"))
    #expect(texts.contains("SET character_set_client = utf8mb4"))
    #expect(texts.contains("SET character_set_client = @saved_cs_client"))
    #expect(texts.contains("LOCK TABLES `items` WRITE"))
    #expect(texts.contains("ALTER TABLE `items` DISABLE KEYS"))
    #expect(texts.contains("ALTER TABLE `tags` ENABLE KEYS"))
    #expect(texts.contains("UNLOCK TABLES"))
  }

  @Test("The executed header saves unique checks but never turns them off", arguments: fixtures)
  func uniqueChecksNeverOff(name: String, script: String) throws {
    let plan = try Self.plan(script)
    let texts = plan.statements.map {
      SQLTokenizer.asciiUppercased($0.text).filter { !$0.isWhitespace }
    }
    #expect(!texts.contains { $0.contains("UNIQUE_CHECKS=0") }, "\(name)")
    #expect(plan.statements.map(\.text).contains("SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS"))
    #expect(plan.statements.map(\.text).contains("SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS"))
  }

  @Test("utf8 and utf8mb3 are run as utf8mb4")
  func utf8RunsAsUTF8MB4() throws {
    var script = Self.replacing(
      "/*!50503 SET NAMES utf8mb4 */;", with: ["/*!40101 SET NAMES utf8 */;"],
      in: MySQLDumpFixtures.mysqlDump)
    script = Self.replacing(
      "/*!50503 SET character_set_client = utf8mb4 */;",
      with: ["/*!40101 SET character_set_client = utf8mb3 */;"], in: script)
    let plan = try Self.plan(script)
    let texts = plan.statements.map(\.text)
    #expect(texts.contains("SET NAMES utf8mb4"))
    #expect(texts.filter { $0 == "SET character_set_client = utf8mb4" }.count == 2)
    #expect(!texts.contains { $0.contains("utf8 ") || $0.hasSuffix("utf8") })
    #expect(!texts.contains { $0.contains("utf8mb3") })
  }

  @Test("A mysqldump header is read only on a MySQL connection")
  func headerOnlyOnMySQL() {
    for engine in [DatabaseType.postgresql, .sqlite, .duckdb] {
      #expect(Self.planError(MySQLDumpFixtures.mysqlDump, engine: engine) == .headerMissing)
      #expect(Self.planError(MySQLDumpFixtures.mariaDBDump, engine: engine) == .headerMissing)
    }
  }

  @Test("The sandbox line is stripped only as the file's exact first line")
  func sandboxLineOnlyFirst() {
    let sandbox = "/*M!999999\\- enable the sandbox mode */ "
    let moved = Self.replacing(sandbox, with: [], in: MySQLDumpFixtures.mariaDBDump)
    let inside = Self.replacing(
      "/*!40101 SET NAMES utf8mb4 */;", with: [sandbox, "/*!40101 SET NAMES utf8mb4 */;"],
      in: moved)
    #expect(Self.refusal(inside) != nil)
    #expect(Self.planError("\n" + MySQLDumpFixtures.mariaDBDump) == .headerMissing)
  }

  // MARK: - Refusals

  @Test("A GTID dump is refused at its first binary log line, naming --set-gtid-purged=OFF")
  func gtidRefused() throws {
    let refused = try #require(Self.refusal(MySQLDumpFixtures.mysqlDumpWithGTID))
    #expect(refused.index == 9)
    #expect(
      SQLRestoreError.statementRefused(index: refused.index, reason: refused.reason)
        .localizedDescription
        == "Statement 10 is not part of a SQL dump: "
        + SQLRestorePlan.mysqlDumpGTIDRefusal + ". Nothing was executed.")
    #expect(refused.reason.contains("--set-gtid-purged=OFF"))
    let purged = Self.replacing(
      "SET @MYSQLDUMP_TEMP_LOG_BIN = @@SESSION.SQL_LOG_BIN;", with: [],
      in: Self.replacing(
        "SET @@SESSION.SQL_LOG_BIN= 0;", with: [], in: MySQLDumpFixtures.mysqlDumpWithGTID))
    #expect(Self.refusal(purged)?.reason == SQLRestorePlan.mysqlDumpGTIDRefusal)
  }

  @Test("A footer line without its header line is refused")
  func unpairedFooterRefused() throws {
    let script = Self.replacing(
      "/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;", with: [],
      in: MySQLDumpFixtures.mysqlDump)
    let refused = try #require(Self.refusal(script))
    #expect(
      refused.reason
        == "a mysqldump footer line sets UNIQUE_CHECKS back to the value its header line saved, "
        + "and this file saves no UNIQUE_CHECKS before it")
  }

  @Test("A header line without its footer line is refused")
  func unpairedHeaderRefused() throws {
    let script = Self.replacing(
      "/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;", with: [], in: MySQLDumpFixtures.mysqlDump)
    let refused = try #require(Self.refusal(script))
    #expect(refused.index == 9)
    #expect(
      refused.reason
        == "a mysqldump header line saves and changes SQL_NOTES, and this file never sets it "
        + "back at its end")
  }

  @Test("A header or footer line twice is refused")
  func duplicateRefused() throws {
    let header = "/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;"
    let twice = Self.replacing(header, with: [header, header], in: MySQLDumpFixtures.mysqlDump)
    #expect(Self.refusal(twice)?.index == 5)
    let footer = "/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;"
    let footerTwice = Self.replacing(
      footer, with: [footer, footer], in: MySQLDumpFixtures.mysqlDump)
    #expect(Self.refusal(footerTwice) != nil)
  }

  @Test("Only footer lines come after the first footer line")
  func nothingAfterFooter() throws {
    let footer = "/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;"
    let script = Self.replacing(
      footer, with: [footer, "INSERT INTO `tags` VALUES (12,1,'late');"],
      in: MySQLDumpFixtures.mysqlDump)
    #expect(Self.refusal(script) != nil)
  }

  @Test(
    "Free SET lines, a lone UNIQUE_CHECKS=0 and other version comments are refused",
    arguments: [
      "SET @x = f();", "SET @x = 1;", "/*!40101 SET @x = f() */;",
      "/*!40014 SET UNIQUE_CHECKS=0 */;", "/*!40014 SET FOREIGN_KEY_CHECKS=0 */;",
      "/*!40101 SET SQL_MODE='' */;", "/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE */;",
      "/*!40103 SET TIME_ZONE='SYSTEM' */;", "/*!40101 SET NAMES utf8mb4 */ SELECT 1;",
      "/*!99999 SET NAMES utf8mb4 */;", "/*!40000 ALTER TABLE `items` DISABLE KEYS, ADD x int */;",
      "LOCK TABLES `items` READ;", "LOCK TABLES `items` WRITE, `tags` WRITE;",
      "/*!40101 SET character_set_client = latin1 */;",
    ])
  func freeLinesRefused(line: String) throws {
    let script = Self.replacing(
      "/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;",
      with: ["/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;", line],
      in: MySQLDumpFixtures.mysqlDump)
    #expect(Self.refusal(script)?.index == 10, "\(line)")
  }

  @Test("A SET NAMES latin1 line is refused with the character set text")
  func latin1Refused() throws {
    let script = Self.replacing(
      "/*!50503 SET NAMES utf8mb4 */;", with: ["/*!40101 SET NAMES latin1 */;"],
      in: MySQLDumpFixtures.mysqlDump)
    let refused = try #require(Self.refusal(script))
    #expect(refused.index == 3)
    #expect(refused.reason == SQLRestorePlan.setNamesRefusalReason("/*!40101 SET NAMES latin1 */"))
    #expect(refused.reason.contains("--default-character-set=utf8mb4"))
  }

  @Test("An INSERT value that is not a literal is refused")
  func nonLiteralValueRefused() throws {
    let script = MySQLDumpFixtures.mysqlDump.replacingOccurrences(
      of: "(10,1,'fruit')", with: "(10,1+1,'fruit')")
    let refused = try #require(Self.refusal(script))
    #expect(refused.reason.contains("holds only literal values"))
  }

  @Test("LOCK TABLES and DISABLE KEYS only in pairs, on a table the file writes")
  func locksAndKeysPaired() throws {
    let unlock = Self.replacing(
      "UNLOCK TABLES;", with: [], in: MySQLDumpFixtures.mysqlDump)
    #expect(Self.refusal(unlock) != nil)
    let enable = Self.replacing(
      "/*!40000 ALTER TABLE `items` ENABLE KEYS */;", with: [], in: MySQLDumpFixtures.mysqlDump)
    #expect(Self.refusal(enable) != nil)
    let other = MySQLDumpFixtures.mysqlDump.replacingOccurrences(
      of: "LOCK TABLES `tags` WRITE;", with: "LOCK TABLES `users` WRITE;")
    let refused = try #require(Self.refusal(other))
    #expect(refused.reason.contains("users"))
    let otherKeys = MySQLDumpFixtures.mysqlDump.replacingOccurrences(
      of: "ALTER TABLE `tags` DISABLE KEYS", with: "ALTER TABLE `users` DISABLE KEYS"
    ).replacingOccurrences(
      of: "ALTER TABLE `tags` ENABLE KEYS", with: "ALTER TABLE `users` ENABLE KEYS")
    #expect(Self.refusal(otherKeys) != nil)
  }

  @Test(
    "Lines of other mysqldump options are refused naming the option",
    arguments: [
      ("USE `qa_b12_dump`;", "without --databases"),
      (
        "CREATE DATABASE /*!32312 IF NOT EXISTS*/ `qa_b12_dump` /*!40100 DEFAULT CHARACTER SET "
          + "utf8mb4 */;", "without --databases"
      ),
      ("/*!50003 SET @saved_cs_client      = @@character_set_client */ ;", "--skip-triggers"),
      (
        "/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`%`*/ /*!50003 TRIGGER `t` BEFORE INSERT ON "
          + "`items` FOR EACH ROW SET NEW.note = 'x' */;", "--skip-triggers"
      ),
      ("/*!50001 DROP VIEW IF EXISTS `v`*/;", "DEFINER"),
      (
        "/*!50001 CREATE ALGORITHM=UNDEFINED */ /*!50013 DEFINER=`root`@`%` SQL SECURITY "
          + "DEFINER */ /*!50001 VIEW `v` AS select 1 AS `1` */;", "DEFINER"
      ),
    ])
  func optionLinesRefused(line: String, option: String) throws {
    let script = Self.replacing(
      "UNLOCK TABLES;", with: ["UNLOCK TABLES;", line], in: MySQLDumpFixtures.mysqlDump)
    let refused = try #require(Self.refusal(script), "\(line)")
    #expect(refused.reason.contains(option), "\(line): \(refused.reason)")
  }
}
