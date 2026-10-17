// MongoDriverCode.swift
// A find or an aggregate as code for the official MongoDB drivers: Node.js (`mongodb`, CommonJS),
// Python (PyMongo), Java (sync driver), Go (driver v2) and C# (`MongoDB.Driver`). Pure text.

import Foundation

/// Driver code for a `MongoCommand`. Only `find` and `aggregate` (each with every cursor option)
/// export.
///
/// Values keep their BSON type and key order (duplicate keys collapse in the languages whose map
/// literals cannot hold them: Node.js, Python, Java, C#). Every string goes through one escaper,
/// so a database value can never end its literal. The connection boilerplate reads the URI from
/// the `MONGODB_URI` environment variable: no host or credential ever reaches the code.
nonisolated enum MongoDriverCode {
  nonisolated enum Language: CaseIterable, Sendable {
    case node, python, java, go, csharp

    var title: String {
      switch self {
      case .node: "Node.js"
      case .python: "Python"
      case .java: "Java"
      case .go: "Go"
      case .csharp: "C#"
      }
    }
  }

  /// The code for `command`, nil for anything but `find` and `aggregate`. Without the connection
  /// the snippet starts with a comment naming the collection variable it expects.
  static func code(
    for command: MongoCommand, database: String, language: Language, includeImports: Bool,
    includeConnection: Bool
  ) -> String? {
    let query: Query
    let collection: String
    switch command {
    case .find(let name, let filter, let projection, let sort, let skip, let limit, let options):
      collection = name
      query = .find(
        Find(
          filter: filter, projection: projection, sort: sort, skip: skip, limit: limit,
          options: options))
    case .aggregate(let name, let pipeline, let options):
      collection = name
      query = .aggregate(pipeline, options)
    case .countDocuments, .distinct, .insertOne, .insertMany, .updateOne, .updateMany,
      .replaceOne, .deleteOne, .deleteMany, .listCollections, .explain:
      return nil
    }
    let target = Target(
      database: database, collection: collection, imports: includeImports,
      connection: includeConnection)
    let lines: [String]
    switch language {
    case .node: lines = NodeCode.code(query, target)
    case .python: lines = PythonCode.code(query, target)
    case .java: lines = JavaCode.code(query, target)
    case .go: lines = GoCode.code(query, target)
    case .csharp: lines = CSharpCode.code(query, target)
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: - Shared model

nonisolated extension MongoDriverCode {
  nonisolated struct Find {
    var filter: MongoValue?
    var projection: MongoValue?
    var sort: MongoValue?
    var skip: Int?
    var limit: Int?
    var options: MongoCommand.CursorOptions
  }

  nonisolated enum Query {
    case find(Find)
    case aggregate([MongoValue], MongoCommand.CursorOptions)

    /// The values printed as literals (the collation only where it is one).
    func literals(withCollation: Bool) -> [MongoValue] {
      switch self {
      case .find(let find):
        let collation = withCollation ? find.options.collation : nil
        return [find.filter, find.projection, find.sort, find.options.hint, collation]
          .compactMap { $0 }
      case .aggregate(let pipeline, let options):
        let collation = withCollation ? options.collation : nil
        return pipeline + [options.hint, collation].compactMap { $0 }
      }
    }
  }

  nonisolated struct Target {
    let database: String
    let collection: String
    let imports: Bool
    let connection: Bool
  }

  /// Value kinds that need an import or a helper in some language.
  nonisolated enum Feature: Hashable {
    case array, int64, integralDouble, negativeZero, nonFinite, decimal128, objectId
    case calendarDate, epochDate, binary, regex, timestamp, minKey, maxKey
  }

  static func features(of values: [MongoValue]) -> Set<Feature> {
    var found: Set<Feature> = []
    var pending = values
    while let value = pending.popLast() {
      switch value {
      case .document(let fields): pending += fields.map(\.value)
      case .array(let items):
        found.insert(.array)
        pending += items
      case .string, .int32, .bool, .null: break
      case .int64: found.insert(.int64)
      case .double(let number):
        if !number.isFinite {
          found.insert(.nonFinite)
        } else if number.rounded() == number {
          found.insert(.integralDouble)
          if number == 0, number.sign == .minus { found.insert(.negativeZero) }
        }
      case .decimal128: found.insert(.decimal128)
      case .objectId: found.insert(.objectId)
      case .date(let ms): found.insert(Moment(ms: ms) == nil ? .epochDate : .calendarDate)
      case .binary: found.insert(.binary)
      case .regex: found.insert(.regex)
      case .timestamp: found.insert(.timestamp)
      case .minKey: found.insert(.minKey)
      case .maxKey: found.insert(.maxKey)
      }
    }
    return found
  }

  /// A UTC calendar date of the proleptic Gregorian calendar, for years 1 through 9999 only.
  nonisolated struct Moment {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int
    let millisecond: Int

    init?(ms: Int64) {
      let (days, msOfDay) = Self.floorDivision(ms, 86_400_000)
      // Days since 0000-03-01 split into 400-year eras (civil-from-days).
      let shifted = days + 719_468
      let era = Self.floorDivision(shifted, 146_097).quotient
      let dayOfEra = shifted - era * 146_097
      let yearOfEra =
        (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
      let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
      let monthIndex = (5 * dayOfYear + 2) / 153
      let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
      let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
      guard (1...9999).contains(year) else { return nil }
      self.year = Int(year)
      self.month = Int(month)
      day = Int(dayOfYear - (153 * monthIndex + 2) / 5 + 1)
      hour = Int(msOfDay / 3_600_000)
      minute = Int(msOfDay / 60_000 % 60)
      second = Int(msOfDay / 1000 % 60)
      millisecond = Int(msOfDay % 1000)
    }

    /// `2024-01-02T03:04:05.678Z`.
    var iso: String {
      "\(Self.pad(year, 4))-\(Self.pad(month, 2))-\(Self.pad(day, 2))T\(Self.pad(hour, 2)):"
        + "\(Self.pad(minute, 2)):\(Self.pad(second, 2)).\(Self.pad(millisecond, 3))Z"
    }

    private static func pad(_ number: Int, _ width: Int) -> String {
      let text = String(number)
      return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    private static func floorDivision(
      _ value: Int64, _ divisor: Int64
    ) -> (
      quotient: Int64, remainder: Int64
    ) {
      var quotient = value / divisor
      var remainder = value % divisor
      if remainder < 0 {
        quotient -= 1
        remainder += divisor
      }
      return (quotient, remainder)
    }
  }

  /// How a scalar above U+FFFF is escaped: two `\uXXXX` UTF-16 units or one `\UXXXXXXXX`.
  nonisolated enum WideEscape { case surrogatePair, eightDigit }

  /// A double-quoted literal. `"`, `\`, newline, return and tab use their short escapes; other
  /// controls, format characters (bidi overrides, zero-width), separators other than the space,
  /// private-use and unassigned scalars use `\u` escapes. Other text stays as written (UTF-8).
  /// No control code reaches a Java `\u` escape, so its pre-lexing pass cannot end the literal.
  static func literal(_ text: String, _ wide: WideEscape) -> String {
    var output = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": output += "\\\""
      case "\\": output += "\\\\"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      default:
        if needsEscape(scalar) {
          output += escape(scalar, wide)
        } else {
          output.unicodeScalars.append(scalar)
        }
      }
    }
    return output + "\""
  }

  private static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.value < 0x20 || scalar.value == 0x7F { return true }
    if scalar.isASCII { return false }
    switch scalar.properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator, .privateUse,
      .surrogate, .unassigned:
      return true
    default:
      return false
    }
  }

  private static func escape(_ scalar: Unicode.Scalar, _ wide: WideEscape) -> String {
    func hex(_ value: UInt32, _ width: Int) -> String {
      let text = String(value, radix: 16, uppercase: true)
      return String(repeating: "0", count: max(0, width - text.count)) + text
    }
    if scalar.value <= 0xFFFF { return "\\u" + hex(scalar.value, 4) }
    switch wide {
    case .eightDigit:
      return "\\U" + hex(scalar.value, 8)
    case .surrogatePair:
      let offset = scalar.value - 0x10000
      return "\\u" + hex(0xD800 + (offset >> 10), 4) + "\\u" + hex(0xDC00 + (offset & 0x3FF), 4)
    }
  }

  /// A finite double with a `.` or an exponent, so no language reads it as an integer.
  static func decimalText(_ number: Double) -> String {
    let text = "\(number)"
    return text.contains(where: { $0 == "." || $0 == "e" }) ? text : text + ".0"
  }

  static func hexText(_ data: Data) -> String {
    data.map { byte in
      let text = String(byte, radix: 16)
      return byte < 0x10 ? "0" + text : text
    }.joined()
  }

  /// `open`, then each item on its own line with a trailing comma, then `close`.
  static func block(
    _ open: String, _ items: [String], _ close: String, indent: String
  )
    -> [String]
  {
    items.isEmpty ? [open + close] : [open] + items.map { indent + $0 + "," } + [close]
  }

  /// `head` then the chained calls, one per line, the last one ending with `;`.
  static func chain(_ head: String, _ calls: [String], indent: String) -> [String] {
    guard let last = calls.last else { return [head + ";"] }
    return [head] + calls.dropLast().map { indent + $0 } + [indent + last + ";"]
  }

  static func indented(_ lines: [String], by prefix: String) -> [String] {
    lines.map { $0.isEmpty ? $0 : prefix + $0 }
  }

  /// A collation option with a typed setter in the Java and Go drivers.
  nonisolated enum CollationSetting {
    case text(String)
    case flag(Bool)
    case number(Int64)
  }

  /// The collation fields with a known key and type; `complete` is false when any was left out.
  static func collationSettings(
    _ collation: MongoValue
  ) -> (
    settings: [(key: String, setting: CollationSetting)], complete: Bool
  ) {
    guard case .document(let fields) = collation else { return ([], false) }
    var settings: [(key: String, setting: CollationSetting)] = []
    var complete = true
    for field in fields {
      switch (field.key, field.value) {
      case ("locale", .string(let text)), ("caseFirst", .string(let text)),
        ("alternate", .string(let text)), ("maxVariable", .string(let text)):
        settings.append((field.key, .text(text)))
      case ("caseLevel", .bool(let flag)), ("numericOrdering", .bool(let flag)),
        ("normalization", .bool(let flag)), ("backwards", .bool(let flag)):
        settings.append((field.key, .flag(flag)))
      case ("strength", .int32(let number)):
        settings.append((field.key, .number(Int64(number))))
      case ("strength", .int64(let number)):
        settings.append((field.key, .number(number)))
      default:
        complete = false
      }
    }
    return (settings, complete)
  }
}

// MARK: - Node.js

/// The `mongodb` package, CommonJS (`require`), so the file runs with plain `node`.
private nonisolated enum NodeCode {
  typealias Code = MongoDriverCode

  static func code(_ query: Code.Query, _ target: Code.Target) -> [String] {
    var body: [String]
    switch query {
    case .find(let find):
      var options: [String] = []
      if let projection = find.projection { options.append("projection: \(value(projection))") }
      if let sort = find.sort { options.append("sort: \(value(sort))") }
      if let skip = find.skip { options.append("skip: \(skip)") }
      if let limit = find.limit { options.append("limit: \(limit)") }
      options += cursorOptions(find.options)
      let filter = find.filter.map(value) ?? "{}"
      body =
        options.isEmpty
        ? ["const cursor = collection.find(\(filter));"]
        : Code.block("const cursor = collection.find(\(filter), {", options, "});", indent: "  ")
    case .aggregate(let pipeline, let aggregate):
      let options = cursorOptions(aggregate)
      let stages = pipeline.map(value)
      body =
        options.isEmpty
        ? Code.block("const cursor = collection.aggregate([", stages, "]);", indent: "  ")
        : Code.block("const cursor = collection.aggregate([", stages, "], {", indent: "  ")
          + options.map { "  \($0)," } + ["});"]
    }

    var lines: [String] = []
    if target.imports {
      let features = Code.features(of: query.literals(withCollation: true))
      let table: [(Code.Feature, String)] = [
        (.binary, "Binary"), (.regex, "BSONRegExp"), (.decimal128, "Decimal128"),
        (.integralDouble, "Double"), (.int64, "Long"), (.maxKey, "MaxKey"), (.minKey, "MinKey"),
        (.objectId, "ObjectId"), (.timestamp, "Timestamp"),
      ]
      let names =
        (target.connection ? ["MongoClient"] : [])
        + table.filter { features.contains($0.0) }.map(\.1)
      if !names.isEmpty {
        lines += [
          "const { \(names.sorted().joined(separator: ", ")) } = require(\"mongodb\");", "",
        ]
      }
    }
    guard target.connection else {
      return lines + ["// Expects `collection`, a Collection of the mongodb driver."] + body
    }
    let database = Code.literal(target.database, .surrogatePair)
    let collection = Code.literal(target.collection, .surrogatePair)
    return lines + [
      "async function main() {",
      "  const client = new MongoClient(process.env.MONGODB_URI);",
      "  try {",
      "    const collection = client.db(\(database)).collection(\(collection));",
    ]
      + Code.indented(body, by: "    ")
      + [
        "    for await (const document of cursor) {",
        "      console.log(document);",
        "    }",
        "  } finally {",
        "    await client.close();",
        "  }",
        "}",
        "",
        "main().catch(console.error);",
      ]
  }

  /// The `collation`, `hint` and `maxTimeMS` entries of an options object.
  private static func cursorOptions(_ options: MongoCommand.CursorOptions) -> [String] {
    var entries: [String] = []
    if let collation = options.collation { entries.append("collation: \(value(collation))") }
    if let hint = options.hint { entries.append("hint: \(value(hint))") }
    if let maxTimeMS = options.maxTimeMS { entries.append("maxTimeMS: \(maxTimeMS)") }
    return entries
  }

  static func value(_ value: MongoValue) -> String {
    switch value {
    case .document(let fields):
      guard !fields.isEmpty else { return "{}" }
      return "{ " + fields.map { "\(key($0.key)): \(self.value($0.value))" }.joined(separator: ", ")
        + " }"
    case .array(let items):
      return "[" + items.map { self.value($0) }.joined(separator: ", ") + "]"
    case .string(let text): return string(text)
    case .int32(let number): return String(number)
    case .int64(let number): return "Long.fromString(\"\(number)\")"
    case .double(let number):
      if number.isNaN { return "NaN" }
      if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
      // An integral number would be stored as an int32: `Double` keeps the BSON type.
      let text = Code.decimalText(number)
      return number.rounded() == number ? "new Double(\(text))" : text
    case .decimal128(let text): return "Decimal128.fromString(\(string(text)))"
    case .bool(let flag): return flag ? "true" : "false"
    case .null: return "null"
    case .objectId(let id): return "new ObjectId(\"\(id.hex)\")"
    case .date(let ms):
      return Code.Moment(ms: ms).map { "new Date(\"\($0.iso)\")" } ?? "new Date(\(ms))"
    case .binary(let subtype, let data):
      return "new Binary(Buffer.from(\"\(data.base64EncodedString())\", \"base64\"), \(subtype))"
    case .regex(let pattern, let options):
      return "new BSONRegExp(\(string(pattern)), \(string(options)))"
    case .timestamp(let t, let i): return "new Timestamp({ t: \(t), i: \(i) })"
    case .minKey: return "new MinKey()"
    case .maxKey: return "new MaxKey()"
    }
  }

  private static func string(_ text: String) -> String { Code.literal(text, .surrogatePair) }

  /// A quoted key; `__proto__` is computed, since the literal form would set the prototype.
  private static func key(_ text: String) -> String {
    text == "__proto__" ? "[\(string(text))]" : string(text)
  }
}

// MARK: - Python

/// PyMongo with the `bson` package it ships.
private nonisolated enum PythonCode {
  typealias Code = MongoDriverCode

  static func code(_ query: Code.Query, _ target: Code.Target) -> [String] {
    var body: [String]
    switch query {
    case .find(let find):
      var arguments: [String] = []
      if find.filter != nil || find.projection != nil {
        arguments.append(find.filter.map(value) ?? "{}")
      }
      if let projection = find.projection { arguments.append(value(projection)) }
      if let sort = find.sort { arguments.append("sort=\(pairs(sort))") }
      if let skip = find.skip { arguments.append("skip=\(skip)") }
      if let limit = find.limit { arguments.append("limit=\(limit)") }
      arguments += cursorArguments(find.options, maxTime: "max_time_ms")
      body =
        arguments.count <= 1
        ? ["cursor = collection.find(\(arguments.joined()))"]
        : Code.block("cursor = collection.find(", arguments, ")", indent: "    ")
    case .aggregate(let pipeline, let options):
      // PyMongo passes aggregate keyword options to the command as named: `maxTimeMS`.
      let arguments = cursorArguments(options, maxTime: "maxTimeMS")
      if arguments.isEmpty {
        body = Code.block(
          "cursor = collection.aggregate([", pipeline.map(value), "])", indent: "    ")
      } else {
        let stages = Code.block("[", pipeline.map(value), "],", indent: "    ")
        body =
          ["cursor = collection.aggregate("] + Code.indented(stages, by: "    ")
          + arguments.map { "    \($0)," } + [")"]
      }
    }

    var lines: [String] = []
    if target.imports {
      let features = Code.features(of: query.literals(withCollation: true))
      let table: [(Code.Feature, String)] = [
        (.binary, "Binary"), (.decimal128, "Decimal128"), (.int64, "Int64"), (.maxKey, "MaxKey"),
        (.minKey, "MinKey"), (.objectId, "ObjectId"), (.regex, "Regex"),
        (.timestamp, "Timestamp"),
      ]
      var standard: [String] = []
      if target.connection { standard.append("import os") }
      if features.contains(.calendarDate) {
        standard.append("from datetime import datetime, timezone")
      }
      var external: [String] = []
      let names = table.filter { features.contains($0.0) }.map(\.1)
      if !names.isEmpty { external.append("from bson import \(names.joined(separator: ", "))") }
      if features.contains(.epochDate) {
        external.append("from bson.datetime_ms import DatetimeMS")
      }
      if target.connection { external.append("from pymongo import MongoClient") }
      for group in [standard, external] where !group.isEmpty { lines += group + [""] }
    }
    guard target.connection else {
      return lines + ["# Expects `collection`, a pymongo Collection."] + body
    }
    let database = Code.literal(target.database, .eightDigit)
    let collection = Code.literal(target.collection, .eightDigit)
    return lines + [
      "client = MongoClient(os.environ[\"MONGODB_URI\"])",
      "collection = client[\(database)][\(collection)]",
      "",
    ]
      + body
      + ["for document in cursor:", "    print(document)", "", "client.close()"]
  }

  static func value(_ value: MongoValue) -> String {
    switch value {
    case .document(let fields):
      return "{"
        + fields.map { "\(string($0.key)): \(self.value($0.value))" }
        .joined(separator: ", ") + "}"
    case .array(let items):
      return "[" + items.map { self.value($0) }.joined(separator: ", ") + "]"
    case .string(let text): return string(text)
    case .int32(let number): return String(number)
    case .int64(let number): return "Int64(\(number))"
    case .double(let number):
      if number.isNaN { return "float(\"nan\")" }
      if number.isInfinite { return number < 0 ? "float(\"-inf\")" : "float(\"inf\")" }
      return Code.decimalText(number)
    case .decimal128(let text): return "Decimal128(\(string(text)))"
    case .bool(let flag): return flag ? "True" : "False"
    case .null: return "None"
    case .objectId(let id): return "ObjectId(\"\(id.hex)\")"
    case .date(let ms):
      guard let moment = Code.Moment(ms: ms) else { return "DatetimeMS(\(ms))" }
      return "datetime(\(moment.year), \(moment.month), \(moment.day), \(moment.hour), "
        + "\(moment.minute), \(moment.second), \(moment.millisecond * 1000), "
        + "tzinfo=timezone.utc)"
    case .binary(let subtype, let data):
      return "Binary(bytes.fromhex(\"\(Code.hexText(data))\"), \(subtype))"
    case .regex(let pattern, let options):
      return "Regex(\(string(pattern)), \(string(options)))"
    case .timestamp(let t, let i): return "Timestamp(\(t), \(i))"
    case .minKey: return "MinKey()"
    case .maxKey: return "MaxKey()"
    }
  }

  /// The `collation=`, `hint=` and maxTimeMS keyword arguments, the last named `maxTime`.
  private static func cursorArguments(
    _ options: MongoCommand.CursorOptions, maxTime: String
  ) -> [String] {
    var arguments: [String] = []
    if let collation = options.collation { arguments.append("collation=\(value(collation))") }
    if let hint = options.hint {
      if case .string = hint {
        arguments.append("hint=\(value(hint))")
      } else {
        arguments.append("hint=\(pairs(hint))")
      }
    }
    if let maxTimeMS = options.maxTimeMS { arguments.append("\(maxTime)=\(maxTimeMS)") }
    return arguments
  }

  /// A key document as the list of `(key, value)` pairs PyMongo takes for `sort` and `hint`.
  private static func pairs(_ keys: MongoValue) -> String {
    guard case .document(let fields) = keys else { return value(keys) }
    return "["
      + fields.map { "(\(string($0.key)), \(value($0.value)))" }
      .joined(separator: ", ") + "]"
  }

  private static func string(_ text: String) -> String { Code.literal(text, .eightDigit) }
}

// MARK: - Java

/// The Java sync driver (`mongodb-driver-sync`) with `org.bson.Document`.
private nonisolated enum JavaCode {
  typealias Code = MongoDriverCode

  static func code(_ query: Code.Query, _ target: Code.Target) -> [String] {
    var body: [String] = []
    var collationTypes: Set<String> = []
    var usesTimeUnit = false
    /// The `.collation`, `.hint` and `.maxTime` calls of `options` (find and aggregate iterables).
    func optionCalls(_ options: MongoCommand.CursorOptions) -> [String] {
      var calls: [String] = []
      if let collation = options.collation {
        let (settings, complete) = Code.collationSettings(collation)
        if !complete {
          body.append("// Collation fields with no Collation.Builder method were left out.")
        }
        var builder = "Collation.builder()"
        collationTypes.insert("Collation")
        for (key, setting) in settings {
          let (method, type) = builderCall(key, setting)
          builder += method
          if let type { collationTypes.insert(type) }
        }
        calls.append(".collation(\(builder).build())")
      }
      if let hint = options.hint {
        if case .string(let name) = hint {
          calls.append(".hintString(\(string(name)))")
        } else {
          calls.append(".hint(\(value(hint)))")
        }
      }
      if let maxTimeMS = options.maxTimeMS {
        calls.append(".maxTime(\(maxTimeMS), TimeUnit.MILLISECONDS)")
        usesTimeUnit = true
      }
      return calls
    }
    switch query {
    case .find(let find):
      var calls: [String] = []
      if let projection = find.projection { calls.append(".projection(\(value(projection)))") }
      if let sort = find.sort { calls.append(".sort(\(value(sort)))") }
      if let skip = find.skip { calls.append(".skip(\(skip))") }
      if let limit = find.limit { calls.append(".limit(\(limit))") }
      calls += optionCalls(find.options)
      let filter = find.filter.map(value) ?? ""
      body += Code.chain(
        "FindIterable<Document> cursor = collection.find(\(filter))", calls, indent: "    ")
    case .aggregate(let pipeline, let options):
      let calls = optionCalls(options)
      let stages = pipeline.map(value)
      let head =
        stages.isEmpty
        ? ["AggregateIterable<Document> cursor = collection.aggregate(Arrays.asList())"]
        : ["AggregateIterable<Document> cursor = collection.aggregate(Arrays.asList("]
          + stages.dropLast().map { "    \($0)," } + ["    \(stages[stages.count - 1]))"]
      body += head.dropLast() + Code.chain(head[head.count - 1], calls, indent: "    ")
    }

    var lines: [String] = []
    if target.imports {
      let features = Code.features(of: query.literals(withCollation: false))
      var imports: Set<String> = ["org.bson.Document"]
      if case .find = query {
        imports.insert("com.mongodb.client.FindIterable")
      } else {
        imports.formUnion(["com.mongodb.client.AggregateIterable", "java.util.Arrays"])
      }
      if target.connection {
        imports.formUnion(
          ["MongoClient", "MongoClients", "MongoCollection", "MongoDatabase"]
            .map { "com.mongodb.client.\($0)" })
      }
      imports.formUnion(collationTypes.map { "com.mongodb.client.model.\($0)" })
      if usesTimeUnit { imports.insert("java.util.concurrent.TimeUnit") }
      let table: [(Code.Feature, [String])] = [
        (.array, ["java.util.Arrays"]), (.calendarDate, ["java.time.Instant", "java.util.Date"]),
        (.epochDate, ["java.util.Date"]),
        (.binary, ["java.util.Base64", "org.bson.types.Binary"]),
        (.regex, ["org.bson.BsonRegularExpression"]), (.timestamp, ["org.bson.BsonTimestamp"]),
        (.decimal128, ["org.bson.types.Decimal128"]), (.maxKey, ["org.bson.types.MaxKey"]),
        (.minKey, ["org.bson.types.MinKey"]), (.objectId, ["org.bson.types.ObjectId"]),
      ]
      for (feature, names) in table where features.contains(feature) {
        imports.formUnion(names)
      }
      lines += imports.sorted().map { "import \($0);" } + [""]
    }
    guard target.connection else {
      return lines + ["// Expects `collection`, a MongoCollection<Document>."] + body
    }
    let database = Code.literal(target.database, .surrogatePair)
    let collection = Code.literal(target.collection, .surrogatePair)
    return lines + [
      "public class Main {",
      "  public static void main(String[] args) {",
      "    try (MongoClient client = MongoClients.create(System.getenv(\"MONGODB_URI\"))) {",
      "      MongoDatabase database = client.getDatabase(\(database));",
      "      MongoCollection<Document> collection = database.getCollection(\(collection));",
    ]
      + Code.indented(body, by: "      ")
      + [
        "      for (Document document : cursor) {",
        "        System.out.println(document.toJson());",
        "      }",
        "    }",
        "  }",
        "}",
      ]
  }

  /// The `Collation.Builder` call for one setting, and the enum type it needs, if any.
  private static func builderCall(
    _ key: String, _ setting: Code.CollationSetting
  ) -> (
    String, String?
  ) {
    let argument: String
    switch setting {
    case .text(let text): argument = string(text)
    case .flag(let flag): argument = flag ? "true" : "false"
    case .number(let number): argument = String(number)
    }
    switch key {
    case "caseFirst":
      return (
        ".collationCaseFirst(CollationCaseFirst.fromString(\(argument)))", "CollationCaseFirst"
      )
    case "strength":
      return (
        ".collationStrength(CollationStrength.fromInt(\(argument)))", "CollationStrength"
      )
    case "alternate":
      return (
        ".collationAlternate(CollationAlternate.fromString(\(argument)))", "CollationAlternate"
      )
    case "maxVariable":
      return (
        ".collationMaxVariable(CollationMaxVariable.fromString(\(argument)))",
        "CollationMaxVariable"
      )
    default:
      // locale, caseLevel, numericOrdering, normalization, backwards: same-named setters.
      return (".\(key)(\(argument))", nil)
    }
  }

  static func value(_ value: MongoValue) -> String {
    switch value {
    case .document(let fields):
      guard let first = fields.first else { return "new Document()" }
      return "new Document(\(string(first.key)), \(self.value(first.value)))"
        + fields.dropFirst().map { ".append(\(string($0.key)), \(self.value($0.value)))" }
        .joined()
    case .array(let items):
      // A lone `null` argument would be read as a null varargs array.
      if items == [.null] { return "Arrays.asList((Object) null)" }
      return "Arrays.asList(" + items.map { self.value($0) }.joined(separator: ", ") + ")"
    case .string(let text): return string(text)
    case .int32(let number): return String(number)
    case .int64(let number): return "\(number)L"
    case .double(let number):
      if number.isNaN { return "Double.NaN" }
      if number.isInfinite {
        return number < 0 ? "Double.NEGATIVE_INFINITY" : "Double.POSITIVE_INFINITY"
      }
      return Code.decimalText(number)
    case .decimal128(let text): return "Decimal128.parse(\(string(text)))"
    case .bool(let flag): return flag ? "true" : "false"
    case .null: return "null"
    case .objectId(let id): return "new ObjectId(\"\(id.hex)\")"
    case .date(let ms):
      return Code.Moment(ms: ms).map { "Date.from(Instant.parse(\"\($0.iso)\"))" }
        ?? "new Date(\(ms)L)"
    case .binary(let subtype, let data):
      let base64 = data.base64EncodedString()
      return "new Binary((byte) \(subtype), Base64.getDecoder().decode(\"\(base64)\"))"
    case .regex(let pattern, let options):
      return "new BsonRegularExpression(\(string(pattern)), \(string(options)))"
    case .timestamp(let t, let i):
      // The int arguments carry the unsigned 32-bit values bit for bit.
      return "new BsonTimestamp(\(Int32(bitPattern: t)), \(Int32(bitPattern: i)))"
    case .minKey: return "new MinKey()"
    case .maxKey: return "new MaxKey()"
    }
  }

  private static func string(_ text: String) -> String { Code.literal(text, .surrogatePair) }
}

// MARK: - Go

/// The Go driver v2 (`go.mongodb.org/mongo-driver/v2`), tab-indented as gofmt prints it.
private nonisolated enum GoCode {
  typealias Code = MongoDriverCode

  static func code(_ query: Code.Query, _ target: Code.Target) -> [String] {
    let features = Code.features(of: query.literals(withCollation: false))
    var body: [String] = []
    if features.contains(.objectId) {
      body += helper("objectID", "hex string", "bson.ObjectID", "bson.ObjectIDFromHex(hex)")
    }
    if features.contains(.decimal128) {
      body += helper("decimal128", "text string", "bson.Decimal128", "bson.ParseDecimal128(text)")
    }
    var context = "ctx"
    var usesOptions = false
    var usesTimeout = false
    /// The `SetCollation` and `SetHint` setters of `options` (find and aggregate builders).
    func optionSetters(_ options: MongoCommand.CursorOptions) -> [String] {
      var setters: [String] = []
      if let collation = options.collation {
        let (settings, complete) = Code.collationSettings(collation)
        if !complete {
          body.append("// Collation fields with no options.Collation field were left out.")
        }
        let fields = settings.map { "\(fieldName($0.key)): \(argument($0.setting))" }
        setters.append("SetCollation(&options.Collation{\(fields.joined(separator: ", "))})")
      }
      if let hint = options.hint { setters.append("SetHint(\(value(hint)))") }
      return setters
    }
    /// `opts := options.<builder>().` and the chained setters, when there are any.
    func appendOptions(_ builder: String, _ setters: [String]) {
      guard !setters.isEmpty else { return }
      usesOptions = true
      body.append("opts := options.\(builder)().")
      body += setters.enumerated().map { index, setter in
        "\t" + setter + (index == setters.count - 1 ? "" : ".")
      }
    }
    /// The context deadline that stands for a `maxTimeMS` the v2 driver has no option for.
    func appendTimeout(_ options: MongoCommand.CursorOptions, _ method: String) {
      guard let maxTimeMS = options.maxTimeMS, maxTimeMS > 0 else { return }
      usesTimeout = true
      context = "queryCtx"
      body += [
        "// The v2 driver has no maxTimeMS \(method) option: a context deadline bounds the query.",
        "queryCtx, cancel := context.WithTimeout(ctx, \(maxTimeMS)*time.Millisecond)",
        "defer cancel()",
      ]
    }
    switch query {
    case .find(let find):
      var setters: [String] = []
      if let projection = find.projection { setters.append("SetProjection(\(value(projection)))") }
      if let sort = find.sort { setters.append("SetSort(\(value(sort)))") }
      if let skip = find.skip { setters.append("SetSkip(\(skip))") }
      if let limit = find.limit { setters.append("SetLimit(\(limit))") }
      setters += optionSetters(find.options)
      body.append("filter := \(find.filter.map(value) ?? "bson.D{}")")
      appendOptions("Find", setters)
      appendTimeout(find.options, "find")
      body.append("cursor, err := coll.Find(\(context), filter\(usesOptions ? ", opts" : ""))")
    case .aggregate(let pipeline, let options):
      body += Code.block("pipeline := mongo.Pipeline{", pipeline.map(value), "}", indent: "\t")
      appendOptions("Aggregate", optionSetters(options))
      appendTimeout(options, "aggregate")
      body.append(
        "cursor, err := coll.Aggregate(\(context), pipeline\(usesOptions ? ", opts" : ""))")
    }

    var lines: [String] = []
    if target.connection { lines += ["package main", ""] }
    if target.imports {
      var standard: Set<String> = []
      if target.connection { standard.formUnion(["context", "fmt", "log", "os"]) }
      if usesTimeout { standard.formUnion(["context", "time"]) }
      if features.contains(.calendarDate) { standard.insert("time") }
      if features.contains(.nonFinite) || features.contains(.negativeZero) {
        standard.insert("math")
      }
      // Go refuses unused imports: list a package only when the code names it.
      var usesBSON = target.connection
      var usesMongo = target.connection
      switch query {
      case .find: usesBSON = true
      case .aggregate(let pipeline, let options):
        var hintIsDocument = false
        if case .document? = options.hint { hintIsDocument = true }
        usesBSON = usesBSON || !pipeline.isEmpty || hintIsDocument
        usesMongo = true
      }
      var driver: [String] = []
      if usesBSON { driver.append("bson") }
      if usesMongo { driver.append("mongo") }
      if target.connection || usesOptions { driver.append("mongo/options") }
      lines.append("import (")
      lines += standard.sorted().map { "\t\"\($0)\"" }
      if !standard.isEmpty, !driver.isEmpty { lines.append("") }
      lines += driver.map { "\t\"go.mongodb.org/mongo-driver/v2/\($0)\"" }
      lines += [")", ""]
    }
    guard target.connection else {
      return lines + ["// Expects ctx (a context.Context) and coll (a *mongo.Collection)."] + body
    }
    let database = Code.literal(target.database, .eightDigit)
    let collection = Code.literal(target.collection, .eightDigit)
    return lines + [
      "func main() {",
      "\tctx := context.Background()",
      "\tclient, err := mongo.Connect(options.Client().ApplyURI(os.Getenv(\"MONGODB_URI\")))",
      "\tif err != nil {",
      "\t\tlog.Fatal(err)",
      "\t}",
      "\tdefer func() {",
      "\t\tif err := client.Disconnect(ctx); err != nil {",
      "\t\t\tlog.Fatal(err)",
      "\t\t}",
      "\t}()",
      "\tcoll := client.Database(\(database)).Collection(\(collection))",
      "",
    ]
      + Code.indented(body, by: "\t")
      + [
        "\tif err != nil {",
        "\t\tlog.Fatal(err)",
        "\t}",
        "\tdefer cursor.Close(\(context))",
        "\tfor cursor.Next(\(context)) {",
        "\t\tvar document bson.M",
        "\t\tif err := cursor.Decode(&document); err != nil {",
        "\t\t\tlog.Fatal(err)",
        "\t\t}",
        "\t\tfmt.Println(document)",
        "\t}",
        "\tif err := cursor.Err(); err != nil {",
        "\t\tlog.Fatal(err)",
        "\t}",
        "}",
      ]
  }

  /// A closure that parses a checked literal, since the bson parsers also return an error.
  private static func helper(
    _ name: String, _ parameter: String, _ type: String, _ call: String
  )
    -> [String]
  {
    [
      "\(name) := func(\(parameter)) \(type) {",
      "\tvalue, err := \(call)",
      "\tif err != nil {",
      "\t\tpanic(err)",
      "\t}",
      "\treturn value",
      "}",
    ]
  }

  private static func fieldName(_ key: String) -> String {
    key.prefix(1).uppercased() + key.dropFirst()
  }

  private static func argument(_ setting: Code.CollationSetting) -> String {
    switch setting {
    case .text(let text): string(text)
    case .flag(let flag): flag ? "true" : "false"
    case .number(let number): String(number)
    }
  }

  static func value(_ value: MongoValue) -> String {
    switch value {
    case .document(let fields):
      return "bson.D{"
        + fields.map { "{Key: \(string($0.key)), Value: \(self.value($0.value))}" }
        .joined(separator: ", ") + "}"
    case .array(let items):
      return "bson.A{" + items.map { self.value($0) }.joined(separator: ", ") + "}"
    case .string(let text): return string(text)
    case .int32(let number): return "int32(\(number))"
    case .int64(let number): return "int64(\(number))"
    case .double(let number):
      if number.isNaN { return "math.NaN()" }
      if number.isInfinite { return number < 0 ? "math.Inf(-1)" : "math.Inf(1)" }
      // Go constants have no negative zero.
      if number == 0, number.sign == .minus { return "math.Copysign(0, -1)" }
      return Code.decimalText(number)
    case .decimal128(let text): return "decimal128(\(string(text)))"
    case .bool(let flag): return flag ? "true" : "false"
    case .null: return "nil"
    case .objectId(let id): return "objectID(\"\(id.hex)\")"
    case .date(let ms):
      guard let moment = Code.Moment(ms: ms) else { return "bson.DateTime(\(ms))" }
      return "time.Date(\(moment.year), \(moment.month), \(moment.day), \(moment.hour), "
        + "\(moment.minute), \(moment.second), \(moment.millisecond * 1_000_000), time.UTC)"
    case .binary(let subtype, let data):
      let bytes = data.map { "0x" + Code.hexText(Data([$0])) }.joined(separator: ", ")
      return "bson.Binary{Subtype: 0x\(Code.hexText(Data([subtype]))), Data: []byte{\(bytes)}}"
    case .regex(let pattern, let options):
      return "bson.Regex{Pattern: \(string(pattern)), Options: \(string(options))}"
    case .timestamp(let t, let i): return "bson.Timestamp{T: \(t), I: \(i)}"
    case .minKey: return "bson.MinKey{}"
    case .maxKey: return "bson.MaxKey{}"
    }
  }

  private static func string(_ text: String) -> String { Code.literal(text, .eightDigit) }
}

// MARK: - C#

/// The .NET driver (`MongoDB.Driver`) with `BsonDocument`; top-level statements.
private nonisolated enum CSharpCode {
  typealias Code = MongoDriverCode

  static func code(_ query: Code.Query, _ target: Code.Target) -> [String] {
    var body: [String] = []
    var usesTimeSpan = false
    /// `var options = new <type> { … };` with the settings of `options`, false when none is set.
    func appendOptions(_ type: String, _ options: MongoCommand.CursorOptions) -> Bool {
      var settings: [String] = []
      if let collation = options.collation {
        settings.append("Collation = Collation.FromBsonDocument(\(value(collation))),")
      }
      if let hint = options.hint { settings.append("Hint = \(value(hint)),") }
      if let maxTimeMS = options.maxTimeMS {
        settings.append("MaxTime = TimeSpan.FromMilliseconds(\(maxTimeMS)),")
        usesTimeSpan = true
      }
      guard !settings.isEmpty else { return false }
      body += ["var options = new \(type)", "{"] + settings.map { "    " + $0 } + ["};"]
      return true
    }
    switch query {
    case .find(let find):
      let hasOptions = appendOptions("FindOptions", find.options)
      var calls: [String] = []
      if let projection = find.projection { calls.append(".Project(\(value(projection)))") }
      if let sort = find.sort { calls.append(".Sort(\(value(sort)))") }
      if let skip = find.skip { calls.append(".Skip(\(skip))") }
      if let limit = find.limit { calls.append(".Limit(\(limit))") }
      let filter = find.filter.map(value) ?? "new BsonDocument()"
      let head = "var cursor = collection.Find(\(filter)\(hasOptions ? ", options" : ""))"
      body += Code.chain(head, calls, indent: "    ")
    case .aggregate(let pipeline, let options):
      body =
        ["PipelineDefinition<BsonDocument, BsonDocument> pipeline = new BsonDocument[]", "{"]
        + pipeline.map { "    \(value($0))," } + ["};"]
      let hasOptions = appendOptions("AggregateOptions", options)
      body.append("var cursor = collection.Aggregate(pipeline\(hasOptions ? ", options" : ""));")
    }

    var lines: [String] = []
    if target.imports {
      let features = Code.features(of: query.literals(withCollation: true))
      let usesSystem =
        target.connection || usesTimeSpan || features.contains(.calendarDate)
        || features.contains(.binary)
      lines +=
        (usesSystem ? ["using System;"] : []) + [
          "using MongoDB.Bson;", "using MongoDB.Driver;", "",
        ]
    }
    guard target.connection else {
      return lines + ["// Expects `collection`, an IMongoCollection<BsonDocument>."] + body
    }
    let database = Code.literal(target.database, .eightDigit)
    let collection = Code.literal(target.collection, .eightDigit)
    return lines + [
      "var client = new MongoClient(Environment.GetEnvironmentVariable(\"MONGODB_URI\"));",
      "var collection = client.GetDatabase(\(database))"
        + ".GetCollection<BsonDocument>(\(collection));",
      "",
    ]
      + body
      + [
        "foreach (var document in cursor.ToEnumerable())",
        "{",
        "    Console.WriteLine(document.ToJson());",
        "}",
      ]
  }

  static func value(_ value: MongoValue) -> String {
    switch value {
    case .document(let fields):
      guard !fields.isEmpty else { return "new BsonDocument()" }
      return "new BsonDocument { "
        + fields.map { "{ \(string($0.key)), \(self.value($0.value)) }" }.joined(separator: ", ")
        + " }"
    case .array(let items):
      guard !items.isEmpty else { return "new BsonArray()" }
      return "new BsonArray { " + items.map { self.value($0) }.joined(separator: ", ") + " }"
    case .string(let text): return string(text)
    case .int32(let number): return String(number)
    case .int64(let number): return "\(number)L"
    case .double(let number):
      if number.isNaN { return "double.NaN" }
      if number.isInfinite {
        return number < 0 ? "double.NegativeInfinity" : "double.PositiveInfinity"
      }
      return Code.decimalText(number)
    case .decimal128(let text): return "new BsonDecimal128(Decimal128.Parse(\(string(text))))"
    case .bool(let flag): return flag ? "true" : "false"
    // A bare `null` would be a null BsonValue, which the document refuses.
    case .null: return "BsonNull.Value"
    case .objectId(let id): return "ObjectId.Parse(\"\(id.hex)\")"
    case .date(let ms):
      guard let moment = Code.Moment(ms: ms) else { return "new BsonDateTime(\(ms)L)" }
      return "new BsonDateTime(new DateTime(\(moment.year), \(moment.month), \(moment.day), "
        + "\(moment.hour), \(moment.minute), \(moment.second), \(moment.millisecond), "
        + "DateTimeKind.Utc))"
    case .binary(let subtype, let data):
      return "new BsonBinaryData(Convert.FromBase64String(\"\(data.base64EncodedString())\"), "
        + "(BsonBinarySubType)\(subtype))"
    case .regex(let pattern, let options):
      return "new BsonRegularExpression(\(string(pattern)), \(string(options)))"
    case .timestamp(let t, let i):
      // The int arguments carry the unsigned 32-bit values bit for bit.
      return "new BsonTimestamp(\(Int32(bitPattern: t)), \(Int32(bitPattern: i)))"
    case .minKey: return "BsonMinKey.Value"
    case .maxKey: return "BsonMaxKey.Value"
    }
  }

  private static func string(_ text: String) -> String { Code.literal(text, .eightDigit) }
}
