// DatabaseConnectionManager+MongoOverview.swift
// Read-only overview reads of the MongoDB server (databases list, database and collection
// stats), through the same path as the other catalog reads: `fetchCatalog` (metadata pause guard,
// errors wrapped as "Failed to fetch …") and the cancellable `MongoSession` catalog commands.
// Read commands only, no Safe Mode prompt; not exposed to MCP tools.
//
// - `mongoDatabases()`: `listDatabases` on `admin`. A user without the privilege (code 13) gets
//   the connection's database alone, with a note.
// - `mongoDatabaseStats(_:)`: `dbStats` in the named database, which may differ from the
//   session's; the name must pass `MongoDatabaseName`'s character and length rules (the server's
//   own `admin`, `local` and `config` may be read).
// - `mongoCollectionStats(_:)`: `$collStats storageStats` of a collection in the session's
//   database (fails on a view).

import Foundation

extension DatabaseConnectionManager {
  /// `$collStats` returns one document per shard.
  private static let mongoShardDocumentCap = 64

  /// The databases the user may read, with sizes.
  func mongoDatabases() async throws -> MongoDatabaseList {
    try await PerfSignpost.interval("mongo.databases") {
      try await fetchCatalog("databases") { session in
        guard let mongo = session as? MongoSession else {
          throw MongoSessionError(message: "Databases need a MongoDB session.")
        }
        do {
          return MongoDatabaseList.parse(
            try await mongo.catalogCommand(MongoDatabaseList.command, database: "admin"))
        } catch let error as MongoSessionError
          where error.code == 13 || error.codeName == "Unauthorized"
        {
          return MongoDatabaseList.currentOnly(mongo.databaseName)
        }
      }
    }
  }

  /// `dbStats` of database `name`.
  func mongoDatabaseStats(_ name: String) async throws -> MongoDatabaseStats {
    // The reserved names pass the character and length rules; only creating or dropping them is
    // refused.
    if let problem = MongoDatabaseName.validate(name),
      !MongoDatabaseName.reserved.contains(name.lowercased())
    {
      throw DatabaseError.queryFailed(problem, 0)
    }
    return try await PerfSignpost.interval("mongo.databaseStats") {
      try await fetchCatalog("database stats") { session in
        guard let mongo = session as? MongoSession else {
          throw MongoSessionError(message: "Database stats need a MongoDB session.")
        }
        return MongoDatabaseStats.parse(
          try await mongo.catalogCommand(MongoDatabaseStats.command, database: name))
      }
    }
  }

  /// Storage stats of collection `name` in the session's database.
  func mongoCollectionStats(_ name: String) async throws -> MongoCollectionStats {
    try await PerfSignpost.interval("mongo.collectionStats") {
      try await fetchCatalog("collection stats") { session in
        guard let mongo = session as? MongoSession else {
          throw MongoSessionError(message: "Collection stats need a MongoDB session.")
        }
        return MongoCollectionStats.parse(
          try await mongo.catalogDocuments(
            MongoIndexInfo.collStatsCommand(collection: name), cap: Self.mongoShardDocumentCap))
      }
    }
  }
}
