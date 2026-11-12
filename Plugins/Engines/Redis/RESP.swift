// RESP.swift
// The Redis wire format: the encoder of a command (an array of bulk strings, binary safe) and the
// incremental RESP2 / RESP3 reply decoder.
//
// A reply is read one node at a time, depth first, so a reply of a million elements streams out
// row by row on the run loop's credit. Each node becomes one row `[path, type, value]`:
// - path: "0" for the reply itself, "0.i" for its children, "0.i.j" below them.
// - type: `simple`, `bulk`, `verbatim`, `error`, `integer`, `double`, `boolean`, `null`,
//   `bignum`, `array`, `set`, `map` or `push`.
// - value: text for a simple string, an error, a double, a big number or a boolean
//   ("true" / "false"); a bulk or verbatim string as text when its bytes are valid UTF-8, else as
//   bytes (a verbatim string without its "txt:" format prefix); an int for an integer; null for
//   a null; for an aggregate, the number of child rows that follow it (a map of n pairs has 2n
//   children, alternating key and value).
// RESP3 attributes (`|`) are dropped wherever they appear; a push (`>`) before the reply is an
// out-of-band message and is dropped too.
//
// The decoder consumes whole tokens only (a header line, or a payload with its CRLF) and records
// what the reply still owes (payload bytes, whole nodes) before it reads on, so a read stopped by
// an interrupt leaves it in step: `skipNext` then drains the rest without building rows.

import Foundation

enum RESP {
  /// The rows' columns
  static let columns: [EngineEvent.Column] = [
    EngineEvent.Column(name: "path", type: "text"),
    EngineEvent.Column(name: "type", type: "text"),
    EngineEvent.Column(name: "value", type: "value"),
  ]

  /// A command as a RESP array of bulk strings
  static func command(_ args: [Data]) -> Data {
    var out = Data("*\(args.count)\r\n".utf8)
    for arg in args {
      out.append(contentsOf: "$\(arg.count)\r\n".utf8)
      out.append(arg)
      out.append(contentsOf: crlf)
    }
    return out
  }

  /// A command of text arguments
  static func command(_ args: String...) -> Data {
    command(args.map { Data($0.utf8) })
  }

  static let crlf: [UInt8] = [0x0D, 0x0A]
}

/// Where a reply is read from. Each call consumes whole tokens only, or throws without consuming.
protocol RESPSource: AnyObject {
  /// The next line without its CRLF
  func line() throws -> Data
  /// Exactly `count` bytes
  func bytes(_ count: Int) throws -> Data
  /// Drops up to `count` bytes, at least one, and lowers `count` by as many
  func skip(_ count: inout Int) throws
}

/// The reply's bytes do not follow RESP: the stream is out of step
struct RESPProtocolError: Error {}

/// One node of a reply
struct RESPNode {
  let path: String
  let type: String
  let value: EngineCell

  var row: [EngineCell] { [.text(path), .text(type), value] }

  /// The text of a simple string, bulk string or error
  var text: String? {
    if case .text(let text) = value { return text }
    return nil
  }
}

/// The decoder of one reply
final class RESPReply {
  /// Aggregate nesting a reply may reach (the top node is level 1); deeper means a broken or
  /// hostile server, since every level lengthens the path each node below it keeps
  static let maxDepth = 128

  /// An aggregate whose children are still being read
  private struct Frame {
    let path: String
    /// Its nesting level, whether or not its parents are still open
    let depth: Int
    var remaining: Int
    var next = 0
  }

  private enum Header {
    /// `+ - : , # ( _`, and the RESP2 nulls `$-1` / `*-1`
    case line(type: String, text: Data)
    /// `$ = !`: a length, then the payload and CRLF
    case blob(type: String, length: Int)
    /// `* ~ % >`: the number of child nodes (2n for a map)
    case aggregate(type: String, children: Int)
    /// `|`: 2n nodes to drop, then the node they describe
    case attribute(children: Int)
  }

  private var stack: [Frame] = []
  private var started = false
  /// Payload bytes (CRLF included) the reply still owes before the next header
  private var pendingBytes = 0
  /// Whole nodes to drop before the next header that counts (attributes, out-of-band pushes)
  private var pendingNodes = 0

  /// Whether the whole reply has been read
  var isComplete: Bool {
    started && stack.isEmpty && pendingBytes == 0 && pendingNodes == 0
  }

  /// The next node, nil at the end of the reply
  func next(from source: any RESPSource) throws -> RESPNode? {
    try advance(source, keep: true)
  }

  /// Reads past the next node without building it; false at the end of the reply
  func skipNext(from source: any RESPSource) throws -> Bool {
    try advance(source, keep: false) != nil
  }

  private static let skipped = RESPNode(path: "", type: "", value: .null)

  private func advance(_ source: any RESPSource, keep: Bool) throws -> RESPNode? {
    while true {
      try skipPending(source)
      if started && stack.isEmpty { return nil }
      let header = try Self.header(try source.line())
      switch header {
      case .attribute(let children):
        pendingNodes += children
        continue
      case .aggregate("push", let children) where !started:
        pendingNodes += children
        continue
      default: break
      }
      // The node is taken: its place in the parent is used up
      var path = "0"
      let depth = (stack.last?.depth ?? 0) + 1
      if let top = stack.indices.last {
        if keep { path = "\(stack[top].path).\(stack[top].next)" }
        stack[top].next += 1
        stack[top].remaining -= 1
      } else {
        started = true
      }
      while let last = stack.last, last.remaining == 0 { stack.removeLast() }

      switch header {
      case .line(let type, let text):
        guard keep else { return Self.skipped }
        return RESPNode(path: path, type: type, value: try Self.lineValue(type, text))
      case .blob(let type, let length):
        pendingBytes = length + 2
        guard keep else {
          try skipPending(source)
          return Self.skipped
        }
        guard length <= EnginePluginProtocol.maxValueBytes else {
          throw EngineFailure(code: .tooLarge, message: "A value of the reply is over 256 MiB.")
        }
        var data = try source.bytes(length + 2)
        pendingBytes = 0
        guard data.count == length + 2, data.suffix(2).elementsEqual(RESP.crlf) else {
          throw RESPProtocolError()
        }
        data.removeLast(2)
        if type == "verbatim", data.count >= 4, data[data.startIndex + 3] == UInt8(ascii: ":") {
          data.removeFirst(4)
        }
        return RESPNode(path: path, type: type, value: Self.cell(data))
      case .aggregate(let type, let children):
        if children > 0 {
          guard depth <= Self.maxDepth else { throw RESPProtocolError() }
          stack.append(Frame(path: keep ? path : "", depth: depth, remaining: children))
        }
        guard keep else { return Self.skipped }
        return RESPNode(path: path, type: type, value: .int(children))
      case .attribute:
        throw RESPProtocolError()
      }
    }
  }

  /// Drops the payload bytes and whole nodes the reply owes before its next node
  private func skipPending(_ source: any RESPSource) throws {
    while true {
      while pendingBytes > 0 { try source.skip(&pendingBytes) }
      guard pendingNodes > 0 else { return }
      switch try Self.header(try source.line()) {
      case .attribute(let children):
        // The node it describes still follows
        pendingNodes += children
      case .line:
        pendingNodes -= 1
      case .blob(_, let length):
        pendingNodes -= 1
        pendingBytes = length + 2
      case .aggregate(_, let children):
        pendingNodes += children - 1
      }
    }
  }

  /// The largest aggregate a header may announce
  private static let maxChildren = Int(Int32.max)

  private static func header(_ line: Data) throws -> Header {
    guard let marker = line.first else { throw RESPProtocolError() }
    let text = line.dropFirst()
    func count() throws -> Int {
      guard let value = Int(String(decoding: text, as: UTF8.self)), value >= -1,
        value <= maxChildren
      else { throw RESPProtocolError() }
      return value
    }
    switch marker {
    case UInt8(ascii: "+"): return .line(type: "simple", text: Data(text))
    case UInt8(ascii: "-"): return .line(type: "error", text: Data(text))
    case UInt8(ascii: ":"): return .line(type: "integer", text: Data(text))
    case UInt8(ascii: ","): return .line(type: "double", text: Data(text))
    case UInt8(ascii: "#"): return .line(type: "boolean", text: Data(text))
    case UInt8(ascii: "("): return .line(type: "bignum", text: Data(text))
    case UInt8(ascii: "_"): return .line(type: "null", text: Data())
    case UInt8(ascii: "$"), UInt8(ascii: "="), UInt8(ascii: "!"):
      let length = try count()
      if length < 0 { return .line(type: "null", text: Data()) }
      let type =
        marker == UInt8(ascii: "$") ? "bulk" : marker == UInt8(ascii: "=") ? "verbatim" : "error"
      return .blob(type: type, length: length)
    case UInt8(ascii: "*"), UInt8(ascii: "~"), UInt8(ascii: "%"), UInt8(ascii: ">"):
      let children = try count()
      if children < 0 { return .line(type: "null", text: Data()) }
      switch marker {
      case UInt8(ascii: "*"): return .aggregate(type: "array", children: children)
      case UInt8(ascii: "~"): return .aggregate(type: "set", children: children)
      case UInt8(ascii: "%"): return .aggregate(type: "map", children: children * 2)
      default: return .aggregate(type: "push", children: children)
      }
    case UInt8(ascii: "|"):
      let children = try count()
      guard children >= 0 else { throw RESPProtocolError() }
      return .attribute(children: children * 2)
    default:
      throw RESPProtocolError()
    }
  }

  private static func lineValue(_ type: String, _ text: Data) throws -> EngineCell {
    switch type {
    case "null": return .null
    case "integer":
      let string = String(decoding: text, as: UTF8.self)
      return Int(string).map(EngineCell.int) ?? .text(string)
    case "boolean":
      switch text.first {
      case UInt8(ascii: "t"): return .text("true")
      case UInt8(ascii: "f"): return .text("false")
      default: throw RESPProtocolError()
      }
    default: return cell(text)
    }
  }

  /// Text when the bytes are valid UTF-8 (checked byte for byte), else bytes
  static func cell(_ data: Data) -> EngineCell {
    let text = String(decoding: data, as: UTF8.self)
    return text.utf8.elementsEqual(data) ? .text(text) : .bytes(data)
  }
}
