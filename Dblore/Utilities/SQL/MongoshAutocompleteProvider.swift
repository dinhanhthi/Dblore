//
//  MongoshAutocompleteProvider.swift
//  Dblore
//
//  Autocomplete for mongosh cells (the Dblore MongoDB subset)
//

import Foundation

/// mongosh completions, from one forward pass over the text before the cursor (at most
/// `maxScan` UTF-16 units back, starting at a line start) with a bracket stack:
/// - after `db.` (top level): collections and the database methods (`getCollection`,
///   `getCollectionNames`, `createCollection`, `createView`, `runCommand`). A name that is not a
///   plain identifier, or is a database method name, is inserted as `getCollection("<name>")`;
/// - inside the string of `db.getCollection("` or `db["` (or `'`): collection names, escaped for
///   that quote so the string ends where it did;
/// - after `db.<collection>.`: the parser's collection methods; after `find(...)`: the unused
///   chain methods `sort`, `limit`, `skip`;
/// - at the start of a key in a document: field paths of the command's collection and query
///   operators in filters (also `$match` and the arrays of `$and`, `$or`, ...), field paths only
///   at the top level of projections, in sorts, inserted documents and update operator bodies,
///   update operators only at the top level of an update's second argument, stage names
///   directly inside the `aggregate([...])` array. A field path that is not a plain identifier
///   is inserted quoted;
/// - expression operators inside `$expr`, inside a nested document of `$project`, `$addFields`
///   and `$set` (whose top level offers field paths), in a `$replaceWith` or `$sortByCount`
///   body, the `newRoot` of `$replaceRoot`, the `_id` of `$group`, the `groupBy` of `$bucket`,
///   and in their nested documents and arrays;
/// - option keys at the top level of `$lookup`, `$unwind`, `$bucket`, ... (`_id` for `$group`);
///   accumulators and expression operators in the value document of a `$group` key or of a key
///   of a `$bucket` `output`.
///
/// Server-side JavaScript (`$where`, `$function`, `$accumulator`) is never offered.
///
/// Member completions (after `.`) show with an empty prefix; key completions need a typed
/// prefix. Nothing is offered inside other strings, regex literals or comments. Prefixes match
/// case-insensitively.
///
/// The editor replaces its own token (text between whitespace or `(),;`, see
/// `SQLTextView.findTokenRange`) with the suggestion text, so each text is that token with the
/// completed word swapped in (`db.users`, `{$gt`, `[{$match`, `"a.b"`).
enum MongoshAutocompleteProvider {
  /// UTF-16 units scanned back from the cursor (as `SQLAutocompleteProvider.maxStatementWindow`)
  static let maxScan = 10_240
  static let maxSuggestions = 20

  /// The collection methods `MongoshParser` accepts
  static let collectionMethods = [
    "find", "aggregate", "countDocuments", "distinct", "insertOne", "insertMany", "updateOne",
    "updateMany", "replaceOne", "deleteOne", "deleteMany", "createIndex", "dropIndex", "hideIndex",
    "unhideIndex", "drop", "renameCollection",
  ]
  static let databaseMethods = [
    "getCollection", "getCollectionNames", "createCollection", "createView", "runCommand",
  ]
  static let chainMethods = [
    "sort", "limit", "skip", "collation", "hint", "maxTimeMS", "explain",
  ]
  static let queryOperators = [
    "$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$in", "$nin", "$exists", "$type", "$regex",
    "$and", "$or", "$nor", "$not", "$elemMatch", "$size", "$all", "$expr", "$mod", "$text",
    "$jsonSchema", "$geoWithin", "$geoIntersects", "$near", "$nearSphere", "$bitsAllClear",
    "$bitsAllSet", "$bitsAnyClear", "$bitsAnySet", "$comment",
  ]
  static let updateOperators = [
    "$set", "$unset", "$inc", "$push", "$pull", "$addToSet", "$rename", "$min", "$max", "$mul",
    "$currentDate",
  ]
  static let stages = [
    "$match", "$group", "$project", "$sort", "$limit", "$skip", "$lookup", "$unwind", "$count",
    "$addFields", "$set", "$unset", "$replaceRoot", "$replaceWith", "$facet", "$sample", "$out",
    "$merge", "$sortByCount", "$bucket", "$bucketAuto", "$unionWith", "$graphLookup",
    "$setWindowFields", "$densify", "$fill", "$redact", "$geoNear",
  ]
  static let expressionOperators = [
    // Arithmetic (the accumulators below also work as expressions on an array)
    "$sum", "$avg", "$min", "$max", "$stdDevPop", "$stdDevSamp", "$add", "$subtract", "$multiply",
    "$divide", "$mod", "$abs", "$ceil", "$floor", "$round",
    "$trunc", "$pow", "$sqrt", "$exp", "$ln", "$log", "$log10",
    // Comparison, boolean, conditional
    "$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$cmp", "$and", "$or", "$not", "$cond",
    "$ifNull", "$switch",
    // String
    "$concat", "$substr", "$substrCP", "$toUpper", "$toLower", "$trim", "$ltrim", "$rtrim",
    "$split", "$strLenCP", "$regexMatch", "$replaceAll",
    // Array
    "$size", "$arrayElemAt", "$filter", "$map", "$reduce", "$in", "$concatArrays", "$slice",
    "$first", "$last", "$isArray", "$range", "$reverseArray",
    // Date
    "$dateToString", "$dateFromString", "$year", "$month", "$dayOfMonth", "$dayOfWeek", "$hour",
    "$minute", "$second", "$dateAdd", "$dateDiff", "$dateTrunc",
    // Type
    "$toString", "$toInt", "$toLong", "$toDouble", "$toDecimal", "$toBool", "$toDate",
    "$toObjectId", "$type", "$convert",
    // Object, misc
    "$mergeObjects", "$objectToArray", "$arrayToObject", "$getField", "$literal", "$let",
  ]
  static let accumulators = [
    "$sum", "$avg", "$min", "$max", "$first", "$last", "$push", "$addToSet", "$count",
    "$stdDevPop", "$stdDevSamp", "$mergeObjects", "$top", "$bottom", "$topN", "$bottomN",
    "$firstN", "$lastN", "$maxN", "$minN", "$median", "$percentile",
  ]
  /// Keys at the top level of these stage bodies
  static let stageOptions = [
    "$group": ["_id"],
    "$lookup": ["from", "localField", "foreignField", "as", "let", "pipeline"],
    "$unwind": ["path", "includeArrayIndex", "preserveNullAndEmptyArrays"],
    "$bucket": ["groupBy", "boundaries", "default", "output"],
    "$bucketAuto": ["groupBy", "buckets", "output", "granularity"],
    "$sample": ["size"],
    "$unionWith": ["coll", "pipeline"],
    "$merge": ["into", "on", "whenMatched", "whenNotMatched"],
    "$replaceRoot": ["newRoot"],
  ]

  /// Suggestions at `position` (UTF-16 offset), sorted: exact match first, then in group
  /// order (collections, methods; fields, operators), alphabetically inside a group.
  static func suggestions(
    for text: String, at position: Int, tables: [DatabaseTable]
  ) -> [AutocompleteSuggestion] {
    let ns = text as NSString
    let cursor = min(max(position, 0), ns.length)
    guard let context = context(in: ns, at: cursor) else { return [] }

    let token = editorToken(in: ns, at: cursor)
    guard token.start <= context.wordStart, context.wordEnd <= token.end else { return [] }
    let stem = ns.substring(
      with: NSRange(location: token.start, length: context.wordStart - token.start))
    let tail = ns.substring(
      with: NSRange(location: context.wordEnd, length: token.end - context.wordEnd))

    let prefix = context.partial.lowercased()
    let matches = candidates(for: context.kind, tables: tables).filter {
      $0.name.lowercased().hasPrefix(prefix)
    }
    let exact = matches.filter { $0.name.lowercased() == prefix }
    let others = matches.filter { $0.name.lowercased() != prefix }
    return (exact + others).prefix(maxSuggestions).map {
      AutocompleteSuggestion(
        text: stem + $0.insertion + tail, type: $0.type, description: $0.description)
    }
  }

  /// Where a bare document (no `db.` command around it) is used
  enum DocumentMode: Equatable {
    /// A `find` filter
    case filter
    /// The body of the aggregation stage `op` (`$match`, `$project`, ...)
    case stage(String)
  }

  /// Suggestions inside a bare document of `collection`: the text is read as if it followed
  /// `db.getCollection("<collection>").find(` or `...aggregate([{<op>: `. Both prefixes end at
  /// an editor token boundary, so the suggestion texts fit `text` unchanged. The `.stage(op)`
  /// operator must be a trusted literal stage name: it is interpolated unescaped into the prefix.
  static func documentSuggestions(
    for text: String, at position: Int, collection: String, mode: DocumentMode,
    tables: [DatabaseTable]
  ) -> [AutocompleteSuggestion] {
    let command = "db.getCollection(\(quoted(collection)))"
    let prefix: String
    switch mode {
    case .filter: prefix = command + ".find("
    case .stage(let op): prefix = command + ".aggregate([{\(op): "
    }
    let cursor = min(max(position, 0), (text as NSString).length)
    return suggestions(
      for: prefix + text, at: (prefix as NSString).length + cursor, tables: tables)
  }

  // MARK: - Candidates

  private struct Candidate {
    /// Matched against the typed prefix
    let name: String
    /// Replaces the typed word
    let insertion: String
    let type: AutocompleteSuggestionType
    let description: String
  }

  private static func candidates(for kind: Context.Kind, tables: [DatabaseTable]) -> [Candidate] {
    switch kind {
    case .collectionMember:
      return collections(tables) {
        isPlainIdentifier($0) && !databaseMethods.contains($0)
          ? $0 : "getCollection(\(quoted($0)))"
      }
        + keywords(databaseMethods.filter { $0 != "runCommand" }, "Database method")
        // The parser takes only `runCommand({collMod: …})`
        + keywords(["runCommand"], "Database method, {collMod: …} only")
    case .collectionName(let quote):
      return collections(tables) { escaped($0, quote: quote) }
    case .method:
      return keywords(collectionMethods, "Collection method")
    case .chain(let used):
      return keywords(chainMethods.filter { !used.contains($0) }, "Cursor method")
    case .query(let collection):
      return fields(of: collection, tables) + keywords(queryOperators, "Query operator")
    case .fields(let collection):
      return fields(of: collection, tables)
    case .update:
      return keywords(updateOperators, "Update operator")
    case .stage:
      return keywords(stages, "Aggregation stage")
    case .expression:
      return keywords(expressionOperators, "Expression operator")
    case .accumulator:
      // `$first`, `$last`, ... are both: listed once, as accumulators
      return keywords(accumulators, "Accumulator")
        + keywords(
          expressionOperators.filter { !accumulators.contains($0) }, "Expression operator")
    case .options(let stage):
      return keywords(stageOptions[stage] ?? [], "\(stage) option")
    }
  }

  private static func collections(
    _ tables: [DatabaseTable], insertion: (String) -> String
  ) -> [Candidate] {
    sortedByName(
      tables.map { table in
        Candidate(
          name: table.name, insertion: insertion(table.name), type: .table,
          description: "Collection (\(table.schema))")
      })
  }

  private static func fields(of collection: String, _ tables: [DatabaseTable]) -> [Candidate] {
    guard let table = tables.first(where: { $0.name == collection }) else { return [] }
    return sortedByName(
      table.columns.map { column in
        Candidate(
          name: column.name,
          insertion: isPlainIdentifier(column.name) ? column.name : quoted(column.name),
          type: .column(tableName: table.qualifiedName),
          description: "\(column.type) (\(table.name))")
      })
  }

  private static func keywords(_ names: [String], _ description: String) -> [Candidate] {
    sortedByName(
      names.map {
        Candidate(name: $0, insertion: $0, type: .keyword, description: description)
      })
  }

  private static func sortedByName(_ candidates: [Candidate]) -> [Candidate] {
    candidates.sorted { $0.name.lowercased() < $1.name.lowercased() }
  }

  private static func quoted(_ name: String) -> String {
    "\"" + escaped(name, quote: 0x22) + "\""
  }

  /// `name` as the content of a string literal opened by `quote` (`"` or `'`): the mongosh string
  /// escapes (backslash, `"`, control characters), plus `'` for `'` and U+2028/U+2029, which
  /// the editor treats as line breaks. The parser reads all of them back.
  private static func escaped(_ name: String, quote: unichar) -> String {
    let literal = MongoRelaxedJSON.render(.string(name), as: .mongosh)
    var result = ""
    for scalar in literal.unicodeScalars.dropFirst().dropLast() {
      switch scalar.value {
      case 0x27 where quote == 0x27: result += "\\'"
      case 0x2028: result += "\\u2028"
      case 0x2029: result += "\\u2029"
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result
  }

  /// `[A-Za-z_$][A-Za-z0-9_$]*`, what the parser reads after `db.` and as an unquoted key
  private static func isPlainIdentifier(_ name: String) -> Bool {
    guard let first = name.utf16.first, isWordStart(first) else { return false }
    return name.utf16.allSatisfy(isWordPart)
  }

  // MARK: - Editor token

  /// The range `SQLTextView.findTokenRange` replaces: from after the last whitespace or `(),;`
  /// before the cursor to the next one after it.
  private static func editorToken(in ns: NSString, at cursor: Int) -> (start: Int, end: Int) {
    func isBoundary(_ unit: unichar) -> Bool {
      guard let scalar = Unicode.Scalar(unit) else { return false }
      return "(),;".unicodeScalars.contains(scalar) || Character(scalar).isWhitespace
    }
    var start = cursor
    while start > 0 && !isBoundary(ns.character(at: start - 1)) { start -= 1 }
    var end = cursor
    while end < ns.length && !isBoundary(ns.character(at: end)) { end += 1 }
    return (start, end)
  }

  // MARK: - Context

  fileprivate struct Context: Equatable {
    enum Kind: Equatable {
      /// After `db.`
      case collectionMember
      /// Inside the string of `getCollection("` or `db["`, opened by `quote`
      case collectionName(quote: unichar)
      /// After `db.<collection>.`
      case method
      /// After `find(...)` and its chains, then `.`
      case chain(used: Set<String>)
      case query(collection: String)
      case fields(collection: String)
      case update
      case stage
      case expression
      /// Accumulators, then expression operators
      case accumulator
      /// Option keys of the stage
      case options(stage: String)
    }

    let kind: Kind
    /// Text of the word before the cursor
    let partial: String
    /// UTF-16 range of the whole word around the cursor (the part replaced by a completion)
    let wordStart: Int
    let wordEnd: Int
  }

  /// The completion context at `cursor`, nil when nothing is offered there.
  fileprivate static func context(in ns: NSString, at cursor: Int) -> Context? {
    var wordStart = cursor
    while wordStart > 0 && isWordPart(ns.character(at: wordStart - 1)) { wordStart -= 1 }
    var wordEnd = cursor
    while wordEnd < ns.length && isWordPart(ns.character(at: wordEnd)) { wordEnd += 1 }

    let scanStart = scanStart(in: ns, before: wordStart)
    var buffer = [unichar](repeating: 0, count: wordStart - scanStart)
    ns.getCharacters(&buffer, range: NSRange(location: scanStart, length: buffer.count))
    var scanner = Scanner(buffer: buffer)
    scanner.run()

    switch scanner.end {
    case .comment, .regex:
      return nil
    case .string(let quote):
      guard let top = scanner.stack.last, top.role == .collectionName, top.tokens == 0 else {
        return nil
      }
      let contentStart = scanStart + quote + 1
      let quoteChar = buffer[quote]
      var end = cursor
      while end < ns.length, ns.character(at: end) != quoteChar, !isLineBreak(ns.character(at: end))
      {
        end += 1
      }
      let partial = ns.substring(
        with: NSRange(location: contentStart, length: cursor - contentStart))
      return Context(
        kind: .collectionName(quote: quoteChar), partial: partial, wordStart: contentStart,
        wordEnd: end)
    case .code:
      let partial = ns.substring(with: NSRange(location: wordStart, length: cursor - wordStart))
      guard let kind = scanner.kind(partialIsEmpty: partial.isEmpty) else { return nil }
      return Context(kind: kind, partial: partial, wordStart: wordStart, wordEnd: wordEnd)
    }
  }

  /// `maxScan` units before `index`, moved forward to the next line start (0 if in reach)
  private static func scanStart(in ns: NSString, before index: Int) -> Int {
    guard index > maxScan else { return 0 }
    var start = index - maxScan
    while start < index && !isLineBreak(ns.character(at: start - 1)) { start += 1 }
    return start
  }

  fileprivate static func isWordStart(_ c: unichar) -> Bool {
    (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || c == 0x5F || c == 0x24  // _ $
  }

  fileprivate static func isWordPart(_ c: unichar) -> Bool {
    isWordStart(c) || (0x30...0x39).contains(c)
  }

  fileprivate static func isLineBreak(_ c: unichar) -> Bool {
    c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029
  }
}

// MARK: - Scanner

extension MongoshAutocompleteProvider {
  /// Tracks the command at the top level and a frame per open bracket.
  private struct Scanner {
    enum End: Equatable {
      case code
      case comment
      case regex
      /// Inside a string opened at this buffer index
      case string(Int)
    }

    /// Progress of the top-level command
    enum Command: Equatable {
      case none
      case db
      case dbDot
      /// `db.<word>`: a collection, or `getCollection` when `(` follows
      case dbWord(String)
      case collectionDot(String)
      case method(String, collection: String)
      /// After `find(...)` or one of its chains
      case found(collection: String, used: Set<String>)
      case foundDot(collection: String, used: Set<String>)
      case chainName(String, collection: String, used: Set<String>)
    }

    enum Document: Equatable {
      case query, fields, update, stage, none
      /// Keys are field paths, nested documents expressions (`$project`, `$addFields`, ...)
      case projection
      case expression
      /// The value of a `$group` key or of a `$bucket` output
      case accumulator
      /// Top level of a stage body with option keys
      case options(String)
      /// A `$bucket` `output`: keys are new names, their values accumulators
      case outputs
    }
    enum List: Equatable { case pipeline, query, documents, expression, none }

    struct Frame {
      enum Role: Equatable {
        case collectionName
        case call(String)
        case document(Document)
        case list(List)
        case other
      }

      let role: Role
      let collection: String
      /// Top-level command after the closing bracket (top-level frames only)
      var afterClose: Command = .none
      /// Call: arguments before the current one
      var argument = 0
      /// Document: nothing since `{` or `,`
      var atKeyStart = true
      /// Document: after the key's `:`
      var inValue = false
      /// Document: the first token of the current key, the key once `:` is read
      var key: String?
      /// Collection name: tokens inside and the first string
      var tokens = 0
      var name: String?
    }

    enum Token {
      case word(String)
      case string(String)
      case punctuation(unichar)
      case value
    }

    let buffer: [unichar]
    private(set) var stack: [Frame] = []
    private(set) var end = End.code
    private var command = Command.none
    private var i = 0
    /// Last significant character, 0 at the start
    private var previous: unichar = 0
    /// A regex scan failed on this line: no `/` before here starts one
    private var regexFailsBefore = 0

    init(buffer: [unichar]) {
      self.buffer = buffer
    }

    private static let slash = unichar(UInt8(ascii: "/"))
    private static let star = unichar(UInt8(ascii: "*"))
    private static let backslash = unichar(UInt8(ascii: "\\"))
    /// Characters after which `/` starts a regex literal (as the highlighter)
    private static let regexPrefixes = Set("(,:[{=!&|?;".utf16)

    // MARK: Lexing

    mutating func run() {
      let n = buffer.count
      while i < n {
        let c = buffer[i]
        let next: unichar = i + 1 < n ? buffer[i + 1] : 0
        if c == Self.slash && next == Self.slash {
          while i < n && !MongoshAutocompleteProvider.isLineBreak(buffer[i]) { i += 1 }
          if i == n { end = .comment }
        } else if c == Self.slash && next == Self.star {
          var k = i + 2
          while k + 1 < n && !(buffer[k] == Self.star && buffer[k + 1] == Self.slash) { k += 1 }
          guard k + 1 < n else {
            end = .comment
            return
          }
          i = k + 2
        } else if c == 0x22 || c == 0x27 {  // " '
          guard scanString(quote: c) else { return }
        } else if c == Self.slash, i >= regexFailsBefore,
          previous == 0 || Self.regexPrefixes.contains(previous)
        {
          guard scanRegex() else { return }
        } else if (0x30...0x39).contains(c) {
          var k = i + 1
          while k < n && (MongoshAutocompleteProvider.isWordPart(buffer[k]) || buffer[k] == 0x2E) {
            k += 1
          }
          consume(.value, upTo: k)
        } else if MongoshAutocompleteProvider.isWordStart(c) {
          var k = i + 1
          while k < n && MongoshAutocompleteProvider.isWordPart(buffer[k]) { k += 1 }
          consume(.word(String(decoding: buffer[i..<k], as: UTF16.self)), upTo: k)
        } else if c == 0x20 || (0x09...0x0D).contains(c) || c == 0xA0 || c == 0x2028 || c == 0x2029
        {
          i += 1
        } else {
          consume(.punctuation(c), upTo: i + 1)
        }
      }
    }

    private mutating func consume(_ token: Token, upTo next: Int) {
      handle(token)
      previous = buffer[next - 1]
      i = next
    }

    /// Reads the string at `i`; false when it is still open at the end of the buffer
    private mutating func scanString(quote: unichar) -> Bool {
      var k = i + 1
      while k < buffer.count {
        if buffer[k] == quote {
          consume(.string(String(decoding: buffer[(i + 1)..<k], as: UTF16.self)), upTo: k + 1)
          return true
        }
        k += buffer[k] == Self.backslash ? 2 : 1
      }
      end = .string(i)
      return false
    }

    /// `/pattern/flags` on one line; without a closer the `/` is plain. False when the literal
    /// is still open at the end of the buffer.
    private mutating func scanRegex() -> Bool {
      let n = buffer.count
      var k = i + 1
      var inClass = false
      while k < n && !MongoshAutocompleteProvider.isLineBreak(buffer[k]) {
        let d = buffer[k]
        if d == Self.backslash {
          guard k + 1 < n else {
            k = n
            break
          }
          if MongoshAutocompleteProvider.isLineBreak(buffer[k + 1]) { break }
          k += 2
          continue
        }
        if d == 0x5B {  // [
          inClass = true
        } else if d == 0x5D {  // ]
          inClass = false
        } else if d == Self.slash && !inClass {
          var flagsEnd = k + 1
          while flagsEnd < n && MongoshAutocompleteProvider.isWordPart(buffer[flagsEnd]) {
            flagsEnd += 1
          }
          consume(.value, upTo: flagsEnd)
          return true
        }
        k += 1
      }
      guard k < n else {
        end = .regex
        return false
      }
      regexFailsBefore = k
      consume(.punctuation(Self.slash), upTo: i + 1)
      return true
    }

    // MARK: Structure

    private mutating func handle(_ token: Token) {
      if case .punctuation(let c) = token {
        switch c {
        case 0x28, 0x5B, 0x7B:  // ( [ {
          noteToken(token)
          open(c)
          return
        case 0x29, 0x5D, 0x7D:  // ) ] }
          close()
          return
        case 0x3B where stack.isEmpty:  // ;
          command = .none
          return
        default:
          break
        }
      }
      if stack.isEmpty {
        command = advance(command, token)
      } else {
        noteToken(token)
      }
    }

    /// The top-level command after `token`
    private func advance(_ command: Command, _ token: Token) -> Command {
      let dot = unichar(UInt8(ascii: "."))
      switch (command, token) {
      case (.db, .punctuation(dot)): return .dbDot
      case (.dbDot, .word(let word)): return .dbWord(word)
      case (.dbWord(let collection), .punctuation(dot)): return .collectionDot(collection)
      case (.collectionDot(let collection), .word(let method)):
        return .method(method, collection: collection)
      case (.found(let collection, let used), .punctuation(dot)):
        return .foundDot(collection: collection, used: used)
      case (.foundDot(let collection, let used), .word(let name)):
        return .chainName(name, collection: collection, used: used)
      case (_, .word("db")): return .db
      default: return .none
      }
    }

    /// Records a token (an opening bracket included) inside the innermost frame
    private mutating func noteToken(_ token: Token) {
      guard var top = stack.popLast() else { return }
      defer { stack.append(top) }
      let separator = { (c: unichar) -> Bool in
        if case .punctuation(c) = token { return true }
        return false
      }
      switch top.role {
      case .call:
        if separator(0x2C) { top.argument += 1 }  // ,
      case .document:
        if separator(0x2C) {
          top.atKeyStart = true
          top.inValue = false
          top.key = nil
        } else if separator(0x3A) {  // :
          top.atKeyStart = false
          top.inValue = true
        } else if top.atKeyStart {
          top.atKeyStart = false
          switch token {
          case .word(let text), .string(let text): top.key = text
          default: top.key = nil
          }
        } else if !top.inValue {
          top.key = nil
        }
      case .collectionName:
        top.tokens += 1
        if top.tokens == 1, case .string(let name) = token { top.name = name }
      case .list, .other:
        break
      }
    }

    private mutating func open(_ bracket: unichar) {
      guard let parent = stack.last else {
        stack.append(topLevelFrame(bracket))
        command = .none
        return
      }
      stack.append(Frame(role: role(of: bracket, in: parent), collection: parent.collection))
    }

    private func topLevelFrame(_ bracket: unichar) -> Frame {
      switch (command, bracket) {
      case (.dbWord("getCollection"), 0x28), (.db, 0x5B):
        return Frame(role: .collectionName, collection: "")
      case (.method(let method, let collection), 0x28):
        let after: Command = method == "find" ? .found(collection: collection, used: []) : .none
        return Frame(role: .call(method), collection: collection, afterClose: after)
      case (.chainName(let name, let collection, let used), 0x28)
      where MongoshAutocompleteProvider.chainMethods.contains(name):
        return Frame(
          role: .call(name), collection: collection,
          // `explain` must be the last method
          afterClose: name == "explain"
            ? .none : .found(collection: collection, used: used.union([name])))
      default:
        return Frame(role: .other, collection: "")
      }
    }

    private func role(of bracket: unichar, in parent: Frame) -> Frame.Role {
      switch (parent.role, bracket) {
      case (.call(let method), 0x7B):  // {
        return .document(Self.document(of: method, argument: parent.argument))
      case (.call(let method), 0x5B):  // [
        switch (method, parent.argument) {
        case ("aggregate", 0): return .list(.pipeline)
        case ("insertMany", 0): return .list(.documents)
        default: return .list(.none)
        }
      case (.document(let document), 0x7B):
        guard parent.inValue, let key = parent.key else { return .document(.none) }
        switch document {
        case .query: return .document(key == "$expr" ? .expression : .query)
        case .update: return .document(.fields)
        case .stage:
          switch key {
          case "$match": return .document(.query)
          case "$sort": return .document(.fields)
          case "$project", "$addFields", "$set": return .document(.projection)
          case "$replaceWith", "$sortByCount": return .document(.expression)
          case _ where MongoshAutocompleteProvider.stageOptions[key] != nil:
            return .document(.options(key))
          default: return .document(.none)
          }
        case .options(let stage):
          switch (stage, key) {
          case ("$group", "_id"), ("$bucket", "groupBy"), ("$bucketAuto", "groupBy"),
            ("$replaceRoot", "newRoot"):
            return .document(.expression)
          case ("$group", _): return .document(.accumulator)
          case ("$bucket", "output"), ("$bucketAuto", "output"): return .document(.outputs)
          default: return .document(.none)
          }
        case .outputs: return .document(.accumulator)
        case .projection, .expression, .accumulator: return .document(.expression)
        case .fields, .none: return .document(.none)
        }
      case (.document(.query), 0x5B):
        return .list(parent.inValue ? .query : .none)
      case (.document(.expression), 0x5B), (.document(.accumulator), 0x5B):
        return .list(parent.inValue ? .expression : .none)
      case (.list(let list), 0x7B):
        switch list {
        case .pipeline: return .document(.stage)
        case .query: return .document(.query)
        case .documents: return .document(.fields)
        case .expression: return .document(.expression)
        case .none: return .document(.none)
        }
      case (_, 0x5B):
        return .list(.none)
      case (_, 0x7B):
        return .document(.none)
      default:
        return .other
      }
    }

    /// What a document directly in argument `argument` of `method` holds
    private static func document(of method: String, argument: Int) -> Document {
      switch (method, argument) {
      case ("find", 0), ("countDocuments", 0), ("distinct", 1), ("updateOne", 0),
        ("updateMany", 0), ("replaceOne", 0), ("deleteOne", 0), ("deleteMany", 0):
        return .query
      case ("find", 1), ("sort", 0), ("insertOne", 0), ("replaceOne", 1):
        return .fields
      case ("updateOne", 1), ("updateMany", 1):
        return .update
      default:
        return .none
      }
    }

    private mutating func close() {
      guard let frame = stack.popLast() else {
        command = .none
        return
      }
      guard stack.isEmpty else { return }
      if frame.role == .collectionName {
        // One string and nothing else names the collection
        if frame.tokens == 1, let name = frame.name {
          command = .dbWord(name)
        } else {
          command = .none
        }
      } else {
        command = frame.afterClose
      }
    }

    // MARK: Result

    /// The completion kind at the end of the buffer (code only)
    func kind(partialIsEmpty: Bool) -> Context.Kind? {
      guard let top = stack.last else {
        switch command {
        case .dbDot: return .collectionMember
        case .collectionDot: return .method
        case .foundDot(_, let used): return .chain(used: used)
        default: return nil
        }
      }
      guard !partialIsEmpty, case .document(let document) = top.role, top.atKeyStart else {
        return nil
      }
      switch document {
      case .query: return .query(collection: top.collection)
      case .fields, .projection: return .fields(collection: top.collection)
      case .update: return .update
      case .stage: return .stage
      case .expression: return .expression
      case .accumulator: return .accumulator
      case .options(let stage): return .options(stage: stage)
      case .outputs, .none: return nil
      }
    }
  }
}
