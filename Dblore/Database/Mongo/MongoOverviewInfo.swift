// MongoOverviewInfo.swift
// The overview reads of MongoDB's documented reply shapes:
//
// - `listDatabases` (on `admin`, `nameOnly: false`, `authorizedDatabases: true`): `databases`
//   with `name`, `sizeOnDisk` and `empty`, and `totalSize`. Entries without a name are skipped.
// - `dbStats` (in the database itself): `collections`, `views`, `objects`, `dataSize`,
//   `storageSize`, `indexes`, `indexSize`.
// - `$collStats` with `storageStats` (`MongoIndexInfo.collStatsCommand`): one document per shard
//   (one when unsharded); `count`, `size`, `storageSize` and `totalIndexSize` are summed,
//   `nindexes` is the largest, and `avgObjSize` is recomputed as size / count over several shards.
//
// Numbers come as int32, int64 or double (a mongos may send doubles); a double is rounded. A
// missing or non-numeric field is nil (unknown), never zero.

import Foundation

nonisolated struct MongoDatabaseInfo: Equatable, Sendable, Identifiable {
  var id: String { name }
  let name: String
  /// Bytes
  let sizeOnDisk: Int64?
  let empty: Bool?
}

/// What `mongoDatabases()` found.
nonisolated struct MongoDatabaseList: Equatable, Sendable {
  typealias Field = MongoValue.Field

  var databases: [MongoDatabaseInfo]
  /// Bytes
  var totalSize: Int64?
  /// Why the list is partial (the user cannot list databases), nil when complete.
  var note: String?

  /// Run on `admin`. `authorizedDatabases` lists what the user may read without a cluster
  /// privilege.
  static let command: [Field] = [
    Field("listDatabases", .int32(1)), Field("nameOnly", .bool(false)),
    Field("authorizedDatabases", .bool(true)),
  ]

  static func parse(_ reply: MongoValue) -> MongoDatabaseList {
    var databases: [MongoDatabaseInfo] = []
    if case .array(let entries)? = MongoOverviewNumbers.value("databases", of: reply) {
      for entry in entries {
        guard case .string(let name)? = MongoOverviewNumbers.value("name", of: entry) else {
          continue
        }
        var empty: Bool?
        if case .bool(let flag)? = MongoOverviewNumbers.value("empty", of: entry) { empty = flag }
        databases.append(
          MongoDatabaseInfo(
            name: name, sizeOnDisk: MongoOverviewNumbers.integer("sizeOnDisk", of: entry),
            empty: empty))
      }
    }
    return MongoDatabaseList(
      databases: databases, totalSize: MongoOverviewNumbers.integer("totalSize", of: reply))
  }

  /// The user may not list databases (code 13): the connection's database alone.
  static func currentOnly(_ database: String) -> MongoDatabaseList {
    MongoDatabaseList(
      databases: [MongoDatabaseInfo(name: database, sizeOnDisk: nil, empty: nil)],
      totalSize: nil,
      note: "This user cannot list databases; showing the current database only.")
  }
}

nonisolated struct MongoDatabaseStats: Equatable, Sendable {
  typealias Field = MongoValue.Field

  let collections: Int64?
  let views: Int64?
  let objects: Int64?
  /// Bytes
  let dataSize: Int64?
  let storageSize: Int64?
  let indexes: Int64?
  let indexSize: Int64?

  static let command: [Field] = [Field("dbStats", .int32(1))]

  static func parse(_ reply: MongoValue) -> MongoDatabaseStats {
    let number = { (key: String) in MongoOverviewNumbers.integer(key, of: reply) }
    return MongoDatabaseStats(
      collections: number("collections"), views: number("views"), objects: number("objects"),
      dataSize: number("dataSize"), storageSize: number("storageSize"),
      indexes: number("indexes"), indexSize: number("indexSize"))
  }
}

nonisolated struct MongoCollectionStats: Equatable, Sendable {
  let count: Int64?
  /// Bytes
  let size: Int64?
  let avgObjSize: Int64?
  let storageSize: Int64?
  let nindexes: Int64?
  let totalIndexSize: Int64?

  /// `$collStats` documents (one per shard), see the file header.
  static func parse(_ documents: [MongoValue]) -> MongoCollectionStats {
    let stats = documents.compactMap { MongoOverviewNumbers.value("storageStats", of: $0) }
    let sum = { (key: String) -> Int64? in
      stats.compactMap { MongoOverviewNumbers.integer(key, of: $0) }
        .reduce(nil) { MongoIndexInfo.saturatingSum($0 ?? 0, $1) }
    }
    let count = sum("count")
    let size = sum("size")
    var average: Int64?
    if stats.count == 1 {
      average = MongoOverviewNumbers.integer("avgObjSize", of: stats[0])
    } else if let count, let size, count > 0 {
      average = size / count
    }
    return MongoCollectionStats(
      count: count, size: size, avgObjSize: average, storageSize: sum("storageSize"),
      nindexes: stats.compactMap { MongoOverviewNumbers.integer("nindexes", of: $0) }.max(),
      totalIndexSize: sum("totalIndexSize"))
  }
}

/// Field lookup and tolerant numbers of the overview replies.
private nonisolated enum MongoOverviewNumbers {
  static func value(_ key: String, of document: MongoValue) -> MongoValue? {
    guard case .document(let fields) = document else { return nil }
    return fields.first { $0.key == key }?.value
  }

  /// int32, int64 or a finite double (rounded) within Int64.
  static func integer(_ key: String, of document: MongoValue) -> Int64? {
    switch value(key, of: document) {
    case .int32(let number)?: return Int64(number)
    case .int64(let number)?: return number
    case .double(let number)? where number.isFinite && abs(number) < 9e18:
      return Int64(number.rounded())
    default: return nil
    }
  }
}
