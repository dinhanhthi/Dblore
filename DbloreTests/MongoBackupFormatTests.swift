// MongoBackupFormatTests.swift
// The MongoDB backup file contract: the header and document lines read back with every type kept
// (a number-heavy document whose text is over 1 MiB included), a newer format version is refused,
// and a bad line or a document for a collection the header does not list stops the read with its
// line number. The writer sets each count from what it wrote and leaves no temporary file.

import Foundation
import Testing

@testable import Dblore

@Suite("Mongo backup format")
struct MongoBackupFormatTests {
  private let limit = 16 * 1_048_576

  private let header = MongoBackupHeader(
    database: "shop", createdAt: 1_700_000_000_123,
    collections: [
      .init(
        name: "orders",
        options: .document([.init("capped", .bool(true)), .init("size", .int64(1_048_576))]),
        validator: .document([
          .init("validator", .document([.init("qty", .document([.init("$gt", .int32(0))]))])),
          .init("validationLevel", .string("strict")),
        ]),
        indexes: [
          .document([
            .init("v", .int32(2)), .init("key", .document([.init("sku", .int32(1))])),
            .init("name", .string("sku_1")), .init("unique", .bool(true)),
          ])
        ],
        count: 2),
      .init(name: "empty", options: .document([]), validator: nil, indexes: [], count: 0),
    ],
    views: [
      .init(
        name: "big_orders", viewOn: "orders",
        pipeline: [.document([.init("$match", .document([.init("qty", .int32(5))]))])],
        options: .document([]))
    ])

  private let typed: MongoValue = .document([
    .init("_id", .objectId(MongoObjectId(hex: "65a1b2c3d4e5f60718293a4b")!)),
    .init("at", .date(1_700_000_000_123)),
    .init("big", .int64(9_007_199_254_740_993)),
    .init("price", .decimal128("12.50")),
    .init("blob", .binary(subtype: 4, data: Data([0, 1, 2, 255]))),
    .init("address", .document([.init("city", .string("Paris")), .init("tags", .array([]))])),
  ])

  /// Writes `lines` to a fresh file joined by `separator`, with a trailing separator.
  private func file(_ lines: [String], separator: String = "\n") throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("MongoBackupFormatTests-\(UUID().uuidString).ndjson")
    try Data((lines.joined(separator: separator) + separator).utf8).write(to: url)
    return url
  }

  /// Every line the reader hands out, or its error.
  private func read(_ url: URL) async throws -> [MongoBackupLine] {
    var lines: [MongoBackupLine] = []
    try await MongoBackupFormat.forEachLine(url: url, maxBsonObjectSize: limit) {
      lines.append($0)
    }
    return lines
  }

  private func failure(_ url: URL) async -> MongoBackupFormatError? {
    do {
      _ = try await read(url)
      return nil
    } catch {
      return error as? MongoBackupFormatError
    }
  }

  @Test("Header and document lines read back with types kept, a document over 1 MiB included")
  func roundTrips() async throws {
    // Canonical Extended JSON of 120,000 int32 values: far more text than 1 MiB
    let large: MongoValue = .document([
      .init("_id", .int32(2)), .init("values", .array((0..<120_000).map { .int32(Int32($0)) })),
    ])
    let largeLine = MongoBackupFormat.documentLine(collection: "orders", document: large)
    #expect(largeLine.utf8.count > 1_048_576)
    let url = try file([
      MongoBackupFormat.headerLine(header),
      MongoBackupFormat.documentLine(collection: "orders", document: typed), largeLine,
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let lines = try await read(url)

    #expect(
      lines == [
        .header(header), .document(line: 2, collection: "orders", document: typed),
        .document(line: 3, collection: "orders", document: large),
      ])
  }

  @Test("A backup of a newer format version is refused on line 1")
  func newerVersionRefused() async throws {
    let line = MongoBackupFormat.headerLine(header).replacingOccurrences(
      of: "\"version\": {\"$numberInt\": \"1\"}", with: "\"version\": {\"$numberInt\": \"2\"}")
    #expect(line.contains("\"2\""))
    let url = try file([line])
    defer { try? FileManager.default.removeItem(at: url) }

    let error = await failure(url)

    #expect(error?.line == 1)
    #expect(error?.message.contains("version 2") == true)
  }

  @Test("A bad line stops the read with its line number")
  func badLineReportsItsNumber() async throws {
    let url = try file([
      MongoBackupFormat.headerLine(header),
      MongoBackupFormat.documentLine(collection: "orders", document: typed),
      "{\"c\": \"orders\", \"d\": {\"qty\": ",
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(await failure(url)?.line == 3)
  }

  @Test("A document for a collection the header does not list is refused with its line number")
  func unknownCollectionRefused() async throws {
    let url = try file(
      [
        MongoBackupFormat.headerLine(header),
        MongoBackupFormat.documentLine(collection: "orders", document: typed),
        MongoBackupFormat.documentLine(collection: "ghost", document: typed),
      ], separator: "\r\n")
    defer { try? FileManager.default.removeItem(at: url) }

    let error = await failure(url)

    #expect(error?.line == 3)
    #expect(error?.message.contains("ghost") == true)
  }

  @Test("The writer sets the counts from what it wrote, reads back, and leaves no temporary file")
  func writerRoundTripsAndCleansUp() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("MongoBackupFormatTests-\(UUID().uuidString)")
    let temporary = folder.appendingPathComponent("tmp")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let destination = folder.appendingPathComponent("shop.ndjson")
    let second: MongoValue = .document([.init("_id", .int32(7))])
    var empty = header
    for index in empty.collections.indices { empty.collections[index].count = 0 }

    let writer = try MongoBackupWriter(
      destination: destination, maxBsonObjectSize: limit, temporaryDirectory: temporary)
    _ = try await writer.write(collection: "orders", documents: [typed])
    _ = try await writer.write(collection: "orders", documents: [second])
    _ = try await writer.write(collection: "empty", documents: [])
    let written = try await writer.finish(header: empty)

    #expect(written.collections.map(\.count) == [2, 0])
    #expect(
      try await read(destination) == [
        .header(written), .document(line: 2, collection: "orders", document: typed),
        .document(line: 3, collection: "orders", document: second),
      ])
    #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)

    let cancelled = folder.appendingPathComponent("cancelled.ndjson")
    let stopped = try MongoBackupWriter(
      destination: cancelled, maxBsonObjectSize: limit, temporaryDirectory: temporary)
    _ = try await stopped.write(collection: "orders", documents: [typed])
    await stopped.cancel()

    #expect(!FileManager.default.fileExists(atPath: cancelled.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
  }
}
