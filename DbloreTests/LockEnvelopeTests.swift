// LockEnvelopeTests.swift
// Envelope v1 (encrypted workspace format): the byte layout is a contract every future build must
// read, so a golden file built independently from the layout pins it. Also guards the crypto
// (any changed header, wrap or ciphertext byte fails; wrong password fails), the version policy
// and that older builds refuse an envelope instead of reading it as an empty document.

import CryptoKit
import Foundation
import Testing

@testable import Dblore

@Suite("Lock Envelope")
struct LockEnvelopeTests {
  /// Kind 3 (script), workspace 6F1C2D3E-4A5B-4C6D-8E7F-90A1B2C3D4E5, content key bytes 0...31,
  /// password "correct horse battery", PBKDF2 100,000 iterations, salt A0...AF, wrap nonce
  /// B0...BB, payload nonce C0...CB, payload "SELECT 1;\n". Built outside the app from the layout.
  static let goldenHex =
    "8944424c4b0d0a1a000103006f1c2d3e4a5b4c6d8e7f90a1b2c3d4e501000186a0a0a1a2a3a4a5a6a7a8a9aaab"
    + "acadaeafb0b1b2b3b4b5b6b7b8b9babb910a34647583f6469ac51e521b6b7e0227456912dff1c9e18e1fccd8"
    + "3f2991317cf56d47766cff1171bad293231d181ac0c1c2c3c4c5c6c7c8c9cacb530d6b22342cb66fa3d38584"
    + "0c133b1f547c4ce07a803600d4d4"
  static let goldenId = UUID(uuidString: "6F1C2D3E-4A5B-4C6D-8E7F-90A1B2C3D4E5")!
  static let goldenKey = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
  static let goldenPassword = "correct horse battery"

  let golden = Data(hex: LockEnvelopeTests.goldenHex)

  @Test("A golden v1 file opens, unwraps with its password, and a new seal writes the same header")
  func goldenV1() throws {
    let header = try #require(try LockEnvelope.sniff(golden))
    #expect(header.kind == .script)
    #expect(header.workspaceId == Self.goldenId)
    #expect(try LockEnvelope.open(golden, contentKey: Self.goldenKey) == Data("SELECT 1;\n".utf8))

    let key = try LockEnvelope.unwrapKey(header.wrapBlock, password: Self.goldenPassword)
    #expect(key.withUnsafeBytes { Data($0) } == Data((0..<32).map { UInt8($0) }))

    // Magic, version, kind, flags, workspace id and the wrap block (copied verbatim) are fixed bytes
    let resealed = try LockEnvelope.seal(
      Data("SELECT 1;\n".utf8), kind: .script, workspaceId: Self.goldenId,
      wrapBlock: header.wrapBlock, contentKey: Self.goldenKey)
    #expect(resealed.count == golden.count)
    #expect(resealed.prefix(109) == golden.prefix(109))
    #expect(
      golden.prefix(33)
        == Data(hex: "8944424c4b0d0a1a000103006f1c2d3e4a5b4c6d8e7f90a1b2c3d4e501000186a0"))
  }

  @Test("Every kind round-trips with a new wrap block, and every file of a workspace shares it")
  func roundTripPerKind() throws {
    let workspaceId = UUID()
    let contentKey = SymmetricKey(size: .bits256)
    let wrapBlock = try LockEnvelope.makeWrapBlock(
      contentKey: contentKey, password: "a lock password", workspaceId: workspaceId)
    // The wrap is offline-attackable: written with at least 600,000 PBKDF2 iterations (bytes 1..<5)
    #expect(wrapBlock.bytes.dropFirst().prefix(4).reduce(0) { $0 << 8 | Int($1) } >= 600_000)

    for kind in LockEnvelope.Kind.allCases {
      for payload in [Data(), Data("{\"cells\":[]}".utf8)] {
        let sealed = try LockEnvelope.seal(
          payload, kind: kind, workspaceId: workspaceId, wrapBlock: wrapBlock,
          contentKey: contentKey)
        #expect(sealed.count == 137 + payload.count)
        let header = try #require(try LockEnvelope.sniff(sealed))
        #expect(header.kind == kind)
        #expect(header.wrapBlock == wrapBlock)
        #expect(try LockEnvelope.open(sealed, contentKey: contentKey) == payload)
      }
    }

    let unwrapped = try LockEnvelope.unwrapKey(wrapBlock, password: "a lock password")
    let sealed = try LockEnvelope.seal(
      Data("x".utf8), kind: .markdown, workspaceId: workspaceId, wrapBlock: wrapBlock,
      contentKey: contentKey)
    #expect(try LockEnvelope.open(sealed, contentKey: unwrapped) == Data("x".utf8))
  }

  @Test("A changed header, wrap block or ciphertext byte fails to open")
  func flippedByteFails() throws {
    // Workspace id, KDF salt, wrap nonce/key/tag, payload nonce, ciphertext and tag pass the
    // structural checks, so only authentication catches them
    for offset in [12, 27, 40, 50, 70, 100, 115, 125, golden.count - 1] {
      var damaged = golden
      damaged[offset] ^= 0xFF
      #expect(throws: LockEnvelopeError.tampered) {
        try LockEnvelope.open(damaged, contentKey: Self.goldenKey)
      }
    }
    // Magic, version, kind, flags, KDF id and iterations are refused before decryption
    for offset in [0, 7, 9, 10, 11, 28, 30] {
      var damaged = golden
      damaged[offset] ^= 0xFF
      #expect(throws: LockEnvelopeError.self) {
        try LockEnvelope.open(damaged, contentKey: Self.goldenKey)
      }
    }
    #expect(throws: LockEnvelopeError.tampered) {
      try LockEnvelope.open(golden, contentKey: SymmetricKey(size: .bits256))
    }
  }

  @Test("The password is NFC-normalized: an NFD-typed password unwraps a block made with NFC")
  func passwordIsNormalizedToNFC() throws {
    let contentKey = SymmetricKey(size: .bits256)
    let block = try LockEnvelope.makeWrapBlock(
      contentKey: contentKey, password: "caf\u{E9} lock", workspaceId: UUID(),
      iterations: 100_000)

    #expect(try LockEnvelope.unwrapKey(block, password: "cafe\u{301} lock") == contentKey)
  }

  @Test("A wrong password does not unwrap the content key")
  func wrongPassword() throws {
    let header = try #require(try LockEnvelope.sniff(golden))
    #expect(throws: LockEnvelopeError.wrongPassword) {
      try LockEnvelope.unwrapKey(header.wrapBlock, password: "correct horse battery ")
    }
  }

  @Test("Version 2 is refused as made by a newer Dblore; plain data is not an envelope")
  func versionPolicy() throws {
    var newer = golden
    newer[9] = 2
    #expect(throws: LockEnvelopeError.newerVersion(2)) { try LockEnvelope.sniff(newer) }
    #expect(throws: LockEnvelopeError.newerVersion(2)) {
      try LockEnvelope.open(newer, contentKey: Self.goldenKey)
    }

    let plain = Data("{\"version\":1}".utf8)
    #expect(try LockEnvelope.sniff(plain) == nil)
    #expect(throws: LockEnvelopeError.notAnEnvelope) {
      try LockEnvelope.open(plain, contentKey: Self.goldenKey)
    }
  }

  @Test("Older builds' readers refuse an envelope instead of opening an empty document")
  @MainActor
  func oldBuildsRefuse() {
    #expect(throws: (any Error).self) { try JSONSerialization.jsonObject(with: golden) }
    #expect(throws: (any Error).self) { try JSONDecoder().decode(Workspace.self, from: golden) }
    #expect(String(data: golden, encoding: .utf8) == nil)
  }
}

nonisolated extension Data {
  fileprivate init(hex: String) {
    var bytes = [UInt8]()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      bytes.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    self.init(bytes)
  }
}
