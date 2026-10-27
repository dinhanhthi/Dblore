// BinaryDisplayFormat.swift
// How a binary cell is shown: its size (the default), hex, a UUID (16 bytes, as stored or in the
// swapped-time order of MySQL's UUID_TO_BIN(u, 1)), or decoded MessagePack / schema-less Protobuf.
// The bytes are untrusted: a format that does not fit them gives nil and the caller shows the
// raw value. Pure and nonisolated, so decoding can run off the main actor.

import Foundation

nonisolated enum BinaryDisplayFormat: String, Codable, CaseIterable, Sendable {
  // Raw values are stored per column: never change them
  case size
  case hex
  case uuid
  case uuidSwappedTime
  case messagePack
  case protobuf

  /// Longest display text before "…", the same as the grid's cell text cap
  static let maxTextLength = 1_000
  /// Largest value MessagePack and Protobuf decode; a bigger one shows its size
  static let maxDecodedBytes = 16 * 1024 * 1024

  var title: String {
    switch self {
    case .size: "Size"
    case .hex: "Hex"
    case .uuid: "UUID"
    case .uuidSwappedTime: "UUID (Swapped Time)"
    case .messagePack: "MessagePack"
    case .protobuf: "Protobuf"
    }
  }

  /// One-line text of `data`, at most `limit` characters plus "…" when cut; nil when the bytes do
  /// not fit the format. Size, hex and UUID cost at most the bytes shown; MessagePack and
  /// Protobuf decode the whole value.
  func text(for data: Data, limit: Int = Self.maxTextLength) -> String? {
    switch self {
    case .size: "<\(data.count) bytes>"
    case .hex: BinaryValueNode.hex(data, limit: limit)
    case .uuid: Self.uuidText(data, order: Array(0..<16))
    // Stored as time_hi + version, time_mid, time_low, then the rest
    case .uuidSwappedTime: Self.uuidText(data, order: [4, 5, 6, 7, 2, 3, 0, 1] + Array(8..<16))
    case .messagePack, .protobuf: tree(for: data)?.compactText(limit: limit)
    }
  }

  /// The decoded value, for MessagePack and Protobuf only; nil for malformed bytes or a value
  /// past `maxDecodedBytes`
  func tree(for data: Data) -> BinaryValueNode? {
    guard data.count <= Self.maxDecodedBytes else { return nil }
    return switch self {
    case .messagePack: MessagePackDecoder.decode(data)
    case .protobuf: ProtobufWireDecoder.decode(data)
    case .size, .hex, .uuid, .uuidSwappedTime: nil
    }
  }

  /// Canonical UUID (uppercase, as uuid columns show) of exactly 16 bytes, read in `order`
  private static func uuidText(_ data: Data, order: [Int]) -> String? {
    guard data.count == 16 else { return nil }
    let stored = [UInt8](data)
    let b = order.map { stored[$0] }
    let uuid = UUID(
      uuid: (
        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13],
        b[14], b[15]
      ))
    return uuid.uuidString
  }
}

/// One decoded value: a scalar with its text, or a container with children. Map entries and
/// Protobuf fields carry their key or field number as `label`.
nonisolated struct BinaryValueNode: Equatable, Sendable {
  enum Kind: String, Sendable {
    // MessagePack
    case null, bool, integer, float, string, binary, array, map, ext, timestamp
    // Protobuf: a message and the wire types of its fields; a length-delimited field is a
    // `message`, a `string` or `binary`
    case message, varint, fixed64, fixed32
  }

  /// Deepest node level, the root being level 1
  static let maxDepth = 32
  /// Most nodes in one decoded value, map keys included
  static let maxNodes = 10_000
  /// Longest scalar text (and map key label) before "…"
  static let maxScalarLength = 1_000

  var kind: Kind
  /// Map key as compact text, or Protobuf field number; nil for the root and array elements
  var label: String? = nil
  /// Scalar text, capped at `maxScalarLength`; nil for containers
  var text: String? = nil
  var children: [BinaryValueNode] = []

  /// One-line text: `{"key": 1, "list": [true, null]}`, Protobuf as `{1: 150, 2: "text"}`;
  /// at most `limit` characters plus "…" when cut
  func compactText(limit: Int = BinaryDisplayFormat.maxTextLength) -> String {
    var out = CappedText(limit: limit)
    write(to: &out)
    return out.text
  }

  private func write(to out: inout CappedText) {
    switch kind {
    case .array:
      out.append("[")
      writeChildren(to: &out)
      out.append("]")
    case .map, .message:
      out.append("{")
      writeChildren(to: &out)
      out.append("}")
    case .string:
      let escaped = (text ?? "").replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
      out.append("\"" + escaped + "\"")
    default:
      out.append(text ?? "")
    }
  }

  private func writeChildren(to out: inout CappedText) {
    for (index, child) in children.enumerated() {
      guard !out.isFull else { return }
      if index > 0 { out.append(", ") }
      if let label = child.label { out.append(label + ": ") }
      child.write(to: &out)
    }
  }

  /// `text` cut to `maxScalarLength` characters plus "…"
  static func capped(_ text: String) -> String {
    var out = CappedText(limit: maxScalarLength)
    out.append(text)
    return out.text
  }

  /// "0x" and uppercase hex of the bytes that fit in `limit` characters, plus "…" when cut
  static func hex(_ bytes: some Collection<UInt8>, limit: Int = maxScalarLength) -> String {
    let digits = Array("0123456789ABCDEF".utf8)
    let shown = bytes.prefix(max(0, (limit - 2) / 2))
    var ascii: [UInt8] = Array("0x".utf8)
    ascii.reserveCapacity(2 + shown.count * 2)
    for byte in shown {
      ascii.append(digits[Int(byte >> 4)])
      ascii.append(digits[Int(byte & 0x0f)])
    }
    let text = String(decoding: ascii, as: UTF8.self)
    return shown.count < bytes.count ? text + "…" : text
  }
}

/// Text that stops growing at `limit` characters and then ends with "…"
nonisolated struct CappedText {
  let limit: Int
  private(set) var text = ""
  private(set) var isFull = false
  private var count = 0

  init(limit: Int) {
    self.limit = limit
  }

  mutating func append(_ string: String) {
    guard !isFull else { return }
    var end = string.startIndex
    while end < string.endIndex, count < limit {
      string.formIndex(after: &end)
      count += 1
    }
    text += string[..<end]
    if end < string.endIndex {
      text += "…"
      isFull = true
    }
  }
}
