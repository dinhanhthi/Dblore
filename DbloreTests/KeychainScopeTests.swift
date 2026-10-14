// Keychain scope: only MySQL and MongoDB keys carry the engine. PostgreSQL, SQLite and DuckDB
// keep the legacy password key and certificate account byte for byte (existing items, no
// migration).

import Foundation
import Testing

@testable import Dblore

@Suite("Keychain scope")
@MainActor
struct KeychainScopeTests {
  private nonisolated static let historyKey = "ace.thi.dblore.connectionHistory"

  private static func config(_ type: DatabaseType, port: Int = 5432) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: type, host: "db.example", port: port, database: "app", username: "ada")
  }

  /// Password key and certificate account seen by every copy of the key formula.
  private static func passwordKeys(_ config: ConnectionConfig) -> Set<String> {
    let entry = ConnectionHistoryEntry(config: config)
    return [
      entry.keychainKey,
      Workspace.newUntitled(connection: config).connectionKeychainKey ?? "",
      Workspace(name: "w", connectionConfig: config).keychainKey ?? "",
    ]
  }

  @Test("Only MySQL and MongoDB have a Keychain scope")
  func scopes() {
    #expect(DatabaseType.postgresql.keychainScope == nil)
    #expect(DatabaseType.sqlite.keychainScope == nil)
    #expect(DatabaseType.duckdb.keychainScope == nil)
    #expect(DatabaseType.mysql.keychainScope == "MySQL")
    #expect(DatabaseType.mongodb.keychainScope == "MongoDB")
  }

  @Test(
    "Legacy engines keep the password key byte for byte",
    arguments: [DatabaseType.postgresql, .sqlite, .duckdb])
  func legacyPasswordKey(type: DatabaseType) {
    #expect(Self.passwordKeys(Self.config(type)) == ["db.example:5432:app:ada"])
  }

  @Test("A file engine keeps its legacy password key")
  func fileEngineLegacyKey() {
    let config = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: "/tmp/a.db", username: "")
    #expect(Self.passwordKeys(config) == [":0:/tmp/a.db:"])
  }

  @Test(
    "Legacy engines keep the certificate account byte for byte",
    arguments: [DatabaseType.postgresql, .sqlite, .duckdb])
  func legacyCertificateAccount(type: DatabaseType) {
    #expect(
      ClientCertificateStoreFactory.account(for: Self.config(type))
        == "v2|10:db.example|4:5432|3:app|3:ada")
  }

  @Test("MySQL password key carries the scope in every formula copy")
  func mysqlPasswordKey() {
    #expect(
      Self.passwordKeys(Self.config(.mysql, port: 3306))
        == ["v2|5:MySQL|10:db.example|4:3306|3:app|3:ada"])
  }

  @Test("MongoDB password key and certificate account carry the scope")
  func mongoDBKeys() {
    let config = Self.config(.mongodb, port: 27017)
    #expect(Self.passwordKeys(config) == ["v2|7:MongoDB|10:db.example|5:27017|3:app|3:ada"])
    #expect(
      ClientCertificateStoreFactory.account(for: config)
        == "v2|7:MongoDB|10:db.example|5:27017|3:app|3:ada")
  }

  @Test("Colons in a field never make a MySQL key equal a legacy key")
  func noColonCollision() {
    let mysql = ConnectionConfig(
      databaseType: .mysql, host: "5432", port: 3306, database: "app", username: "ada")
    let postgres = ConnectionConfig(
      databaseType: .postgresql, host: "MySQL", port: 5432, database: "3306",
      username: "app:ada")
    #expect(Self.passwordKeys(mysql).isDisjoint(with: Self.passwordKeys(postgres)))
  }

  @Test("MySQL certificate account carries the scope")
  func mysqlCertificateAccount() {
    #expect(
      ClientCertificateStoreFactory.account(for: Self.config(.mysql, port: 3306))
        == "v2|5:MySQL|10:db.example|4:3306|3:app|3:ada")
  }

  @Test("MySQL and PostgreSQL on the same tuple never share a slot")
  func noCrossEngineSharing() {
    let postgres = Self.config(.postgresql)
    let mysql = Self.config(.mysql)
    #expect(Self.passwordKeys(postgres).isDisjoint(with: Self.passwordKeys(mysql)))
    #expect(
      ClientCertificateStoreFactory.account(for: postgres)
        != ClientCertificateStoreFactory.account(for: mysql))
  }

  @Test("An undecodable saved row uses the same key as a decoded one")
  func rawRowKeys() throws {
    let suiteName = "ace.thi.Dblore.tests.keychain-scope.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    // No sslMode, so these rows do not decode and go through the raw path
    func row(_ type: String?, host: String) -> [String: Any] {
      var config: [String: Any] = [
        "host": host, "port": 3306, "database": "app", "username": "ada",
      ]
      config["databaseType"] = type
      return ["id": UUID().uuidString, "lastUsedAt": 0, "config": config]
    }
    let rows = [
      row("MySQL", host: "my"), row("PostgreSQL", host: "pg"), row(nil, host: "old"),
      row("FutureEngine", host: "future"),
    ]
    defaults.set(try JSONSerialization.data(withJSONObject: rows), forKey: Self.historyKey)

    #expect(
      SessionManager.savedConnectionKeys(defaults: defaults) == [
        "v2|5:MySQL|2:my|4:3306|3:app|3:ada", "pg:3306:app:ada", "old:3306:app:ada",
        "future:3306:app:ada",
      ])
  }

  @Test("Saving a MySQL connection stores its password under the scoped key")
  func savesScopedPassword() throws {
    let suiteName = "ace.thi.Dblore.tests.keychain-scope.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RecordingConnectionPasswordStore()
    var postgres = Self.config(.postgresql, port: 3306)
    postgres.password = "pg-secret"
    var mysql = Self.config(.mysql, port: 3306)
    mysql.password = "my-secret"

    SessionManager.saveConnection(postgres, defaults: defaults, passwords: store)
    SessionManager.saveConnection(mysql, defaults: defaults, passwords: store)

    #expect(store.loadPassword(forKey: "db.example:3306:app:ada") == "pg-secret")
    #expect(
      store.loadPassword(forKey: "v2|5:MySQL|10:db.example|4:3306|3:app|3:ada") == "my-secret")
    let history = SessionManager.loadHistory(defaults: defaults, passwords: store)
    #expect(Set(history.map(\.config.password)) == ["pg-secret", "my-secret"])
  }
}
