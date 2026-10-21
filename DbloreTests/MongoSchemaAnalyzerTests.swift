// MongoSchemaAnalyzerTests.swift
// MongoSchemaAnalyzer.analyze over sampled documents: presence and type distribution ("undefined"
// for a field missing where its parent document is present), dotted paths down to three
// segments, keys holding a dot or empty kept apart from other fields, array element types and
// array element documents entered without an index; top values with counts for strings
// (apart from numbers and bools of the same text), numbers and bools, number and date ranges,
// weekday and hour histograms for dates and ObjectId timestamps read with the injected
// Calendar; the exact filter value of a top value (none for a cut text); the 5,000 field node
// cap and its truncation flag. sampleCommand refuses server-side JavaScript in the filter and
// builds `$sample` or `find().limit()` text.
// MongoSchemaFilter edits filter text from schema clicks; MongoSchemaExport writes JSON Schema and
// `$jsonSchema`.
//
// The suite is not main-actor isolated on purpose: the analyzer is `nonisolated` (it runs in a
// detached task), so calling it from here must compile without `await`.

import Foundation
import Testing

@testable import Dblore

@Suite
struct MongoSchemaAnalyzerTests {
  private static func parse(_ texts: [String]) throws -> [MongoValue] {
    try texts.map { try MongoRelaxedJSON.parse($0) }
  }

  private static func calendar(_ zone: String = "UTC") throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: zone))
    return calendar
  }

  private static func field(
    _ path: String, in report: MongoSchemaAnalyzer.Report
  ) throws -> MongoSchemaAnalyzer.Field {
    try #require(report.fields.first { $0.path == path }, "no field \(path)")
  }

  /// The field of `keyPath`, for paths two fields share.
  private static func field(
    keys keyPath: [String], in report: MongoSchemaAnalyzer.Report
  ) throws -> MongoSchemaAnalyzer.Field {
    try #require(report.fields.first { $0.keyPath == keyPath }, "no field \(keyPath)")
  }

  /// `name:count` per type share, in report order.
  private static func types(_ shares: [MongoSchemaAnalyzer.TypeShare]?) -> [String]? {
    shares?.map { "\($0.name):\($0.count)" }
  }

  /// `value:count` per top value, in report order.
  private static func values(_ field: MongoSchemaAnalyzer.Field) -> [String] {
    field.topValues.map { "\($0.value):\($0.count)" }
  }

  /// `count` zero buckets with `hits` (bucket index to count) filled in.
  private static func buckets(_ count: Int, _ hits: [Int: Int]) -> [Int] {
    (0..<count).map { hits[$0] ?? 0 }
  }

  /// Whole seconds since the epoch, so Date equality is exact.
  private static func date(_ seconds: Int) -> Date {
    Date(timeIntervalSince1970: Double(seconds))
  }

  // MARK: - Presence, types, paths

  @Test("Presence and types: undefined only under a present parent, depth 3, arrays")
  func presenceAndTypes() throws {
    let documents = try Self.parse([
      """
      {_id: ObjectId('6acc06e0aaaaaaaaaaaaaaaa'), name: 'Ada', age: 36,
       address: {city: 'Paris', zip: '75001', geo: {lat: 48.85, pos: {x: 1}}},
       tags: ['a', 'b'], items: [{sku: 'p1', qty: 2}, {sku: 'p2'}], a: {b: 2}}
      """,
      """
      {_id: ObjectId('6acc9380aaaaaaaaaaaaaaaa'), name: 'Bob', age: 'unknown',
       address: {city: 'Lyon'}, tags: ['c', 3], items: [{qty: 1}]}
      """,
      """
      {_id: ObjectId('6acc9a88aaaaaaaaaaaaaaaa'), age: 41, address: null, tags: [], items: [],
       'a.b': 1}
      """,
    ])

    let report = MongoSchemaAnalyzer.analyze(documents, calendar: try Self.calendar())

    #expect(report.sampleSize == 3)
    // Dotted paths down to three segments; `address.geo.pos.x` (four) is not listed. Array
    // element documents are entered without an index; scalar elements get no path.
    #expect(
      Set(report.fields.map(\.path)) == [
        "_id", "name", "age", "address", "address.city", "address.zip", "address.geo",
        "address.geo.lat", "address.geo.pos", "tags", "items", "items.sku", "items.qty", "a",
        "a.b",
      ])
    // Ids are the key paths: unique even where two fields share a display path.
    #expect(Set(report.fields.map(\.id)).count == report.fields.count)

    // A dotted top-level key is a field of its own, apart from the nested `a` then `b`; its
    // parent is the top level (3 documents), not `a`.
    #expect(report.fields.filter { $0.path == "a.b" }.count == 2)
    let dotted = try Self.field(keys: ["a.b"], in: report)
    #expect(dotted.depth == 1)
    #expect(dotted.name == "a.b")
    #expect(dotted.parentPath == "")
    #expect(Self.types(dotted.types) == ["undefined:2", "int:1"])
    let nestedB = try Self.field(keys: ["a", "b"], in: report)
    #expect(nestedB.name == "b")
    #expect(nestedB.parentPath == "a")
    #expect(Self.types(nestedB.types) == ["int:1"])

    let name = try Self.field("name", in: report)
    #expect(name.depth == 1)
    #expect(name.presentCount == 2)
    #expect(Self.types(name.types) == ["string:2", "undefined:1"])
    #expect(name.elementTypes == nil)

    // Mixed types are all listed, count descending.
    let age = try Self.field("age", in: report)
    #expect(age.presentCount == 3)
    #expect(Self.types(age.types) == ["int:2", "string:1"])

    let address = try Self.field("address", in: report)
    #expect(Self.types(address.types) == ["object:2", "null:1"])

    // A null or missing parent is not a parent: `address.zip` is undefined once (Lyon), not twice.
    let zip = try Self.field("address.zip", in: report)
    #expect(zip.depth == 2)
    #expect(zip.presentCount == 1)
    #expect(Self.types(zip.types) == ["string:1", "undefined:1"])
    #expect(Self.types(try Self.field("address.city", in: report).types) == ["string:2"])

    let pos = try Self.field("address.geo.pos", in: report)
    #expect(pos.depth == 3)
    #expect(Self.types(pos.types) == ["object:1"])
    #expect(Self.types(try Self.field("address.geo.lat", in: report).types) == ["double:1"])

    // An array is typed `array`; its elements are counted one by one in `elementTypes`.
    let tags = try Self.field("tags", in: report)
    #expect(Self.types(tags.types) == ["array:3"])
    #expect(Self.types(tags.elementTypes) == ["string:3", "int:1"])

    // Each element document is one parent occurrence of `items.<field>`.
    let items = try Self.field("items", in: report)
    #expect(Self.types(items.elementTypes) == ["object:3"])
    let sku = try Self.field("items.sku", in: report)
    #expect(sku.depth == 2)
    #expect(sku.presentCount == 2)
    #expect(Self.types(sku.types) == ["string:2", "undefined:1"])
    #expect(Self.types(try Self.field("items.qty", in: report).types) == ["int:2", "undefined:1"])
  }

  // MARK: - Values

  @Test("Top values for strings, numbers and bools; number range; first-seen samples")
  func topValuesAndNumberRange() throws {
    let documents = try Self.parse([
      "{status: 'active', qty: 5, active: true}",
      "{status: 'done', qty: 2, active: false}",
      "{status: 'active', qty: 5, active: true}",
      "{status: 'archived', qty: 7.5, active: true}",
      "{status: 'active', qty: -1}",
      "{qty: '5', note: '\(String(repeating: "x", count: 300))'}",
    ])

    let report = MongoSchemaAnalyzer.analyze(documents, calendar: try Self.calendar())

    // Count descending, then value ascending; strings unquoted, numbers and bools as written.
    let status = try Self.field("status", in: report)
    #expect(Self.values(status) == ["active:3", "archived:1", "done:1"])
    #expect(status.distinctCount == 3)
    #expect(status.numberRange == nil)
    #expect(status.dateRange == nil)
    #expect(status.weekdays == nil)
    // Distinct values in first-seen order, rendered as mongosh text.
    #expect(status.samples == ["\"active\"", "\"done\"", "\"archived\""])

    // int and double values share one range; the string '5' is not the number 5.
    let qty = try Self.field("qty", in: report)
    #expect(Self.values(qty) == ["5:2", "-1:1", "2:1", "5:1", "7.5:1"])
    #expect(qty.distinctCount == 5)
    #expect(qty.numberRange == -1...7.5)
    // The exact value to filter on keeps the type: the string '5' is not the number 5.
    #expect(
      qty.topValues.map(\.filterValue) == [
        .int32(5), .int32(-1), .int32(2), .string("5"), .double(7.5),
      ])
    // Regression: the two `5` shares keep their kind, so the view can quote the string one.
    #expect(qty.topValues.map(\.isString) == [false, false, false, true, false])
    #expect(status.topValues.first?.filterValue == .string("active"))
    // A text cut at 256 characters is no exact value.
    let note = try #require(try Self.field("note", in: report).topValues.first)
    #expect(note.value == String(repeating: "x", count: 256) + "…")
    #expect(note.filterValue == nil)

    let active = try Self.field("active", in: report)
    #expect(Self.values(active) == ["true:3", "false:1"])
    #expect(active.distinctCount == 2)
    #expect(Self.types(active.types) == ["bool:4", "undefined:2"])
  }

  @Test("Empty keys: the walk ends and nested counts stay apart from the top level")
  func emptyKeys() throws {
    let documents = try Self.parse(["{'': 1, a: {'': 2}}", "{a: {b: 3}}"])

    let report = MongoSchemaAnalyzer.analyze(documents, calendar: try Self.calendar())

    #expect(report.sampleSize == 2)
    #expect(report.fields.map(\.keyPath) == [[""], ["a"], ["a", ""], ["a", "b"]])
    #expect(report.fields.map(\.path) == ["", "a", "a.", "a.b"])
    let top = try Self.field("", in: report)
    #expect(top.depth == 1)
    #expect(Self.types(top.types) == ["int:1", "undefined:1"])
    #expect(Self.types(try Self.field("a", in: report).types) == ["object:2"])
    let nested = try Self.field("a.", in: report)
    #expect(nested.depth == 2)
    #expect(Self.types(nested.types) == ["int:1", "undefined:1"])
  }

  @Test("Node cap: fields stop at 5,000 and the report is flagged truncated")
  func nodeCap() throws {
    let wide = MongoValue.document(
      (0..<(MongoSchemaAnalyzer.nodeLimit + 10)).map { MongoValue.Field("k\($0)", .int32(1)) })

    let report = MongoSchemaAnalyzer.analyze([wide], calendar: try Self.calendar())

    #expect(report.fields.count == 5_000)
    #expect(report.isTruncated)
    #expect(report.fields.last?.path == "k4999")
    let small = MongoSchemaAnalyzer.analyze(
      try Self.parse(["{a: 1}"]), calendar: try Self.calendar())
    #expect(!small.isTruncated)
  }

  @Test("Dates and ObjectId timestamps: range, weekday and hour histograms in the calendar's zone")
  func datesAndObjectIds() throws {
    let documents = try Self.parse([
      "{_id: ObjectId('6acc06e0aaaaaaaaaaaaaaaa'), createdAt: ISODate('2026-10-11T09:05:00Z')}",
      "{_id: ObjectId('6acc9380aaaaaaaaaaaaaaaa'), createdAt: ISODate('2026-10-12T09:30:00Z')}",
      "{_id: ObjectId('6acc9a88aaaaaaaaaaaaaaaa'), createdAt: ISODate('2026-10-12T23:59:59Z')}",
      "{_id: ObjectId('6ad22354aaaaaaaaaaaaaaaa'), createdAt: ISODate('2026-10-14T14:00:00Z')}",
      "{_id: ObjectId('6ad22a5caaaaaaaaaaaaaaaa'), createdAt: ISODate('2026-10-17T00:00:00Z')}",
    ])

    let report = MongoSchemaAnalyzer.analyze(documents, calendar: try Self.calendar())

    // Weekday bucket = calendar weekday - 1 (0 = Sunday); hour bucket = calendar hour.
    let created = try Self.field("createdAt", in: report)
    #expect(created.dateRange == Self.date(1_791_709_500)...Self.date(1_792_195_200))
    #expect(created.weekdays == Self.buckets(7, [0: 1, 1: 2, 3: 1, 6: 1]))
    #expect(created.hours == Self.buckets(24, [0: 1, 9: 2, 14: 1, 23: 1]))
    #expect(created.topValues.isEmpty)
    #expect(created.distinctCount == nil)
    #expect(created.numberRange == nil)

    // ObjectId time: the first 8 hex characters as seconds since the epoch.
    let id = try Self.field("_id", in: report)
    #expect(Self.types(id.types) == ["objectId:5"])
    #expect(id.dateRange == Self.date(1_791_756_000)...Self.date(1_792_158_300))
    #expect(id.weekdays == Self.buckets(7, [0: 1, 1: 2, 5: 2]))
    #expect(id.hours == Self.buckets(24, [8: 2, 13: 2, 22: 1]))
    #expect(id.topValues.isEmpty)

    // The injected calendar decides the buckets: UTC+9 moves every date by nine hours.
    let tokyo = MongoSchemaAnalyzer.analyze(documents, calendar: try Self.calendar("Asia/Tokyo"))
    let createdTokyo = try Self.field("createdAt", in: tokyo)
    #expect(createdTokyo.weekdays == Self.buckets(7, [0: 1, 1: 1, 2: 1, 3: 1, 6: 1]))
    #expect(createdTokyo.hours == Self.buckets(24, [8: 1, 9: 1, 18: 2, 23: 1]))
  }

  // MARK: - Sample command

  @Test("sampleCommand: server-side JavaScript in the filter is refused; $sample or find text")
  func sampleCommand() throws {
    let collection = "sales.orders"
    for filter in [
      "{$where: 'this.qty > 5'}",
      """
      {$or: [{status: 'active'},
        {$expr: {$function: {body: 'function(q) { return q > 5 }', args: ['$qty'], lang: 'js'}}}]}
      """,
      """
      {$expr: {$gt: [{$accumulator: {init: 'function() { return 0 }', accumulate: 'function(s) { return s }',
        accumulateArgs: [], merge: 'function(a, b) { return a }', lang: 'js'}}, 0]}}
      """,
    ] {
      #expect(throws: MongoSchemaAnalyzer.SampleCommandError.serverSideJavaScript, "\(filter)") {
        try MongoSchemaAnalyzer.sampleCommand(
          collection: collection, filterText: filter, size: 1000)
      }
    }

    #expect(
      try MongoSchemaAnalyzer.sampleCommand(
        collection: collection, filterText: "{status: 'active'}", size: 1000)
        == "db.getCollection(\"sales.orders\").find({ status: \"active\" }).limit(1000)")
    let sample = "db.getCollection(\"sales.orders\").aggregate([ { $sample: { size: 250 } } ])"
    for empty in ["", "  \n ", "{}"] {
      #expect(
        try MongoSchemaAnalyzer.sampleCommand(collection: collection, filterText: empty, size: 250)
          == sample)
    }
  }

  // MARK: - Schema filter

  private static func apply(
    _ keyPath: [String], _ kind: MongoSchemaFilter.Kind, to text: String, adding: Bool = false
  ) throws -> String {
    try MongoSchemaFilter.apply(
      MongoSchemaFilter.Condition(keyPath: keyPath, kind: kind), to: text, adding: adding)
  }

  @Test("Schema filter: click sets, shift-click adds to $in, other fields stay; type and missing")
  func schemaFilter() throws {
    var text = try Self.apply(["status"], .value(.string("active")), to: "")
    #expect(text == "{ status: \"active\" }")
    // Shift-click turns the equality into $in, without duplicates.
    text = try Self.apply(["status"], .value(.string("done")), to: text, adding: true)
    #expect(text == "{ status: { $in: [ \"active\", \"done\" ] } }")
    #expect(try Self.apply(["status"], .value(.string("done")), to: text, adding: true) == text)
    text = try Self.apply(["status"], .value(.int32(5)), to: text, adding: true)
    #expect(text == "{ status: { $in: [ \"active\", \"done\", 5 ] } }")

    // Other fields stay (AND); a nested field is addressed by its dotted path; a click replaces
    // the field's condition in place.
    text = try Self.apply(["address", "city"], .value(.string("Paris")), to: text)
    text = try Self.apply(["age"], .type("string"), to: text)
    text = try Self.apply(["email"], .missing, to: text)
    text = try Self.apply(["status"], .value(.string("archived")), to: text)
    #expect(
      text
        == "{ status: \"archived\", \"address.city\": \"Paris\", age: { $type: \"string\" }, "
        + "email: { $exists: false } }")
    // The text reads back through the filter parser.
    #expect(throws: Never.self) { try DataViewerState.documentFilterValue(text).get() }
  }

  @Test("Schema filter: a key holding a dot or starting with $ cannot be addressed")
  func schemaFilterRefusesKeys() throws {
    for keyPath in [["a.b"], ["meta", "$id"]] {
      #expect(throws: MongoSchemaFilter.FilterError.self, "\(keyPath)") {
        try Self.apply(keyPath, .value(.int32(1)), to: "{status: 'active'}")
      }
    }
  }

  // MARK: - Schema export

  /// The value at `keys` (document keys one by one) in `value`.
  private static func member(_ value: MongoValue?, _ keys: String...) -> MongoValue? {
    keys.reduce(value) { current, key in
      guard case .document(let fields)? = current else { return nil }
      return fields.first { $0.key == key }?.value
    }
  }

  @Test("Schema export: JSON Schema and $jsonSchema with required, type mapping and depth note")
  func schemaExport() throws {
    let documents = try Self.parse([
      """
      {_id: ObjectId('6acc06e0aaaaaaaaaaaaaaaa'), name: 'Ada', nick: 'ada', age: 36,
       born: ISODate('1990-01-01T00:00:00Z'), tags: ['a'], a: {b: {c: {d: 1}}}}
      """,
      """
      {_id: ObjectId('6acc9380aaaaaaaaaaaaaaaa'), name: null, age: NumberLong('40'),
       born: ISODate('1991-01-01T00:00:00Z'), tags: [], a: {b: {c: {d: 2}}}}
      """,
    ])
    let report = MongoSchemaAnalyzer.analyze(documents, calendar: try Self.calendar())
    let required: MongoValue = .array(
      ["_id", "name", "age", "born", "tags", "a"].map { .string($0) })

    let json = try MongoRelaxedJSON.parse(MongoSchemaExport.jsonSchema(report))
    #expect(
      Self.member(json, "$schema") == .string("https://json-schema.org/draft/2020-12/schema"))
    #expect(Self.member(json, "type") == .string("object"))
    guard case .string(let summary)? = Self.member(json, "description") else {
      Issue.record("no description")
      return
    }
    #expect(summary.contains("2 documents"))
    #expect(Self.member(json, "required") == required)
    let properties = Self.member(json, "properties")
    #expect(Self.member(properties, "_id", "type") == .string("string"))
    #expect(Self.member(properties, "_id", "pattern") == .string("^[0-9a-fA-F]{24}$"))
    #expect(
      Self.member(properties, "name", "type") == .array([.string("null"), .string("string")]))
    #expect(Self.member(properties, "age", "type") == .string("integer"))
    #expect(Self.member(properties, "born", "type") == .string("string"))
    #expect(Self.member(properties, "born", "format") == .string("date-time"))
    #expect(Self.member(properties, "tags", "items", "type") == .string("string"))
    #expect(Self.member(properties, "a", "properties", "b", "description") == nil)
    #expect(
      Self.member(properties, "a", "properties", "b", "properties", "c", "description") != nil)

    let mongo = try MongoRelaxedJSON.parse(MongoSchemaExport.mongoJSONSchema(report))
    #expect(Self.member(mongo, "$schema") == nil)
    #expect(Self.member(mongo, "bsonType") == .string("object"))
    #expect(Self.member(mongo, "required") == required)
    let bsonProperties = Self.member(mongo, "properties")
    #expect(
      Self.member(bsonProperties, "_id") == .document([.init("bsonType", .string("objectId"))]))
    #expect(
      Self.member(bsonProperties, "age", "bsonType") == .array([.string("int"), .string("long")]))
    #expect(Self.member(bsonProperties, "born") == .document([.init("bsonType", .string("date"))]))
    #expect(Self.member(bsonProperties, "tags", "items", "bsonType") == .string("string"))
    #expect(
      Self.member(bsonProperties, "a", "properties", "b", "properties", "c", "description") != nil)
  }
}
