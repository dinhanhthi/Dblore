// MongoRelaxedJSONTests.swift
// MongoValue parsing (relaxed JSON, mongosh helpers, canonical Extended JSON wrappers), error
// offsets, limits, and the exact round-trips of canonical Extended JSON and mongosh notation

import Foundation
import Testing

@testable import Dblore

@Suite("Mongo relaxed JSON")
struct MongoRelaxedJSONTests {

  private static let hex = "507f1f77bcf86cd799439011"

  private func doc(_ pairs: (String, MongoValue)...) -> MongoValue {
    .document(pairs.map { MongoValue.Field($0.0, $0.1) })
  }

  private func oid(_ hex: String = Self.hex) -> MongoValue {
    .objectId(MongoObjectId(hex: hex)!)
  }

  private func parse(_ text: String) throws -> MongoValue {
    try MongoRelaxedJSON.parse(text)
  }

  private func parseError(_ text: String) -> MongoRelaxedJSON.ParseError? {
    do {
      _ = try MongoRelaxedJSON.parse(text)
      return nil
    } catch {
      return error
    }
  }

  private func render(_ value: MongoValue, _ format: MongoRelaxedJSON.Format) -> String {
    MongoRelaxedJSON.render(value, as: format)
  }

  // MARK: - Syntax

  @Test("Unquoted and quoted keys, trailing commas, comments and duplicate keys")
  func relaxedSyntax() throws {
    #expect(
      try parse("{a: 1, 'b': \"x\", $set: {c_d: [1, 2,],}, }")
        == doc(
          ("a", .int32(1)), ("b", .string("x")),
          ("$set", doc(("c_d", .array([.int32(1), .int32(2)]))))))
    #expect(
      try parse("// lead\n{ /* c */ a: /* d */ true, b: false, c: null } // tail")
        == doc(("a", .bool(true)), ("b", .bool(false)), ("c", .null)))
    #expect(try parse("{a: 1, a: 2}") == doc(("a", .int32(1)), ("a", .int32(2))))
    #expect(try parse(" [ ] ") == .array([]))
    #expect(try parse("{}") == .document([]))
    #expect(parseError("[1,,2]") != nil)
    #expect(parseError("{,}") != nil)
    #expect(parseError("{a.b: 1}") != nil)
  }

  @Test("String escapes, including \\u and surrogate pairs, in both quote styles")
  func stringEscapes() throws {
    #expect(
      try parse(#"" \" \\ \/ \b\f\n\r\t é 😀 \' ""#)
        == .string(" \" \\ / \u{8}\u{C}\n\r\t é 😀 ' "))
    #expect(try parse(#"'it\'s "ok"'"#) == .string("it's \"ok\""))
    #expect(try parse("'tab\there é'") == .string("tab\there é"))
    #expect(parseError(#""\uD800""#) != nil)
    #expect(parseError(#""\uD800A""#) != nil)
    #expect(parseError(#""\uDC00""#) != nil)
    #expect(parseError(#""\x41""#) != nil)
    #expect(parseError("\"a\nb\"") != nil)
  }

  /// Unlike mongosh (where every plain number is a double), an integer literal stays an integer:
  /// int32 when it fits, else int64, else double. Anything with `.` or an exponent is a double.
  @Test("Plain numbers: int32, then int64, then double; fraction or exponent means double")
  func numberTyping() throws {
    #expect(try parse("0") == .int32(0))
    #expect(try parse("-0") == .int32(0))
    #expect(try parse("2147483647") == .int32(.max))
    #expect(try parse("-2147483648") == .int32(.min))
    #expect(try parse("2147483648") == .int64(2_147_483_648))
    #expect(try parse("-9223372036854775808") == .int64(.min))
    #expect(try parse("9223372036854775807") == .int64(.max))
    #expect(try parse("9223372036854775808") == .double(9_223_372_036_854_775_808))
    #expect(try parse("1.0") == .double(1))
    #expect(try parse("1e2") == .double(100))
    #expect(try parse("1E+20") == .double(1e20))
    #expect(try parse("-0.0") == .double(-0.0))
    #expect(try parse("Infinity") == .double(.infinity))
    #expect(try parse("-Infinity") == .double(-.infinity))
    #expect(try parse("NaN") == .double(.nan))
    for bad in ["01", "1.", ".5", "1e", "0x10", "+1", "-", "1a", "inf"] {
      #expect(parseError(bad) != nil, "\(bad)")
    }
  }

  @Test("Double equality: NaN equals NaN, -0.0 differs from 0.0, types never mix")
  func doubleEquality() {
    #expect(MongoValue.double(.nan) == .double(-.nan))
    #expect(MongoValue.double(.nan) != .double(0))
    #expect(MongoValue.double(0.0) != .double(-0.0))
    #expect(MongoValue.double(1) != .int32(1))
    #expect(MongoValue.int32(1) != .int64(1))
  }

  @Test("mongosh helpers: ObjectId, ISODate, new Date, NumberLong, NumberInt, NumberDecimal")
  func mongoshScalarHelpers() throws {
    #expect(try parse(#"ObjectId("507F1F77BCF86CD799439011")"#) == oid())
    #expect(parseError("ObjectId('507f1f77bcf86cd79943901')") != nil)
    #expect(parseError("ObjectId()") != nil)

    let noon: Int64 = 1_709_210_096_000
    #expect(try parse(#"ISODate("2024-02-29T12:34:56Z")"#) == .date(noon))
    #expect(try parse(#"ISODate("2024-02-29T12:34:56.789Z")"#) == .date(noon + 789))
    #expect(try parse(#"ISODate("2024-02-29T14:34:56.789+02:00")"#) == .date(noon + 789))
    #expect(try parse(#"ISODate("2024-02-29T07:04:56.789123-0530")"#) == .date(noon + 789))
    #expect(try parse(#"ISODate("2024-02-29T12:34:56.7")"#) == .date(noon + 700))
    #expect(try parse(#"ISODate("2024-02-29")"#) == .date(1_709_164_800_000))
    #expect(try parse(#"new Date("1969-12-31T23:59:59.999Z")"#) == .date(-1))
    #expect(try parse("new Date(-62135596800000)") == .date(-62_135_596_800_000))
    #expect(try parse("new  Date( 0 )") == .date(0))
    for bad in ["2023-02-29T00:00:00Z", "2024-13-01", "2024-01-01T24:00:00Z", "not a date", ""] {
      #expect(parseError("ISODate(\"\(bad)\")") != nil, "\(bad)")
    }
    #expect(parseError("new Date(1.5)") != nil)
    #expect(parseError("Date(\"2024-01-01\")") != nil)

    #expect(try parse("NumberLong(5)") == .int64(5))
    #expect(try parse(#"NumberLong("-9223372036854775808")"#) == .int64(.min))
    #expect(parseError("NumberLong(1.5)") != nil)
    #expect(parseError(#"NumberLong("9223372036854775808")"#) != nil)
    #expect(try parse("NumberInt(7)") == .int32(7))
    #expect(try parse(#"NumberInt("-2147483648")"#) == .int32(.min))
    #expect(parseError("NumberInt(2147483648)") != nil)

    for text in ["1.50", "-1.5E+10", "Infinity", "-inf", "NaN", ".5", "5.", "+0e-6176"] {
      #expect(try parse("NumberDecimal(\"\(text)\")") == .decimal128(text), "\(text)")
    }
    for bad in ["1.2.3", "abc", "1e", "", "1e+", "--1", "0x1"] {
      #expect(parseError("NumberDecimal(\"\(bad)\")") != nil, "\(bad)")
    }
    #expect(parseError("NumberDecimal(1.5)") != nil)
  }

  @Test("Long, as current mongosh prints int64, is an alias of NumberLong")
  func longAlias() throws {
    let big: Int64 = 9_007_199_254_740_993
    for text in ["'9007199254740993'", #""9007199254740993""#, "9007199254740993"] {
      #expect(try parse("Long(\(text))") == .int64(big), "\(text)")
      #expect(try parse("Long(\(text))") == parse("NumberLong(\(text))"), "\(text)")
    }
    #expect(parseError("Long(1.5)") != nil)
  }

  @Test("mongosh helpers: Timestamp, BinData, RegExp, regex literal, MinKey, MaxKey")
  func mongoshOtherHelpers() throws {
    #expect(try parse("Timestamp(1700000000, 3)") == .timestamp(t: 1_700_000_000, i: 3))
    #expect(try parse("Timestamp({ t: 1700000000, i: 3 })") == .timestamp(t: 1_700_000_000, i: 3))
    #expect(try parse("Timestamp(4294967295, 0)") == .timestamp(t: .max, i: 0))
    #expect(parseError("Timestamp(-1, 0)") != nil)
    #expect(parseError("Timestamp(1)") != nil)

    #expect(
      try parse(#"BinData(4, "AAEC/w==")"#) == .binary(subtype: 4, data: Data([0, 1, 2, 255])))
    #expect(try parse(#"BinData(0, "")"#) == .binary(subtype: 0, data: Data()))
    #expect(parseError(#"BinData(0, "!!")"#) != nil)
    #expect(parseError(#"BinData(256, "")"#) != nil)

    #expect(try parse(#"RegExp("a/b", "i")"#) == .regex(pattern: "a/b", options: "i"))
    #expect(try parse(#"RegExp("a")"#) == .regex(pattern: "a", options: ""))
    #expect(try parse("/ab+c/i") == .regex(pattern: "ab+c", options: "i"))
    #expect(try parse(#"/a\/b[/]/"#) == .regex(pattern: #"a\/b[/]"#, options: ""))
    #expect(try parse("{ name: /^Jo/ }") == doc(("name", .regex(pattern: "^Jo", options: ""))))
    #expect(parseError("/abc") != nil)
    #expect(parseError("/a\nb/") != nil)

    #expect(try parse("[MinKey(), MaxKey()]") == .array([.minKey, .maxKey]))
    for bad in ["undefined", #"Code("x")"#, "MinKey", "new ISODate(\"2024-01-01\")"] {
      #expect(parseError(bad) != nil, "\(bad)")
    }
  }

  @Test("Canonical Extended JSON wrappers, recognised only with exactly their keys")
  func canonicalWrappers() throws {
    let cases: [(String, MongoValue)] = [
      (#"{"$oid": "507F1F77BCF86CD799439011"}"#, oid()),
      (#"{"$date": {"$numberLong": "-1"}}"#, .date(-1)),
      (#"{"$date": "1970-01-01T00:00:00.001Z"}"#, .date(1)),
      (#"{"$numberLong": "42"}"#, .int64(42)),
      (#"{"$numberInt": "-7"}"#, .int32(-7)),
      (#"{"$numberDouble": "Infinity"}"#, .double(.infinity)),
      (#"{"$numberDouble": "-Infinity"}"#, .double(-.infinity)),
      (#"{"$numberDouble": "NaN"}"#, .double(.nan)),
      (#"{"$numberDouble": "-0.0"}"#, .double(-0.0)),
      (#"{"$numberDouble": "1.5"}"#, .double(1.5)),
      (#"{"$numberDecimal": "1.10"}"#, .decimal128("1.10")),
      (
        #"{"$binary": {"base64": "AAEC", "subType": "80"}}"#,
        .binary(subtype: 0x80, data: Data([0, 1, 2]))
      ),
      (#"{"$binary": {"subType": "4", "base64": ""}}"#, .binary(subtype: 4, data: Data())),
      (
        #"{"$regularExpression": {"pattern": "^a", "options": "im"}}"#,
        .regex(pattern: "^a", options: "im")
      ),
      (#"{"$timestamp": {"t": 4294967295, "i": 1}}"#, .timestamp(t: .max, i: 1)),
      (#"{"$minKey": 1}"#, .minKey),
      (#"{"$maxKey": 1}"#, .maxKey),
    ]
    for (text, expected) in cases {
      #expect(try parse(text) == expected, "\(text)")
    }

    #expect(
      try parse(#"{"$oid": "507f1f77bcf86cd799439011", "x": 1}"#)
        == doc(("$oid", .string(Self.hex)), ("x", .int32(1))))
    #expect(
      try parse(#"{$regex: "a", $options: "i"}"#)
        == doc(("$regex", .string("a")), ("$options", .string("i"))))
    #expect(
      try parse(#"{"$numberLong": "1", "$numberLong": "2"}"#)
        == doc(("$numberLong", .string("1")), ("$numberLong", .string("2"))))

    let malformed = [
      #"{$oid: 5}"#, #"{$numberLong: "1.5"}"#, #"{$numberInt: "2147483648"}"#,
      #"{$numberDouble: "inf"}"#, #"{$numberDouble: "0x1p3"}"#, #"{$date: true}"#,
      #"{$minKey: 2}"#, #"{$binary: {base64: "", subType: "00", x: 1}}"#,
      #"{$binary: {base64: "", subType: "100"}}"#, #"{$timestamp: {t: 1}}"#,
      #"{$numberDecimal: "x"}"#, #"{$regularExpression: {pattern: 1, options: ""}}"#,
    ]
    for text in malformed {
      #expect(parseError(text) != nil, "\(text)")
    }
  }

  // MARK: - Errors and limits

  /// Offsets count UTF-16 code units from the start of the text.
  @Test("Errors carry a UTF-16 offset")
  func errorOffsets() {
    let cases: [(String, Int)] = [
      ("", 0),
      ("   ", 3),
      ("{a: }", 4),
      (#"{"😀": }"#, 7),
      (#"{"é": 01}"#, 6),
      ("[1 2]", 3),
      ("{a: 1", 5),
      ("{a: 1} x", 7),
      ("\"abc", 0),
      ("/* open", 0),
      (#"{a: ObjectId("zz")}"#, 13),
      ("{a: @}", 4),
    ]
    for (text, offset) in cases {
      let error = parseError(text)
      #expect(error?.offset == offset, "\(text)")
      #expect(error?.message.isEmpty == false, "\(text)")
    }
  }

  @Test("Nesting deeper than 100 levels is refused; wrapper braces do not count")
  func depthLimit() throws {
    func arrays(_ n: Int) -> String {
      String(repeating: "[", count: n) + String(repeating: "]", count: n)
    }
    #expect(try parse(arrays(100)).nestingDepth == 100)
    #expect(parseError(arrays(101))?.offset == 100)
    #expect(parseError(arrays(5000))?.offset == 100)

    var deep = doc(("at", .date(1)), ("bin", .binary(subtype: 0, data: Data([1]))))
    for _ in 1..<100 { deep = doc(("x", deep)) }
    #expect(deep.nestingDepth == 100)
    #expect(try parse(render(deep, .canonicalExtendedJSON)) == deep)
    #expect(parseError(render(doc(("x", deep)), .canonicalExtendedJSON)) != nil)

    // Helpers nest like brackets: a deep chain is refused, never a stack overflow
    let tooDeep = "Nesting is deeper than \(MongoRelaxedJSON.maxDepth) levels"
    for count in [200, 5000] {
      for opener in ["ObjectId(", "MinKey(", "NumberLong(", "new Date("] {
        let text =
          String(repeating: opener, count: count) + "\"x\"" + String(repeating: ")", count: count)
        #expect(parseError(text)?.message == tooDeep, "\(opener) \(count)")
      }
    }
    #expect(parseError(String(repeating: "MinKey(", count: 100_000))?.message == tooDeep)
    // Helper arguments still parse within the wrapper slack below the deepest bracket
    func inArrays(_ value: MongoValue) -> MongoValue {
      (0..<100).reduce(value) { inner, _ in .array([inner]) }
    }
    let brackets = (String(repeating: "[", count: 100), String(repeating: "]", count: 100))
    #expect(
      try parse(brackets.0 + "Timestamp({t: 1, i: 2})" + brackets.1)
        == inArrays(.timestamp(t: 1, i: 2)))
    #expect(try parse(brackets.0 + "new Date(NumberLong(5))" + brackets.1) == inArrays(.date(5)))
  }

  @Test("Input above 1 MiB of UTF-8 is refused")
  func sizeLimit() throws {
    let limit = MongoRelaxedJSON.maxInputBytes
    #expect(limit == 1_048_576)
    let fits = "\"" + String(repeating: "x", count: limit - 2) + "\""
    #expect(try parse(fits) == .string(String(repeating: "x", count: limit - 2)))
    #expect(parseError("\"" + String(repeating: "x", count: limit - 1) + "\"")?.offset == 0)
    #expect(parseError("\"" + String(repeating: "é", count: limit / 2) + "\"") != nil)
  }

  @Test("parse(maxBytes:) accepts a document over 1 MiB that parse(_:) refuses")
  func perCallSizeLimit() throws {
    let text = "{a: \"" + String(repeating: "x", count: MongoRelaxedJSON.maxInputBytes) + "\"}"
    #expect(
      try MongoRelaxedJSON.parse(text, maxBytes: 2 * 1_048_576)
        == doc(("a", .string(String(repeating: "x", count: MongoRelaxedJSON.maxInputBytes)))))
    let error = parseError(text)
    #expect(error?.message == "The text is larger than 1 MiB")
    #expect(error?.offset == 0)
  }

  // MARK: - Rendering

  @Test("The three renderers on one document")
  func renderFormats() {
    let value = doc(
      ("_id", oid()), ("n", .int64(5)), ("i", .int32(1)), ("d", .double(1)), ("at", .date(0)),
      ("a b", .array([])), ("", .document([])))
    #expect(
      render(value, .canonicalExtendedJSON)
        == #"{"_id": {"$oid": "507f1f77bcf86cd799439011"}, "n": {"$numberLong": "5"}, "#
        + #""i": {"$numberInt": "1"}, "d": {"$numberDouble": "1.0"}, "#
        + #""at": {"$date": {"$numberLong": "0"}}, "a b": [], "": {}}"#)
    #expect(
      render(value, .relaxedExtendedJSON)
        == #"{"_id": {"$oid": "507f1f77bcf86cd799439011"}, "n": 5, "i": 1, "d": 1.0, "#
        + #""at": {"$date": "1970-01-01T00:00:00.000Z"}, "a b": [], "": {}}"#)
    #expect(
      render(value, .mongosh)
        == #"{ _id: ObjectId("507f1f77bcf86cd799439011"), n: NumberLong("5"), i: 1, d: 1.0, "#
        + #"at: ISODate("1970-01-01T00:00:00.000Z"), "a b": [], "": {} }"#)
  }

  @Test("mongosh notation for every scalar kind")
  func mongoshScalars() {
    let cases: [(MongoValue, String)] = [
      (.timestamp(t: 1, i: 2), "Timestamp(1, 2)"),
      (.binary(subtype: 4, data: Data([0, 1])), #"BinData(4, "AAE=")"#),
      (.regex(pattern: "a", options: "i"), "/a/i"),
      (.regex(pattern: "a/b", options: ""), #"RegExp("a/b", "")"#),
      (.regex(pattern: "", options: ""), #"RegExp("", "")"#),
      (.minKey, "MinKey()"),
      (.maxKey, "MaxKey()"),
      (.decimal128("1.5"), #"NumberDecimal("1.5")"#),
      (.date(-62_167_219_200_000), #"ISODate("0000-01-01T00:00:00.000Z")"#),
      (.date(-62_167_219_200_001), "new Date(-62167219200001)"),
      (.double(.nan), "NaN"),
      (.double(-.infinity), "-Infinity"),
      (.double(-0.0), "-0.0"),
      (.double(1e20), "1e+20"),
      (.string("a\"b\n"), #""a\"b\n""#),
      (.array([.int32(1), .null, .bool(true)]), "[ 1, null, true ]"),
      (doc(("$set", .int32(1)), ("a.b", .int32(2))), #"{ $set: 1, "a.b": 2 }"#),
    ]
    for (value, text) in cases {
      #expect(render(value, .mongosh) == text, "\(text)")
    }
  }

  /// Relaxed Extended JSON is for display and copy only: it drops the int64 and date types, so
  /// it is never stored or offered for editing.
  @Test("Relaxed Extended JSON is lossy: a small int64 comes back as int32")
  func relaxedIsDisplayOnly() throws {
    let value = doc(("n", .int64(5)))
    let relaxed = render(value, .relaxedExtendedJSON)
    #expect(relaxed == #"{"n": 5}"#)
    #expect(try parse(relaxed) == doc(("n", .int32(5))))
    #expect(try parse(relaxed) != value)
    #expect(render(.date(-1), .relaxedExtendedJSON) == #"{"$date": {"$numberLong": "-1"}}"#)
    #expect(render(.double(.infinity), .relaxedExtendedJSON) == #"{"$numberDouble": "Infinity"}"#)
  }

  // MARK: - Round-trips

  private static var edgeValues: [MongoValue] {
    var values: [MongoValue] = [
      .int32(.min), .int32(.max), .int32(0), .int64(.min), .int64(.max), .int64(0), .int64(5),
      .string(""), .string("plain"), .string("quote \" and \\ and '"),
      .string("line\nbreak\ttab\u{0}\u{1F}\u{7F}"), .string("é 😀 \u{2028} 中文"),
      .string("/* not a comment */ // nor this"),
      .decimal128("1.50"), .decimal128("-0"), .decimal128("1E+6144"), .decimal128("NaN"),
      .decimal128("-Infinity"),
      .bool(true), .bool(false), .null, .minKey, .maxKey,
      .objectId(MongoObjectId(hex: hex)!),
      .binary(subtype: 0, data: Data()),
      .binary(subtype: 4, data: Data((0..<16).map { UInt8($0) })),
      .binary(subtype: 255, data: Data([0xff])),
      .timestamp(t: 0, i: 0), .timestamp(t: .max, i: .max),
      .document([]), .array([]), .array([.array([]), .array([.array([])]), .document([])]),
    ]
    let doubles: [Double] = [
      0, -0.0, 1, -1.5, 1e20, 1e-7, 5e-324, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
      .infinity, -.infinity, .nan, 0.1, 123_456_789.123, 1e15, 1e16,
    ]
    values += doubles.map { .double($0) }
    let dates: [Int64] = [
      0, -1, 1, 1_709_210_096_789, -62_167_219_200_000, -62_167_219_200_001, 253_402_300_799_999,
      253_402_300_800_000, .min, .max,
    ]
    values += dates.map { .date($0) }
    let regexes: [(String, String)] = [
      ("", ""), ("a/b", "i"), (#"a\/b"#, "g"), ("[/]", ""), ("*x", ""), (#"a\"#, ""), ("[a", ""),
      ("a\nb", "m"), ("^Jo", "imsx"), ("x", "i-"), ("é", "u"), (#"\d+"#, ""),
    ]
    values += regexes.map { .regex(pattern: $0.0, options: $0.1) }
    let keys = ["", "a b", "a.b", "1x", "$set", "_id", "é", "with \"quote\"", "x", "x"]
    values.append(
      .document(keys.enumerated().map { MongoValue.Field($0.element, .int32(Int32($0.offset))) }))
    values.append(
      .document(values.enumerated().map { MongoValue.Field("k\($0.offset)", $0.element) }))
    return values
  }

  @Test("parse(render(x)) == x for canonical Extended JSON and mongosh notation")
  func roundTripTable() throws {
    for value in Self.edgeValues {
      for format in [MongoRelaxedJSON.Format.canonicalExtendedJSON, .mongosh] {
        let text = render(value, format)
        #expect(try parse(text) == value, "\(format): \(text)")
      }
    }
  }

  @Test("Round-trips hold for seeded random trees")
  func roundTripRandomTrees() throws {
    var rng = SplitMix64(seed: 0x5EED_2026_1014)
    for _ in 0..<300 {
      let value = randomValue(depth: 0, rng: &rng)
      for format in [MongoRelaxedJSON.Format.canonicalExtendedJSON, .mongosh] {
        let text = render(value, format)
        #expect(try parse(text) == value, "\(format): \(text)")
      }
    }
  }

  // MARK: - Random trees

  /// Keys never start with `$` except operator names: a document whose keys are exactly a
  /// wrapper's (`{$oid: …}`) is read back as that wrapper in every Extended JSON form.
  private static let keyPool = ["a", "b", "_id", "a b", "", "é", "$set", "$in", "x.y", "q\"", "1"]
  private static let stringPool = ["", "x", "a\"b", "c\\d", "line\n", "😀", "'", "/*", "\u{1}"]
  private static let decimalPool = ["0", "1.5", "-0", "1E+10", "Infinity", "-Infinity", "NaN"]
  private static let regexPool = ["", "a", "a/b", #"\/"#, "[/]", "*", "x\ny", #"\"#]

  private func randomValue(depth: Int, rng: inout SplitMix64) -> MongoValue {
    let kind = Int.random(in: 0..<(depth < 4 ? 17 : 15), using: &rng)
    switch kind {
    case 0: return .string(Self.stringPool.randomElement(using: &rng)!)
    case 1: return .int32(Int32(truncatingIfNeeded: rng.next()))
    case 2: return .int64(Int64(truncatingIfNeeded: rng.next()))
    case 3: return .double(Double(bitPattern: rng.next()))
    case 4: return .double(Double(Int.random(in: -1000...1000, using: &rng)) / 8)
    case 5: return .decimal128(Self.decimalPool.randomElement(using: &rng)!)
    case 6: return .bool(Bool.random(using: &rng))
    case 7: return .null
    case 8:
      let hex = (0..<24).map { _ in "0123456789abcdef".randomElement(using: &rng)! }
      return .objectId(MongoObjectId(hex: String(hex))!)
    case 9: return .date(Int64.random(in: -100_000_000_000_000...300_000_000_000_000, using: &rng))
    case 10:
      let bytes = (0..<Int.random(in: 0..<8, using: &rng)).map { _ in
        UInt8.random(in: 0...255, using: &rng)
      }
      return .binary(subtype: UInt8.random(in: 0...255, using: &rng), data: Data(bytes))
    case 11:
      let options = ["", "i", "ms", "x-"].randomElement(using: &rng)!
      return .regex(pattern: Self.regexPool.randomElement(using: &rng)!, options: options)
    case 12:
      return .timestamp(
        t: UInt32.random(in: 0...UInt32.max, using: &rng),
        i: UInt32.random(in: 0...UInt32.max, using: &rng))
    case 13: return .minKey
    case 14: return .maxKey
    case 15:
      let count = Int.random(in: 0..<4, using: &rng)
      return .array((0..<count).map { _ in randomValue(depth: depth + 1, rng: &rng) })
    default:
      let count = Int.random(in: 0..<4, using: &rng)
      return .document(
        (0..<count).map { _ in
          MongoValue.Field(
            Self.keyPool.randomElement(using: &rng)!, randomValue(depth: depth + 1, rng: &rng))
        })
    }
  }
}

/// Deterministic generator for the random round-trip test.
private struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
