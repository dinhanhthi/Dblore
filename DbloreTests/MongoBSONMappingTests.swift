// MongoBSONMappingTests.swift
// MongoBSONMapping: BSON bytes <-> MongoValue for every type (checked against BSON 8's own reader
// and writer where they are exact), Decimal128 text encoding and formatting, malformed input,
// result cells, and result columns. The gated test sends mapping-encoded Decimal128 values to the
// docker MongoDB (TEST_RUNNER_MONGO_TESTS=1) and compares the server's `$toString`.

import BSON
import Foundation
import MongoClient
import MongoKitten
import NIOCore
import NIOPosix
import Testing

@testable import Dblore

@Suite("Mongo BSON mapping")
struct MongoBSONMappingTests {
  private typealias Mapping = MongoBSONMapping
  private static let hex = "507f1f77bcf86cd799439011"

  private func doc(_ pairs: (String, MongoValue)...) -> MongoValue {
    .document(pairs.map { MongoValue.Field($0.0, $0.1) })
  }

  private func oid(_ hex: String = Self.hex) -> MongoValue {
    .objectId(MongoObjectId(hex: hex)!)
  }

  private func roundTrip(_ value: MongoValue) throws -> MongoValue {
    let document = try Mapping.bsonDocument(value)
    #expect(document.validate().isValid)
    return try Mapping.document(document)
  }

  /// A BSON document from raw element bytes (size header and terminator added).
  private func bson(_ elements: [UInt8]) -> Document {
    let size = UInt32(elements.count + 5)
    let header = (0..<4).map { UInt8(truncatingIfNeeded: size >> (8 * $0)) }
    return Document(bytes: header + elements + [0])
  }

  private func mappingError(_ body: () throws -> Void) -> MongoBSONMapping.MappingError? {
    do {
      try body()
      return nil
    } catch let error as MongoBSONMapping.MappingError {
      return error
    } catch {
      Issue.record("unexpected error \(error)")
      return nil
    }
  }

  /// Every MongoValue case, with edge values.
  private var everyType: MongoValue {
    doc(
      ("_id", oid()),
      ("str", .string("h\u{E9}llo \u{2713} \u{0}nul")),
      ("i32", .int32(.min)),
      ("i64", .int64(.max)),
      ("dbl", .double(-0.0)),
      ("inf", .double(-.infinity)),
      ("dec", .decimal128("-1.50")),
      ("t", .bool(true)),
      ("f", .bool(false)),
      ("null", .null),
      ("date", .date(1_700_000_000_001)),
      ("before1970", .date(-62_135_596_800_001)),
      ("bin", .binary(subtype: 0x00, data: Data([0, 1, 254, 255]))),
      ("uuid", .binary(subtype: 0x04, data: Data(0..<16))),
      ("user", .binary(subtype: 0x80, data: Data())),
      ("regex", .regex(pattern: "^a.*z$", options: "imx")),
      ("ts", .timestamp(t: .max, i: 1)),
      ("min", .minKey),
      ("max", .maxKey),
      ("nested", doc(("a", .int32(1)), ("b", doc(("c", .array([])))))),
      ("arr", .array([.int32(1), .string("two"), .double(3), doc(("k", .bool(true)))])),
      ("dup", .int32(1)),
      ("dup", .string("again")),
      ("js", doc(("$code", .string("function () { return 1; }")))),
      (
        "jsScope",
        doc(("$code", .string("function () { return x; }")), ("$scope", doc(("x", .int32(1)))))
      ),
      ("empty", doc())
    )
  }

  // MARK: - Both directions

  @Test("Every type round-trips through BSON bytes, keeping key order and duplicate keys")
  func everyTypeRoundTrips() throws {
    #expect(try roundTrip(everyType) == everyType)
    let array = MongoValue.array([.int32(1), doc(("a", .null)), .array([.string("x")])])
    let document = try Mapping.bsonDocument(array)
    #expect(document.isArray)
    #expect(try Mapping.document(document) == array)
  }

  @Test("NaN round-trips; regex options are written in alphabetical order")
  func nanAndRegexOptions() throws {
    #expect(try roundTrip(doc(("n", .double(.nan)))) == doc(("n", .double(.nan))))
    #expect(
      try roundTrip(doc(("r", .regex(pattern: "a", options: "xmi"))))
        == doc(("r", .regex(pattern: "a", options: "imx"))))
  }

  @Test("Documents BSON 8 writes are read with the right types")
  func readsLibraryDocuments() throws {
    let id = try #require(ObjectId(Self.hex))
    var source = Document()
    source["_id"] = id
    source["i32"] = Int32(-5)
    source["i64"] = 9_007_199_254_740_993
    source["dbl"] = 2.5
    source["str"] = "h\u{E9}"
    source["bool"] = true
    source["date"] = Date(timeIntervalSince1970: 1_700_000_000)
    source["bin"] = Binary(subType: .uuid, buffer: ByteBuffer(bytes: [1, 2, 3]))
    source["regex"] = RegularExpression(pattern: "^a", options: "i")
    source["ts"] = Timestamp(increment: 7, timestamp: 1_700_000_000)
    source["null"] = Null()
    source["min"] = MinKey()
    source["max"] = MaxKey()
    source["nested"] = ["a": Int32(1)] as Document
    source["arr"] = [Int32(1), "two"] as Document
    source["js"] = JavaScriptCode("f()")
    source["jsScope"] = JavaScriptCodeWithScope("g()", scope: ["x": Int32(1)])

    let expected = doc(
      ("_id", oid()), ("i32", .int32(-5)), ("i64", .int64(9_007_199_254_740_993)),
      ("dbl", .double(2.5)), ("str", .string("h\u{E9}")), ("bool", .bool(true)),
      ("date", .date(1_700_000_000_000)),
      ("bin", .binary(subtype: 0x04, data: Data([1, 2, 3]))),
      ("regex", .regex(pattern: "^a", options: "i")),
      ("ts", .timestamp(t: 1_700_000_000, i: 7)), ("null", .null), ("min", .minKey),
      ("max", .maxKey), ("nested", doc(("a", .int32(1)))),
      ("arr", .array([.int32(1), .string("two")])),
      ("js", doc(("$code", .string("f()")))),
      ("jsScope", doc(("$code", .string("g()")), ("$scope", doc(("x", .int32(1)))))))
    #expect(try Mapping.document(source) == expected)
  }

  @Test("Documents the mapping writes are valid BSON that BSON 8 reads with the right types")
  func libraryReadsMappedDocuments() throws {
    let document = try Mapping.bsonDocument(everyType)
    #expect(document.validate().isValid)
    #expect(Array(document.keys.prefix(4)) == ["_id", "str", "i32", "i64"])
    #expect((document["_id"] as? ObjectId)?.hexString == Self.hex)
    #expect(document["str"] as? String == "h\u{E9}llo \u{2713} \u{0}nul")
    #expect(document["i32"] as? Int32 == .min)
    #expect(document["i64"] as? Int == .max)
    #expect((document["dbl"] as? Double).map { $0 == 0 && $0.sign == .minus } == true)
    #expect(document["t"] as? Bool == true)
    #expect(document["null"] is Null)
    let date = try #require(document["date"] as? Date)
    #expect((date.timeIntervalSince1970 * 1000).rounded() == 1_700_000_000_001)
    let uuid = try #require(document["uuid"] as? Binary)
    #expect(uuid.data == Data(0..<16))
    if case .uuid = uuid.subType {} else { Issue.record("uuid subtype \(uuid.subType)") }
    #expect((document["regex"] as? RegularExpression)?.pattern == "^a.*z$")
    let stamp = try #require(document["ts"] as? Timestamp)
    #expect(UInt32(bitPattern: stamp.timestamp) == .max)
    #expect(stamp.increment == 1)
    #expect(document["min"] is MinKey)
    #expect(document["max"] is MaxKey)
    #expect(document.typeIdentifier(forKey: "dec") == .decimal128)
    #expect((document["arr"] as? Document)?.isArray == true)
    #expect((document["nested"] as? Document)?.isArray == false)
    #expect((document["js"] as? JavaScriptCode)?.code == "function () { return 1; }")
    let scope = try #require(document["jsScope"] as? JavaScriptCodeWithScope)
    #expect(scope.code == "function () { return x; }")
    #expect(scope.scope["x"] as? Int32 == 1)
  }

  @Test("Driver primitives map to MongoValue, dates to exact milliseconds")
  func primitives() throws {
    #expect(try Mapping.value(from: Int32(3)) == .int32(3))
    #expect(try Mapping.value(from: 3) == .int64(3))
    #expect(try Mapping.value(from: 1.5) == .double(1.5))
    #expect(try Mapping.value(from: true) == .bool(true))
    #expect(try Mapping.value(from: "s") == .string("s"))
    #expect(try Mapping.value(from: Null()) == .null)
    #expect(try Mapping.value(from: MinKey()) == .minKey)
    #expect(try Mapping.value(from: MaxKey()) == .maxKey)
    #expect(try Mapping.value(from: try #require(ObjectId(Self.hex))) == oid())
    let date = Date(timeIntervalSince1970: Double(1_700_000_000_001) / 1000)
    #expect(try Mapping.value(from: date) == .date(1_700_000_000_001))
    #expect(
      try Mapping.value(from: Binary(subType: .userDefined(0x80), buffer: ByteBuffer(bytes: [9])))
        == .binary(subtype: 0x80, data: Data([9])))
    #expect(
      try Mapping.value(from: RegularExpression(pattern: "p", options: "s"))
        == .regex(pattern: "p", options: "s"))
    #expect(
      try Mapping.value(from: Timestamp(increment: -1, timestamp: 5))
        == .timestamp(t: 5, i: .max))
    #expect(try Mapping.value(from: JavaScriptCode("f()")) == doc(("$code", .string("f()"))))
    #expect(
      try Mapping.value(from: [Int32(1), "a"] as Document) == .array([.int32(1), .string("a")]))
    let decimal = try #require(
      try Mapping.bsonDocument(doc(("v", .decimal128("1.50"))))["v"] as? Decimal128)
    #expect(try Mapping.value(from: decimal) == .decimal128("1.50"))
    #expect(try Mapping.value(from: Unmapped()) == .string("Unmapped()"))
  }

  private struct Unmapped: Primitive {}

  @Test("Values become BSON primitives; documents keep their bytes")
  func primitivesFromValues() throws {
    #expect(try Mapping.primitive(.int32(5)) as? Int32 == 5)
    #expect(try Mapping.primitive(.int64(5)) as? Int == 5)
    #expect(try Mapping.primitive(.string("x")) as? String == "x")
    #expect(try Mapping.primitive(.null) is Null)
    let decimal = try #require(try Mapping.primitive(.decimal128("1E+10")) as? Decimal128)
    #expect(try Mapping.value(from: decimal) == .decimal128("1E+10"))
    let nested = try #require(try Mapping.primitive(doc(("a", .date(1)))) as? Document)
    #expect(try Mapping.document(nested) == doc(("a", .date(1))))
    #expect(try Mapping.value(from: try Mapping.primitive(everyType)) == everyType)
  }

  @Test("Deprecated undefined, DBPointer and symbol are read without dropping later fields")
  func deprecatedTypes() throws {
    let idBytes: [UInt8] = [0x50, 0x7F, 0x1F, 0x77, 0xBC, 0xF8, 0x6C, 0xD7, 0x99, 0x43, 0x90, 0x11]
    var elements: [UInt8] = [0x06] + Array("u".utf8) + [0]
    elements += [0x0E] + Array("s".utf8) + [0, 3, 0, 0, 0] + Array("ab".utf8) + [0]
    elements += [0x0C] + Array("p".utf8) + [0, 5, 0, 0, 0] + Array("db.c".utf8) + [0] + idBytes
    elements += [0x10] + Array("z".utf8) + [0, 7, 0, 0, 0]
    let pointer = doc(("$dbPointer", doc(("$ref", .string("db.c")), ("$id", oid()))))
    #expect(
      try Mapping.document(bson(elements))
        == doc(("u", .null), ("s", .string("ab")), ("p", pointer), ("z", .int32(7))))
  }

  @Test("Malformed BSON throws instead of crashing or truncating")
  func malformedInput() {
    let int32Field: [UInt8] = [0x10, 0x61, 0, 1, 0, 0, 0]
    let cases: [(String, Document)] = [
      ("unknown type", bson([0x14, 0x61, 0, 1])),
      ("truncated value", bson([0x12, 0x61, 0, 1, 2])),
      ("unterminated key", Document(bytes: [9, 0, 0, 0, 0x10, 0x61, 0x62, 0x63, 0x64])),
      ("size too large", Document(bytes: [99, 0, 0, 0] + int32Field + [0])),
      ("size too small", Document(bytes: [3, 0, 0, 0, 0])),
      ("trailing bytes", Document(bytes: Array(bson(int32Field).makeData()) + [0])),
      ("negative string length", bson([0x02, 0x61, 0, 0xFF, 0xFF, 0xFF, 0xFF])),
      ("string without NUL", bson([0x02, 0x61, 0, 2, 0, 0, 0, 0x62, 0x63])),
    ]
    for (name, document) in cases {
      #expect(mappingError { _ = try Mapping.document(document) } != nil, "\(name)")
    }

    var deep: [UInt8] = [5, 0, 0, 0, 0]
    for _ in 0...Mapping.maxDepth {
      let body: [UInt8] = [0x03, 0x61, 0] + deep
      let size = UInt32(body.count + 5)
      deep = (0..<4).map { UInt8(truncatingIfNeeded: size >> (8 * $0)) } + body + [0]
    }
    #expect(mappingError { _ = try Mapping.document(Document(bytes: deep)) } != nil)
  }

  @Test("Values BSON cannot hold are refused")
  func writerRefusals() {
    #expect(mappingError { _ = try Mapping.bsonDocument(.int32(1)) } != nil)
    #expect(mappingError { _ = try Mapping.bsonDocument(doc(("a\u{0}b", .null))) } != nil)
    let regex = MongoValue.regex(pattern: "a\u{0}", options: "")
    #expect(mappingError { _ = try Mapping.bsonDocument(doc(("r", regex))) } != nil)
    #expect(mappingError { _ = try Mapping.bsonDocument(doc(("d", .decimal128("1e")))) } != nil)
    var deep = MongoValue.null
    for _ in 0...Mapping.maxDepth { deep = doc(("a", deep)) }
    #expect(mappingError { _ = try Mapping.bsonDocument(deep) } != nil)
  }

  // MARK: - Decimal128

  /// Input text and the canonical text the server's `$toString` prints for it.
  static let decimalTable: [(String, String)] = [
    ("1234.5678", "1234.5678"),
    ("-0.0001", "-0.0001"),
    ("1.50", "1.50"),
    ("0", "0"),
    ("-0", "-0"),
    ("1E+10", "1E+10"),
    ("1E-7", "1E-7"),
    ("1234567890123456789012345678901234", "1234567890123456789012345678901234"),
    ("9.999999999999999999999999999999999E+6144", "9.999999999999999999999999999999999E+6144"),
    ("1E-6176", "1E-6176"),
    ("Infinity", "Infinity"),
    ("-Infinity", "-Infinity"),
    ("NaN", "NaN"),
  ]

  /// Accepted spellings that print differently (clamping, exact zero folding, case).
  static let decimalNormalized: [(String, String)] = [
    ("0.0000001", "1E-7"),
    ("+12", "12"),
    ("00012.3400", "12.3400"),
    (".5", "0.5"),
    ("5.", "5"),
    ("1e3", "1E+3"),
    ("0.00", "0.00"),
    ("0E+9999", "0E+6111"),
    ("-0E-9999", "-0E-6176"),
    ("1E+6144", "1.000000000000000000000000000000000E+6144"),
    ("10E-6177", "1E-6176"),
    ("1000000000000000000000000000000000000", "1.000000000000000000000000000000000E+36"),
    ("inf", "Infinity"),
    ("-INFINITY", "-Infinity"),
    ("-nan", "NaN"),
  ]

  @Test(
    "Decimal128 text encodes to 0x13 bytes and decodes to the same text", arguments: decimalTable)
  func decimalRoundTrip(input: String, expected: String) throws {
    let value = try roundTrip(doc(("d", .decimal128(input))))
    #expect(value == doc(("d", .decimal128(expected))))
  }

  @Test("Decimal128 spellings normalize to the canonical text", arguments: decimalNormalized)
  func decimalNormalizes(input: String, expected: String) throws {
    let value = try roundTrip(doc(("d", .decimal128(input))))
    #expect(value == doc(("d", .decimal128(expected))))
  }

  @Test("Decimal128 bit layout follows the BID spec (sign, biased exponent, coefficient)")
  func decimalBits() throws {
    #expect(try Decimal128Text.encode("1") == (low: 1, high: 0x3040_0000_0000_0000))
    #expect(try Decimal128Text.encode("-1") == (low: 1, high: 0xB040_0000_0000_0000))
    #expect(try Decimal128Text.encode("0.1") == (low: 1, high: 0x303E_0000_0000_0000))
    #expect(try Decimal128Text.encode("Infinity") == (low: 0, high: 0x7800_0000_0000_0000))
    #expect(try Decimal128Text.encode("NaN") == (low: 0, high: 0x7C00_0000_0000_0000))
    #expect(
      try Decimal128Text.encode("9.999999999999999999999999999999999E+6144")
        == (low: 0x378D_8E63_FFFF_FFFF, high: 0x5FFF_ED09_BEAD_87C0))
    // Wire order: low word then high word, each little-endian.
    let data = try Mapping.bsonDocument(doc(("v", .decimal128("1")))).makeData()
    #expect(Array(data[7..<23]) == [1] + Array(repeating: 0, count: 13) + [0x40, 0x30])
    // A non-canonical coefficient (above 10^34 - 1) reads as zero.
    #expect(Decimal128Text.format(low: .max, high: 0x6C10_0000_0000_0000) == "0")
  }

  @Test(
    "Invalid or unrepresentable Decimal128 text is refused",
    arguments: [
      "", "abc", "1.2.3", "1e", "--1", "1E+", "Infinit",
      "12345678901234567890123456789012345", "1.234567890123456789012345678901234E+6145",
      "1E+6145", "1E-6177", "1.5E-6176",
    ])
  func decimalRefused(text: String) {
    #expect(mappingError { _ = try Decimal128Text.encode(text) } != nil)
  }

  // MARK: - Cells

  @Test("Cells per Key decision d")
  @MainActor
  func cellValues() {
    #expect(Mapping.cellValue(.int32(-3)) == .int(-3))
    #expect(Mapping.cellValue(.int64(.max)) == .int(.max))
    #expect(Mapping.cellValue(.double(2.5)) == .double(2.5))
    #expect(Mapping.cellValue(.bool(false)) == .bool(false))
    #expect(Mapping.cellValue(.date(1_500)) == .date(Date(timeIntervalSince1970: 1.5)))
    #expect(Mapping.cellValue(.binary(subtype: 4, data: Data([1]))) == .data(Data([1])))
    #expect(Mapping.cellValue(.decimal128("1.50")) == .string("1.50"))
    #expect(Mapping.cellValue(oid()) == .string(Self.hex))
    #expect(Mapping.cellValue(.string("s")) == .string("s"))
    #expect(Mapping.cellValue(.null) == .null)
    #expect(Mapping.cellValue(.regex(pattern: "^a", options: "i")) == .string("/^a/i"))
    #expect(Mapping.cellValue(.timestamp(t: 5, i: 6)) == .string("Timestamp(5, 6)"))
    #expect(Mapping.cellValue(.minKey) == .string("MinKey()"))
    #expect(Mapping.cellValue(.maxKey) == .string("MaxKey()"))
    #expect(
      Mapping.cellValue(doc(("a", .int64(1)))) == .json("{\"a\": {\"$numberLong\": \"1\"}}"))
    #expect(Mapping.cellValue(.array([.int32(1)])) == .json("[{\"$numberInt\": \"1\"}]"))
  }

  @Test("JSON cells hold canonical Extended JSON that parses back to the same value")
  func jsonCellsRoundTrip() throws {
    guard case .document(let fields) = everyType else { return }
    for field in fields {
      guard case .json(let text) = Mapping.cellValue(field.value) else { continue }
      #expect(try MongoRelaxedJSON.parse(text) == field.value, "\(field.key)")
    }
    guard case .json(let text) = Mapping.cellValue(everyType) else {
      Issue.record("document cell is not JSON")
      return
    }
    #expect(try MongoRelaxedJSON.parse(text) == everyType)
  }

  // MARK: - Columns and rows

  private func columns(_ documents: [MongoValue]) -> [String] {
    Mapping.columns(for: documents).map { "\($0.name):\($0.type)" }
  }

  @Test("Columns: _id first, then first-seen order across documents")
  func columnOrder() {
    let documents = [
      doc(("b", .int32(1)), ("_id", oid())),
      doc(("_id", oid()), ("c", .string("x")), ("b", .int32(2))),
      doc(("a", .bool(true))),
    ]
    #expect(columns(documents) == ["_id:objectId", "b:int", "c:string", "a:bool"])
  }

  @Test("Columns: different types are mixed; null and missing never count")
  func columnTypes() {
    let documents = [
      doc(("_id", .int32(1)), ("n", .null), ("x", .null), ("m", .int32(1)), ("d", .null)),
      doc(("_id", .string("k")), ("n", .null), ("x", .int64(2)), ("m", .int64(1))),
      doc(("_id", oid()), ("d", .date(0))),
    ]
    #expect(columns(documents) == ["_id:mixed", "n:null", "x:long", "m:mixed", "d:date"])
  }

  @Test("Columns: zero documents give _id typed objectId; no _id is not invented")
  func columnEdges() {
    #expect(columns([]) == ["_id:objectId"])
    #expect(columns([doc(("a", .int32(1)))]) == ["a:int"])
    #expect(columns([doc()]) == [])
  }

  @Test("Type names are MongoDB $type aliases")
  func typeNames() {
    let names = [
      Mapping.typeName(oid()), Mapping.typeName(.string("")), Mapping.typeName(.int32(0)),
      Mapping.typeName(.int64(0)), Mapping.typeName(.double(0)),
      Mapping.typeName(.decimal128("0")), Mapping.typeName(.bool(true)),
      Mapping.typeName(.date(0)), Mapping.typeName(.binary(subtype: 0, data: Data())),
      Mapping.typeName(doc()), Mapping.typeName(.array([])), Mapping.typeName(.null),
      Mapping.typeName(.regex(pattern: "", options: "")),
      Mapping.typeName(.timestamp(t: 0, i: 0)), Mapping.typeName(.minKey),
      Mapping.typeName(.maxKey), Mapping.typeName(doc(("$code", .string("f")))),
      Mapping.typeName(doc(("$code", .string("f")), ("$scope", doc()))),
      Mapping.typeName(doc(("$code", .int32(1)))),
    ]
    #expect(
      names == [
        "objectId", "string", "int", "long", "double", "decimal", "bool", "date", "binData",
        "object", "array", "null", "regex", "timestamp", "minKey", "maxKey", "javascript",
        "javascriptWithScope", "object",
      ])
  }

  @Test("Rows follow the columns; missing keys are null and duplicates show the first value")
  @MainActor
  func rows() {
    let documents = [
      doc(("_id", oid()), ("a", .int32(1)), ("a", .int32(2))),
      doc(("b", .string("x")), ("_id", oid())),
    ]
    let columns = Mapping.columns(for: documents)
    #expect(
      Mapping.row(for: documents[0], columns: columns) == [.string(Self.hex), .int(1), .null])
    #expect(
      Mapping.row(for: documents[1], columns: columns) == [.string(Self.hex), .null, .string("x")])
    #expect(Mapping.row(for: .int32(1), columns: columns) == [.null, .null, .null])
  }

  // MARK: - Live server

  @Test(
    "The server stores mapping-encoded Decimal128 exactly ($toString) and reads back the same text",
    .requiresMongo)
  func decimalOnServer() async throws {
    let table = Self.decimalTable + Self.decimalNormalized
    let settings = ConnectionSettings(
      authentication: .scramSha256(
        username: TestMongoDatabase.username, password: TestMongoDatabase.password),
      authenticationSource: TestMongoDatabase.authSource,
      hosts: [
        ConnectionSettings.Host(hostname: TestMongoDatabase.host, port: TestMongoDatabase.port)
      ],
      targetDatabase: TestMongoDatabase.database)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let cluster = try await MongoCluster(connectingTo: settings, eventLoopGroup: group)
    let database = cluster[TestMongoDatabase.database]
    let collection = database["bson_mapping_decimal"]
    do {
      try? await collection.drop()
      var fields = [MongoValue.Field("_id", .string("dec"))]
      for (index, entry) in table.enumerated() {
        fields.append(MongoValue.Field("d\(index)", .decimal128(entry.0)))
      }
      let insert = try await collection.insert(try Mapping.bsonDocument(.document(fields)))
      #expect(insert.insertCount == 1)

      var projection: Document = ["_id": 0]
      for index in table.indices {
        projection["d\(index)"] = ["$toString": "$d\(index)"] as Document
      }
      let pipeline: [Document] = [
        ["$match": ["_id": "dec"] as Document], ["$project": projection],
      ]
      let connection = try await database.pool.next(for: .basic)
      let reply = try await connection.execute(
        ["aggregate": collection.name, "pipeline": pipeline, "cursor": [:] as Document],
        namespace: database.commandNamespace
      ).getDocument()
      let batch = (reply["cursor"] as? Document)?["firstBatch"] as? Document
      let serverTexts = try #require(batch?.values.first as? Document)

      let stored = try #require(try await collection.findOne(["_id": "dec"]))
      var back: [MongoValue.Field] = []
      if case .document(let fields) = try Mapping.document(stored) { back = fields }
      for (index, entry) in table.enumerated() {
        let key = "d\(index)"
        #expect(serverTexts[key] as? String == entry.1, "\(entry.0) $toString")
        #expect(stored.typeIdentifier(forKey: key) == .decimal128)
        #expect(back.first { $0.key == key }?.value == .decimal128(entry.1), "\(entry.0) read")
      }
      try await collection.drop()
    } catch {
      try? await collection.drop()
      await cluster.disconnect()
      try await group.shutdownGracefully()
      throw error
    }
    await cluster.disconnect()
    try await group.shutdownGracefully()
  }
}
