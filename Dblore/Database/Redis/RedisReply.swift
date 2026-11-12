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
