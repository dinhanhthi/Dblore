// MongoSchemaIntrospector.swift
// MongoDB catalog for one open `MongoSession`. MongoDB has no schemas: the schema of every
// relation is the session's database (`MongoSession.databaseName`, `test` when the connection
// names none), as MySQL uses its connected database, so `allColumns` keys read
// `"<database>.<collection>"` (`namesSchema` is false: the sidebar never shows it).
//
// - tables: collections and time series collections from `listCollections` (full entries, so
//   the `listCollections` privilege is needed: `read`/`readWrite` have it). Names starting with
//   `system.` (`system.views`, `system.buckets.*`, `system.profile`, …) are hidden. The first 200
//   collections by name carry their `count` (see rowCount) for the sidebar badge, at most 8 in
//   flight, each with the sampling `maxTimeMS`. They are pipelined on the session's connection
//   (the server still runs them one by one), so a load pays about one round trip, not one per
//   collection. A time series has no badge (its count unpacks every bucket). A count that fails
//   leaves that badge out and is logged. `collectionFlags` marks capped, time series and
//   clustered collections (`options.capped`, `options.timeseries`, `options.clusteredIndex`).
// - views: `type: "view"`, `definition` = the view's pipeline in mongosh notation, `source` =
//   `options.viewOn`.
// - allColumns: fields sampled from the first 200 relations by name (the rest get no columns),
//   each with its own `maxTimeMS` (2,000 ms, or the statement timeout when shorter; the session's
//   statement timeout is not changed). A collection samples `aggregate([{$sample: {size: 100}}])`
//   and falls back to `find().limit(100)` when that fails; a view always reads with find. A
//   relation whose sampling fails gets no columns and is logged; the rest still load. Cancel
//   (killOp of the running sample) stops the whole read.
// - Columns: dot paths into embedded documents down to three levels (`a`, `a.b`, `a.b.c`); an
//   array is one column typed `array` (its elements are not entered), as is a JavaScript value.
//   A field name containing a dot reads like a path. Types are `MongoBSONMapping`'s (`$type`
//   aliases, `mixed` when the samples disagree, null never makes a column mixed); `_id` comes
//   first and is the primary key.
// - rowCount: the `count` command without a query (what `estimatedDocumentCount` sends): the
//   collection's metadata count, so it is instant on large collections; exact except after an
//   unclean shutdown or with orphaned documents on a sharded cluster. A view counts by running
//   its pipeline.
// - primaryKeyColumns: always `_id`. editTable: nil (SQL inline edits never target MongoDB;
//   document edits build their own target). tableStructure: refused (`supportsStructure` false).
// - Functions, procedures, triggers, users, roles and foreign keys: empty.
// - Collection identity: `TableRef.mongodb(database:collection:)` (result edit targets).

import Foundation

nonisolated struct MongoSchemaIntrospector: SchemaIntrospector {
  typealias Field = MongoValue.Field

  /// Documents sampled per relation.
  static let sampleSize = 100
  /// Relations whose fields are sampled (and collections counted), the first by name.
  static let maxSampledRelations = 200
  /// Badge `count` commands in flight at once.
  static let maxConcurrentCounts = 8
  /// `maxTimeMS` of each sample command (capped by the statement timeout).
  static let sampleMaxTimeMS: Int64 = 2000
  /// Path segments of the deepest sampled field (`a.b.c`).
  static let maxPathDepth = 3

  /// One `listCollections` entry.
  struct Relation: Equatable, Sendable {
    var name: String
    var isView: Bool
    /// The view's pipeline in mongosh notation; nil for a collection.
    var definition: String?
    /// `type: "timeseries"` or `options.timeseries`.
    var isTimeseries = false
    /// Capped, time series and clustered markers of a collection.
    var flags: DatabaseTable.CollectionFlags = []
    /// The view's `viewOn`; nil for a collection.
    var source: String? = nil
  }

  // MARK: - SchemaIntrospector

  func tables(in session: any DatabaseSession) async throws -> [DatabaseTable] {
    let mongo = try Self.mongoSession(session)
    let relations = try await Self.relations(in: mongo)
    let counts = try await Self.badgeCounts(of: Self.countedCollections(relations), in: mongo)
    return relations.filter { !$0.isView }.map {
      DatabaseTable(
        schema: mongo.databaseName, name: $0.name, rowCount: counts[$0.name],
        collectionFlags: $0.flags)
    }
  }

  func views(in session: any DatabaseSession) async throws -> [DatabaseView] {
    let mongo = try Self.mongoSession(session)
    return try await Self.relations(in: mongo).filter(\.isView).map {
      DatabaseView(
        schema: mongo.databaseName, name: $0.name, definition: $0.definition, source: $0.source)
    }
  }

  func foreignKeys(in _: any DatabaseSession) async throws -> [ForeignKey] { [] }

  /// Sampled fields of the first 200 relations by name (see the file header).
  func allColumns(in session: any DatabaseSession) async throws -> [String: [DatabaseColumn]] {
    let mongo = try Self.mongoSession(session)
    let database = mongo.databaseName
    let maxTimeMS = min(Self.sampleMaxTimeMS, mongo.maxTimeMS)
    var columns: [String: [DatabaseColumn]] = [:]
    for relation in Self.sampledRelations(try await Self.relations(in: mongo)) {
      guard let documents = try await Self.sample(relation, in: mongo, maxTimeMS: maxTimeMS)
      else { continue }
      columns["\(database).\(relation.name)"] = Self.columns(for: documents)
    }
    return columns
  }

  func editTable(named _: String, in _: any DatabaseSession) async throws -> EditTable? { nil }

  func enrichColumnTypes(
    _ columns: [ColumnInfo], query _: String, in _: any DatabaseSession
  ) async -> [ColumnInfo] {
    columns
  }

  /// `count` of `table` in the session's database (`schema` is that database).
  func rowCount(
    schema _: String, table: String, in session: any DatabaseSession
  ) async throws
    -> Int
  {
    try await Self.count(table, in: try Self.mongoSession(session))
  }

  func primaryKeyColumns(of _: String, in _: any DatabaseSession) async throws -> [String] {
    ["_id"]
  }

  func tableStructure(
    schema _: String, table _: String, in _: any DatabaseSession
  ) async throws -> TableStructure {
    throw MongoSessionError(message: "MongoDB collections have no table structure to edit.")
  }

  // MARK: - Reads

  private static func mongoSession(_ session: any DatabaseSession) throws -> MongoSession {
    guard let mongo = session as? MongoSession else {
      throw MongoSessionError(message: "The MongoDB catalog needs a MongoDB session.")
    }
    return mongo
  }

  /// Every listed collection and view except `system.*`, by name.
  private static func relations(in session: MongoSession) async throws -> [Relation] {
    let command = [Field("listCollections", .int32(1)), Field("cursor", .document([]))]
    return relations(
      from: try await session.catalogDocuments(
        command, cap: MongoSession.maxBufferedDocuments))
  }

  /// `count` of `collection` (no query) in the session's database.
  private static func count(
    _ collection: String, in session: MongoSession, maxTimeMS: Int64? = nil
  ) async throws -> Int {
    let reply = try await session.catalogCommand(
      [Field("count", .string(collection))], maxTimeMS: maxTimeMS)
    guard case .document(let fields) = reply,
      let count = fields.first(where: { $0.key == "n" }).flatMap({ int($0.value) })
    else { throw MongoSessionError(message: "The server sent an unexpected reply.") }
    return count
  }

  /// Badge counts of `collections` by name, at most `maxConcurrentCounts` in flight. A failed
  /// count is left out; cancel stops the rest.
  private static func badgeCounts(
    of collections: [String], in session: MongoSession
  ) async throws -> [String: Int] {
    let maxTimeMS = min(sampleMaxTimeMS, session.maxTimeMS)
    return try await withThrowingTaskGroup(of: (String, Int?).self) { group in
      var counts: [String: Int] = [:]
      for (index, name) in collections.enumerated() {
        if index >= maxConcurrentCounts, let (done, count) = try await group.next() {
          counts[done] = count
        }
        try Task.checkCancellation()
        group.addTask { (name, try await badgeCount(name, in: session, maxTimeMS: maxTimeMS)) }
      }
      for try await (name, count) in group { counts[name] = count }
      return counts
    }
  }

  /// `count` of `collection` for the sidebar badge, or nil when it failed (logged). Cancel is
  /// rethrown.
  private static func badgeCount(
    _ collection: String, in session: MongoSession, maxTimeMS: Int64
  ) async throws -> Int? {
    do {
      return try await count(collection, in: session, maxTimeMS: maxTimeMS)
    } catch {
      if Task.isCancelled || error is CancellationError || MongoSession.isInterruption(error) {
        throw error
      }
      await AppLogger.shared.warning(
        "MongoDB document count skipped \(collection): \(session.formatError(error))",
        category: "Schema")
      return nil
    }
  }

  /// The sampled documents of `relation`, or nil when every sample command failed (logged).
  /// Cancel is rethrown.
  private static func sample(
    _ relation: Relation, in session: MongoSession, maxTimeMS: Int64
  ) async throws -> [MongoValue]? {
    var lastError: (any Error)?
    for command in sampleCommands(for: relation) {
      do {
        return try await session.catalogDocuments(command, cap: sampleSize, maxTimeMS: maxTimeMS)
      } catch {
        if Task.isCancelled || error is CancellationError || MongoSession.isInterruption(error) {
          throw error
        }
        lastError = error
      }
    }
    if let lastError {
      await AppLogger.shared.warning(
        "MongoDB field sampling skipped \(relation.name): \(session.formatError(lastError))",
        category: "Schema")
    }
    return nil
  }

  // MARK: - Pure parts

  /// Collections and views of `listCollections` entries: `system.*` and entries without a name
  /// left out, sorted by name. `type: "view"` is a view; anything else (`collection`,
  /// `timeseries`) a table. Collections keep their capped / time series / clustered markers,
  /// views their `viewOn`.
  static func relations(from entries: [MongoValue]) -> [Relation] {
    entries.compactMap { entry -> Relation? in
      guard case .string(let name)? = field("name", of: entry), !name.hasPrefix("system.")
      else { return nil }
      let options = field("options", of: entry)
      func option(_ key: String) -> MongoValue? { options.flatMap { field(key, of: $0) } }
      guard case .string("view")? = field("type", of: entry) else {
        let isTimeseries =
          field("type", of: entry) == .string("timeseries") || option("timeseries") != nil
        var flags: DatabaseTable.CollectionFlags = []
        if option("capped") == .bool(true) { flags.insert(.capped) }
        if isTimeseries { flags.insert(.timeSeries) }
        // `clusteredIndex` is the index document or `true`.
        if let clustered = option("clusteredIndex"), clustered != .bool(false) {
          flags.insert(.clustered)
        }
        return Relation(
          name: name, isView: false, definition: nil, isTimeseries: isTimeseries, flags: flags)
      }
      var source: String?
      if case .string(let viewOn)? = option("viewOn") { source = viewOn }
      return Relation(
        name: name, isView: true,
        definition: option("pipeline").map { MongoRelaxedJSON.render($0, as: .mongosh) },
        source: source)
    }
    .sorted { $0.name < $1.name }
  }

  /// The collections whose badge count is read: the first `maxSampledRelations` of a sorted
  /// list, never a view or a time series.
  static func countedCollections(_ relations: [Relation]) -> [String] {
    sampledRelations(relations.filter { !$0.isView && !$0.isTimeseries }).map(\.name)
  }

  /// The relations whose fields are sampled: the first `maxSampledRelations` of a sorted list.
  static func sampledRelations(_ relations: [Relation]) -> [Relation] {
    Array(relations.prefix(maxSampledRelations))
  }

  /// The commands tried in order: `$sample` then find for a collection, find for a view.
  /// No `singleBatch`: a find on a view runs as an aggregate, which refuses it (code 168).
  static func sampleCommands(for relation: Relation) -> [[Field]] {
    let find = [Field("find", .string(relation.name)), Field("limit", .int64(Int64(sampleSize)))]
    guard !relation.isView else { return [find] }
    let sample = MongoValue.document([
      Field("$sample", .document([Field("size", .int32(Int32(sampleSize)))]))
    ])
    return [
      [
        Field("aggregate", .string(relation.name)), Field("pipeline", .array([sample])),
        Field("cursor", .document([])),
      ],
      find,
    ]
  }

  /// Field paths of `documents` (see the file header). No documents gives just `_id`.
  static func columns(for documents: [MongoValue]) -> [DatabaseColumn] {
    MongoBSONMapping.columns(for: documents.map(flattened)).map {
      let isID = $0.name == "_id"
      return DatabaseColumn(name: $0.name, type: $0.type, isNullable: !isID, isPrimaryKey: isID)
    }
  }

  /// One flat document whose keys are the dot paths of `document`, each embedded document
  /// followed by its fields, down to `maxPathDepth` segments.
  private static func flattened(_ document: MongoValue) -> MongoValue {
    guard case .document(let fields) = document else { return document }
    var flat: [Field] = []
    appendPaths(of: fields, prefix: "", depth: 1, to: &flat)
    return .document(flat)
  }

  private static func appendPaths(
    of fields: [Field], prefix: String, depth: Int, to flat: inout [Field]
  ) {
    for field in fields {
      let path = prefix + field.key
      flat.append(Field(path, field.value))
      // `typeName` keeps the JavaScript shape (`{$code}`) out: it is a value, not a document.
      if depth < maxPathDepth, case .document(let inner) = field.value,
        MongoBSONMapping.typeName(field.value) == "object"
      {
        appendPaths(of: inner, prefix: path + ".", depth: depth + 1, to: &flat)
      }
    }
  }

  private static func field(_ key: String, of value: MongoValue) -> MongoValue? {
    guard case .document(let fields) = value else { return nil }
    return fields.first { $0.key == key }?.value
  }

  private static func int(_ value: MongoValue) -> Int? {
    switch value {
    case .int32(let number): Int(number)
    case .int64(let number): Int(number)
    case .double(let number) where number.isFinite && number.rounded() == number:
      Int(exactly: number)
    default: nil
    }
  }
}

extension TableRef {
  /// MongoDB collection identity: `mongodb:` then the double-quoted database and collection, each
  /// with its double quotes doubled, so dotted names never collide. Built only here; compared,
  /// never split.
  nonisolated static func mongodb(database: String, collection: String) -> TableRef {
    func quoted(_ name: String) -> String {
      "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return TableRef("mongodb:" + quoted(database) + "." + quoted(collection))
  }
}
