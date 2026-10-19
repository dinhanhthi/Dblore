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

  @Test("A saved Mongo query reopens under its own collection only")
  func mongoQueryIsolation() {
    let store = makeStore()
    let config = ConnectionConfig(databaseType: .mongodb, host: "h", port: 27017, database: "db")
    let users = SavedFilterStore.key(for: config, schema: "db", name: "users")
    var options = MongoQueryOptions()
    options.limit = "10"
    store.saveMongoQuery(filter: "{a: 1}", options: options, named: "mine", for: users)
    let saved = store.listMongoQueries(for: users)
    #expect(saved.map(\.name) == ["mine"])
    #expect(saved.first?.filter == "{a: 1}")
    #expect(saved.first?.options == options)
    #expect(
      store.listMongoQueries(for: SavedFilterStore.key(for: config, schema: "db", name: "orders"))
        .isEmpty)
  }

  @Test("A saved Mongo pipeline round-trips and saving under its name replaces it")
  func mongoPipelineRoundTripAndReplace() {
    let store = makeStore()
    let config = ConnectionConfig(databaseType: .mongodb, host: "h", port: 27017, database: "db")
    let users = SavedFilterStore.key(for: config, schema: "db", name: "users")
    var options = MongoQueryOptions()
    options.maxTimeMS = "500"
    let first = [
      SavedMongoPipeline.Stage(operator: "$match", body: "{a: 1}", isEnabled: true),
      SavedMongoPipeline.Stage(operator: "$limit", body: "5", isEnabled: false),
    ]
    store.saveMongoPipeline(stages: first, options: options, named: "mine", for: users)
    let saved = store.listMongoPipelines(for: users)
    #expect(saved.map(\.name) == ["mine"])
    #expect(saved.first?.stages == first)
    #expect(saved.first?.options == options)

    let second = [SavedMongoPipeline.Stage(operator: "$sort", body: "{a: -1}", isEnabled: true)]
    store.saveMongoPipeline(stages: second, options: .init(), named: "mine", for: users)
    let replaced = store.listMongoPipelines(for: users)
    #expect(replaced.count == 1)
    #expect(replaced.first?.id == saved.first?.id)
    #expect(replaced.first?.stages == second)
    #expect(replaced.first?.options == MongoQueryOptions())
    #expect(
      store.listMongoPipelines(for: SavedFilterStore.key(for: config, schema: "db", name: "orders"))
        .isEmpty)
  }

  @Test("A pipeline saved without options or stage enabled flags still decodes")
  func decodesPipelineWithoutOptionsOrEnabledFlag() {
    let name = "ace.thi.Dblore.tests.savedFilters.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    let json = """
      {
        "\(key())": [
          {
            "id": "\(id.uuidString)",
            "name": "old",
            "stages": [{"operator": "$match", "body": "{a: 1}"}]
          }
        ]
      }
      """
    defaults.set(Data(json.utf8), forKey: "ace.thi.dblore.savedMongoPipelines")
    let saved = SavedFilterStore(defaults: defaults).listMongoPipelines(for: key())
    #expect(saved.count == 1)
    #expect(saved.first?.id == id)
    #expect(saved.first?.name == "old")
    #expect(
      saved.first?.stages == [
        SavedMongoPipeline.Stage(operator: "$match", body: "{a: 1}", isEnabled: true)
      ])
    #expect(saved.first?.options == MongoQueryOptions())
    defaults.removePersistentDomain(forName: name)
  }

  @Test("A view preference round-trips per collection; unknown values read as grid and 100")
  func mongoViewPreferencePerCollection() {
    let store = makeStore()
    let config = ConnectionConfig(databaseType: .mongodb, host: "h", port: 27017, database: "db")
    let users = SavedFilterStore.key(for: config, schema: "db", name: "users")
    let orders = SavedFilterStore.key(for: config, schema: "db", name: "orders")
    let json = MongoViewPreference(mode: .json, pageSize: 250)
    store.saveMongoViewPreference(json, for: users)
    store.saveMongoViewPreference(MongoViewPreference(mode: .documents, pageSize: 50), for: orders)
    #expect(store.mongoViewPreference(for: users) == json)
    #expect(store.mongoViewPreference(for: users)?.mode == .json)
    #expect(store.mongoViewPreference(for: orders)?.mode == .documents)
    #expect(store.mongoViewPreference(for: orders)?.pageSize == 50)
    #expect(
      store.mongoViewPreference(for: SavedFilterStore.key(for: config, schema: "db", name: "x"))
        == nil)

    store.saveMongoViewPreference(
      MongoViewPreference(displayMode: "bogus", pageSize: 7), for: users)
    #expect(store.mongoViewPreference(for: users)?.mode == .grid)
    #expect(store.mongoViewPreference(for: users)?.pageSize == 100)
  }

  @Test("A condition saved without the empty-string flag still decodes")
  func decodesConditionWithoutEmptyStringFlag() throws {
    let name = "ace.thi.Dblore.tests.savedFilters.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let filterID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let conditionID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let json = """
      {
        "\(key())": [
          {
            "id": "\(filterID.uuidString)",
            "name": "old",
            "filter": {
              "conditions": [
                {
                  "id": "\(conditionID.uuidString)",
                  "column": "name",
                  "op": "equals",
                  "value": "1",
                  "connector": "and"
                }
              ]
            }
          }
        ]
      }
      """
    defaults.set(Data(json.utf8), forKey: "ace.thi.dblore.savedFilters")
    let saved = SavedFilterStore(defaults: defaults).list(for: key())
    #expect(saved.count == 1)
    #expect(saved[0].name == "old")
    #expect(saved[0].filter.conditions.count == 1)
    #expect(saved[0].filter.conditions[0].id == conditionID)
    #expect(saved[0].filter.conditions[0].column == "name")
    #expect(saved[0].filter.conditions[0].value == "1")
    #expect(saved[0].filter.conditions[0].emptyStringIsValue == false)
    #expect(saved[0].filter.whereClause(dialect: .postgresql) == #""name" = '1'"#)
    defaults.removePersistentDomain(forName: name)
  }

  @Test("A condition encodes every key, including the empty-string flag, and decodes back")
  func conditionEncodingRoundTrips() throws {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    let condition = FilterCondition(
      id: id, column: "code", op: .notEquals, value: "", connector: .or, emptyStringIsValue: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let json = String(decoding: try encoder.encode(condition), as: UTF8.self)
    #expect(
      json
        == #"{"column":"code","connector":"or","emptyStringIsValue":true,"id":"\#(id.uuidString)","op":"notEquals","value":""}"#
    )
    #expect(try JSONDecoder().decode(FilterCondition.self, from: Data(json.utf8)) == condition)
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
