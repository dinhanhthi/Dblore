// SQLTokenizerIncrementalSplitTests.swift
// The incremental split gives the whole-text split for any chunk boundary, and resumes its scan

import Foundation
import Testing

@testable import Dblore

@Suite("SQL Tokenizer - Incremental Split")
struct SQLTokenizerIncrementalSplitTests {

  private static let postgresInputs = [
    "SELECT 1; SELECT 2",
    "CREATE FUNCTION f() RETURNS int AS $fn$ BEGIN RETURN 1; END; $fn$ LANGUAGE plpgsql;"
      + " SELECT $$a;b$$, $1, a$b, $x$ $$; $x$; DO $$ BEGIN PERFORM 1; END $$;$$a$$$$b$$; SELECT 2",
    "SELECT /* a /* b; */ c; */ 1; -- x;\nSELECT 'it''s;', E'a\\';b', \"q;\"\"x\"; SELECT 'emoji 😀;'"
      + " AS \"列;🧪\" -- 😀;\r\nFROM t;\n;  ; SELECT 3 ;",
    "SELECT 1; SELECT 'open; x",
    "SELECT 1; SELECT $tag$ open; x",
    "SELECT 1; SELECT /* open /* x */; y",
    "SELECT 1;\n-- only a comment",
  ]

  private static let mysqlInputs = [
    "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END//\nDELIMITER ;\nSELECT 2; SELECT 3",
    "delimiter $$\nCREATE TRIGGER t BEFORE INSERT ON x FOR EACH ROW BEGIN SET @a = 1; END$$\n"
      + "delimiter ;\n",
    "DELIMITER $$\nab$$cd$$DELIMITER ;\nSELECT 1;",
    "DELIMITER $$\nx$$1.5$$y$$",
    "DELIMITER ab\nxabyabzab",
    "DELIMITER 1\nSELECT a1b1c",
    "DELIMITER ;;;\nSELECT 1;;;SELECT 2;;;;\nDELIMITER  \nSELECT 3;",
    "DELIMITER //\nSELECT '//', `//` # //\n; SELECT 1//",
    "SELECT delimiter FROM t; SELECT 2;\n-- setup\nDELIMITER //\nSELECT 1; SELECT 2//\nDELIMITER //",
    "SELECT 'it\\'s;', \"a\\\"b;\"; SELECT 5--1; SELECT 1 --\u{7F}x; d\nFROM t; SELECT 'é😀;';",
    "/*!40101 SET x = 1 */; /*M!999999\\- sandbox */\nSELECT 1 # c; d\n; SELECT `a``;`",
    MySQLDumpFixtures.mysqlDump,
    MySQLDumpFixtures.mariaDBDump,
  ]

  private static let sqliteInputs = [
    "CREATE TABLE a (id INTEGER PRIMARY KEY);\nCREATE TEMPORARY TRIGGER IF NOT EXISTS t AFTER"
      + " DELETE ON a BEGIN DELETE FROM b WHERE a_id = old.id; /* c; */ END -- done;\n;\n"
      + "INSERT INTO a VALUES (1); SELECT CASE WHEN 1 THEN 2 END; END; SELECT 3",
    "create temp trigger t before update on a begin select case when new.x > 0 then 1"
      + " else raise(abort, 'negative; no') end; end; SELECT 2",
    "EXPLAIN CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; END; SELECT 2",
    "CREATE TRIGGER \"end\" AFTER INSERT ON [a;b] BEGIN SELECT `x;`; END; SELECT '😀;'",
    "CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1;\u{0B}END; SELECT 2; END; SELECT 3",
    "CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; -- c\r; END;\n SELECT 2; END; SELECT 3",
    "SELECT $x; CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; END",
  ]

  private static let duckdbInputs = postgresInputs + ["SELECT 'a\\'; SELECT 2; SELECT $$b;$$"]

  @Test(
    "Every chunk size gives the whole split",
    arguments: [
      (SQLDialect.postgresql, postgresInputs), (.mysql, mysqlInputs), (.sqlite, sqliteInputs),
      (.duckdb, duckdbInputs),
    ])
  func everyChunkSize(dialect: SQLDialect, inputs: [String]) {
    let tokenizer = SQLTokenizer(dialect: dialect)
    for sql in inputs {
      let whole = tokenizer.splitStatements(sql)
      let scalars = Array(sql.unicodeScalars)
      for size in 1...64 {
        var state = SQLTokenizer.SplitState()
        var buffer: [Unicode.Scalar] = []
        var statements: [String] = []
        var offset = 0
        while offset < scalars.count {
          let end = min(offset + size, scalars.count)
          buffer.append(contentsOf: scalars[offset..<end])
          offset = end
          let part = tokenizer.splitStatements(scalars: buffer, isFinal: false, state: &state)
          #expect(part.consumed <= buffer.count)
          statements += part.statements
          buffer.removeFirst(part.consumed)
        }
        statements +=
          tokenizer.splitStatements(scalars: buffer, isFinal: true, state: &state)
          .statements
        #expect(statements == whole, "\(dialect) chunk \(size): \(sql.prefix(40))")
      }
    }
  }

  @Test("One long statement is emitted once, at the end, and each call resumes its scan")
  func longStatementResumes() {
    let tokenizer = SQLTokenizer(dialect: .mysql)
    let rows = (0..<14_000).map { "(\($0),'v\($0)')" }.joined(separator: ",")
    let sql = "INSERT INTO t VALUES " + rows
    let scalars = Array(sql.unicodeScalars)
    #expect(scalars.count > 200_000)
    var state = SQLTokenizer.SplitState()
    var buffer: [Unicode.Scalar] = []
    var offset = 0
    while offset < scalars.count {
      let end = min(offset + 1_024, scalars.count)
      buffer.append(contentsOf: scalars[offset..<end])
      offset = end
      let part = tokenizer.splitStatements(scalars: buffer, isFinal: false, state: &state)
      #expect(part.statements.isEmpty && part.consumed == 0)
      // The next call starts at the last lexeme, not at the start of the statement
      #expect(buffer.count - state.resume < 16)
    }
    let last = tokenizer.splitStatements(scalars: buffer, isFinal: true, state: &state)
    #expect(last.statements == [sql])
    #expect(last.consumed == buffer.count)
  }
}
