// SavedFilterStoreTests.swift
// Saved filters are keyed by connection + table and persisted as JSON in UserDefaults.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Saved Filter Store Tests")
struct SavedFilterStoreTests {
  private func makeStore() -> SavedFilterStore {
    let name = "ace.thi.Dblore.tests.savedFilters.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return SavedFilterStore(defaults: defaults)
  }

  /// Fixed condition id, so equal columns give equal filters
  private func filter(_ column: String) -> TableFilter {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    return TableFilter(conditions: [
      FilterCondition(id: id, column: column, op: .equals, value: "1")
    ])
  }

  private func key(
    _ database: String = "app", table: String = "users", type: DatabaseType = .postgresql
  ) -> String {
    SavedFilterStore.key(
      for: ConnectionConfig(databaseType: type, host: "h", port: 5432, database: database),
      schema: "public", name: table)
  }

  @Test("Key is databaseType|host|port|database|schema.name")
  func keyFormat() {
    #expect(key() == "PostgreSQL|h|5432|app|public.users")
  }

  @Test("Save then list round-trips the filter")
  func roundTrip() {
    let store = makeStore()
    store.save(filter("a"), named: "mine", for: key())
    let saved = store.list(for: key())
    #expect(saved.count == 1)
    #expect(saved[0].name == "mine")
    #expect(saved[0].filter == filter("a"))
  }

  @Test("Saving under an existing name replaces the filter")
  func replaceByName() {
    let store = makeStore()
    store.save(filter("a"), named: "mine", for: key())
    let id = store.list(for: key())[0].id
    store.save(filter("b"), named: "mine", for: key())
    let saved = store.list(for: key())
    #expect(saved.count == 1)
    #expect(saved[0].id == id)
    #expect(saved[0].filter == filter("b"))
  }

  @Test("Delete removes only the given filter")
  func delete() {
    let store = makeStore()
    store.save(filter("a"), named: "one", for: key())
    store.save(filter("b"), named: "two", for: key())
    store.delete(id: store.list(for: key())[0].id, for: key())
    #expect(store.list(for: key()).map(\.name) == ["two"])
  }

  @Test("Tables and connections are isolated")
  func isolation() {
    let store = makeStore()
    store.save(filter("a"), named: "mine", for: key())
    #expect(store.list(for: key(table: "orders")).isEmpty)
    #expect(store.list(for: key("other")).isEmpty)
    #expect(store.list(for: key(type: .sqlite)).isEmpty)
  }

  @Test("Undecodable data gives an empty list")
  func decodeFailure() {
    let name = "ace.thi.Dblore.tests.savedFilters.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.set(Data("not json".utf8), forKey: "ace.thi.dblore.savedFilters")
    #expect(SavedFilterStore(defaults: defaults).list(for: key()).isEmpty)
    defaults.removePersistentDomain(forName: name)
  }
}
