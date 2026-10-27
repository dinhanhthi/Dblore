// BinaryDisplayDecoderTests.swift
// Binary Display As: the stored raw values of the formats, size / hex / UUID / swapped-time UUID
// text, MessagePack and schema-less Protobuf decoding against the published spec vectors, and
// untrusted bytes (truncated, hostile lengths, deep nesting, too many nodes) -> nil, never a crash.

import Foundation
import Testing

@testable import Dblore

@Suite struct BinaryDisplayDecoderTests {
  private static func bytes(_ hex: String) -> Data {
    let digits = hex.filter { !$0.isWhitespace }
    var data = Data()
    var index = digits.startIndex
    while index < digits.endIndex {
      let next = digits.index(index, offsetBy: 2)
      data.append(UInt8(digits[index..<next], radix: 16)!)
      index = next
    }
    return data
  }

  private static func depth(_ node: BinaryValueNode) -> Int {
    1 + (node.children.map(depth).max() ?? 0)
  }

  // MARK: Formats

  /// Raw values are stored per column, so they never change
  @Test func rawValuesAreStable() {
    #expect(
      BinaryDisplayFormat.allCases.map(\.rawValue) == [
        "size", "hex", "uuid", "uuidSwappedTime", "messagePack", "protobuf",
      ])
  }

  @Test func sizeHexAndUUIDText() {
    let uuid = Self.bytes("6ccd780cbaba102695645b8c656024db")
    // MySQL reference manual: UUID_TO_BIN('6ccd780c-baba-1026-9564-5b8c656024db', 1)
    let swapped = Self.bytes("1026BABA6CCD780C95645B8C656024DB")
    let canonical = "6CCD780C-BABA-1026-9564-5B8C656024DB"
    #expect(BinaryDisplayFormat.size.text(for: uuid) == "<16 bytes>")
    #expect(BinaryDisplayFormat.hex.text(for: Self.bytes("01ab00")) == "0x01AB00")
    #expect(BinaryDisplayFormat.uuid.text(for: uuid) == canonical)
    #expect(BinaryDisplayFormat.uuidSwappedTime.text(for: swapped) == canonical)
    #expect(BinaryDisplayFormat.uuid.text(for: uuid.dropLast()) == nil)
    #expect(BinaryDisplayFormat.uuidSwappedTime.text(for: uuid + Data([0])) == nil)
  }

  @Test func hexTextIsCappedWithoutEncodingEveryByte() throws {
    let text = try #require(
      BinaryDisplayFormat.hex.text(for: Data(count: 10_000_000), limit: 1_000))
    #expect(text.count == 1_001)
    #expect(text.hasPrefix("0x00"))
    #expect(text.hasSuffix("…"))
  }

  // MARK: MessagePack

  @Test(
    "MessagePack values render compactly",
    arguments: [
      // msgpack.org: {"compact":true,"schema":0}
      ("82 a7 636f6d70616374 c3 a6 736368656d61 00", #"{"compact": true, "schema": 0}"#),
      ("c0", "null"),
      ("c2", "false"),
      ("7f", "127"),
      ("ff", "-1"),
      ("cc ff", "255"),
      ("cd 0100", "256"),
      ("cf ffffffffffffffff", "18446744073709551615"),
      ("d0 80", "-128"),
      ("d3 8000000000000000", "-9223372036854775808"),
      ("ca 3fc00000", "1.5"),
      ("cb 3ff8000000000000", "1.5"),
      ("a3 616263", #""abc""#),
      ("d9 02 2222", #""\"\"""#),
      ("c4 02 0102", "0x0102"),
      ("92 01 a1 61", #"[1, "a"]"#),
      ("dc 0001 90", "[[]]"),
      ("80", "{}"),
      ("81 01 c3", "{1: true}"),
      ("d4 05 07", "ext(5, 0x07)"),
      ("d6 ff 00000000", "1970-01-01T00:00:00.000Z"),
      // 64-bit timestamp: 500,000,000 ns (30 high bits) and 1 s (34 low bits)
      ("d7 ff 77359400 00000001", "1970-01-01T00:00:01.500Z"),
      ("c7 0c ff 00000000 0000000000000000", "1970-01-01T00:00:00.000Z"),
    ])
  func messagePackVectors(hex: String, expected: String) {
    #expect(BinaryDisplayFormat.messagePack.text(for: Self.bytes(hex)) == expected)
  }

  @Test func messagePackTree() throws {
    let tree = try #require(
      MessagePackDecoder.decode(Self.bytes("82 a7 636f6d70616374 c3 a6 736368656d61 92 00 01")))
    #expect(tree.kind == .map)
    #expect(tree.children.map(\.label) == [#""compact""#, #""schema""#])
    #expect(tree.children[0] == BinaryValueNode(kind: .bool, label: #""compact""#, text: "true"))
    #expect(tree.children[1].kind == .array)
    #expect(tree.children[1].children.map(\.text) == ["0", "1"])
  }

  // MARK: Protobuf

  @Test(
    "Protobuf wire format renders field numbers and values",
    arguments: [
      // protobuf.dev encoding guide: field 1 varint 150, field 2 "testing", field 3 message
      ("08 9601", "{1: 150}"),
      ("12 07 74657374696e67", #"{2: "testing"}"#),
      ("1a 03 089601", "{3: {1: 150}}"),
      ("08 9601 12 07 74657374696e67", #"{1: 150, 2: "testing"}"#),
      ("0d 01000000", "{1: 1}"),
      ("09 0100000000000000", "{1: 1}"),
      ("12 02 fffe", "{2: 0xFFFE}"),
      ("12 00", #"{2: ""}"#),
      // printable text stays text even when it would also parse as a message
      ("12 02 2861", #"{2: "(a"}"#),
      ("08 ffffffffffffffffff01", "{1: 18446744073709551615}"),
    ])
  func protobufVectors(hex: String, expected: String) {
    #expect(BinaryDisplayFormat.protobuf.text(for: Self.bytes(hex)) == expected)
  }

  @Test func protobufTreeCarriesWireTypes() throws {
    let tree = try #require(
      ProtobufWireDecoder.decode(Self.bytes("08 9601 1a 03 089601 15 01000000 19 0200000000000000"))
    )
    #expect(tree.kind == .message)
    #expect(tree.children.map(\.label) == ["1", "3", "2", "3"])
    #expect(tree.children.map(\.kind) == [.varint, .message, .fixed32, .fixed64])
    #expect(tree.children[1].children == [BinaryValueNode(kind: .varint, label: "1", text: "150")])
  }

  // MARK: Untrusted input

  @Test(
    "Malformed or hostile MessagePack is nil",
    arguments: [
      "",
      "c1",  // never used
      "01 02",  // trailing bytes
      "a3 6162",  // truncated str
      "a1 ff",  // invalid UTF-8
      "cb 00",  // truncated float
      "db ffffffff 61",  // str32 longer than the input
      "c6 ffffffff",  // bin32 longer than the input
      "dd ffffffff 00",  // array32 longer than the input
      "df ffffffff 00",  // map32 longer than the input
      "c9 ffffffff 01",  // ext32 longer than the input
      "d6 ff 00",  // truncated fixext4
      "d7 ff ffffffff 00000000",  // timestamp nanoseconds >= 1e9
    ])
  func hostileMessagePack(hex: String) {
    #expect(MessagePackDecoder.decode(Self.bytes(hex)) == nil)
    #expect(BinaryDisplayFormat.messagePack.text(for: Self.bytes(hex)) == nil)
  }

  @Test(
    "Malformed or hostile Protobuf is nil",
    arguments: [
      "",
      "00 01",  // field number 0
      "0b",  // start group
      "0c",  // end group
      "0f",  // wire type 7
      "08",  // truncated varint
      "08 ffffffffffffffffff7f",  // varint beyond 64 bits
      "0a ffffffff0f 00",  // length longer than the input
      "0d 0102",  // truncated fixed32
      "f8ffffff1f 01",  // field number beyond 2^29 - 1
    ])
  func hostileProtobuf(hex: String) {
    #expect(ProtobufWireDecoder.decode(Self.bytes(hex)) == nil)
    #expect(BinaryDisplayFormat.protobuf.text(for: Self.bytes(hex)) == nil)
  }

  @Test func messagePackDepthAndNodeCaps() throws {
    let maxDepth = BinaryValueNode.maxDepth
    let atCap = Data(repeating: 0x91, count: maxDepth - 1) + Data([0x00])
    let tree = try #require(MessagePackDecoder.decode(atCap))
    #expect(Self.depth(tree) == maxDepth)
    #expect(MessagePackDecoder.decode(Data(repeating: 0x91, count: maxDepth) + Data([0])) == nil)
    #expect(MessagePackDecoder.decode(Data(repeating: 0x91, count: 100_000)) == nil)

    // an array of n zeros is n + 1 nodes
    let maxNodes = BinaryValueNode.maxNodes
    func array(_ count: Int) -> Data {
      Data([0xdc, UInt8(count >> 8), UInt8(count & 0xff)]) + Data(count: count)
    }
    #expect(MessagePackDecoder.decode(array(maxNodes - 1)) != nil)
    #expect(MessagePackDecoder.decode(array(maxNodes)) == nil)
  }

  @Test func protobufDepthAndNodeCaps() throws {
    // 40 nested messages: past the depth cap the payload stays bytes
    var nested = Self.bytes("08 01")
    for _ in 0..<40 { nested = Data([0x0a, UInt8(nested.count)]) + nested }
    let tree = try #require(ProtobufWireDecoder.decode(nested))
    #expect(Self.depth(tree) == BinaryValueNode.maxDepth)

    // a message of n fields is n + 1 nodes
    let fields = BinaryValueNode.maxNodes
    #expect(ProtobufWireDecoder.decode(Data([0x08, 0x00]).repeated(fields - 1)) != nil)
    #expect(ProtobufWireDecoder.decode(Data([0x08, 0x00]).repeated(fields)) == nil)
  }

  /// Valid values one byte past the cap are not decoded: the caller shows the size
  @Test func valuesPastTheDecodeCapAreRefused() {
    let cap = BinaryDisplayFormat.maxDecodedBytes
    // bin 32 holding the rest of the bytes
    let binLength = cap + 1 - 5
    let messagePack =
      Data([
        0xc6, UInt8(binLength >> 24), UInt8(binLength >> 16 & 0xff), UInt8(binLength >> 8 & 0xff),
        UInt8(binLength & 0xff),
      ]) + Data(count: binLength)
    #expect(messagePack.count == cap + 1)
    #expect(BinaryDisplayFormat.messagePack.tree(for: messagePack) == nil)
    #expect(BinaryDisplayFormat.messagePack.text(for: messagePack) == nil)
    #expect(BinaryDisplayFormat.messagePack.text(for: Self.bytes("92 01 a1 61")) == #"[1, "a"]"#)

    // field 1, length-delimited, holding the rest of the bytes (a 4-byte varint length)
    let fieldLength = cap + 1 - 5
    var varint = Data()
    var rest = fieldLength
    while rest >= 0x80 {
      varint.append(UInt8(rest & 0x7f) | 0x80)
      rest >>= 7
    }
    varint.append(UInt8(rest))
    let protobuf = Data([0x0a]) + varint + Data(repeating: 0x61, count: fieldLength)
    #expect(protobuf.count == cap + 1)
    #expect(BinaryDisplayFormat.protobuf.tree(for: protobuf) == nil)
    #expect(BinaryDisplayFormat.protobuf.text(for: protobuf) == nil)
  }

  @Test func decodedTextAndTreeTextAreCapped() throws {
    let long = Data([0xda, 0x13, 0x88]) + Data(repeating: 0x61, count: 5_000)
    let text = try #require(BinaryDisplayFormat.messagePack.text(for: long, limit: 1_000))
    #expect(text.count == 1_001)
    #expect(text.hasSuffix("…"))
    let node = try #require(MessagePackDecoder.decode(long))
    #expect(node.text?.count == BinaryValueNode.maxScalarLength + 1)

    let many = Data([0xdc, 0x07, 0xd0]) + Data(repeating: 0x7f, count: 2_000)
    let list = try #require(BinaryDisplayFormat.messagePack.text(for: many, limit: 100))
    #expect(list.count == 101)
    #expect(list.hasPrefix("[127, 127"))
  }
}

extension Data {
  fileprivate func repeated(_ count: Int) -> Data {
    var data = Data(capacity: self.count * count)
    for _ in 0..<count { data.append(self) }
    return data
  }
}
