// MongoExportWriterTests.swift
// Export file formats: canonical NDJSON lines that parse back to the same document, the JSON
// array layout, CSV with dot-path columns (and the field picker's paths), and no file left behind
// by a cancelled export

import Foundation
import Testing

@testable import Dblore

@Suite("Mongo export writer")
struct MongoExportWriterTests {

  /// A fresh folder for one test; the writer's temporary file goes there too.
  private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("MongoExportWriterTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func contents(of folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
  }

  private func export(
    _ pages: [[MongoValue]], as format: MongoExportWriter.Format, in folder: URL
  ) async throws -> String {
    let destination = folder.appendingPathComponent("out.txt")
    let writer = try MongoExportWriter(
      destination: destination, format: format, temporaryDirectory: folder)
    for page in pages { try await writer.write(page) }
    try await writer.finish()
    return try String(contentsOf: destination, encoding: .utf8)
  }

  private let typed: MongoValue = .document([
    .init("_id", .objectId(MongoObjectId(hex: "65a1b2c3d4e5f60718293a4b")!)),
    .init("at", .date(1_700_000_000_123)),
    .init("small", .int32(7)),
    .init("big", .int64(9_007_199_254_740_993)),
    .init("price", .decimal128("12.50")),
    .init("ratio", .double(0.5)),
    .init("address", .document([.init("city", .string("Paris"))])),
    .init("tags", .array([.string("a"), .int32(2)])),
  ])

  @Test("Canonical NDJSON: each line parses back to the same document; finish replaces the file")
  func canonicalNDJSONRoundTrips() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try "old".write(to: folder.appendingPathComponent("out.txt"), atomically: true, encoding: .utf8)
    let second: MongoValue = .document([.init("n", .int64(1)), .init("none", .null)])

    let text = try await export(
      [[typed], [second]], as: .extendedJSON(mode: .canonical, layout: .ndjson), in: folder)

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 3 && lines.last == "")
    #expect(try MongoRelaxedJSON.parse(String(lines[0])) == typed)
    #expect(try MongoRelaxedJSON.parse(String(lines[1])) == second)
    #expect(try contents(of: folder) == ["out.txt"])
  }

  @Test("Array layout is valid JSON with one element per document, and [] when empty")
  func arrayLayoutIsValidJSON() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let doc: MongoValue = .document([.init("x", .int32(1))])

    for mode in [MongoExportWriter.JSONMode.relaxed, .canonical] {
      let text = try await export(
        [[typed, doc], [doc]], as: .extendedJSON(mode: mode, layout: .array), in: folder)
      let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any]
      #expect(parsed?.count == 3)
    }
    let empty = try await export([], as: .extendedJSON(mode: .relaxed, layout: .array), in: folder)
    #expect(empty == "[]")
  }

  @Test("CSV: dot-path header, nested values, empty cell when missing, RFC 4180 quoting")
  func csvColumns() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first: MongoValue = .document([
      .init("name", .string("a, \"b\"\nc")),
      .init("address", .document([.init("city", .string("Paris")), .init("zip", .int32(75001))])),
      .init("tags", .array([.string("x"), .int32(1)])),
    ])
    let second: MongoValue = .document([.init("name", .string("plain"))])

    let text = try await export(
      [[first], [second]], as: .csv(fields: ["name", "address.city", "address.zip", "tags"]),
      in: folder)

    #expect(
      text == """
        name,address.city,address.zip,tags
        "a, ""b""
        c",Paris,75001,"[""x"", 1]"
        plain,,,

        """)
    let empty = try await export([], as: .csv(fields: ["a.b", "c"]), in: folder)
    #expect(empty == "a.b,c\n")
  }

  @Test(
    "CSV field picker: nested dot paths, arrays as leaves, _id first, unaddressable keys skipped")
  func fieldPathsOfSample() {
    let documents: [MongoValue] = [
      .document([
        .init("name", .string("a")),
        .init("address", .document([.init("city", .string("Paris"))])),
        .init("tags", .array([.document([.init("x", .int32(1))])])),
        .init("a.b", .int32(1)),
        .init("$weird", .int32(1)),
        .init("_id", .int32(1)),
      ]),
      .document([
        .init("address", .document([.init("zip", .int32(75001))])), .init("empty", .document([])),
      ]),
    ]
    #expect(
      MongoExportModel.fieldPaths(documents)
        == ["_id", "name", "address.city", "tags", "address.zip", "empty"])
  }

  @Test("Cancel leaves neither the temporary file nor the destination")
  func cancelLeavesNoFile() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let writer = try MongoExportWriter(
      destination: folder.appendingPathComponent("out.json"),
      format: .extendedJSON(mode: .relaxed, layout: .ndjson), temporaryDirectory: folder)
    try await writer.write([typed])
    #expect(await writer.documentsWritten == 1)

    await writer.cancel()
    await writer.cancel()

    #expect(try contents(of: folder).isEmpty)
    await #expect(throws: CancellationError.self) { try await writer.write([typed]) }
  }
}
