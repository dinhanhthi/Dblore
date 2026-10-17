// MongoshParser.swift
// Parses one command of the Dblore mongosh subset into a `MongoCommand`. Never evaluates
// JavaScript: argument values go through `MongoRelaxedJSON`, everything else is fixed grammar.

import Foundation

/// The mongosh subset:
/// - `show collections`, `db.getCollectionNames()`
/// - `db.<name>`, `db.getCollection("<name>")` or `db["<name>"]`, then one method:
///   `find(filter?, projection?)` with `.sort(doc)`, `.skip(n)`, `.limit(n)`, `.collation(doc)`,
///   `.hint(name or doc)`, `.maxTimeMS(n)` in any order (each at most once),
///   `aggregate([stages], {collation, hint, maxTimeMS}?)`,
///   `countDocuments(filter?, {skip, limit, collation, hint, maxTimeMS}?)`,
///   `distinct("field", filter?)`, `insertOne(doc)`, `insertMany([docs])`,
///   `updateOne`/`updateMany(filter, update, {upsert}?)`, `replaceOne(filter, replacement,
///   {upsert}?)`, `deleteOne`/`deleteMany(filter)`.
/// - A find chain or an aggregate may end with `.explain()` (`queryPlanner`) or
///   `.explain("queryPlanner" | "executionStats" | "allPlansExecution")`, once and last.
///
/// Whitespace, `//` and `/* */` comments and one trailing `;` are allowed. Any other method,
/// including `.toArray()` and `.pretty()`, fails with "<method> is not supported in the Dblore
/// MongoDB subset". Errors are `MongoRelaxedJSON.ParseError` with a UTF-16 offset into the text.
nonisolated enum MongoshParser {
  typealias ParseError = MongoRelaxedJSON.ParseError

  static func parse(_ text: String) throws(ParseError) -> MongoCommand {
    guard text.utf8.count <= MongoRelaxedJSON.maxInputBytes else {
      throw ParseError(message: "The text is larger than 1 MiB", offset: 0)
    }
    var scanner = Scanner(bytes: Array(text.utf8))
    return try scanner.parseScript()
  }

  fileprivate static let collectionMethods: Set<String> = [
    "find", "aggregate", "countDocuments", "distinct", "insertOne", "insertMany", "updateOne",
    "updateMany", "replaceOne", "deleteOne", "deleteMany",
  ]

  fileprivate static func unsupported(_ name: String) -> String {
    "\(name) is not supported in the Dblore MongoDB subset"
  }
}

// MARK: - Scanner

nonisolated extension MongoshParser {
  fileprivate nonisolated struct Scanner {
    typealias Argument = (value: MongoValue, offset: Int)

    let bytes: [UInt8]
    private var pos = 0

    init(bytes: [UInt8]) {
      self.bytes = bytes
    }

    mutating func parseScript() throws(ParseError) -> MongoCommand {
      try skipTrivia()
      let command = try parseCommand()
      try skipTrivia()
      if take(";") { try skipTrivia() }
      guard pos == bytes.count else { throw failure("Unexpected text after the command", at: pos) }
      return command
    }

    // MARK: Commands

    private mutating func parseCommand() throws(ParseError) -> MongoCommand {
      let start = pos
      let word = identifier()
      guard !word.isEmpty else {
        throw failure("Expected a command such as db.<collection>.find()", at: start)
      }
      if word == "show" { return try parseShow(at: start) }
      guard word == "db" else { throw failure(unsupported(word), at: start) }
      try skipTrivia()
      if take("[") { return try parseMethod(on: bracketCollection()) }
      guard take(".") else { throw failure("Expected '.' or '[' after db", at: pos) }
      try skipTrivia()
      let nameStart = pos
      let name = identifier()
      guard !name.isEmpty else { throw failure("Expected a collection name after db.", at: pos) }
      try skipTrivia()
      guard peek() == UInt8(ascii: "(") else { return try parseMethod(on: name) }
      switch name {
      case "getCollection":
        let arguments = try parseArguments()
        return try parseMethod(on: collectionName(arguments, at: nameStart))
      case "getCollectionNames":
        guard try parseArguments().isEmpty else {
          throw failure("getCollectionNames takes no arguments", at: nameStart)
        }
        try refuseChain()
        return .listCollections
      default:
        throw failure(unsupported(name), at: nameStart)
      }
    }

    private mutating func parseShow(at start: Int) throws(ParseError) -> MongoCommand {
      try skipTrivia()
      let what = identifier()
      guard !what.isEmpty else {
        throw failure("Expected what to show, such as show collections", at: pos)
      }
      guard what == "collections" else { throw failure(unsupported("show \(what)"), at: start) }
      return .listCollections
    }

    private mutating func bracketCollection() throws(ParseError) -> String {
      try skipTrivia()
      let offset = pos
      let (value, end) = try MongoRelaxedJSON.parseValue(in: bytes, from: pos)
      pos = end
      try skipTrivia()
      guard take("]") else { throw failure("Expected ']'", at: pos) }
      guard case .string(let name) = value else {
        throw failure("The collection name must be a string", at: offset)
      }
      guard !name.isEmpty else {
        throw failure("The collection name must not be empty", at: offset)
      }
      return name
    }

    private func collectionName(
      _ arguments: [Argument], at nameStart: Int
    ) throws(ParseError) -> String {
      guard arguments.count == 1, case .string(let name) = arguments[0].value else {
        throw failure(
          "getCollection needs a collection name string", at: arguments.first?.offset ?? nameStart)
      }
      guard !name.isEmpty else {
        throw failure("The collection name must not be empty", at: arguments[0].offset)
      }
      return name
    }

    // MARK: Methods

    private mutating func parseMethod(on collection: String) throws(ParseError) -> MongoCommand {
      try skipTrivia()
      guard take(".") else {
        throw failure("Expected a method such as .find() after the collection", at: pos)
      }
      let (method, nameStart) = try methodName()
      guard MongoshParser.collectionMethods.contains(method) else {
        if peek() == UInt8(ascii: ".") {
          let dotted = MongoRelaxedJSON.render(.string("\(collection).\(method)"), as: .mongosh)
          throw failure(
            "Use db.getCollection(\(dotted)) for a collection name with dots", at: nameStart)
        }
        throw failure(unsupported(method), at: nameStart)
      }
      guard peek() == UInt8(ascii: "(") else {
        throw failure("Expected '(' after \(method)", at: pos)
      }
      let call = Call(method: method, offset: nameStart, arguments: try parseArguments())
      let command: MongoCommand
      switch method {
      case "find": return try parseFind(on: collection, call)
      case "aggregate": return try explainChain(after: aggregate(on: collection, call))
      case "countDocuments":
        if let extra = call[2] {
          throw failure(
            "countDocuments takes at most a filter and an options document", at: extra.offset)
        }
        let filter = try optionalDocument(call[0], "filter")
        let options = try countOptions(call[1])
        command = .countDocuments(collection: collection, filter: filter, options: options)
      case "distinct": command = try distinct(on: collection, call)
      case "insertOne": command = try insertOne(on: collection, call)
      case "insertMany": command = try insertMany(on: collection, call)
      case "updateOne", "updateMany": command = try update(on: collection, call)
      case "replaceOne": command = try replaceOne(on: collection, call)
      default: command = try delete(on: collection, call)
      }
      try refuseChain()
      return command
    }

    /// The identifier after a `.`, with trivia skipped after it.
    private mutating func methodName() throws(ParseError) -> (name: String, offset: Int) {
      try skipTrivia()
      let start = pos
      let name = identifier()
      guard !name.isEmpty else { throw failure("Expected a method name", at: pos) }
      try skipTrivia()
      return (name, start)
    }

    private mutating func parseFind(
      on collection: String, _ call: Call
    ) throws(ParseError) -> MongoCommand {
      try call.allowPositional(2)
      let filter = try optionalDocument(call[0], "filter")
      let projection = try optionalDocument(call[1], "projection")
      var sort: MongoValue?
      var skip: Int?
      var limit: Int?
      var options = MongoCommand.CursorOptions.none
      var seen: Set<String> = []
      var explainStart: Int?
      while true {
        try skipTrivia()
        guard take(".") else { break }
        let (name, nameStart) = try methodName()
        if name == "explain" {
          explainStart = nameStart
          break
        }
        guard ["sort", "skip", "limit", "collation", "hint", "maxTimeMS"].contains(name) else {
          throw failure(unsupported(name), at: nameStart)
        }
        guard peek() == UInt8(ascii: "(") else {
          throw failure("Expected '(' after \(name)", at: pos)
        }
        guard seen.insert(name).inserted else {
          throw failure("\(name) can only be used once", at: nameStart)
        }
        let chained = Call(method: name, offset: nameStart, arguments: try parseArguments())
        switch name {
        case "sort":
          guard chained.arguments.count == 1 else {
            throw failure("sort needs one document", at: nameStart)
          }
          sort = try optionalDocument(chained[0], "sort")
        case "skip": skip = try integer(chained)
        case "limit": limit = try integer(chained)
        case "collation":
          guard chained.arguments.count == 1 else {
            throw failure("collation needs one document", at: nameStart)
          }
          options.collation = try requiredDocument(chained[0], "collation")
        case "hint":
          guard chained.arguments.count == 1 else {
            throw failure("hint needs an index name or a key document", at: nameStart)
          }
          options.hint = try hint(chained.arguments[0])
        default:
          let value = try integer(chained)
          guard value >= 0 else {
            throw failure("maxTimeMS needs a non-negative integer", at: chained.arguments[0].offset)
          }
          options.maxTimeMS = value
        }
      }
      let command = MongoCommand.find(
        collection: collection, filter: filter, projection: projection, sort: sort, skip: skip,
        limit: limit, options: options)
      guard let explainStart else { return command }
      return try parseExplain(command, at: explainStart)
    }

    /// Any `.method(` after a command other than find or aggregate is outside the subset.
    private mutating func refuseChain() throws(ParseError) {
      try skipTrivia()
      guard take(".") else { return }
      let (name, nameStart) = try methodName()
      guard name != "explain" else {
        throw failure("explain only follows find or aggregate", at: nameStart)
      }
      throw failure(unsupported(name), at: nameStart)
    }

    /// `command` (an aggregate), or its `.explain(...)` when one follows; any other method is
    /// outside the subset.
    private mutating func explainChain(
      after command: MongoCommand
    ) throws(ParseError) -> MongoCommand {
      try skipTrivia()
      guard take(".") else { return command }
      let (name, nameStart) = try methodName()
      guard name == "explain" else { throw failure(unsupported(name), at: nameStart) }
      return try parseExplain(command, at: nameStart)
    }

    /// The `(verbosity?)` of an `explain` whose name ends just before `pos`; nothing may follow.
    private mutating func parseExplain(
      _ command: MongoCommand, at nameStart: Int
    ) throws(ParseError) -> MongoCommand {
      guard peek() == UInt8(ascii: "(") else {
        throw failure("Expected '(' after explain", at: pos)
      }
      let call = Call(method: "explain", offset: nameStart, arguments: try parseArguments())
      if let extra = call[1] {
        throw failure("explain takes at most one verbosity", at: extra.offset)
      }
      var verbosity = "queryPlanner"
      if let argument = call[0] {
        guard case .string(let value) = argument.value,
          ["queryPlanner", "executionStats", "allPlansExecution"].contains(value)
        else {
          throw failure(
            "explain needs \"queryPlanner\", \"executionStats\" or \"allPlansExecution\"",
            at: argument.offset)
        }
        verbosity = value
      }
      try skipTrivia()
      if take(".") {
        let (name, nameStart) = try methodName()
        throw failure(
          name == "explain" ? "explain can only be used once" : "explain must be the last method",
          at: nameStart)
      }
      return .explain(command, verbosity: verbosity)
    }

    private func aggregate(
      on collection: String, _ call: Call
    ) throws(ParseError) -> MongoCommand {
      guard let argument = call[0], case .array(let stages) = argument.value else {
        throw failure("aggregate needs a pipeline array", at: call[0]?.offset ?? call.offset)
      }
      try call.allowPositional(2)
      try requireDocuments(stages, argument, "Each pipeline stage must be a document")
      return .aggregate(
        collection: collection, pipeline: stages, options: try aggregateOptions(call[1]))
    }

    /// The aggregate options document: only collation, hint and maxTimeMS, each at most once;
    /// any other key is refused. Missing or `{}` is `.none`.
    private func aggregateOptions(
      _ argument: Argument?
    ) throws(ParseError) -> MongoCommand.CursorOptions {
      guard let document = try optionalDocument(argument, "options"), let argument,
        case .document(let fields) = document
      else { return .none }
      var options = MongoCommand.CursorOptions.none
      var seen: Set<String> = []
      for field in fields {
        guard seen.insert(field.key).inserted else {
          throw failure("The option \(field.key) can only be used once", at: argument.offset)
        }
        switch field.key {
        case "collation":
          options.collation = try requiredDocument((field.value, argument.offset), "collation")
        case "hint": options.hint = try hint((field.value, argument.offset))
        case "maxTimeMS":
          switch field.value {
          case .int32(let value) where value >= 0: options.maxTimeMS = Int(value)
          case .int64(let value) where value >= 0: options.maxTimeMS = Int(value)
          default:
            throw failure("maxTimeMS needs a non-negative integer", at: argument.offset)
          }
        default:
          throw failure(unsupported("aggregate option \(field.key)"), at: argument.offset)
        }
      }
      return options
    }

    private func distinct(
      on collection: String, _ call: Call
    ) throws(ParseError) -> MongoCommand {
      guard let argument = call[0], case .string(let field) = argument.value else {
        throw failure("distinct needs a field name string", at: call[0]?.offset ?? call.offset)
      }
      try call.allowPositional(2)
      let filter = try optionalDocument(call[1], "filter")
      return .distinct(collection: collection, field: field, filter: filter)
    }

    private func insertOne(
      on collection: String, _ call: Call
    ) throws(ParseError) -> MongoCommand {
      guard let argument = call[0], case .document = argument.value else {
        throw failure("insertOne needs a document", at: call[0]?.offset ?? call.offset)
      }
      try call.allowPositional(1)
      return .insertOne(collection: collection, document: argument.value)
    }

    private func insertMany(
      on collection: String, _ call: Call
    ) throws(ParseError) -> MongoCommand {
      guard let argument = call[0], case .array(let documents) = argument.value else {
        throw failure("insertMany needs an array of documents", at: call[0]?.offset ?? call.offset)
      }
      try requireDocuments(documents, argument, "insertMany needs an array of documents")
      guard !documents.isEmpty else {
        throw failure("insertMany needs at least one document", at: argument.offset)
      }
      try call.allowPositional(1)
      return .insertMany(collection: collection, documents: documents)
    }

    private func update(
      on collection: String, _ call: Call
    ) throws(ParseError) -> MongoCommand {
      guard call.arguments.count >= 2 else {
        throw failure("\(call.method) needs a filter and an update", at: call.offset)
      }
      let filter = try requiredDocument(call[0], "filter")
      let update = call.arguments[1]
      switch update.value {
      case .array(let stages):
        try requireDocuments(stages, update, "Each pipeline stage must be a document")
      case .document(let fields)
      where !fields.isEmpty && fields.allSatisfy({ $0.key.hasPrefix("$") }):
        break
      default:
        throw failure(
          "The update must be a document of update operators such as $set, or a pipeline array",
          at: update.offset)
      }
      let upsert = try upsertOption(call)
      return call.method == "updateOne"
        ? .updateOne(collection: collection, filter: filter, update: update.value, upsert: upsert)
        : .updateMany(collection: collection, filter: filter, update: update.value, upsert: upsert)
    }

    private func replaceOne(
      on collection: String, _ call: Call
    ) throws(ParseError) -> MongoCommand {
      guard call.arguments.count >= 2 else {
        throw failure("replaceOne needs a filter and a replacement", at: call.offset)
      }
      let filter = try requiredDocument(call[0], "filter")
      let replacement = call.arguments[1]
      guard case .document(let fields) = replacement.value else {
        throw failure("The replacement must be a document", at: replacement.offset)
      }
      guard !fields.contains(where: { $0.key.hasPrefix("$") }) else {
        throw failure(
          "The replacement must not contain update operators ($ keys)", at: replacement.offset)
      }
      let upsert = try upsertOption(call)
      return .replaceOne(
        collection: collection, filter: filter, replacement: replacement.value, upsert: upsert)
    }

    private func delete(
      on collection: String, _ call: Call
    ) throws(ParseError) -> MongoCommand {
      guard let argument = call[0], case .document = argument.value else {
        throw failure("\(call.method) needs a filter document", at: call[0]?.offset ?? call.offset)
      }
      try call.allowPositional(1)
      return call.method == "deleteOne"
        ? .deleteOne(collection: collection, filter: argument.value)
        : .deleteMany(collection: collection, filter: argument.value)
    }

    // MARK: Argument checks

    /// A method call's name, its offset and its arguments.
    private nonisolated struct Call {
      let method: String
      let offset: Int
      let arguments: [Argument]

      subscript(index: Int) -> Argument? {
        index < arguments.count ? arguments[index] : nil
      }

      /// Refuses arguments after the first `count` (an options argument in mongosh).
      func allowPositional(_ count: Int) throws(ParseError) {
        guard let extra = self[count] else { return }
        throw ParseError(
          message: "\(method) options are not supported in the Dblore MongoDB subset",
          offset: extra.offset)
      }
    }

    /// A document, or nil when missing or empty.
    private func optionalDocument(
      _ argument: Argument?, _ role: String
    ) throws(ParseError) -> MongoValue? {
      guard let argument else { return nil }
      guard case .document(let fields) = argument.value else {
        throw failure("The \(role) must be a document", at: argument.offset)
      }
      return fields.isEmpty ? nil : argument.value
    }

    private func requiredDocument(
      _ argument: Argument?, _ role: String
    ) throws(ParseError) -> MongoValue {
      guard let argument, case .document = argument.value else {
        throw failure("The \(role) must be a document", at: argument?.offset ?? pos)
      }
      return argument.value
    }

    private func requireDocuments(
      _ items: [MongoValue], _ argument: Argument, _ message: String
    ) throws(ParseError) {
      for item in items {
        guard case .document = item else { throw failure(message, at: argument.offset) }
      }
    }

    private func integer(_ call: Call) throws(ParseError) -> Int {
      guard call.arguments.count == 1 else {
        throw failure("\(call.method) needs an integer", at: call.offset)
      }
      let argument = call.arguments[0]
      switch argument.value {
      case .int32(let value): return Int(value)
      case .int64(let value): return Int(value)
      default: throw failure("\(call.method) needs an integer", at: argument.offset)
      }
    }

    /// An index name string or a key pattern document.
    private func hint(_ argument: Argument) throws(ParseError) -> MongoValue {
      switch argument.value {
      case .string, .document: return argument.value
      default: throw failure("hint needs an index name or a key document", at: argument.offset)
      }
    }

    /// The `countDocuments` options document as written, nil when missing or empty. Only skip,
    /// limit, collation, hint and maxTimeMS, each at most once; any other key is refused.
    private func countOptions(_ argument: Argument?) throws(ParseError) -> MongoValue? {
      guard let options = try optionalDocument(argument, "options"), let argument,
        case .document(let fields) = options
      else { return nil }
      var seen: Set<String> = []
      for field in fields {
        guard seen.insert(field.key).inserted else {
          throw failure("The option \(field.key) can only be used once", at: argument.offset)
        }
        switch field.key {
        case "skip", "limit", "maxTimeMS":
          switch field.value {
          case .int32(let value) where value >= 0: break
          case .int64(let value) where value >= 0: break
          default:
            throw failure("\(field.key) needs a non-negative integer", at: argument.offset)
          }
        case "collation":
          guard case .document = field.value else {
            throw failure("The collation must be a document", at: argument.offset)
          }
        case "hint": _ = try hint((field.value, argument.offset))
        default:
          throw failure(unsupported("The option \(field.key)"), at: argument.offset)
        }
      }
      return options
    }

    /// The `{upsert: bool}` options of an update or replace (third argument), false if absent.
    private func upsertOption(_ call: Call) throws(ParseError) -> Bool {
      if let extra = call[3] {
        throw failure("\(call.method) takes at most 3 arguments", at: extra.offset)
      }
      guard let options = call[2] else { return false }
      guard case .document(let fields) = options.value else {
        throw failure("The options must be a document", at: options.offset)
      }
      var upsert = false
      for field in fields {
        guard field.key == "upsert" else {
          throw failure(unsupported("The option \(field.key)"), at: options.offset)
        }
        guard case .bool(let flag) = field.value else {
          throw failure("upsert must be true or false", at: options.offset)
        }
        upsert = flag
      }
      return upsert
    }

    // MARK: Lexing

    /// `(` value, ... `)` with values parsed by `MongoRelaxedJSON` (trailing comma allowed).
    private mutating func parseArguments() throws(ParseError) -> [Argument] {
      pos += 1
      var arguments: [Argument] = []
      while true {
        try skipTrivia()
        if take(")") { break }
        let offset = pos
        let (value, end) = try MongoRelaxedJSON.parseValue(in: bytes, from: pos)
        pos = end
        arguments.append((value, offset))
        try skipTrivia()
        if take(",") { continue }
        if take(")") { break }
        throw failure("Expected ',' or ')'", at: pos)
      }
      return arguments
    }

    private func peek() -> UInt8? { pos < bytes.count ? bytes[pos] : nil }

    private mutating func take(_ ascii: Unicode.Scalar) -> Bool {
      guard peek() == UInt8(ascii: ascii) else { return false }
      pos += 1
      return true
    }

    /// `[A-Za-z_$][A-Za-z0-9_$]*`, empty when none starts here.
    private mutating func identifier() -> String {
      let start = pos
      guard peek()?.isMongoshIdentifierStart == true else { return "" }
      while let byte = peek(), byte.isMongoshIdentifierStart || (0x30...0x39).contains(byte) {
        pos += 1
      }
      return String(decoding: bytes[start..<pos], as: UTF8.self)
    }

    /// Whitespace, `//` line comments and `/* */` block comments.
    private mutating func skipTrivia() throws(ParseError) {
      while let byte = peek() {
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D:
          pos += 1
        case UInt8(ascii: "/") where pos + 1 < bytes.count && bytes[pos + 1] == UInt8(ascii: "/"):
          while let next = peek(), next != 0x0A, next != 0x0D { pos += 1 }
        case UInt8(ascii: "/") where pos + 1 < bytes.count && bytes[pos + 1] == UInt8(ascii: "*"):
          let start = pos
          pos += 2
          while pos + 1 < bytes.count,
            !(bytes[pos] == UInt8(ascii: "*") && bytes[pos + 1] == UInt8(ascii: "/"))
          {
            pos += 1
          }
          guard pos + 1 < bytes.count else { throw failure("Unterminated comment", at: start) }
          pos += 2
        default:
          return
        }
      }
    }

    private func unsupported(_ name: String) -> String { MongoshParser.unsupported(name) }

    /// An error at a byte offset, reported as UTF-16 code units from the start of the text.
    private func failure(_ message: String, at byteOffset: Int) -> ParseError {
      var end = min(byteOffset, bytes.count)
      while end > 0, end < bytes.count, bytes[end] & 0xC0 == 0x80 { end -= 1 }
      let offset = String(decoding: bytes[..<end], as: UTF8.self).utf16.count
      return ParseError(message: message, offset: offset)
    }
  }
}

nonisolated extension UInt8 {
  /// `A-Z`, `a-z`, `_` or `$`.
  fileprivate var isMongoshIdentifierStart: Bool {
    (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self) || self == UInt8(ascii: "_")
      || self == UInt8(ascii: "$")
  }
}
