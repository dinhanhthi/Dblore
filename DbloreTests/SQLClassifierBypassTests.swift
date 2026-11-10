// SQLClassifierBypassTests.swift
// Inputs whose PostgreSQL parse contains a write must never be classified as read-only safe

import Foundation
import Testing

@testable import Dblore

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
    "WITH a AS (SELECT E'\\\u{301}') DELETE FROM t --'",
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
    #expect(manager.isCommentOnlyStatement("/* a /* b */ c */", dialect: .postgresql))
    #expect(!manager.isCommentOnlyStatement("/* a /* b */ c */ SELECT 1", dialect: .postgresql))
    #expect(manager.isCommentOnlyStatement("/* a /* b */ SELECT 1", dialect: .postgresql))
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

  @Test("REPLACE() in the main query of a WITH stays a read")
  func replaceFunctionAfterWith() {
    #expect(kinds("WITH c AS (SELECT 1) SELECT REPLACE(x,'a','b') FROM c") == [.read])
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
    #expect(manager.isCommentOnlyStatement("-- c\r\n", dialect: .postgresql))
    #expect(!manager.isCommentOnlyStatement("-- c\r\nSELECT 1", dialect: .postgresql))
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

  // MARK: - 13. SQL Server batches without `;`

  private func sqlserver(_ sql: String) -> [StatementKind] {
    SQLStatementClassifier.classify(sql, dialect: .sqlserver).map(\.kind)
  }

  /// T-SQL runs every statement of these; the splitter sees one statement in each.
  nonisolated static let sqlserverBatches: [String] = [
    "SELECT 1 DELETE FROM t",
    "SELECT 1 DROP TABLE x",
    "WITH a AS (SELECT 1 AS x) SELECT * FROM a DROP TABLE x",
    "WITH a AS (SELECT 1 AS x) DROP TABLE x",
    "WITH a AS (SELECT 1 AS x) EXEC ('DROP TABLE x')",
    "SELECT * FROM t WHERE id = 1 UPDATE t SET a = 2",
    "SELECT 1 INSERT INTO t VALUES (1)",
    "SELECT 1 TRUNCATE TABLE t",
    "SELECT 1 EXEC sp_configure 'show advanced options', 1",
    "SELECT 1 EXECUTE ('DROP TABLE x')",
    "SELECT 1 DBCC FREEPROCCACHE",
    "SELECT 1 USE master",
    "SELECT * FROM OPENROWSET(BULK 'C:\\data.csv', SINGLE_CLOB) AS r",
    "SELECT * FROM (SELECT 1 AS x) s GRANT CONTROL TO u",
    "SELECT a FROM t WHERE 1 = 1 DISABLE TRIGGER tr ON t",
    "SET NOCOUNT ON DELETE FROM t",
    "BEGIN TRAN DROP TABLE x",
    "COMMIT DELETE FROM t",
    "UPDATE t SET a = 1 WHERE id = 1 DROP TABLE x",
    "UPDATE t SET a = 1 WHERE id = 1 SET NOCOUNT ON",
    "INSERT INTO t EXEC ('DROP TABLE x')",
    "DELETE FROM t WHERE id = 1 ALTER TABLE t DROP COLUMN a",
    // Quotes the PostgreSQL scanner has and SQL Server does not, or lexes differently
    "SELECT [a'b] FROM t DROP TABLE x --'",
    "SELECT [a]]'] FROM t DROP TABLE x --'",
    "SELECT [a/*] FROM t DROP TABLE x /*]*/",
    "SELECT [a;b] FROM t DROP TABLE x",
    "SELECT E'\\' FROM t DROP TABLE x --'",
    "SELECT $$ FROM t DROP TABLE x --$$",
    // A number the server ends before the next word: `0x` is a binary constant
    "SELECT 0xTRUNCATE TABLE t",
    "SELECT 0xINSERT t VALUES (1)",
    "SELECT 0xKILL 53",
    "SELECT 0xSHUTDOWN",
    "SELECT 0xGRANT CONTROL TO u",
    "SELECT 0xWAITFOR DELAY '00:00:10'",
    "SELECT 0xPRINT 'x'",
    "SELECT 0xUSE master",
    "SELECT 1Ex DROP TABLE t",
    "SELECT 1eTRUNCATE TABLE t",
    // A currency sign is a money prefix (`£1`, a bare `£` too) and ends a word
    "SELECT £1TRUNCATE TABLE t",
    "SELECT ALL£1TRUNCATE TABLE t",
    "SELECT DISTINCT£1KILL 53",
    "SELECT x=£1TRUNCATE TABLE t",
    "SELECT €1KILL 53",
    "SELECT ₹1SHUTDOWN",
    "SELECT x=£TRUNCATE TABLE t",
    // A lone CR ends a `--` comment
    "SELECT 1 --x\r DROP TABLE t",
    // `USE HINT` / `USE PLAN` are query hints only inside `OPTION (...)`
    "SELECT 1 USE HINT",
    "SELECT 1 USE PLAN",
    // SELECT INTO creates a table: after a SET or transaction control it is a second statement
    "SET NOCOUNT ON SELECT * INTO dbo.t2 FROM dbo.t",
    "COMMIT SELECT * INTO dbo.t2 FROM dbo.t",
    "BEGIN TRAN SELECT * INTO dbo.t2 FROM dbo.t",
    "SAVE TRAN x SELECT * INTO dbo.t2 FROM dbo.t",
    "SET NOCOUNT ON SELECT 1",
    // ADD is reserved; END / MOVE / GET start a statement before CONVERSATION
    "SELECT 1 ADD SIGNATURE TO dbo.p BY CERTIFICATE c",
    "SELECT 1 ADD COUNTER SIGNATURE TO dbo.p BY CERTIFICATE c",
    "SELECT 1 END CONVERSATION @h",
    "SELECT 1 MOVE CONVERSATION @h TO @g",
    "SELECT 1 GET CONVERSATION GROUP @g FROM q",
    "ADD SIGNATURE TO dbo.p BY CERTIFICATE c",
    "END CONVERSATION @h",
    "MOVE CONVERSATION @h TO @g",
    "GET CONVERSATION GROUP @g FROM q",
    // A non-ASCII space or zero-width scalar outside quotes: the server may split a word there
    "SELECT a\u{00A0}DELETE FROM t",
    "SELECT a\u{200B}DELETE FROM t",
    "SELECT a\u{FEFF}DROP TABLE t",
    "SELECT a\u{2028}DROP TABLE t",
    "SELECT 1 --x\u{2028}DROP TABLE t",
  ]

  @Test(
    "SQL Server: a second statement with no `;` before it fails closed",
    arguments: sqlserverBatches)
  func sqlserverBatchFailsClosed(_ sql: String) {
    let statements = SQLStatementClassifier.classify(sql, dialect: .sqlserver)
    #expect(statements.map(\.kind) == [.unknown])
    for level in [ConnectionProtectionLevel.readOnly, .schemaOnly] {
      #expect(
        DatabaseConnectionManager.evaluate(
          statements, policy: ProtectionPolicy(protectionLevel: level), dialect: .sqlserver)
          != .allowed)
    }
  }

  @Test(
    "SQL Server: verbs in strings, quoted names, comments and query hints keep a read",
    arguments: [
      "SELECT * FROM t WHERE name = 'DROP TABLE x'",
      "SELECT N'DELETE FROM t' AS s",
      "SELECT [delete], [drop table], [a]]b], \"update\" FROM [exec]",
      "SELECT 1 -- DROP TABLE x",
      "SELECT 1 /* DELETE /* nested */ FROM t */",
      "SELECT path FROM t WHERE path = 'C:\\dir\\'",
      "SELECT a FROM t INNER MERGE JOIN s ON t.id = s.id",
      "SELECT a FROM t OPTION (USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION'), HASH JOIN)",
      "SELECT a FROM t ORDER BY a OFFSET 10 ROWS FETCH NEXT 5 ROWS ONLY",
      "SELECT 1 UNION ALL SELECT 2",
      "WITH a AS (SELECT 1 AS x) SELECT x FROM a",
      "SELECT * FROM t WITH (NOLOCK) WHERE CASE WHEN a = 1 THEN 1 END = 1",
      "SELECT a FROM t OPTION (USE PLAN N'<ShowPlanXML/>')",
      "SELECT 0x1F FROM t",
      "SELECT 0x, 0Xff, 1E5, 1e-5, 2.5E+3, 1.5, 1., .5, $1.00",
      "SELECT £1.50, €2 FROM t",
      "SELECT ¥3, ₩4, ₹5, ¢6, a$b, -$1 FROM t",
      "SELECT [a£1TRUNCATE TABLE t], \"b€1KILL 53\" FROM [c¥1DROP]",
      "SELECT 'x£1TRUNCATE TABLE t' AS s",
      "SELECT CASE WHEN a = 1 THEN 2 END FROM t",
      "SELECT move, get FROM t WHERE move = 1",
      "SELECT 'a\u{00A0}DELETE\u{200B}' AS s, [b\u{00A0}c], \"d\u{FEFF}e\" FROM t",
      "SELECT 1 -- a\u{00A0}b\u{200B}",
    ])
  func sqlserverReadStaysRead(_ sql: String) {
    #expect(sqlserver(sql) == [.read])
  }

  @Test(
    "SQL Server: a data change keeps its own SET, MERGE arms and main statement after WITH",
    arguments: [
      "UPDATE t SET a = 1 WHERE id = 1",
      "UPDATE TOP (5) t WITH (ROWLOCK) SET a = (SELECT MAX(b) FROM s) WHERE id = 1",
      "MERGE t USING s ON t.id = s.id WHEN MATCHED THEN UPDATE SET a = s.a "
        + "WHEN NOT MATCHED THEN INSERT (id) VALUES (s.id) "
        + "WHEN NOT MATCHED BY SOURCE THEN DELETE",
      "WITH a AS (SELECT id FROM s) DELETE FROM t WHERE id IN (SELECT id FROM a)",
      "WITH a AS (SELECT id FROM s) UPDATE t SET b = 1 WHERE id IN (SELECT id FROM a)",
      "INSERT INTO t (a) SELECT a FROM s",
      "DELETE FROM t OUTPUT deleted.id WHERE id = 1",
    ])
  func sqlserverWriteKeepsKind(_ sql: String) {
    #expect(sqlserver(sql) == [.dml])
  }

  @Test("SQL Server batch rules stay off on PostgreSQL")
  func sqlserverRulesAreDialectOnly() {
    // `update` is an unreserved column name on PostgreSQL; T-SQL reserves it
    #expect(kinds("SELECT update FROM t") == [.read])
    #expect(sqlserver("SELECT update FROM t") == [.unknown])
  }

  @Test("SQL Server lexes T-SQL numbers; PostgreSQL keeps digit runs")
  func sqlserverNumbers() {
    let sql = "SELECT 0x1F, 1.5, .5, 1E-5, 1eX, 0xTRUNCATE"
    #expect(
      SQLTokenizer.tokens(sql, dialect: .sqlserver).map(\.text) == [
        "SELECT", "0X1F", ",", "1.5", ",", ".5", ",", "1E-5", ",", "1", "EX", ",", "0X",
        "TRUNCATE",
      ])
    #expect(
      SQLTokenizer.tokens(sql, dialect: .postgresql).map(\.text) == [
        "SELECT", "0", "X1F", ",", "1", ".", "5", ",", ".", "5", ",", "1", "E", "-", "5", ",",
        "1", "EX", ",", "0", "XTRUNCATE",
      ])
    #expect(kinds("SELECT 0xTRUNCATE TABLE t") == [.read])
  }

  @Test("SQL Server: a currency sign is a symbol that ends a word, outside quotes only")
  func sqlserverCurrencySigns() {
    let sql = "SELECT ALL£1, x€y, a$b, [p£q], \"r€s\""
    #expect(
      SQLTokenizer.tokens(sql, dialect: .sqlserver).map(\.text) == [
        "SELECT", "ALL", "£", "1", ",", "X", "€", "Y", ",", "A$B", ",", "p£q", ",", "r€s",
      ])
    #expect(
      SQLTokenizer.tokens(sql, dialect: .postgresql).map(\.text) == [
        "SELECT", "ALL£1", ",", "X€Y", ",", "A$B", ",", "[", "P£Q", "]", ",", "r€s",
      ])
  }

  @Test(
    "SQL Server: a leading word T-SQL has no statement for fails closed",
    arguments: [
      "SHOW TABLES", "VALUES (1)", "TABLE t", "START TRANSACTION", "ABORT", "SAVEPOINT s1",
      "RELEASE SAVEPOINT s1", "RESET ALL", "PREPARE TRANSACTION 'x'",
    ])
  func sqlserverNonStatementWord(_ sql: String) {
    #expect(sqlserver(sql) == [.unknown])
    #expect(kinds(sql) != [.unknown])
  }

  @Test("SQL Server: T-SQL statements keep their kind")
  func sqlserverStatementWordsKeepKind() {
    for tcl in ["BEGIN TRAN", "COMMIT", "ROLLBACK", "SAVE TRAN s1"] {
      #expect(sqlserver(tcl) == [.tcl], "\(tcl)")
    }
    #expect(sqlserver("SET NOCOUNT ON") == [.sessionSet(touchesBrake: false)])
    #expect(sqlserver("SET @x = (SELECT COUNT(*) FROM t)") == [.sessionSet(touchesBrake: false)])
    #expect(sqlserver("SELECT 1 SELECT * INTO t2 FROM t") == [.dml])
    #expect(sqlserver("SELECT 1") == [.read])
    #expect(sqlserver("WITH a AS (SELECT 1 AS x) SELECT x FROM a") == [.read])
  }

  @Test("SQL Server has no EXPLAIN: a leading EXPLAIN fails closed")
  func sqlserverExplainIsUnknown() {
    #expect(sqlserver("EXPLAIN SELECT 1") == [.unknown])
    #expect(sqlserver("EXPLAIN ANALYZE DELETE FROM t") == [.unknown])
    #expect(kinds("EXPLAIN SELECT 1") == [.explain(inner: .read, analyze: false)])
  }
}
