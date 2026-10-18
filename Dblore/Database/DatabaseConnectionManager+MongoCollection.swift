// DatabaseConnectionManager+MongoCollection.swift
// App catalog reads of one MongoDB collection for the data viewer's collection tabs, as typed
// BSON (`MongoValue`), through the same path as the schema browser: `fetchCatalog` (metadata
// pause guard, errors wrapped as "Failed to fetch …") and `MongoSession.catalogDocuments`
// (cancellable statement, the session's `maxTimeMS`). Read-only catalog commands: no Safe Mode
// prompt and no classifier, like `MongoSchemaIntrospector`.
//
// Indexes: `listIndexes` errors propagate, except on a view (`CommandNotSupportedOnView`, 166),
// which answers `.view`. `$indexStats` and `$collStats` need their own privileges: a failure
// leaves their columns nil (see `MongoIndexInfo.merge`). Commands run in the session's database
// (`MongoSession.databaseName`, the data viewer's `schema` on MongoDB).
//
// Schema sample: the mongosh text of `MongoSchemaAnalyzer.sampleCommand` (refused before
// anything is sent when it uses server-side JavaScript) is parsed back with `MongoshParser`, so
// the command sent is exactly the text that passed the check; anything but a `find` or
// `aggregate` on the collection itself is refused. `$sample` failing (e.g. on some views) falls
// back once to `find({}).limit(size)`. Never writes.
//
// Server version: `mongoServerVersion()` reads `MongoSession.serverVersion()` (lazy `buildInfo`,
// cached per session) and never throws; an unknown version turns every feature flag on, so the
// form shows every option and the server's error explains.

import Foundation

/// What `fetchMongoIndexes` found for one namespace.
nonisolated enum MongoIndexesResult: Equatable, Sendable {
  case indexes([MongoIndexInfo])
  /// The namespace is a view: views have no indexes.
  case view
}

/// What the connected MongoDB server can do, for the admin forms.
nonisolated struct MongoServerFeatures: Equatable, Sendable {
  /// Nil when `buildInfo` failed or the session is not MongoDB.
  var version: MongoServerVersion?
  /// `hidden` indexes (4.4).
  var hiddenIndexes: Bool
  /// Time-series collections (5.0).
  var timeSeries: Bool
  /// Clustered collections (5.3).
  var clusteredCollections: Bool

  init(version: MongoServerVersion?) {
    self.version = version
    hiddenIndexes = version.map { $0 >= MongoServerVersion(4, 4) } ?? true
    timeSeries = version.map { $0 >= MongoServerVersion(5, 0) } ?? true
    clusteredCollections = version.map { $0 >= MongoServerVersion(5, 3) } ?? true
  }
}

extension DatabaseConnectionManager {
  /// Indexes per collection never exceed 64 (MongoDB limit).
  private static let mongoIndexCap = 64
  /// `$indexStats` returns one row per index per host or shard member.
  private static let mongoIndexStatsCap = 512
  /// `$collStats` returns one document per shard.
  private static let mongoCollStatsCap = 64
  /// Server time limit of the schema sample read (milliseconds).
  private static let mongoSampleMaxTimeMS: Int64 = 10_000

  /// The server version of the open MongoDB session with its feature flags. Never throws: no
  /// session, another engine or a failed `buildInfo` give an unknown version.
  func mongoServerVersion() async -> MongoServerFeatures {
    let version = try? await withSession { session in
      await (session as? MongoSession)?.serverVersion()
    }
    return MongoServerFeatures(version: version ?? nil)
  }

  /// The indexes of `collection` with usage and sizes when readable. `database`, when given,
  /// must be the session's database (the only one its commands target).
  func fetchMongoIndexes(
    database: String?, collection: String
  ) async throws
    -> MongoIndexesResult
  {
    try await fetchCatalog("indexes") { session in
      guard let mongo = session as? MongoSession else {
        throw MongoSessionError(message: "Indexes need a MongoDB session.")
      }
      if let database, database != mongo.databaseName {
        throw MongoSessionError(
          message: "This connection reads database \(mongo.databaseName), not \(database).")
      }
      let indexes: [MongoValue]
      do {
        indexes = try await mongo.catalogDocuments(
          MongoIndexInfo.listIndexesCommand(collection: collection), cap: Self.mongoIndexCap)
      } catch let error as MongoSessionError
        where error.code == 166 || error.codeName == "CommandNotSupportedOnView"
      {
        return .view
      }
      let stats = try? await mongo.catalogDocuments(
        MongoIndexInfo.indexStatsCommand(collection: collection), cap: Self.mongoIndexStatsCap)
      let collStats = try? await mongo.catalogDocuments(
        MongoIndexInfo.collStatsCommand(collection: collection), cap: Self.mongoCollStatsCap)
      return .indexes(MongoIndexInfo.merge(indexes: indexes, stats: stats, collStats: collStats))
    }
  }

  /// Up to `size` documents of `collection` for the Schema tab: a random `$sample` without a
  /// filter, else `find(filter).limit(size)`. Errors of a bad or server-side JavaScript filter
  /// propagate unchanged, before any command is sent.
  func sampleMongoDocuments(
    database: String?, collection: String, filterText: String, size: Int = 1000
  ) async throws -> [MongoValue] {
    let text = try MongoSchemaAnalyzer.sampleCommand(
      collection: collection, filterText: filterText, size: size)
    let command = try MongoshParser.parse(text)
    let isSample: Bool
    switch command {
    case .find(let target, _, _, _, _, _, _) where target == collection: isSample = false
    case .aggregate(let target, _, _) where target == collection: isSample = true
    default:
      throw MongoSessionError(message: "The schema sample must read \(collection) only.")
    }
    let fields = MongoSession.readCommand(command)
    return try await fetchCatalog("schema sample") { session in
      guard let mongo = session as? MongoSession else {
        throw MongoSessionError(message: "Schema analysis needs a MongoDB session.")
      }
      if let database, database != mongo.databaseName {
        throw MongoSessionError(
          message: "This connection reads database \(mongo.databaseName), not \(database).")
      }
      do {
        return try await mongo.catalogDocuments(
          fields, cap: size, maxTimeMS: Self.mongoSampleMaxTimeMS)
      } catch {
        guard isSample, !Task.isCancelled, !(error is CancellationError),
          !MongoSession.isInterruption(error)
        else { throw error }
        let find = MongoSession.readCommand(
          .find(
            collection: collection, filter: nil, projection: nil, sort: nil, skip: nil,
            limit: size))
        return try await mongo.catalogDocuments(
          find, cap: size, maxTimeMS: Self.mongoSampleMaxTimeMS)
      }
    }
  }
}
