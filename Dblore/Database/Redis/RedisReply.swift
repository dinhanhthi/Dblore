// RedisReply.swift
// One Redis reply as a tree, rebuilt from the plugin's reply rows `[path, type, value]`: one row
// per RESP node, depth first; the root's path is "0", a child's is "<parent>.<i>"; an
// aggregate's value is its child count (a map of n pairs has 2n children, key then value). The
// rows are checked strictly: anything that does not fit throws, never a guessed tree.

import Foundation

/// A string node's value: text when its bytes are valid UTF-8, else the bytes
nonisolated enum RedisReplyString: Sendable, Equatable {
  case text(String)
  case bytes(Data)
}

/// One key and value of a map reply
nonisolated struct RedisReplyPair: Sendable, Equatable {
  let key: RedisReply
  let value: RedisReply
}

/// The rows do not form one reply, or pass the node or depth cap. `message` says what is wrong.
nonisolated struct RedisReplyDecodingError: LocalizedError, Equatable {
  let message: String

  var errorDescription: String? { "Unreadable Redis reply: \(message)" }
}

/// A RESP2 / RESP3 reply. A null bulk string or array is `.null` (the plugin sends them as
/// `null` nodes). `push` is kept only nested in a reply; the plugin drops out-of-band pushes.
nonisolated indirect enum RedisReply: Sendable, Equatable {
  case simple(RedisReplyString)
  case bulk(RedisReplyString)
  case verbatim(RedisReplyString)
  case error(RedisReplyString)
  case integer(Int)
  /// As the server wrote it (`1.5`, `inf`, `nan`)
  case double(String)
  case boolean(Bool)
  case null
  /// As the server wrote it: the digits of a number past 64 bits
  case bignum(String)
  case array([RedisReply])
  case set([RedisReply])
  case map([RedisReplyPair])
  case push([RedisReply])

  /// The most rows a reply is rebuilt from, and the gate collects
  /// (`DatabaseConnectionManager.executeGatedRedisCommand`)
  static let defaultMaxNodes = 100_000

  /// The deepest nesting of aggregates that have children (the top one is level 1): the
  /// plugin's own cap (`RESPReply.maxDepth`), which also keeps the tree's recursive `==` and
  /// release shallow
  static let maxDepth = 128

  /// Rebuilds the reply from its rows. `maxNodes`: the most rows accepted (refused past it,
  /// without decoding the rest).
  /// - Throws: `RedisReplyDecodingError` when the rows are empty, a row is not three cells of
  ///   the expected kinds, a path is not the next one, a child is missing, a row follows the
  ///   end of the reply, a map has an odd child count, or a cap is passed.
  init(rows: [[CellValue]], maxNodes: Int = defaultMaxNodes) throws {
    var stack: [Frame] = []
    var root: RedisReply?
    for (index, row) in rows.enumerated() {
      if index >= maxNodes {
        throw RedisReplyDecodingError(message: "more than \(maxNodes) nodes")
      }
      guard root == nil else {
        throw RedisReplyDecodingError(message: "row \(index + 1) follows the end of the reply")
      }
      let expected = stack.last.map { "\($0.path).\($0.children.count)" } ?? "0"
      guard row.count == 3, case .string(let path) = row[0], case .string(let type) = row[1]
      else {
        throw RedisReplyDecodingError(message: "row \(index + 1) is not a path, type and value")
      }
      guard path == expected else {
        throw RedisReplyDecodingError(
          message: "row \(index + 1) has path \(path), expected \(expected)")
      }
      var node: RedisReply
      if let kind = Aggregate(rawValue: type) {
        guard case .int(let count) = row[2], count >= 0, kind != .map || count % 2 == 0 else {
          throw RedisReplyDecodingError(
            message: "row \(index + 1) is a \(type) with an invalid child count")
        }
        guard count == 0 else {
          // Each open frame keeps its path, so the depth cap also bounds what they hold
          guard stack.count < Self.maxDepth else {
            throw RedisReplyDecodingError(
              message: "row \(index + 1) is nested deeper than \(Self.maxDepth) levels")
          }
          stack.append(Frame(path: path, kind: kind, remaining: count))
          continue
        }
        node = kind.reply([])
      } else {
        node = try Self.leaf(type, row[2], row: index + 1)
      }
      // Close every aggregate this node completes
      while var top = stack.popLast() {
        top.children.append(node)
        top.remaining -= 1
        guard top.remaining == 0 else {
          stack.append(top)
          break
        }
        node = top.kind.reply(top.children)
      }
      if stack.isEmpty { root = node }
    }
    guard let root else {
      throw RedisReplyDecodingError(
        message: rows.isEmpty ? "no rows" : "the reply ends before all its children")
    }
    self = root
  }

  // MARK: - Private

  private enum Aggregate: String {
    case array, set, map, push

    /// `children` are in row order; a map's alternate key, value
    func reply(_ children: [RedisReply]) -> RedisReply {
      switch self {
      case .array: .array(children)
      case .set: .set(children)
      case .push: .push(children)
      case .map:
        .map(
          stride(from: 0, to: children.count, by: 2).map {
            RedisReplyPair(key: children[$0], value: children[$0 + 1])
          })
      }
    }
  }

  /// An aggregate whose children are still being read. The children are appended as they
  /// arrive, never reserved from the announced count (a server may announce any count).
  private struct Frame {
    let path: String
    let kind: Aggregate
    var remaining: Int
    var children: [RedisReply] = []
  }

  private static func leaf(_ type: String, _ value: CellValue, row: Int) throws -> RedisReply {
    switch (type, value) {
    case ("simple", _), ("bulk", _), ("verbatim", _), ("error", _):
      let string: RedisReplyString
      switch value {
      case .string(let text): string = .text(text)
      case .data(let bytes): string = .bytes(bytes)
      default: throw invalidValue(row: row)
      }
      switch type {
      case "simple": return .simple(string)
      case "bulk": return .bulk(string)
      case "verbatim": return .verbatim(string)
      default: return .error(string)
      }
    case ("integer", .int(let number)): return .integer(number)
    case ("double", .string(let text)): return .double(text)
    case ("bignum", .string(let text)): return .bignum(text)
    case ("boolean", .string("true")): return .boolean(true)
    case ("boolean", .string("false")): return .boolean(false)
    case ("null", .null): return .null
    default: throw invalidValue(row: row)
    }
  }

  private static func invalidValue(row: Int) -> RedisReplyDecodingError {
    RedisReplyDecodingError(
      message: "row \(row) has an unknown type or a value its type cannot hold")
  }
}

// MARK: - Display

/// One node of a reply as the reply view's Grid shows it
nonisolated struct RedisReplyDisplayRow: Sendable, Equatable {
  /// A map child's place in its pair
  enum Role: String, Sendable {
    case key, value
  }

  /// As in the plugin's rows: "0" for the reply, "<parent>.<i>" below it
  let path: String
  /// 0 for the reply itself
  let depth: Int
  /// Set for a map's children only
  let role: Role?
  /// The plugin's type name (`bulk`, `map`, …)
  let type: String
  /// One escaped line, cut for display; an aggregate's child count ("2 pairs", "3 items")
  let value: String
}

nonisolated extension RedisReply {
  /// The longest Grid value, in Unicode scalars, before it is cut with an ellipsis
  static let maxDisplayValueLength = 1_000

  /// The most UTF-8 bytes of Raw text, before it ends with a line that says it was cut
  static let maxRawTextBytes = 4 * 1_048_576

  /// The type name the plugin's rows use
  var typeName: String {
    switch self {
    case .simple: "simple"
    case .bulk: "bulk"
    case .verbatim: "verbatim"
    case .error: "error"
    case .integer: "integer"
    case .double: "double"
    case .boolean: "boolean"
    case .null: "null"
    case .bignum: "bignum"
    case .array: "array"
    case .set: "set"
    case .map: "map"
    case .push: "push"
    }
  }

  /// One row per node, depth first, with the plugin's paths. Strings are one line, escaped by
  /// `RedisDisplayText.line` (bytes that are not UTF-8 as `\xNN`, invisible characters as
  /// `\u{XXXX}`) and cut after `maxValueLength` Unicode scalars with "…". Stops early (rows
  /// missing) when the current task is cancelled.
  func displayRows(maxValueLength: Int = maxDisplayValueLength) -> [RedisReplyDisplayRow] {
    var rows: [RedisReplyDisplayRow] = []
    Self.appendRows(
      self, path: "0", depth: 0, role: nil, limit: maxValueLength, to: &rows)
    return rows
  }

  /// The reply in redis-cli style: `(integer) 5`, `(nil)`, `(error) …`,
  /// quoted strings, numbered items (`1)`, a set's `1~`, a map's `1# key => value`), nested
  /// lines indented under their parent's index. Strings are escaped as in the Grid but not cut
  /// one by one, and quoted strings also escape `"`; a verbatim text string keeps its line
  /// breaks (`RedisDisplayText.lines`). The text ends with "… (output cut at 4 MB)" past
  /// `maxRawTextBytes`. Stops early (text missing) when the current task is cancelled.
  var rawText: String {
    var writer = RawWriter(limit: Self.maxRawTextBytes)
    Self.appendRaw(self, prefix: "", to: &writer)
    return writer.out
  }

  // MARK: - Private

  private static func appendRows(
    _ reply: RedisReply, path: String, depth: Int, role: RedisReplyDisplayRow.Role?, limit: Int,
    to rows: inout [RedisReplyDisplayRow]
  ) {
    guard !Task.isCancelled else { return }
    let children: [(RedisReply, RedisReplyDisplayRow.Role?)]
    let value: String
    switch reply {
    case .array(let items), .set(let items), .push(let items):
      children = items.map { ($0, nil) }
      value = items.count == 1 ? "1 item" : "\(items.count) items"
    case .map(let pairs):
      children = pairs.flatMap { [($0.key, .key), ($0.value, .value)] }
      value = pairs.count == 1 ? "1 pair" : "\(pairs.count) pairs"
    default:
      children = []
      value = displayValue(reply, limit: limit)
    }
    rows.append(
      RedisReplyDisplayRow(
        path: path, depth: depth, role: role, type: reply.typeName, value: value))
    for (index, (child, childRole)) in children.enumerated() {
      appendRows(
        child, path: "\(path).\(index)", depth: depth + 1, role: childRole, limit: limit,
        to: &rows)
    }
  }

  private static func displayValue(_ reply: RedisReply, limit: Int) -> String {
    switch reply {
    case .simple(let string), .bulk(let string), .verbatim(let string), .error(let string):
      cut(string, limit: limit)
    case .integer(let number): String(number)
    case .double(let text), .bignum(let text): cut(.text(text), limit: limit)
    case .boolean(let flag): flag ? "true" : "false"
    case .null: "(nil)"
    case .array, .set, .map, .push: ""
    }
  }

  /// `string` escaped, cut after `limit` Unicode scalars. The input is cut first, so a large
  /// value is never escaped whole.
  private static func cut(_ string: RedisReplyString, limit: Int) -> String {
    let (input, inputCut) = head(of: string, limit: limit)
    let shown = RedisDisplayText.line(input)
    guard shown.unicodeScalars.count > limit || inputCut else { return shown }
    return String(String.UnicodeScalarView(shown.unicodeScalars.prefix(limit))) + "…"
  }

  /// The first `limit` Unicode scalars (text) or bytes of `string`, and whether that cut any
  private static func head(
    of string: RedisReplyString, limit: Int
  ) -> (RedisReplyString, Bool) {
    switch string {
    case .text(let text):
      let scalars = text.unicodeScalars.prefix(limit)
      guard scalars.endIndex != text.unicodeScalars.endIndex else { return (string, false) }
      return (.text(String(String.UnicodeScalarView(scalars))), true)
    case .bytes(let bytes):
      return bytes.count > limit ? (.bytes(bytes.prefix(limit)), true) : (string, false)
    }
  }

  /// The Raw text being written, cut at `limit` UTF-8 bytes on a scalar boundary
  private struct RawWriter {
    let limit: Int
    private(set) var out = ""
    private(set) var isFull = false

    init(limit: Int) { self.limit = limit }

    /// `string` escaped; its input cut first to what the budget can still show
    func shown(_ string: RedisReplyString) -> String {
      RedisDisplayText.line(RedisReply.head(of: string, limit: budget).0)
    }

    /// `text` with its line breaks; its input cut first as in `shown`
    func shownLines(_ text: String) -> String {
      guard case .text(let input) = RedisReply.head(of: .text(text), limit: budget).0 else {
        return ""
      }
      return RedisDisplayText.lines(input)
    }

    mutating func write(_ text: String) {
      guard !isFull else { return }
      let room = limit - out.utf8.count
      guard text.utf8.count > room else {
        out += text
        return
      }
      var head = String.UnicodeScalarView()
      var left = room
      for scalar in text.unicodeScalars {
        let size = UTF8.width(scalar)
        guard size <= left else { break }
        head.append(scalar)
        left -= size
      }
      out += String(head)
      isFull = true
      if out.utf8.last != 0x0A { out += "\n" }
      out += "… (output cut at \(limit / 1_048_576) MB)\n"
    }

    /// Drops the line feed that ends the text
    mutating func dropLineFeed() {
      if out.utf8.last == 0x0A { out.unicodeScalars.removeLast() }
    }

    /// One more than the bytes left: an input past it cannot be shown whole
    private var budget: Int { max(0, limit - out.utf8.count) + 1 }
  }

  /// Writes `reply` and its line feed; an aggregate's items each end with theirs
  private static func appendRaw(_ reply: RedisReply, prefix: String, to w: inout RawWriter) {
    guard !w.isFull, !Task.isCancelled else { return }
    switch reply {
    case .simple(let string): w.write(w.shown(string) + "\n")
    case .bulk(let string): w.write(quoted(w.shown(string)) + "\n")
    case .verbatim(.text(let text)): w.write(w.shownLines(text) + "\n")
    case .verbatim(let string): w.write(w.shown(string) + "\n")
    case .error(let string): w.write("(error) " + w.shown(string) + "\n")
    case .integer(let number): w.write("(integer) \(number)\n")
    case .double(let text): w.write("(double) " + w.shown(.text(text)) + "\n")
    case .boolean(let flag): w.write(flag ? "(true)\n" : "(false)\n")
    case .null: w.write("(nil)\n")
    case .bignum(let text): w.write("(big number) " + w.shown(.text(text)) + "\n")
    case .array(let items):
      appendItems(items, marker: ")", empty: "array", prefix: prefix, to: &w)
    case .push(let items): appendItems(items, marker: ")", empty: "push", prefix: prefix, to: &w)
    case .set(let items): appendItems(items, marker: "~", empty: "set", prefix: prefix, to: &w)
    case .map(let pairs): appendPairs(pairs, prefix: prefix, to: &w)
    }
  }

  private static func appendItems(
    _ items: [RedisReply], marker: String, empty: String, prefix: String, to w: inout RawWriter
  ) {
    guard !items.isEmpty else {
      w.write("(empty \(empty))\n")
      return
    }
    let width = String(items.count).count
    let childPrefix = prefix + String(repeating: " ", count: width + 2)
    for (index, item) in items.enumerated() {
      guard !w.isFull else { return }
      w.write((index == 0 ? "" : prefix) + number(index + 1, width: width) + marker + " ")
      appendRaw(item, prefix: childPrefix, to: &w)
    }
  }

  private static func appendPairs(
    _ pairs: [RedisReplyPair], prefix: String, to w: inout RawWriter
  ) {
    guard !pairs.isEmpty else {
      w.write("(empty hash)\n")
      return
    }
    let width = String(pairs.count).count
    let childPrefix = prefix + String(repeating: " ", count: width + 2)
    for (index, pair) in pairs.enumerated() {
      guard !w.isFull else { return }
      w.write((index == 0 ? "" : prefix) + number(index + 1, width: width) + "# ")
      appendRaw(pair.key, prefix: childPrefix, to: &w)
      // Once full, the text ends with the cut line, which must keep its line feed
      guard !w.isFull else { return }
      w.dropLineFeed()
      w.write(" => ")
      appendRaw(pair.value, prefix: childPrefix, to: &w)
    }
  }

  /// `number` right-aligned in `width` columns
  private static func number(_ number: Int, width: Int) -> String {
    let digits = String(number)
    return String(repeating: " ", count: width - digits.count) + digits
  }

  /// `RedisDisplayText.line` doubles every backslash, so a `"` left in `shown` is a literal quote
  private static func quoted(_ shown: String) -> String {
    "\"" + shown.replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }
}
