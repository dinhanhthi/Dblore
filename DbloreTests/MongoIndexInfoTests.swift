// MongoIndexInfoTests.swift
// MongoIndexInfo.merge: listIndexes documents joined with `$indexStats` rows (usage, Building) and
// `$collStats storageStats.indexSizes` (one document per shard, summed), key definitions and index
// types, properties, `_id_` first, and nil usage, size and status when the stats reads failed.

import Foundation
import Testing

@testable import Dblore

@Suite @MainActor
struct MongoIndexInfoTests {
  private static func parse(_ text: String) throws -> MongoValue {
    try MongoRelaxedJSON.parse(text)
  }

  private static func keys(_ index: MongoIndexInfo) -> [String] {
    index.keys.map { "\($0.field):\($0.kind)" }
  }

  /// Whole seconds since the epoch, so the Double comparison is exact.
  private static func date(_ seconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(seconds * 1000) / 1000)
  }

  /// listIndexes as stored by the server: `hidden` only when true, mongosh numbers as doubles.
  private static func listIndexes() throws -> [MongoValue] {
    try [
      "{v: 2, key: {status: 1, createdAt: -1.0}, name: 'status_1_createdAt_-1', unique: true}",
      "{v: 2, key: {_id: 1}, name: '_id_'}",
      "{v: 2, key: {email: 1.0}, name: 'email_1', sparse: true, hidden: true}",
      "{v: 2, key: {expiresAt: 1}, name: 'expiresAt_1', expireAfterSeconds: 3600.0}",
      "{v: 2, key: {price: 1}, name: 'price_1', partialFilterExpression: {type: 'apparel'}}",
    ].map(Self.parse)
  }

  // MARK: - Merge

  @Test("listIndexes + $indexStats + $collStats: order, keys, properties, usage, sizes, status")
  func merge() throws {
    let stats = try [
      """
      {name: '_id_', key: {_id: 1}, host: 'h1:27017',
       accesses: {ops: NumberLong('12'), since: ISODate('2026-10-01T08:00:00Z')}}
      """,
      """
      {name: 'status_1_createdAt_-1', key: {status: 1, createdAt: -1}, host: 'h1:27017',
       accesses: {ops: NumberLong('3'), since: ISODate('2026-09-28T06:30:00Z')}}
      """,
      """
      {name: 'email_1', key: {email: 1}, host: 'h1:27017',
       accesses: {ops: NumberLong('0'), since: ISODate('2026-10-01T08:00:00Z')}}
      """,
      """
      {name: 'expiresAt_1', key: {expiresAt: 1}, host: 'h1:27017',
       accesses: {ops: NumberLong('7'), since: ISODate('2026-10-01T08:00:00Z')}}
      """,
      """
      {name: 'price_1', key: {price: 1}, host: 'h1:27017',
       accesses: {ops: NumberLong('0'), since: ISODate('2026-10-01T08:00:00Z')}, building: true}
      """,
      """
      {name: 'dropped_1', key: {gone: 1}, host: 'h1:27017',
       accesses: {ops: NumberLong('5'), since: ISODate('2026-10-01T08:00:00Z')}}
      """,
    ].map(Self.parse)
    let collStats = try [
      """
      {shard: 's1', storageStats: {indexSizes: {
        _id_: 2147483000, 'status_1_createdAt_-1': 4096, email_1: 8192, expiresAt_1: 1024,
        dropped_1: 99}}}
      """,
      """
      {shard: 's2', storageStats: {indexSizes: {
        _id_: NumberLong('1000000'), 'status_1_createdAt_-1': NumberLong('4096'),
        expiresAt_1: 2048}}}
      """,
    ].map(Self.parse)

    let indexes = MongoIndexInfo.merge(
      indexes: try Self.listIndexes(), stats: stats, collStats: collStats)

    #expect(
      indexes.map(\.name) == [
        "_id_", "status_1_createdAt_-1", "email_1", "expiresAt_1", "price_1",
      ])
    #expect(indexes.map(\.id) == indexes.map(\.name))
    #expect(
      indexes.map(Self.keys) == [
        ["_id:1"], ["status:1", "createdAt:-1"], ["email:1"], ["expiresAt:1"], ["price:1"],
      ])
    #expect(indexes.map(\.type) == [.regular, .compound, .regular, .regular, .regular])
    #expect(indexes.map(\.isUnique) == [false, true, false, false, false])
    #expect(indexes.map(\.isSparse) == [false, false, true, false, false])
    #expect(indexes.map(\.isHidden) == [false, false, true, false, false])
    #expect(indexes.map(\.ttlSeconds) == [nil, nil, nil, 3600, nil])
    #expect(indexes.map(\.partialFilter) == [nil, nil, nil, nil, "{ type: \"apparel\" }"])
    #expect(indexes.map(\.ops) == [12, 3, 0, 7, 0])
    #expect(
      indexes.map(\.since) == [
        Self.date(1_790_841_600), Self.date(1_790_577_000), Self.date(1_790_841_600),
        Self.date(1_790_841_600), Self.date(1_790_841_600),
      ])
    #expect(indexes.map(\.status) == [.ready, .ready, .ready, .ready, .building])
    #expect(indexes.map(\.size) == [2_148_483_000, 8192, 8192, 3072, nil])
  }

  @Test("$indexStats rows from several hosts: ops summed, earliest since, Building from any row")
  func statsAcrossHosts() throws {
    let indexes = try [
      "{v: 2, key: {_id: 1}, name: '_id_'}",
      "{v: 2, key: {sku: 1}, name: 'sku_1'}",
    ].map(Self.parse)
    let stats = try [
      """
      {name: '_id_', key: {_id: 1}, host: 'a:27018', shard: 's1',
       accesses: {ops: NumberLong('10'), since: ISODate('2026-10-01T08:00:00Z')}}
      """,
      """
      {name: '_id_', key: {_id: 1}, host: 'b:27018', shard: 's2',
       accesses: {ops: NumberLong('5'), since: ISODate('2026-09-28T06:30:00Z')}}
      """,
      """
      {name: 'sku_1', key: {sku: 1}, host: 'a:27018', shard: 's1',
       accesses: {ops: NumberLong('1'), since: ISODate('2026-10-01T08:00:00Z')}}
      """,
      """
      {name: 'sku_1', key: {sku: 1}, host: 'b:27018', shard: 's2',
       accesses: {ops: NumberLong('0'), since: ISODate('2026-10-01T08:00:00Z')}, building: true}
      """,
    ].map(Self.parse)

    let merged = MongoIndexInfo.merge(indexes: indexes, stats: stats, collStats: nil)

    #expect(merged.map(\.ops) == [15, 1])
    #expect(merged.map(\.since) == [Self.date(1_790_577_000), Self.date(1_790_841_600)])
    #expect(merged.map(\.status) == [.ready, .building])
    #expect(merged.map(\.size) == [nil, nil])
  }

  @Test("Without $indexStats and $collStats (no privilege): usage, size and status are nil")
  func statsUnavailable() throws {
    let indexes = MongoIndexInfo.merge(
      indexes: try Self.listIndexes(), stats: nil, collStats: nil)

    let none = [Bool](repeating: true, count: 5)
    #expect(indexes.map { $0.ops == nil } == none)
    #expect(indexes.map { $0.since == nil } == none)
    #expect(indexes.map { $0.status == nil } == none)
    #expect(indexes.map { $0.size == nil } == none)
    #expect(indexes.map(\.isUnique) == [false, true, false, false, false])
  }

  // MARK: - Index types

  @Test("Special key types win over compound; text keys come from weights")
  func indexTypes() throws {
    let indexes = try [
      "{v: 2, key: {a: -1.0}, name: 'a_-1'}",
      """
      {v: 2, key: {category: 1, _fts: 'text', _ftsx: 1}, name: 'category_1_body_text_title_text',
       weights: {body: 1, title: 5}, default_language: 'english', language_override: 'language',
       textIndexVersion: 3}
      """,
      """
      {v: 2, key: {loc: '2dsphere', category: 1}, name: 'loc_2dsphere_category_1',
       '2dsphereIndexVersion': 3}
      """,
      "{v: 2, key: {pos: '2d'}, name: 'pos_2d'}",
      "{v: 2, key: {region: 1, userId: 'hashed'}, name: 'region_1_userId_hashed'}",
      "{v: 2, key: {'$**': 1}, name: '$**_1'}",
      "{v: 2, key: {'meta.$**': 1}, name: 'meta.$**_1'}",
      "{v: 2, key: {tenant: 1, '$**': 1}, name: 'tenant_1_$**_1', wildcardProjection: {tenant: 0}}",
    ].map(Self.parse)

    let merged = MongoIndexInfo.merge(indexes: indexes, stats: nil, collStats: nil)

    #expect(
      merged.map(\.type) == [
        .regular, .text, .geo2dsphere, .geo2d, .hashed, .wildcard, .wildcard, .wildcard,
      ])
    #expect(
      merged.map(Self.keys) == [
        ["a:-1"],
        ["category:1", "body:text", "title:text"],
        ["loc:2dsphere", "category:1"],
        ["pos:2d"],
        ["region:1", "userId:hashed"],
        ["$**:1"],
        ["meta.$**:1"],
        ["tenant:1", "$**:1"],
      ])
  }
}
