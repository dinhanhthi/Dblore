// MessagePackDecoder.swift
// One MessagePack value (https://github.com/msgpack/msgpack/blob/master/spec.md) -> a
// BinaryValueNode tree: nil, bool, integers, floats, str (UTF-8), bin, array, map, ext and the
// timestamp extension (type -1). The bytes are untrusted: a declared length is checked against
// the bytes left before it is used, and malformed, truncated or trailing bytes, the unused 0xc1,
// invalid UTF-8, nesting past `BinaryValueNode.maxDepth` or more than `maxNodes` values are nil,
// as is a decode whose task is cancelled.

import Foundation

nonisolated enum MessagePackDecoder {
  static func decode(_ data: Data) -> BinaryValueNode? {
    var parser = Parser(bytes: [UInt8](data))
    guard let node = parser.value(depth: 1), parser.offset == parser.bytes.count else {
      return nil
    }
    return node
  }

  private nonisolated struct Parser {
    let bytes: [UInt8]
    var offset = 0
    var nodes = 0

    private var remaining: Int { bytes.count - offset }

    mutating func value(depth: Int) -> BinaryValueNode? {
      guard depth <= BinaryValueNode.maxDepth, nodes < BinaryValueNode.maxNodes,
        let byte = take(1)?.first
      else { return nil }
      nodes += 1
      // A dropped grid decode stops early
      if nodes % 256 == 0, Task.isCancelled { return nil }
      switch byte {
      case 0x00...0x7f: return BinaryValueNode(kind: .integer, text: String(byte))
      case 0x80...0x8f: return map(count: Int(byte & 0x0f), depth: depth)
      case 0x90...0x9f: return array(count: Int(byte & 0x0f), depth: depth)
      case 0xa0...0xbf: return string(length: Int(byte & 0x1f))
      case 0xc0: return BinaryValueNode(kind: .null, text: "null")
      case 0xc2: return BinaryValueNode(kind: .bool, text: "false")
      case 0xc3: return BinaryValueNode(kind: .bool, text: "true")
      case 0xc4...0xc6:
        guard let length = uint(size: 1 << (byte - 0xc4)), let data = take(length) else {
          return nil
        }
        return BinaryValueNode(kind: .binary, text: BinaryValueNode.hex(data))
      case 0xc7...0xc9:
        guard let length = uint(size: 1 << (byte - 0xc7)) else { return nil }
        return ext(length: length)
      case 0xca:
        guard let bits = uint64(size: 4) else { return nil }
        return BinaryValueNode(kind: .float, text: String(Float(bitPattern: UInt32(bits))))
      case 0xcb:
        guard let bits = uint64(size: 8) else { return nil }
        return BinaryValueNode(kind: .float, text: String(Double(bitPattern: bits)))
      case 0xcc...0xcf:
        guard let value = uint64(size: 1 << (byte - 0xcc)) else { return nil }
        return BinaryValueNode(kind: .integer, text: String(value))
      case 0xd0...0xd3:
        let size = 1 << (byte - 0xd0)
        guard let value = uint64(size: size) else { return nil }
        let shift = UInt64(64 - 8 * size)
        return BinaryValueNode(
          kind: .integer, text: String(Int64(bitPattern: value << shift) >> shift))
      case 0xd4...0xd8: return ext(length: 1 << (byte - 0xd4))
      case 0xd9...0xdb:
        guard let length = uint(size: 1 << (byte - 0xd9)) else { return nil }
        return string(length: length)
      case 0xdc, 0xdd:
        guard let count = uint(size: byte == 0xdc ? 2 : 4) else { return nil }
        return array(count: count, depth: depth)
      case 0xde, 0xdf:
        guard let count = uint(size: byte == 0xde ? 2 : 4) else { return nil }
        return map(count: count, depth: depth)
      case 0xe0...0xff: return BinaryValueNode(kind: .integer, text: String(Int8(bitPattern: byte)))
      default: return nil  // 0xc1 is never used
      }
    }

    private mutating func array(count: Int, depth: Int) -> BinaryValueNode? {
      // every element takes at least one byte
      guard count <= remaining else { return nil }
      var children: [BinaryValueNode] = []
      for _ in 0..<count {
        guard let child = value(depth: depth + 1) else { return nil }
        children.append(child)
      }
      return BinaryValueNode(kind: .array, children: children)
    }

    private mutating func map(count: Int, depth: Int) -> BinaryValueNode? {
      // every key and value takes at least one byte
      guard count <= remaining / 2 else { return nil }
      var children: [BinaryValueNode] = []
      for _ in 0..<count {
        guard let key = value(depth: depth + 1), var child = value(depth: depth + 1) else {
          return nil
        }
        child.label = key.compactText(limit: BinaryValueNode.maxScalarLength)
        children.append(child)
      }
      return BinaryValueNode(kind: .map, children: children)
    }

    private mutating func string(length: Int) -> BinaryValueNode? {
      guard let data = take(length), let text = String(bytes: data, encoding: .utf8) else {
        return nil
      }
      return BinaryValueNode(kind: .string, text: BinaryValueNode.capped(text))
    }

    private mutating func ext(length: Int) -> BinaryValueNode? {
      guard let typeByte = take(1)?.first, let data = take(length) else { return nil }
      let type = Int8(bitPattern: typeByte)
      if type == -1, case (let seconds, let nanoseconds)? = Self.timestamp(data) {
        guard nanoseconds < 1_000_000_000 else { return nil }
        // years 1...9999; past them the generic ext text
        if (-62_135_596_800...253_402_300_799).contains(seconds) {
          let date = Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1e9)
          let text = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
          return BinaryValueNode(kind: .timestamp, text: text)
        }
      }
      let payload = BinaryValueNode.hex(data, limit: BinaryValueNode.maxScalarLength - 12)
      return BinaryValueNode(kind: .ext, text: "ext(\(type), \(payload))")
    }

    /// Seconds and nanoseconds of the three timestamp layouts (32, 64 and 96 bits), else nil
    private static func timestamp(_ data: ArraySlice<UInt8>) -> (Int64, UInt64)? {
      switch data.count {
      case 4:
        return (Int64(bigEndian(data)), 0)
      case 8:
        let value = bigEndian(data)
        return (Int64(value & 0x3_ffff_ffff), value >> 34)
      case 12:
        return (Int64(bitPattern: bigEndian(data.suffix(8))), bigEndian(data.prefix(4)))
      default:
        return nil
      }
    }

    private static func bigEndian(_ data: ArraySlice<UInt8>) -> UInt64 {
      data.reduce(0) { $0 << 8 | UInt64($1) }
    }

    private mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
      guard count >= 0, count <= remaining else { return nil }
      defer { offset += count }
      return bytes[offset..<offset + count]
    }

    private mutating func uint64(size: Int) -> UInt64? {
      take(size).map(Self.bigEndian)
    }

    /// A length or count of `size` bytes (at most 4, so it fits an Int)
    private mutating func uint(size: Int) -> Int? {
      uint64(size: size).map { Int($0) }
    }
  }
}
