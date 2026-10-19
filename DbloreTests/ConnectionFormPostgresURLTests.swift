// ConnectionFormPostgresURLTests.swift
// The PostgreSQL connection string field (`ConnectionFormContent.postgresURL(from:)`): a user or
// password with unencoded reserved characters (`?`, `/`, `#`, `@`, `:`) still parses, and an
// already percent-encoded one keeps its decoded value.

import Foundation
import Testing

@testable import Dblore

@Suite
struct ConnectionFormPostgresURLTests {
  private static let host = "c-da-cluster.example.postgres.cosmos.azure.com"

  private func url(password: String, user: String = "citus") throws -> URL {
    try #require(
      ConnectionFormContent.postgresURL(
        from: "postgresql://\(user):\(password)@\(Self.host):5432/app?sslmode=require"))
  }

  @Test(arguments: [
    "p?ss", "p/ss", "p#ss", "p@ss", "p:ss", "12?x", "a?b/c#d@e:f", "50%off", "p ss",
    "Abc@123#", "x7@kQ9#mZ", "p@1?x", "p@ss/word", "p@h/d?x",
  ])
  func rawReservedCharactersStayInThePassword(password: String) throws {
    let url = try url(password: password)
    #expect(url.password(percentEncoded: false) == password)
    #expect(url.user(percentEncoded: false) == "citus")
    #expect(url.host == Self.host)
    #expect(url.port == 5432)
    #expect(url.path == "/app")
    #expect(url.query == "sslmode=require")
  }

  @Test func percentEncodedPasswordIsDecodedOnce() throws {
    #expect(try url(password: "p%3Fss%2F").password(percentEncoded: false) == "p?ss/")
  }

  @Test func rawReservedCharactersInTheUser() throws {
    let url = try url(password: "pw", user: "us?er")
    #expect(url.user(percentEncoded: false) == "us?er")
    #expect(url.password(percentEncoded: false) == "pw")
  }

  @Test(arguments: [
    "?sslmode=require&application_name=me@laptop", "?sslrootcert=/certs@2/root.crt",
  ])
  func atSignInTheQueryStaysInTheQuery(query: String) throws {
    for password in ["p", "p?ss"] {
      let url = try #require(
        ConnectionFormContent.postgresURL(
          from: "postgresql://u:\(password)@\(Self.host):5432/app\(query)"))
      #expect(url.password(percentEncoded: false) == password)
      #expect(url.host == Self.host)
      #expect(url.path == "/app")
      #expect(url.query(percentEncoded: false) == String(query.dropFirst()))
    }
  }

  @Test func plainPasswordWithoutDatabaseOrQuery() throws {
    let url = try #require(ConnectionFormContent.postgresURL(from: "postgresql://u:p@my_db:5432"))
    #expect(url.password(percentEncoded: false) == "p")
    #expect(url.host == "my_db")
  }

  @Test func atSignInTheQueryWithAnUnderscoreHost() throws {
    let url = try #require(
      ConnectionFormContent.postgresURL(
        from: "postgresql://u:p@my_db:5432/app?application_name=me@laptop"))
    #expect(url.password(percentEncoded: false) == "p")
    #expect(url.host == "my_db")
  }

  @Test func rawAtSignInTheUserBeforeThePassword() throws {
    let url = try url(password: "p?ss", user: "citus@server")
    #expect(url.user(percentEncoded: false) == "citus@server")
    #expect(url.password(percentEncoded: false) == "p?ss")
    #expect(url.host == Self.host)
  }

  @Test func postgresSchemeAndNoUserInfo() throws {
    let url = try #require(ConnectionFormContent.postgresURL(from: "  postgres://localhost/app \n"))
    #expect(url.scheme == "postgresql")
    #expect(url.host == "localhost")
    #expect(url.user == nil)
  }

  @Test func otherSchemesAreRejected() {
    #expect(ConnectionFormContent.postgresURL(from: "mysql://u:p@localhost/app") == nil)
    #expect(ConnectionFormContent.postgresURL(from: "not a url") == nil)
  }
}
