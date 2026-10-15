// MongoAggregationPreviewLiveTests.swift
// The aggregation builder against the docker fixture (mongo:8.0 on 27018, users in `admin`)
// through a real DatabaseConnectionManager: a `$match` → `$group` → `$sort` pipeline built in the
// model, each prefix previewed and checked, and a `$out` stage (and the stage after it) never
// previewed, so its target collection is never created. Opt-in (`.requiresMongo`), serialized;
// both collections are dropped before and after.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized, .timeLimit(.minutes(5))) @MainActor
struct MongoAggregationPreviewLiveTests {
  private let source = "aggregation_preview"
  private let target = "aggregation_preview_out"

  /// Ten documents with `g: 1` over four cities (Oslo 10, Rome 60, Paris 101, Lima 7 by `n`)
  /// and five with `g: 0` the `$match` stage drops.
  private static let seed = [
    (1, "Oslo", 1, 1), (2, "Oslo", 2, 1), (3, "Oslo", 3, 1), (4, "Rome", 10, 1),
    (5, "Rome", 20, 1), (6, "Paris", 100, 1), (7, "Oslo", 4, 1), (8, "Rome", 30, 1),
    (9, "Paris", 1, 1), (10, "Lima", 7, 1), (11, "Oslo", 1000, 0), (12, "Oslo", 1000, 0),
    (13, "Rome", 1000, 0), (14, "Paris", 1000, 0), (15, "Lima", 1000, 0),
  ]

  private func run(
    _ manager: DatabaseConnectionManager, _ text: String
  ) async throws
    -> QueryResult
  {
    try await manager.execute(
      userSQL: text, policy: ProtectionPolicy(protectionLevel: .none), maxRows: 1_000)
  }

  /// The values of column `name` in each row of `result`.
  private func column(_ name: String, of result: QueryResult) throws -> [CellValue] {
    let index = try #require(result.columns.firstIndex { $0.name == name }, "no column \(name)")
    return result.rows.map { $0[index] }
  }

  @Test(
    "$match, $group and $sort prefixes preview their results; $out is never sent", .requiresMongo)
  func previewEachPrefix() async throws {
    await MongoSessionTests.drop(source)
    await MongoSessionTests.drop(target)
    let manager = DatabaseConnectionManager()
    do {
      try await manager.connect(config: MongoSessionTests.config())
      try await check(manager)
    } catch {
      await manager.disconnect()
      await MongoSessionTests.drop(source)
      await MongoSessionTests.drop(target)
      throw error
    }
    await manager.disconnect()
    await MongoSessionTests.drop(source)
    await MongoSessionTests.drop(target)
  }

  private func check(_ manager: DatabaseConnectionManager) async throws {
    let documents = Self.seed.map { "{_id: \($0.0), city: \"\($0.1)\", n: \($0.2), g: \($0.3)}" }
    let seeded = try await run(
      manager, "db.\(source).insertMany([\(documents.joined(separator: ", "))])")
    #expect(seeded.affectedRows == Self.seed.count)

    let model = AggregationBuilderModel(collection: source, connectionManager: manager)
    let match = model.addStage(operator: "$match", body: "{g: 1}")
    let group = model.addStage(
      operator: "$group", body: #"{_id: "$city", total: {$sum: "$n"}}"#)
    let sort = model.addStage(operator: "$sort", body: "{total: -1}")
    let out = model.addStage(operator: "$out", body: "\"\(target)\"")
    let after = model.addStage(operator: "$project", body: "{total: 1}")

    // Stage 1: the ten g: 1 documents
    await model.preview(match)?.value
    let matched = try #require(
      model.previewState(for: match).result, "\(model.previewState(for: match))")
    #expect(matched.rowCount == 10)
    #expect(try column("_id", of: matched).sorted() == (1...10).map(CellValue.int))
    #expect(try column("g", of: matched).allSatisfy { $0 == .int(1) })

    // Stage 2: one document per city, totals of the matched documents only
    await model.preview(group)?.value
    let grouped = try #require(
      model.previewState(for: group).result, "\(model.previewState(for: group))")
    #expect(grouped.rowCount == 4)
    let totals = try zip(column("_id", of: grouped), column("total", of: grouped))
      .map { [$0, $1] }
      .sorted { $0[0] < $1[0] }
    #expect(
      totals == [
        [.string("Lima"), .int(7)], [.string("Oslo"), .int(10)], [.string("Paris"), .int(101)],
        [.string("Rome"), .int(60)],
      ])

    // Stage 3: the same groups by total, descending
    await model.preview(sort)?.value
    let sorted = try #require(
      model.previewState(for: sort).result, "\(model.previewState(for: sort))")
    #expect(
      try column("_id", of: sorted) == ["Paris", "Rome", "Oslo", "Lima"].map(CellValue.string))
    #expect(try column("total", of: sorted) == [101, 60, 10, 7].map(CellValue.int))

    // $out and the stage after it are not previewed, so nothing is written
    for id in [out, after] {
      #expect(model.preview(id) == nil)
      #expect(model.previewState(for: id).message == "not previewed (writes data)")
    }
    let names = try await run(manager, "db.getCollectionNames()")
    let listed = names.rows.flatMap { $0 }
    #expect(listed.contains(.string(source)))
    #expect(!listed.contains(.string(target)))
  }
}
