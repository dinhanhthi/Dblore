// SQLStatementFunctionCallTests.swift
// A capped read with no app transaction resets the session, which aborts the statement on the
// server. A SELECT that calls a function may write (`SELECT archive_row(id) FROM t`), so any
// function call (fail-safe: also pure ones such as `upper`, `count`, set-returning functions in
// FROM) makes the capped read drain instead of reset.

import Testing

@testable import Dblore

struct SQLStatementFunctionCallTests {
  @Test(
    "Plain column selects and SQL constructs call no function",
    arguments: [
      "SELECT * FROM t",
      "SELECT id, name FROM t WHERE id IN (1,2)",
      "SELECT * FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.id = t.id)",
      "SELECT * FROM t WHERE (a = 1 OR b = 2) AND NOT (c = 3)",
      "SELECT a FROM t JOIN u USING (id) JOIN v ON (v.id = t.id)",
      "VALUES (1), (2)",
      "TABLE t",
      "SELECT CAST(a AS int), ARRAY(SELECT 1), ROW(1, 2) FROM t",
      "SELECT * FROM (SELECT 1) s UNION (SELECT 2)",
      "WITH x AS (SELECT * FROM t) SELECT * FROM x",
      "SELECT 'upper(v)' FROM t -- count(*)",
    ])
  func noFunctionCall(_ sql: String) {
    #expect(!SQLStatementClassifier.mayCallFunctions(sql))
  }

  @Test(
    "Any function call counts (fail-safe)",
    arguments: [
      "SELECT archive_row(id) FROM t",
      "SELECT upper(name) FROM t",
      "SELECT count(*) FROM t",
      "SELECT * FROM generate_series(1,1e6)",
      "SELECT public.archive_row(id) FROM t",
      "SELECT \"ArchiveRow\"(id) FROM t",
      "SELECT nextval('s')",
      "SELECT sum(v) OVER (PARTITION BY id) FROM t",
      "WITH x AS (SELECT archive_row(id) FROM t) SELECT * FROM x",
    ])
  func functionCall(_ sql: String) {
    #expect(SQLStatementClassifier.mayCallFunctions(sql))
  }
}
