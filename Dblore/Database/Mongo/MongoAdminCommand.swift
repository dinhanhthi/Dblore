// MongoAdminCommand.swift
// One administration command of the Dblore mongosh subset (indexes, collections, views,
// databases), as
// `MongoCommand.admin` carries it: rendered back to canonical mongosh text and built into the
// server command document.

import Foundation

/// An administration command on the connection's database (or, for `createDatabase` and
/// `dropDatabase(database:)` with a name, on the named database). Option documents are raw
/// `MongoValue` documents, nil when none is written; `collMod` stores its document without the
/// `collMod` key (`render` and `commandDocument` put it first).
nonisolated enum MongoAdminCommand: Equatable, Sendable {
  typealias Field = MongoValue.Field

  case createIndex(collection: String, keys: MongoValue, options: MongoValue?)
  /// `index` is the index name (a string) or its key document.
  case dropIndex(collection: String, index: MongoValue)
  /// `hideIndex(name)` when `hidden`, else `unhideIndex(name)`.
  case setIndexHidden(collection: String, name: String, hidden: Bool)
  case createCollection(name: String, options: MongoValue?)
  case createView(name: String, source: String, pipeline: [MongoValue], options: MongoValue?)
  case drop(collection: String)
  case renameCollection(collection: String, to: String)
  case collMod(collection: String, options: MongoValue)
  /// A new database `database`, created with its first collection (`createCollection` options).
  case createDatabase(database: String, collection: String, options: MongoValue?)
  /// Drops `database`, or the connection's database when nil (`db.dropDatabase()`).
  case dropDatabase(database: String?)

  /// The target collection: the one created for `createCollection`, `createView` and
  /// `createDatabase`, the source for `renameCollection`, the database name for `dropDatabase`
  /// (empty for the connection's database).
  var collection: String {
    switch self {
    case .createIndex(let name, _, _), .dropIndex(let name, _), .setIndexHidden(let name, _, _),
      .createCollection(let name, _), .createView(let name, _, _, _), .drop(let name),
      .renameCollection(let name, _), .collMod(let name, _), .createDatabase(_, let name, _):
      name
    case .dropDatabase(let database):
      database ?? ""
    }
  }

  /// `drop`, `dropIndex` and `dropDatabase` remove data or an index for good.
  var isDestructive: Bool {
    switch self {
    case .drop, .dropIndex, .dropDatabase: true
    case .createIndex, .setIndexHidden, .createCollection, .createView, .renameCollection,
      .collMod, .createDatabase:
      false
    }
  }

  /// Every document or array argument (keys, options, index key, pipeline), for the server-side
  /// JavaScript scan.
  var documentArguments: [MongoValue] {
    switch self {
    case .createIndex(_, let keys, let options): [keys] + (options.map { [$0] } ?? [])
    case .dropIndex(_, let index): [index]
    case .createCollection(_, let options), .createDatabase(_, _, let options):
      options.map { [$0] } ?? []
    case .createView(_, _, let pipeline, let options):
      [.array(pipeline)] + (options.map { [$0] } ?? [])
    case .collMod(_, let options): [options]
    case .setIndexHidden, .drop, .renameCollection, .dropDatabase: []
    }
  }

  /// Canonical mongosh text: the collection helpers `createIndex`, `dropIndex`, `hideIndex`,
  /// `unhideIndex`, `drop()` and `renameCollection`, the database helpers `createCollection` and
  /// `createView`, and `db.runCommand({collMod: …})`; `db.getSiblingDB("<db>")` then
  /// `createCollection` or `dropDatabase()`, and `db.dropDatabase()`. Options only when set.
  func render() -> String {
    switch self {
    case .createIndex(let name, let keys, let options):
      return MongoCommand.call(name, "createIndex", [keys] + (options.map { [$0] } ?? []))
    case .dropIndex(let name, let index):
      return MongoCommand.call(name, "dropIndex", [index])
    case .setIndexHidden(let name, let index, let hidden):
      return MongoCommand.call(name, hidden ? "hideIndex" : "unhideIndex", [.string(index)])
    case .createCollection(let name, let options):
      return Self.databaseCall("createCollection", [.string(name)] + (options.map { [$0] } ?? []))
    case .createView(let name, let source, let pipeline, let options):
      return Self.databaseCall(
        "createView",
        [.string(name), .string(source), .array(pipeline)] + (options.map { [$0] } ?? []))
    case .drop(let name):
      return MongoCommand.call(name, "drop", [])
    case .renameCollection(let name, let target):
      return MongoCommand.call(name, "renameCollection", [.string(target)])
    case .collMod(let name, let options):
      return Self.databaseCall(
        "runCommand", [.document([Field("collMod", .string(name))] + Self.fields(of: options))])
    case .createDatabase(let database, let name, let options):
      return Self.databaseCall(
        "createCollection", [.string(name)] + (options.map { [$0] } ?? []), in: database)
    case .dropDatabase(let database):
      return Self.databaseCall("dropDatabase", [], in: database)
    }
  }

  /// The server command and the database it runs in: `database` for every command but
  /// `renameCollection`, which runs in `admin` with `<database>.<name>` namespaces and
  /// `dropTarget: false`, and the database commands, which run in their named database
  /// (`dropDatabase` without a name in `database`). A `createIndex` without a `name` option gets
  /// the drivers' generated name.
  func commandDocument(in database: String) -> (fields: [Field], database: String) {
    switch self {
    case .createIndex(let name, let keys, let options):
      var spec = [Field("key", keys)]
      let optionFields = options.map(Self.fields(of:)) ?? []
      if !optionFields.contains(where: { $0.key == "name" }) {
        spec.append(Field("name", .string(Self.indexName(keys))))
      }
      return (
        [
          Field("createIndexes", .string(name)),
          Field("indexes", .array([.document(spec + optionFields)])),
        ],
        database
      )
    case .dropIndex(let name, let index):
      return ([Field("dropIndexes", .string(name)), Field("index", index)], database)
    case .setIndexHidden(let name, let index, let hidden):
      return (
        [
          Field("collMod", .string(name)),
          Field(
            "index", .document([Field("name", .string(index)), Field("hidden", .bool(hidden))])),
        ],
        database
      )
    case .createCollection(let name, let options):
      return ([Field("create", .string(name))] + (options.map(Self.fields(of:)) ?? []), database)
    case .createView(let name, let source, let pipeline, let options):
      return (
        [
          Field("create", .string(name)), Field("viewOn", .string(source)),
          Field("pipeline", .array(pipeline)),
        ] + (options.map(Self.fields(of:)) ?? []),
        database
      )
    case .drop(let name):
      return ([Field("drop", .string(name))], database)
    case .renameCollection(let name, let target):
      return (
        [
          Field("renameCollection", .string("\(database).\(name)")),
          Field("to", .string("\(database).\(target)")), Field("dropTarget", .bool(false)),
        ],
        "admin"
      )
    case .collMod(let name, let options):
      return ([Field("collMod", .string(name))] + Self.fields(of: options), database)
    case .createDatabase(let target, let name, let options):
      return ([Field("create", .string(name))] + (options.map(Self.fields(of:)) ?? []), target)
    case .dropDatabase(let target):
      return ([Field("dropDatabase", .int32(1))], target ?? database)
    }
  }

  /// The drivers' index name: `<field>_<kind>` per key, joined by `_` (`a_1_b_-1`, `a_text`,
  /// `$**_1`, `loc_2dsphere`). A whole double is written as an integer.
  private static func indexName(_ keys: MongoValue) -> String {
    fields(of: keys).map { "\($0.key)_\(kindText($0.value))" }.joined(separator: "_")
  }

  private static func kindText(_ value: MongoValue) -> String {
    switch value {
    case .int32(let number): String(number)
    case .int64(let number): String(number)
    case .double(let number): Int(exactly: number).map(String.init) ?? String(number)
    case .string(let text): text
    default: MongoCommand.value(value)
    }
  }

  private static func fields(of value: MongoValue) -> [Field] {
    guard case .document(let fields) = value else { return [] }
    return fields
  }

  /// `db.<method>(…)`, or `db.getSiblingDB("<database>").<method>(…)` when `database` is set.
  private static func databaseCall(
    _ method: String, _ arguments: [MongoValue], in database: String? = nil
  ) -> String {
    let target = database.map { "db.getSiblingDB(\(MongoCommand.value(.string($0))))" } ?? "db"
    return "\(target).\(method)(\(arguments.map(MongoCommand.value).joined(separator: ", ")))"
  }
}

/// The names `createDatabase` and `dropDatabase` accept.
nonisolated enum MongoDatabaseName {
  static let maxBytes = 63
  /// The server's own databases: never created or dropped from Dblore (any letter case).
  static let reserved: Set<String> = ["admin", "local", "config"]
  /// Checked as UTF-8 bytes, so a combining mark cannot hide one inside a larger character.
  private static let forbidden: Set<UInt8> = Set("/\\. \"$*<>:|?\0".utf8)

  /// Why `name` cannot be created or dropped, nil when it can.
  static func validate(_ name: String) -> String? {
    if name.isEmpty { return "Enter a database name" }
    if name.utf8.count > maxBytes { return "A database name is at most \(maxBytes) bytes" }
    if name.utf8.contains(where: forbidden.contains) {
      return "A database name cannot contain spaces, the null character or / \\ . \" $ * < > : | ?"
    }
    if reserved.contains(name.lowercased()) {
      return "The \(name) database is reserved by the server"
    }
    return nil
  }
}
