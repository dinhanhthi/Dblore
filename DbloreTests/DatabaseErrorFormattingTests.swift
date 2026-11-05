// DatabaseErrorFormattingTests.swift
// PostgreSQL server error text: `ERROR <sqlstate>: <message>` (or the severity the server sent,
// such as FATAL) with the server's detail and hint, the hint for an untyped bound parameter (42P08 / 42P18), and the statement timeout brake text
// (57014). A `PSQLError` with server fields can only be built inside PostgresNIO, so the tests
// call the formatting of those fields.

import Testing

@testable import Dblore

@Suite("PostgreSQL error formatting")
struct DatabaseErrorFormattingTests {
  private static func format(
    sqlState: String?, severity: String = "ERROR", message: String?, detail: String? = nil,
    hint: String? = nil, statementTimeoutSeconds: Int = 30
  ) -> String {
    PostgresSession.formatServerError(
      sqlState: sqlState, severity: severity, message: message, detail: detail, hint: hint,
      position: nil, query: nil, code: "server", statementTimeoutSeconds: statementTimeoutSeconds)
  }

  @Test("A server error reads ERROR <sqlstate>: <message>, then its detail and hint")
  func sqlStateDetailAndHint() {
    let text = Self.format(
      sqlState: "23505", message: "duplicate key value violates unique constraint \"t_pkey\"",
      detail: "Key (id)=(1) already exists.", hint: "Pick another id.")
    #expect(
      text
        == "ERROR 23505: duplicate key value violates unique constraint \"t_pkey\"\n\n"
        + "Detail: Key (id)=(1) already exists.\n\n💡 Hint: Pick another id.")
  }

  @Test("The severity the server sent replaces ERROR, such as FATAL for a refused login")
  func fatalSeverity() {
    let text = Self.format(
      sqlState: "28P01", severity: "FATAL",
      message: "password authentication failed for user \"app\"")
    #expect(text == "FATAL 28P01: password authentication failed for user \"app\"")
  }

  @Test("An untyped bound parameter (42P08) gets the cast hint")
  func untypedParameterHint() {
    let text = Self.format(
      sqlState: "42P08", message: "could not determine data type of parameter $1")
    #expect(
      text
        == "ERROR 42P08: could not determine data type of parameter $1\n\n"
        + "💡 Hint: Cast the parameter where it is first used, e.g. :name::integer IS NULL")
  }

  @Test("The statement timeout brake (57014) names the connection's limit")
  func statementTimeoutText() {
    let text = Self.format(
      sqlState: "57014", message: "canceling statement due to statement timeout",
      statementTimeoutSeconds: 7)
    #expect(
      text
        == "Statement timed out after 7s (statement_timeout, SQLSTATE 57014) — change it in the "
        + "connection's Safety settings")
  }
}
