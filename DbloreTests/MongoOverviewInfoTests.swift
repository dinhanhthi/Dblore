// MongoOverviewInfoTests.swift
// Reply parsing of the overview reads: listDatabases, dbStats and `$collStats storageStats`
// (one document per shard, summed). Server numbers come as int32, int64 or double; a missing or
// non-numeric field is nil, never a crash. The code-13 fallback of `mongoDatabases()` needs a
// real `MongoSession` (the fake session is not one), so only the parsers are tested here.

import Foundation
import Testing

@testable import Dblore

@Suite @MainActor
struct MongoOverviewInfoTests {
  private typealias Field = MongoValue.Field

  @Test("listDatabases: mixed number types, empty flag, missing size and nameless entries")
  func listDatabases() {
    let reply = MongoValue.document([
      Field(
        "databases",
        .array([
          .document([
            Field("name", .string("admin")), Field("sizeOnDisk", .int64(40960)),
            Field("empty", .bool(false)),
          ]),
          .document([
            Field("name", .string("shop")), Field("sizeOnDisk", .double(8192.0)),
            Field("empty", .bool(false)),
          ]),
          .document([
            Field("name", .string("scratch")), Field("sizeOnDisk", .int32(0)),
            Field("empty", .bool(true)),
          ]),
          .document([Field("name", .string("unsized"))]),
          .document([Field("sizeOnDisk", .int32(1))]),
        ])),
      Field("totalSize", .double(49152.0)),
      Field("ok", .double(1)),
    ])

    let list = MongoDatabaseList.parse(reply)

    #expect(
      list.databases == [
        MongoDatabaseInfo(name: "admin", sizeOnDisk: 40960, empty: false),
        MongoDatabaseInfo(name: "shop", sizeOnDisk: 8192, empty: false),
        MongoDatabaseInfo(name: "scratch", sizeOnDisk: 0, empty: true),
        MongoDatabaseInfo(name: "unsized", sizeOnDisk: nil, empty: nil),
      ])
    #expect(list.totalSize == 49152)
    #expect(list.note == nil)
  }

  @Test("dbStats: int32, int64 and double numbers; a missing or non-numeric field is nil")
  func dbStats() {
    let reply = MongoValue.document([
      Field("db", .string("shop")),
      Field("collections", .int32(4)),
      Field("views", .int32(1)),
      Field("objects", .int64(1_234_567)),
      Field("dataSize", .double(5.5e9)),
      Field("storageSize", .int64(2_000_000_000)),
      Field("indexes", .string("n/a")),
      Field("ok", .double(1)),
    ])

    #expect(
      MongoDatabaseStats.parse(reply)
        == MongoDatabaseStats(
          collections: 4, views: 1, objects: 1_234_567, dataSize: 5_500_000_000,
          storageSize: 2_000_000_000, indexes: nil, indexSize: nil))
  }

  @Test("$collStats storageStats: one document per shard, sizes summed, average recomputed")
  func collStats() {
    let shard = { (count: MongoValue, size: MongoValue, avg: MongoValue) in
      MongoValue.document([
        Field("ns", .string("shop.orders")),
        Field(
          "storageStats",
          .document([
            Field("count", count), Field("size", size), Field("avgObjSize", avg),
            Field("storageSize", .int32(4096)), Field("nindexes", .int32(3)),
            Field("totalIndexSize", .double(12288)),
          ])),
      ])
    }

    #expect(
      MongoCollectionStats.parse([shard(.int32(10), .int64(1000), .int32(100))])
        == MongoCollectionStats(
          count: 10, size: 1000, avgObjSize: 100, storageSize: 4096, nindexes: 3,
          totalIndexSize: 12288))
    #expect(
      MongoCollectionStats.parse([
        shard(.int32(10), .int64(1000), .int32(100)), shard(.int64(30), .double(1000), .int32(33)),
      ])
        == MongoCollectionStats(
          count: 40, size: 2000, avgObjSize: 50, storageSize: 8192, nindexes: 3,
          totalIndexSize: 24576))
    #expect(
      MongoCollectionStats.parse([.document([Field("ns", .string("shop.orders"))])])
        == MongoCollectionStats(
          count: nil, size: nil, avgObjSize: nil, storageSize: nil, nindexes: nil,
          totalIndexSize: nil))
  }
}
