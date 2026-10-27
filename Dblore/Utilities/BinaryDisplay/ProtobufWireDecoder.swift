// ProtobufWireDecoder.swift
// A Protocol Buffers message without its schema (https://protobuf.dev/programming-guides/encoding/)
// -> a BinaryValueNode tree of field numbers and wire types: varint, fixed64 and fixed32 as
// unsigned integers; a length-delimited field as printable text, else a nested message when its
// payload parses as one (and the depth allows), else UTF-8 text, else bytes. The bytes are
// untrusted: field number 0 or past 2^29 - 1, groups, unknown wire types, overlong varints,
// lengths past the bytes left, more than `BinaryValueNode.maxNodes` nodes, an empty input or a
// cancelled task are nil.

import Foundation

nonisolated enum ProtobufWireDecoder {
  static func decode(_ data: Data) -> BinaryValueNode? {
    var parser = Parser(bytes: [UInt8](data))
    guard !data.isEmpty,
      let fields = try? parser.fields(in: 0..<parser.bytes.count, depth: 2)
    else { return nil }
    return BinaryValueNode(kind: .message, children: fields)
  }

  private nonisolated enum Failure: Error {
    /// Not a message: a length-delimited payload falls back to text or bytes
    case malformed
    /// The node cap: the whole value is refused
    case tooManyNodes
    /// The decode was cancelled: the whole value is dropped
    case cancelled
  }

  private nonisolated struct Parser {
    let bytes: [UInt8]
    /// The root message is the first node
    var nodes = 1

    /// The fields of the message in `range`, as nodes at `depth`
    mutating func fields(in range: Range<Int>, depth: Int) throws(Failure) -> [BinaryValueNode] {
      var offset = range.lowerBound
      let end = range.upperBound
      var fields: [BinaryValueNode] = []
      while offset < end {
        let tag = try varint(&offset, end: end)
        let number = tag >> 3
        guard (1...0x1fff_ffff).contains(number) else { throw .malformed }
        guard nodes < BinaryValueNode.maxNodes else { throw .tooManyNodes }
        nodes += 1
        if nodes % 256 == 0, Task.isCancelled { throw .cancelled }
        var node: BinaryValueNode
        switch tag & 7 {
        case 0:
          node = BinaryValueNode(kind: .varint, text: String(try varint(&offset, end: end)))
        case 1:
          node = BinaryValueNode(kind: .fixed64, text: String(try fixed(8, &offset, end: end)))
        case 5:
          node = BinaryValueNode(kind: .fixed32, text: String(try fixed(4, &offset, end: end)))
        case 2:
          let length = try varint(&offset, end: end)
          guard length <= UInt64(end - offset) else { throw .malformed }
          let payload = offset..<offset + Int(length)
          offset = payload.upperBound
          node = try lengthDelimited(payload, depth: depth)
        default:
          throw .malformed  // groups (3, 4) and unknown wire types
        }
        node.label = String(number)
        fields.append(node)
      }
      return fields
    }

    private mutating func lengthDelimited(
      _ payload: Range<Int>, depth: Int
    ) throws(Failure)
      -> BinaryValueNode
    {
      // The text is not kept while a nested message is tried: nested UTF-8 payloads would each
      // hold a copy of their bytes
      var isUTF8 = false
      if let text = String(bytes: bytes[payload], encoding: .utf8) {
        if text.unicodeScalars.allSatisfy(Self.isPrintable) {
          return BinaryValueNode(kind: .string, text: BinaryValueNode.capped(text))
        }
        isUTF8 = true
      }
      if depth < BinaryValueNode.maxDepth {
        let saved = nodes
        do {
          let children = try fields(in: payload, depth: depth + 1)
          return BinaryValueNode(kind: .message, children: children)
        } catch .malformed {
          nodes = saved
        }
      }
      if isUTF8, let text = String(bytes: bytes[payload], encoding: .utf8) {
        return BinaryValueNode(kind: .string, text: BinaryValueNode.capped(text))
      }
      return BinaryValueNode(kind: .binary, text: BinaryValueNode.hex(bytes[payload]))
    }

    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
      switch scalar.value {
      case 0x09, 0x0a, 0x0d: true
      case 0x00..<0x20, 0x7f..<0xa0: false
      default: true
      }
    }

    /// At most 10 bytes, the 10th holding only the 64th bit
    private func varint(_ offset: inout Int, end: Int) throws(Failure) -> UInt64 {
      var value: UInt64 = 0
      for index in 0..<10 {
        guard offset < end else { throw .malformed }
        let byte = bytes[offset]
        offset += 1
        guard index < 9 || byte <= 1 else { throw .malformed }
        value |= UInt64(byte & 0x7f) << (7 * index)
        if byte & 0x80 == 0 { return value }
      }
      throw .malformed
    }

    /// A little-endian fixed64 or fixed32
    private func fixed(_ size: Int, _ offset: inout Int, end: Int) throws(Failure) -> UInt64 {
      guard size <= end - offset else { throw .malformed }
      defer { offset += size }
      return bytes[offset..<offset + size].reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
  }
}
