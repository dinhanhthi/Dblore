// SQLClassifierBypassTests.swift
// Inputs whose PostgreSQL parse contains a write must never be classified as read-only safe

import Foundation
import Testing

@testable import SQLNotebook

@Suite("SQL Classifier - Fail-closed bypasses")
@MainActor
struct SQLClassifierBypassTests {

  private func classify(_ sql: String) -> [ClassifiedStatement] {
    SQLStatementClassifier.classify(sql)
  }

  private func kinds(_ sql: String) -> [StatementKind] {
    classify(sql).map(\.kind)
  }

  // MARK: - Invariant

  nonisolated static let writeRepros: [String] = [
    // 1. Nested block comments
    "/* /* */ SELECT '*/ DELETE FROM t --'",
    // 2. Non-ASCII dollar-quote tag
    "WITH a AS (SELECT $€$'$€$) DELETE FROM t --'",
    // 3. Data-modifying WITH after CYCLE
    "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<3) "
      + "CYCLE n SET is_cycle USING path DELETE FROM users",
    // 4. Quoted EXPLAIN options
    "EXPLAIN (VERBOSE, \"analyze\") DELETE FROM t",
    "EXPLAIN (\"analyze\") DELETE FROM t",
    // 5. CRLF line comments
    "SELECT 1 -- c\r\n; DROP TABLE t",
    "-- c\r\nSELECT 1;\r\nDROP TABLE t",
    // 6. standard_conforming_strings = off
    #"WITH a AS (SELECT 'x\'') DELETE FROM t --'"#,
    // 7. Grapheme clusters fusing ASCII syntax with combining / prepend scalars
    "WITH a AS (SELECT 'x'\u{301}) DELETE FROM t --'",
    "WITH a AS (SELECT 1 /* */\u{301}) DELETE FROM t",
    "WITH a AS (SELECT 1 /*\u{301} ' */) DELETE FROM t --'",
    "WITH a AS (SELECT \u{600}'x') DELETE FROM t --'",
    // 8. Only PostgreSQL whitespace separates tokens (U+00A0 / U+3000 are identifier chars)
    "WITH a AS (SELECT \u{A0}E'\\') DELETE FROM t --'",
    "WITH a AS (SELECT \u{3000}E'\\') DELETE FROM t --'",
    // 9. Back-to-back dollar-quoted strings
    "WITH a AS (SELECT $$x$$$$'$$) DELETE FROM t --'",
    // 10. Nested WITH whose body ends in SEARCH / CYCLE followed by DML
    nestedSearchRepro,
    nestedCycleRepro,
    // 11. Look-alike scalars never fold into ASCII keywords
    "WITH x AS (SELECT 1) SELECT * FROM t FOR NO \u{212A}EY UPDATE",
    "EXPLAIN (ANALYZE fal\u{17F}e) DELETE FROM t",
    // 12. SELECT ... INTO inside a parenthesized main query after WITH
    "WITH x AS (SELECT 1) (SELECT * INTO t FROM x)",
    "WITH x AS (SELECT 1) (SELECT 1 INTO t) UNION SELECT 2",
    "EXPLAIN ANALYZE WITH x AS (SELECT 1) (SELECT 1 INTO t)",
  ]

  @Test("A write in the PostgreSQL parse is never read-only safe", arguments: writeRepros)
  func writeIsNeverSafe(_ sql: String) {
    let statements = classify(sql)
    #expect(!statements.isEmpty)
    #expect(statements.contains { !$0.isReadOnlySafe })
  }

  // MARK: - 1. Nested block comments

  @Test("Nested block comment repro exposes the DELETE")
  func nestedCommentRepro() {
    let result = classify("/* /* */ SELECT '*/ DELETE FROM t --'")
    #expect(result.map(\.kind) == [.dml])
    #expect(result.first?.affectsAllRows == true)
  }

  @Test("Properly nested block comment is skipped as a whole")
  func nestedCommentSkipped() {
    #expect(kinds("/* a /* b */ c */ SELECT 1") == [.read])
    #expect(SQLTokenizer.splitStatements("/* a /* ; */ ; */ SELECT 1; SELECT 2").count == 2)
  }

  @Test("Nested block comments are comment-only")
  func nestedCommentOnly() {
    let manager = DatabaseConnectionManager()
    #expect(manager.isCommentOnlyStatement("/* a /* b */ c */"))
    #expect(!manager.isCommentOnlyStatement("/* a /* b */ c */ SELECT 1"))
    #expect(manager.isCommentOnlyStatement("/* a /* b */ SELECT 1"))
  }

  // MARK: - 2. Dollar-quote tags with non-ASCII characters

  @Test("Non-ASCII dollar-quote tag repro exposes the DELETE")
  func nonASCIITagRepro() {
    #expect(kinds("WITH a AS (SELECT $€$'$€$) DELETE FROM t --'") == [.dml])
  }

  @Test("Non-ASCII tags open dollar quotes; digits only continue a tag")
  func nonASCIITagSplitting() {
    #expect(SQLTokenizer.splitStatements("SELECT $€$a;b$€$; SELECT 2").count == 2)
    #expect(SQLTokenizer.splitStatements("SELECT $a€1$ x; $a€1$; SELECT 2").count == 2)
    #expect(SQLTokenizer.splitStatements("SELECT $1; SELECT 2").count == 2)
  }

  @Test("Non-ASCII character before $ belongs to the identifier")
  func nonASCIIIdentifierBeforeDollar() {
    #expect(SQLTokenizer.splitStatements("SELECT €$$ ; SELECT 2").count == 2)
  }

  // MARK: - 3. Data-modifying WITH after SEARCH / CYCLE

  nonisolated static let cycleRepro =
    "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<3) "
    + "CYCLE n SET is_cycle USING path DELETE FROM users"

  @Test("DELETE after a CYCLE clause is DML affecting all rows")
  func cycleRepro() {
    let result = classify(Self.cycleRepro)
    #expect(result.map(\.kind) == [.dml])
    #expect(result.first?.affectsAllRows == true)
  }

  @Test("Statement after a SEARCH clause is detected")
  func searchClause() {
    let prefix = "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<3) "
    let delete = classify(prefix + "SEARCH DEPTH FIRST BY n SET ord DELETE FROM users")
    #expect(delete.map(\.kind) == [.dml])
    #expect(delete.first?.affectsAllRows == true)
    let update = classify(prefix + "SEARCH BREADTH FIRST BY n SET ord UPDATE u SET a = 1 WHERE b")
    #expect(update.map(\.kind) == [.dml])
    #expect(update.first?.affectsAllRows == false)
    #expect(kinds(prefix + "SEARCH BREADTH FIRST BY n SET ord SELECT * FROM r") == [.read])
    #expect(kinds(prefix + "CYCLE n SET is_cycle USING path SELECT * FROM r") == [.read])
  }

  nonisolated static let nestedSearchRepro =
    "WITH a AS (WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<3) "
    + "SEARCH DEPTH FIRST BY n SET ord DELETE FROM users RETURNING 1) SELECT * FROM a"

  nonisolated static let nestedCycleRepro =
    "WITH a AS (WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<3) "
    + "CYCLE n SET is_cycle USING path UPDATE users SET x = 1 RETURNING 1) SELECT * FROM a"

  @Test(
    "DML after SEARCH / CYCLE inside a nested WITH is DML affecting all rows",
    arguments: [nestedSearchRepro, nestedCycleRepro])
  func nestedSearchCycleRepro(_ sql: String) {
    let result = classify(sql)
    #expect(result.map(\.kind) == [.dml])
    #expect(result.first?.hasReturning == true)
    #expect(result.first?.affectsAllRows == true)
  }

  @Test("Nested DML with its own WHERE does not affect all rows")
  func nestedSearchWithWhere() {
    let sql =
      "WITH a AS (WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<3) "
      + "SEARCH DEPTH FIRST BY n SET ord DELETE FROM users WHERE id = 1 RETURNING 1) "
      + "SELECT * FROM a"
    let result = classify(sql)
    #expect(result.map(\.kind) == [.dml])
    #expect(result.first?.affectsAllRows == false)
  }

  @Test("Nested row locks and ON CONFLICT DO UPDATE are not data-modifying parts")
  func nestedRowLocksAndOnConflict() {
    #expect(kinds("WITH a AS (SELECT * FROM t FOR UPDATE) SELECT * FROM a") == [.read])
    #expect(kinds("WITH a AS (SELECT * FROM t FOR NO KEY UPDATE) SELECT * FROM a") == [.read])
    let upsert = classify(
      "WITH a AS (INSERT INTO t VALUES (1) ON CONFLICT (id) DO UPDATE SET a = 1 RETURNING 1) "
        + "SELECT * FROM a")
    #expect(upsert.map(\.kind) == [.dml])
    #expect(upsert.first?.affectsAllRows == false)
  }

  @Test("Unreserved KEY as a column name does not hide the DELETE")
  func keyColumnName() {
    let sql =
      "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<3) "
      + "CYCLE n SET is_cycle USING key DELETE FROM users"
    #expect(kinds(sql) == [.dml])
  }

  @Test("Row locks and ON CONFLICT DO UPDATE are not data-modifying parts")
  func rowLocksAndOnConflict() {
    #expect(kinds("WITH x AS (SELECT 1) SELECT * FROM t FOR UPDATE") == [.read])
    #expect(kinds("WITH x AS (SELECT 1) SELECT * FROM t FOR NO KEY UPDATE") == [.read])
    #expect(kinds("SELECT * FROM t FOR NO KEY UPDATE") == [.read])
    let upsert = classify(
      "WITH x AS (SELECT 1) INSERT INTO t VALUES (1) ON CONFLICT (id) DO UPDATE SET a = 1")
    #expect(upsert.map(\.kind) == [.dml])
    #expect(upsert.first?.affectsAllRows == false)
  }

  // MARK: - 4. EXPLAIN options

  @Test("Quoted ANALYZE is detected; unrecognized EXPLAIN options fail closed")
  func explainQuotedOptions() {
    #expect(
      kinds("EXPLAIN (VERBOSE, \"analyze\") DELETE FROM t")
        == [.explain(inner: .dml, analyze: true)])
    #expect(kinds("EXPLAIN (\"analyze\") DELETE FROM t") == [.explain(inner: .dml, analyze: true)])
    #expect(kinds("EXPLAIN (VERBOSE, FOO) SELECT 1") == [.unknown])
  }

  @Test("Quoted EXPLAIN option names match only in lowercase (PostgreSQL does not fold them)")
  func explainRecognizedQuotedOptions() {
    #expect(kinds("EXPLAIN (\"verbose\") SELECT 1") == [.explain(inner: .read, analyze: false)])
    #expect(
      kinds("EXPLAIN (VERBOSE, \"analyze\" off) DELETE FROM t")
        == [.explain(inner: .dml, analyze: false)])
    #expect(
      kinds("EXPLAIN (verbose, Analyze) DELETE FROM t") == [.explain(inner: .dml, analyze: true)])
  }

  @Test("Plain EXPLAIN of an unknown statement is not read-only safe")
  func explainUnknownInner() {
    let result = classify("EXPLAIN (FOO) DELETE FROM t")
    #expect(result.allSatisfy { !$0.isReadOnlySafe })
    #expect(SQLStatementClassifier.summary(result).hasUnknown)
    #expect(classify("EXPLAIN DELETE FROM t").allSatisfy { $0.isReadOnlySafe })
  }

  // MARK: - 5. CRLF and embedded semicolons

  @Test("CRLF ends a line comment in the splitter")
  func crlfLineComment() {
    #expect(kinds("SELECT 1 -- c\r\n; DROP TABLE t") == [.read, .ddl])
    #expect(kinds("-- c\r\nSELECT 1;\r\nDROP TABLE t") == [.read, .ddl])
    #expect(kinds("SELECT 1 -- c\r; DROP TABLE t") == [.read, .ddl])
  }

  @Test("CRLF ends a line comment in isCommentOnlyStatement")
  func crlfCommentOnly() {
    let manager = DatabaseConnectionManager()
    #expect(manager.isCommentOnlyStatement("-- c\r\n"))
    #expect(!manager.isCommentOnlyStatement("-- c\r\nSELECT 1"))
  }

  @Test("A statement containing an unsplit semicolon is never read")
  func embeddedSemicolon() {
    let result = SQLStatementClassifier.classifyStatement("SELECT 1; DROP TABLE t")
    #expect(result?.kind == .unknown)
    #expect(result?.isReadOnlySafe == false)
    #expect(SQLStatementClassifier.classifyStatement("SELECT (1; 2)")?.kind == .unknown)
  }

  @Test("Only CR and LF end a line comment (PostgreSQL rule)")
  func otherNewlinesDoNotEndComment() {
    let sql = "SELECT 1 -- c\u{2028}' \n; DELETE FROM t; --'"
    #expect(classify(sql).contains { !$0.isReadOnlySafe })
  }

  // MARK: - 6. Backslash in standard strings

  @Test("Backslash in a plain string fails closed")
  func backslashInPlainString() {
    #expect(kinds(#"WITH a AS (SELECT 'x\'') DELETE FROM t --'"#) == [.unknown])
    #expect(kinds(#"SELECT 'a\b'"#) == [.unknown])
    #expect(classify(#"SELECT 'a\b'"#).allSatisfy { !$0.isReadOnlySafe })
    #expect(kinds("SELECT 'ab'") == [.read])
    #expect(kinds(#"SELECT E'a\b'"#) == [.read])
    #expect(kinds(#"SELECT $$a\b$$"#) == [.read])
    #expect(kinds(#"SELECT "a\b" FROM t"#) == [.read])
  }

  // MARK: - 11. ASCII-only case folding

  @Test("Words fold only ASCII letters; non-ASCII scalars are kept as typed")
  func asciiOnlyWordFolding() {
    #expect(
      SQLTokenizer.tokens("sel\u{17F}ct \u{212A}ey \u{131}nsert \u{FB01}x")
        .map { Array($0.text.unicodeScalars) }
        == ["SEL\u{17F}CT", "\u{212A}EY", "\u{131}NSERT", "\u{FB01}X"].map {
          Array($0.unicodeScalars)
        })
    #expect(SQLTokenizer.tokens("select Key").map(\.text) == ["SELECT", "KEY"])
  }

  @Test("KELVIN SIGN KEY is not part of a FOR NO KEY UPDATE row lock")
  func kelvinSignRowLock() {
    // A plain `SELECT 1 FOR NO \u{212A}EY UPDATE` is a PostgreSQL syntax error (the look-alike
    // is an identifier, not KEY). Inside WITH the UPDATE must count as a statement start.
    let result = classify("WITH x AS (SELECT 1) SELECT * FROM t FOR NO \u{212A}EY UPDATE")
    #expect(result.map(\.kind) == [.dml])
    #expect(result.allSatisfy { !$0.isReadOnlySafe })
    // SELECT-headed statements are not scanned for DML at their outermost depth (only nested
    // DML fails closed); the server rejects this text as a syntax error, so `.read` runs nothing.
    #expect(kinds("SELECT 1 FOR NO \u{212A}EY UPDATE") == [.read])
  }

  @Test("Look-alike first keyword is unknown, not DML or read")
  func dotlessIKeyword() {
    let result = classify("\u{131}NSERT INTO t VALUES (1)")
    #expect(result.map(\.kind) == [.unknown])
    #expect(result.allSatisfy { !$0.isReadOnlySafe })
  }

  @Test("Look-alike EXPLAIN ANALYZE value is not false")
  func longSExplainValue() {
    let result = classify("EXPLAIN (ANALYZE fal\u{17F}e) DELETE FROM t")
    #expect(result.map(\.kind) == [.explain(inner: .dml, analyze: true)])
    #expect(result.allSatisfy { !$0.isReadOnlySafe })
    #expect(
      kinds("EXPLAIN (ANALYZE FaLsE) DELETE FROM t") == [.explain(inner: .dml, analyze: false)])
  }

  @Test("Quoted non-lowercase EXPLAIN option is unknown and fails closed")
  func quotedUppercaseExplainOption() {
    let result = classify("EXPLAIN (\"ANALYZE\" false) DELETE FROM t")
    #expect(result.allSatisfy { !$0.isReadOnlySafe })
    #expect(SQLStatementClassifier.summary(result).hasUnknown)
    #expect(kinds("EXPLAIN (VERBOSE, \"Analyze\" off) DELETE FROM t") == [.unknown])
  }

  // MARK: - 12. SELECT INTO below the base depth / nested DML

  @Test(
    "SELECT INTO in a parenthesized main query after WITH is DML",
    arguments: [
      "WITH x AS (SELECT 1) (SELECT * INTO t FROM x)",
      "WITH x AS (SELECT 1) (SELECT 1 INTO t) UNION SELECT 2",
    ])
  func withParenthesizedSelectInto(_ sql: String) {
    #expect(kinds(sql) == [.dml])
  }

  @Test("EXPLAIN ANALYZE of a parenthesized SELECT INTO after WITH is a modification")
  func explainAnalyzeWithParenthesizedSelectInto() {
    let result = classify("EXPLAIN ANALYZE WITH x AS (SELECT 1) (SELECT 1 INTO t)")
    #expect(result.map(\.kind) == [.explain(inner: .dml, analyze: true)])
    #expect(SQLStatementClassifier.summary(result).hasModification)
  }

  @Test("SELECT INTO at any depth of a SELECT-headed statement is DML")
  func selectIntoAnyDepth() {
    #expect(kinds("SELECT * FROM (SELECT 1 INTO t) s") == [.dml])
    #expect(kinds("SELECT 1 UNION (SELECT 2 INTO t)") == [.dml])
  }

  @Test(
    "Nested data-modifying WITH in a SELECT / VALUES is never read (PostgreSQL rejects it)",
    arguments: [
      "SELECT * FROM (WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d) s",
      "SELECT (WITH d AS (UPDATE t SET a = 1 RETURNING a) SELECT a FROM d)",
      "VALUES ((WITH d AS (INSERT INTO t VALUES (1) RETURNING 1) SELECT 1))",
      "(SELECT 1) UNION (WITH d AS (DELETE FROM t RETURNING 1) SELECT 1)",
      "((SELECT 1)) UNION (WITH d AS (DELETE FROM t RETURNING 1) SELECT 1)",
    ])
  func nestedDMLInSelectFailsClosed(_ sql: String) {
    #expect(kinds(sql) == [.unknown])
  }

  @Test("Nested row locks in a SELECT stay read")
  func nestedRowLocksInSelect() {
    #expect(kinds("SELECT * FROM (SELECT * FROM t FOR UPDATE) s") == [.read])
    #expect(kinds("SELECT * FROM (SELECT * FROM t FOR NO KEY UPDATE) s") == [.read])
    #expect(kinds("SELECT * FROM (SELECT * FROM t FOR SHARE) s") == [.read])
    #expect(kinds("SELECT * FROM t WHERE id IN (SELECT id FROM u) FOR UPDATE") == [.read])
  }

  @Test("Quoted GUC names compare ASCII case-insensitively, like PostgreSQL")
  func quotedGUCNameCase() {
    #expect(kinds("SET \"Statement_Timeout\" = 0") == [.sessionSet(touchesBrake: true)])
    #expect(kinds("RESET \"LOCK_TIMEOUT\"") == [.sessionSet(touchesBrake: true)])
  }
}
