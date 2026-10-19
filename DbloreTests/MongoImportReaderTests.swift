// MongoImportReaderTests.swift
// The import reader turns an untrusted JSON / NDJSON / CSV file into MongoDB documents, or
// stops at the first bad record with its line (NDJSON / CSV) or document number (JSON array).

import Foundation
import Testing

@testable import Dblore

@Suite("MongoDB import reader")
struct MongoImportReaderTests {
  private func withFile<T>(
    _ text: String, extension ext: String, _ body: (URL) throws -> T
  ) throws -> T {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("mongo-import-\(UUID().uuidString).\(ext)")
    try Data(text.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
  }

  private func message(_ body: () throws -> Void) -> String? {
    do {
      try body()
      return nil
    } catch let error as MongoImportError {
      return error.message
    } catch {
      return "unexpected \(error)"
    }
  }

  @Test("CSV infers a type per column and applies overrides; a bad value names its line")
  func csvInferenceAndOverride() throws {
    let csv = """
      id,count,big,price,active,when,note,ref
      1,10,5000000000,1.5,true,2024-01-15,,507f1f77bcf86cd799439011
      2,-3,7,2,FALSE,2024-01-16T10:30:00.250Z,,507f191e810c19729de860ea

      """
    try withFile(csv, extension: "csv") { url in
      #expect(try MongoImportReader.detect(url: url) == .csv)
      var columns = try MongoImportReader.read(url: url, format: .csv).columns
      #expect(
        columns.map(\.path) == ["id", "count", "big", "price", "active", "when", "note", "ref"])
      #expect(
        columns.map(\.inferred) == [.int32, .int32, .int64, .double, .bool, .date, .null, .string])
      columns[0].override = .string
      columns[7].override = .objectId
      let output = try MongoImportReader.read(url: url, format: .csv, columns: columns)
      #expect(
        output.documents == [
          .document([
            .init("id", .string("1")), .init("count", .int32(10)),
            .init("big", .int64(5_000_000_000)), .init("price", .double(1.5)),
            .init("active", .bool(true)), .init("when", .date(1_705_276_800_000)),
            .init("note", .null),
            .init("ref", .objectId(MongoObjectId(hex: "507f1f77bcf86cd799439011")!)),
          ]),
          .document([
            .init("id", .string("2")), .init("count", .int32(-3)), .init("big", .int64(7)),
            .init("price", .double(2)), .init("active", .bool(false)),
            .init("when", .date(1_705_401_000_250)), .init("note", .null),
            .init("ref", .objectId(MongoObjectId(hex: "507f191e810c19729de860ea")!)),
          ]),
        ])

      columns[4].override = .int32
      let failure = message {
        _ = try MongoImportReader.read(url: url, format: .csv, columns: columns)
      }
      #expect(failure?.contains("line 2") == true)
    }
  }

  @Test("Dotted CSV headers build nested documents; a header both leaf and parent is an error")
  func csvDottedHeaders() throws {
    try withFile("a.b,a.c,d\n1,x,true\n", extension: "csv") { url in
      let output = try MongoImportReader.read(url: url, format: .csv)
      #expect(
        output.documents == [
          .document([
            .init("a", .document([.init("b", .int32(1)), .init("c", .string("x"))])),
            .init("d", .bool(true)),
          ])
        ])
    }
    try withFile("a,a.b\n1,2\n", extension: "csv") { url in
      let failure = message { _ = try MongoImportReader.read(url: url, format: .csv) }
      #expect(failure?.contains("\"a\"") == true)
      #expect(failure?.contains("\"a.b\"") == true)
    }
    let deep = Array(repeating: "a", count: 101).joined(separator: ".")
    try withFile("\(deep)\n1\n", extension: "csv") { url in
      let failure = message { _ = try MongoImportReader.read(url: url, format: .csv) }
      #expect(failure?.contains("deeper than 100") == true)
    }
  }

  @Test("NDJSON reports the physical line of a bad record")
  func ndjsonBadLine() throws {
    try withFile("{\"a\":1}\n\n{\"a\":2}\n{\"a\": oops}\n{\"a\":3}\n", extension: "ndjson") {
      url in
      let format = try MongoImportReader.detect(url: url)
      #expect(format == .ndjson)
      let failure = message { _ = try MongoImportReader.read(url: url, format: .ndjson) }
      #expect(failure?.contains("line 4") == true)
    }
  }

  @Test("A JSON array element that is not a document is an error with its index")
  func jsonArrayNonDocument() throws {
    try withFile("[{\"a\":1}, 5]", extension: "json") { url in
      let format = try MongoImportReader.detect(url: url)
      #expect(format == .jsonArray)
      let failure = message { _ = try MongoImportReader.read(url: url, format: .jsonArray) }
      #expect(failure?.contains("document 2") == true)
    }
  }

  @Test("Canonical and relaxed Extended JSON both parse")
  func extendedJSON() throws {
    let json = """
      [
        {"_id": {"$oid": "507f1f77bcf86cd799439011"},
         "at": {"$date": {"$numberLong": "1705276800000"}}, "n": {"$numberLong": "42"}},
        {"at": {"$date": "2024-01-15T00:00:00Z"}, "n": 42, "x": 1.5}
      ]
      """
    try withFile(json, extension: "json") { url in
      let output = try MongoImportReader.read(url: url, format: .jsonArray)
      #expect(
        output.documents == [
          .document([
            .init("_id", .objectId(MongoObjectId(hex: "507f1f77bcf86cd799439011")!)),
            .init("at", .date(1_705_276_800_000)), .init("n", .int64(42)),
          ]),
          .document([
            .init("at", .date(1_705_276_800_000)), .init("n", .int32(42)),
            .init("x", .double(1.5)),
          ]),
        ])
    }
  }

  @Test("The document-count limit stops the read")
  func documentLimit() throws {
    try withFile("{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n", extension: "ndjson") { url in
      let failure = message {
        _ = try MongoImportReader.read(url: url, format: .ndjson, maxDocuments: 2)
      }
      #expect(failure?.hasPrefix("unexpected") == false)
      let output = try MongoImportReader.read(url: url, format: .ndjson, maxDocuments: 3)
      #expect(output.documents.count == 3)
    }
  }
}
