// MCPCLIPairingTests.swift
// Pairing codes: single use, 5 minutes, burned by the 5th wrong attempt, one at a time, ended
// with the server; a correct code mints a token the registry accepts until it is revoked, and a
// reload running alongside a revoke or a pairing never undoes it.

import CryptoKit
import Foundation
import Testing
import os

@testable import Dblore

@Suite("MCP CLI pairing")
struct MCPCLIPairingTests {
  /// A clock the test moves by hand
  private final class Clock: Sendable {
    private let instant = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(_ duration: Duration) { instant.withLock { $0 += duration } }
  }

  /// Hands out the queued 5-byte code draws in order, real bytes for everything else
  private final class Draws: Sendable {
    private let queue: OSAllocatedUnfairLock<[[UInt8]]>
    init(_ codes: [[UInt8]]) { queue = OSAllocatedUnfairLock(initialState: codes) }
    func bytes(_ count: Int) -> [UInt8] {
      guard count == 5,
        let next = queue.withLock({ $0.isEmpty ? nil : $0.removeFirst() })
      else { return MCPTokenStoreFactory.randomBytes(count: count) }
      return next
    }
  }

  /// "00000000"
  private static let zeros: [UInt8] = [0, 0, 0, 0, 0]
  /// "11111111" (eight 5-bit groups of 00001)
  private static let ones: [UInt8] = [0x08, 0x42, 0x10, 0x84, 0x21]

  private let clock = Clock()
  private let store = InMemoryMCPCLITokenStore()

  private func service(_ codes: [[UInt8]] = [zeros]) -> MCPCLIPairingService {
    let draws = Draws(codes)
    let clock = clock
    return MCPCLIPairingService(
      store: store, now: { clock.now }, randomBytes: { draws.bytes($0) })
  }

  @Test("A code is 8 Crockford base32 symbols from the system random source")
  func codeShape() {
    let code = MCPCLIPairingService().start(port: 41730)
    #expect(code.code.count == 8)
    #expect(code.code.allSatisfy(MCPCLIPairingService.alphabet.contains))
    #expect(code.port == 41730)
  }

  @Test("A correct code mints a token and proof key once; the registry accepts the token")
  func codeWorksOnce() throws {
    let pairing = service()
    #expect(pairing.start(port: 41730).code == "00000000")
    let result = try #require(pairing.redeem(code: "00000000", port: 41730, name: "laptop"))
    #expect(result.port == 41730)
    #expect(result.token.count == 43 && result.proofKey.count == 43)
    #expect(result.token != result.proofKey)
    #expect(pairing.registry.pairedID(for: result.token) == result.id)
    let key = try #require(MCPTokenStoreFactory.data(base64URL: result.proofKey))
    #expect(pairing.registry.proofKey(id: result.id) == SymmetricKey(data: key))
    #expect(store.list().map(\.id) == [result.id])
    #expect(store.list().first?.name == "laptop")

    #expect(pairing.redeem(code: "00000000", port: 41730) == nil)
    #expect(pairing.activeCode == nil)
    #expect(store.list().count == 1)
  }

  @Test("Input follows Crockford decoding: any case, I and L as 1, O as 0, hyphens and spaces")
  func normalizedInput() {
    #expect(MCPCLIPairingService.normalize("iIlL-1 1 1 1") == "11111111")
    let pairing = service([Self.ones])
    _ = pairing.start(port: 41730)
    #expect(pairing.redeem(code: " iL1l-Ii11 ", port: 41730) != nil)
    let zeros = service([Self.zeros])
    _ = zeros.start(port: 41730)
    #expect(zeros.redeem(code: "oO00-0ooO", port: 41730) != nil)
  }

  @Test("An expired code mints nothing")
  func expiredCode() {
    let pairing = service()
    _ = pairing.start(port: 41730)
    clock.advance(MCPCLIPairingService.lifetime)
    #expect(pairing.activeCode == nil)
    #expect(pairing.redeem(code: "00000000", port: 41730) == nil)
    #expect(store.list().isEmpty)
  }

  @Test("A code is still valid just before it expires")
  func codeBeforeExpiry() {
    let pairing = service()
    _ = pairing.start(port: 41730)
    clock.advance(MCPCLIPairingService.lifetime - .seconds(1))
    #expect(pairing.redeem(code: "00000000", port: 41730) != nil)
  }

  @Test("A wrong code mints nothing")
  func wrongCode() {
    let pairing = service()
    _ = pairing.start(port: 41730)
    #expect(pairing.redeem(code: "0000000Z", port: 41730) == nil)
    #expect(pairing.redeem(code: "", port: 41730) == nil)
    #expect(store.list().isEmpty)
    #expect(pairing.registry.pairedID(for: "") == nil)
  }

  @Test("The fifth wrong attempt burns the code; four do not")
  func burnedAfterFiveWrongAttempts() {
    let fourWrong = service()
    _ = fourWrong.start(port: 41730)
    for _ in 1..<MCPCLIPairingService.maxAttempts {
      #expect(fourWrong.redeem(code: "ZZZZZZZZ", port: 41730) == nil)
    }
    #expect(fourWrong.redeem(code: "00000000", port: 41730) != nil)

    let burned = service()
    _ = burned.start(port: 41730)
    for _ in 1...MCPCLIPairingService.maxAttempts {
      #expect(burned.redeem(code: "ZZZZZZZZ", port: 41730) == nil)
    }
    #expect(burned.activeCode == nil)
    #expect(burned.redeem(code: "00000000", port: 41730) == nil)
    #expect(store.list().count == 1)
  }

  @Test("A code works only on the port it was issued for")
  func otherPortRefused() {
    let pairing = service()
    _ = pairing.start(port: 41730)
    #expect(pairing.redeem(code: "00000000", port: 41731) == nil)
    #expect(store.list().isEmpty)
  }

  @Test("A new code replaces the old one")
  func newCodeReplacesOld() {
    let pairing = service([Self.zeros, Self.ones])
    _ = pairing.start(port: 41730)
    #expect(pairing.start(port: 41730).code == "11111111")
    #expect(pairing.redeem(code: "00000000", port: 41730) == nil)
    #expect(pairing.redeem(code: "11111111", port: 41730) != nil)
  }

  @Test("Stopping the server ends the code")
  func invalidateEndsCode() {
    let pairing = service()
    _ = pairing.start(port: 41730)
    pairing.invalidate()
    #expect(pairing.activeCode == nil)
    #expect(pairing.redeem(code: "00000000", port: 41730) == nil)
    #expect(store.list().isEmpty)
  }

  @Test("Revoke refuses the token at once; reload follows the store")
  func revokeUpdatesRegistry() throws {
    let pairing = service([Self.zeros, Self.ones])
    _ = pairing.start(port: 41730)
    let first = try #require(pairing.redeem(code: "00000000", port: 41730))
    _ = pairing.start(port: 41730)
    let second = try #require(pairing.redeem(code: "11111111", port: 41730))
    #expect(pairing.registry.pairedID(for: second.token) == second.id)
    #expect(pairing.registry.pairedID(for: "Bearer " + second.token) == nil)

    pairing.revoke(id: first.id)
    #expect(pairing.registry.pairedID(for: first.token) == nil)
    #expect(pairing.registry.proofKey(id: first.id) == nil)
    #expect(pairing.registry.pairedID(for: second.token) == second.id)
    #expect(pairing.list().map(\.id) == [second.id])

    store.revoke(id: second.id)
    pairing.reloadRegistry()
    #expect(pairing.registry.pairedID(for: second.token) == nil)

    let third = store.save(
      MCPCLICredential(
        id: "cli", token: MCPTokenStoreFactory.generate(),
        proofKey: MCPTokenStoreFactory.generate(), name: "x", date: Date()))
    pairing.reloadRegistry()
    #expect(pairing.registry.pairedID(for: third.token) == "cli")
    pairing.revokeAll()
    #expect(pairing.registry.pairedID(for: third.token) == nil)
    #expect(store.list().isEmpty)
  }

  /// Holds `list()` after it read the store, while `gated`, until the test releases it
  private final class GatedStore: MCPCLITokenStore, @unchecked Sendable {
    let inner = InMemoryMCPCLITokenStore()
    let gated = OSAllocatedUnfairLock(initialState: false)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func list() -> [MCPCLICredential] {
      let snapshot = inner.list()
      if gated.withLock({ $0 }) {
        entered.signal()
        release.wait()
      }
      return snapshot
    }
    func save(_ credential: MCPCLICredential) -> MCPCLICredential { inner.save(credential) }
    func revoke(id: String) -> Bool { inner.revoke(id: id) }
    func revokeAll() -> Bool { inner.revokeAll() }
  }

  @Test("A reload that read the store first never brings back a revoke or drops a pairing")
  func reloadNeverUndoesRevokeOrPair() throws {
    let store = GatedStore()
    let draws = Draws([Self.zeros, Self.ones])
    let pairing = MCPCLIPairingService(store: store, randomBytes: { draws.bytes($0) })
    _ = pairing.start(port: 41730)
    let revoked = try #require(pairing.redeem(code: "00000000", port: 41730))
    _ = pairing.start(port: 41730)

    // The reload has read a store that still holds `revoked` and not the next pairing. Without
    // the service lock the revoke and the pairing finish within the pause and the reload's
    // replace then undoes both; with it they wait for the reload.
    let done = DispatchGroup()
    let paired = OSAllocatedUnfairLock<MCPCLIPairResult?>(initialState: nil)
    store.gated.withLock { $0 = true }
    DispatchQueue.global().async(group: done) { pairing.reloadRegistry() }
    store.entered.wait()
    store.gated.withLock { $0 = false }
    DispatchQueue.global().async(group: done) { _ = pairing.revoke(id: revoked.id) }
    DispatchQueue.global().async(group: done) {
      let result = pairing.redeem(code: "11111111", port: 41730)
      paired.withLock { $0 = result }
    }
    Thread.sleep(forTimeInterval: 0.1)
    store.release.signal()
    done.wait()

    let new = try #require(paired.withLock { $0 })
    #expect(pairing.registry.pairedID(for: revoked.token) == nil)
    #expect(pairing.registry.pairedID(for: new.token) == new.id)
  }

  @Test("A request name is cleaned before it is saved")
  func nameCleaned() throws {
    let pairing = service([Self.zeros, Self.ones])
    _ = pairing.start(port: 41730)
    let first = try #require(pairing.redeem(code: "00000000", port: 41730, name: " \n\t "))
    _ = pairing.start(port: 41730)
    let long = String(repeating: "a", count: 100) + "\u{7}"
    let second = try #require(pairing.redeem(code: "11111111", port: 41730, name: long))
    let names = Dictionary(uniqueKeysWithValues: store.list().map { ($0.id, $0.name) })
    #expect(names[first.id] == MCPCLIPairingService.defaultName)
    #expect(names[second.id] == String(repeating: "a", count: 64))
  }
}
