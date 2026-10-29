// MCPCLIPairing.swift
// Pairs the command-line tool with the running MCP server. Settings starts a pairing: an
// 8-character Crockford base32 code (40 bits from SecRandomCopyBytes, the system CSPRNG the MCP
// token already uses; 5 bytes map to 8 symbols with no bias), valid 5 minutes on a monotonic
// clock, single use, bound to the server's port. One code is active at a time: a new one
// replaces it, and the server controller ends it when the server stops or changes port. The 5th
// wrong attempt (counted across requests) burns it. A correct code mints a CLI token and a proof
// key (32 random bytes each), saves them (`MCPCLITokenStore`) and adds them to the registry the
// request validator reads, so a pairing or a revoke needs no server restart. It also answers the
// listener's `/cli/pair` and `/cli/hello` routes (wire format below).
// Codes and tokens are compared in constant time; codes, tokens, proof keys and nonces are never
// logged.

import CryptoKit
import Foundation
import os

/// The code Settings shows while a pairing waits.
nonisolated struct MCPCLIPairingCode: Equatable, Sendable {
  /// 8 symbols of `MCPCLIPairingService.alphabet`
  let code: String
  /// The bound port the code was issued for
  let port: Int
  let expires: ContinuousClock.Instant
}

/// The `/cli/pair` answer: the CLI saves it and sends `token` as its bearer, after checking a
/// `/cli/hello` answer keyed with `proofKey` (the 32 bytes the base64url text decodes to).
nonisolated struct MCPCLIPairResult: Codable, Equatable, Sendable {
  let token: String
  let proofKey: String
  let port: Int
  let id: String
}

nonisolated final class MCPCLIPairingService: Sendable {
  static let shared = MCPCLIPairingService()

  /// Crockford base32: digits and letters without I, L, O and U
  static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
  static let lifetime = Duration.seconds(300)
  static let maxAttempts = 5
  static let defaultName = "Command-line tool"

  private struct Active {
    var code: String
    var port: Int
    var expires: ContinuousClock.Instant
    var failures = 0
  }

  /// Read by the request validator on every `/mcp` request
  let registry: MCPCLITokenRegistry
  private let store: any MCPCLITokenStore
  private let now: @Sendable () -> ContinuousClock.Instant
  private let randomBytes: @Sendable (Int) -> [UInt8]
  private let pending = OSAllocatedUnfairLock<Active?>(initialState: nil)
  /// Serializes every change of the store and the registry together, so a reload that read the
  /// store before a revoke or a pairing landed never brings the revoked token back or drops the
  /// new one. Held across Keychain I/O, so a lock that blocks, never with `pending` held.
  private let serial = NSLock()

  init(
    store: any MCPCLITokenStore = MCPTokenStoreFactory.sharedCLI,
    registry: MCPCLITokenRegistry = MCPCLITokenRegistry(),
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    randomBytes: @escaping @Sendable (Int) -> [UInt8] = {
      MCPTokenStoreFactory.randomBytes(count: $0)
    }
  ) {
    self.store = store
    self.registry = registry
    self.now = now
    self.randomBytes = randomBytes
  }

  /// A new code for the server bound on `port`; any active code ends.
  func start(port: Int) -> MCPCLIPairingCode {
    let bits = randomBytes(5).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    let code = String((0..<8).map { Self.alphabet[Int(bits >> UInt64(35 - 5 * $0) & 31)] })
    let expires = now() + Self.lifetime
    pending.withLock { $0 = Active(code: code, port: port, expires: expires) }
    return MCPCLIPairingCode(code: code, port: port, expires: expires)
  }

  /// The waiting code, nil once it was used, burned, expired or ended.
  var activeCode: MCPCLIPairingCode? {
    let now = self.now()
    return pending.withLock { active in
      guard let active, now < active.expires else { return nil }
      return MCPCLIPairingCode(code: active.code, port: active.port, expires: active.expires)
    }
  }

  /// Ends the active code. The server controller calls it when the server stops or its port
  /// changes.
  func invalidate() {
    pending.withLock { $0 = nil }
  }

  /// `/cli/pair`: a correct code on the port it was issued for mints a token and a proof key,
  /// saved and added to the registry before this returns. Nil mints nothing. Reads and writes
  /// the Keychain: call it off the main actor. `name` comes from the request and is cleaned.
  func redeem(code: String, port: Int, name: String = defaultName) -> MCPCLIPairResult? {
    let candidate = Self.normalize(code)
    let now = self.now()
    let accepted = pending.withLock { active -> Bool in
      guard var current = active else { return false }
      // Compared before any other check, so the timing never depends on the code
      let matches = MCPRequestValidator.constantTimeEquals(candidate, current.code)
      guard now < current.expires else {
        active = nil
        return false
      }
      if matches && current.port == port {
        active = nil
        return true
      }
      current.failures += 1
      active = current.failures >= Self.maxAttempts ? nil : current
      return false
    }
    guard accepted else { return nil }
    let credential = serial.withLock {
      let credential = store.save(
        MCPCLICredential(
          id: UUID().uuidString, token: MCPTokenStoreFactory.base64URL(randomBytes(32)),
          proofKey: MCPTokenStoreFactory.base64URL(randomBytes(32)), name: Self.cleanName(name),
          date: Date()))
      registry.add(credential)
      return credential
    }
    return MCPCLIPairResult(
      token: credential.token, proofKey: credential.proofKey, port: port, id: credential.id)
  }

  /// Every paired tool. Reads the Keychain: call it off the main actor.
  func list() -> [MCPCLICredential] {
    store.list()
  }

  /// Fills the registry from the store. The server controller calls it off the main actor at
  /// every server start, so a token deleted outside this service stops working.
  func reloadRegistry() {
    serial.withLock { registry.replaceAll(with: store.list()) }
  }

  /// The token is refused at once, then its Keychain item goes. False when the item could not
  /// be deleted (it would work again after a server restart): show it. Call it off the main
  /// actor.
  @discardableResult func revoke(id: String) -> Bool {
    serial.withLock {
      registry.remove(id: id)
      return store.revoke(id: id)
    }
  }

  /// Every paired tool, as `revoke`. Call it off the main actor.
  @discardableResult func revokeAll() -> Bool {
    serial.withLock {
      registry.removeAll()
      return store.revokeAll()
    }
  }

  /// Crockford decoding rules: case-insensitive, I and L read as 1, O as 0, and hyphens and
  /// whitespace are ignored. Any other symbol (U included) stays and simply does not match.
  static func normalize(_ code: String) -> String {
    String(
      code.uppercased().compactMap { character -> Character? in
        if character == "-" || character.isWhitespace { return nil }
        if character == "I" || character == "L" { return "1" }
        return character == "O" ? "0" : character
      })
  }

  /// Display text from the request: no control characters, at most 64 characters.
  private static func cleanName(_ name: String) -> String {
    let cleaned = String(
      name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(64)
    ).trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? defaultName : cleaned
  }
}

// MARK: - Routes

/// `/cli/pair` and `/cli/hello`, which the listener hands over with the port the connection
/// reached (its socket's local address). Wire format (permanent, shared with the dblore tool):
/// - `/cli/pair`: `{"code": "<8 symbols>", "name": "<optional>"}` -> 200 `MCPCLIPairResult`; any
///   other outcome is 401. Every request reaches `redeem`, an unreadable one with an empty code,
///   so each one counts as a wrong attempt.
/// - `/cli/hello`: `{"id": "<paired id>", "nonce": "<32 random bytes, unpadded base64url>"}` ->
///   200 `{"proof": "<unpadded base64url>"}`, the HMAC-SHA256 (RFC 2104) keyed with the 32 bytes
///   of the id's proof key over UTF-8 "dblore-cli-hello-v1", the 32 nonce bytes and the port as
///   a big-endian UInt16. An unknown id or a nonce that is not 32 bytes is 401 with no proof.
///   The tool checks the proof against the port it dialed before it sends its token, so neither
///   a program squatting the port nor one relaying to the real port receives it.
nonisolated extension MCPCLIPairingService {
  static let helloLabel = "dblore-cli-hello-v1"

  private struct PairRequest: Decodable {
    let code: String
    let name: String?
  }

  private struct HelloRequest: Decodable {
    let id: String
    let nonce: String
  }

  private struct HelloResponse: Encodable {
    let proof: String
  }

  /// The listener's handler: `/cli/pair` and `/cli/hello` answered here, anything else (`/mcp`)
  /// passed to `next`.
  func handler(next: @escaping MCPHTTPServer.Handler) -> MCPHTTPServer.Handler {
    { request in
      switch request.path {
      case MCPRequestValidator.pairPath: self.pair(request)
      case MCPRequestValidator.helloPath: self.hello(request)
      default: await next(request)
      }
    }
  }

  /// HMAC-SHA256(`key`, "dblore-cli-hello-v1" || `nonce` || `port` big-endian)
  static func helloProof(key: SymmetricKey, nonce: Data, port: UInt16) -> Data {
    var message = Data(helloLabel.utf8)
    message.append(nonce)
    message.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xFF)])
    return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
  }

  /// Runs on the listener's handler task, off the event loop: `redeem` writes the Keychain.
  private func pair(_ request: MCPHTTPRequest) -> MCPHTTPResponse {
    let body = try? JSONDecoder().decode(PairRequest.self, from: request.body)
    guard
      let result = redeem(
        code: body?.code ?? "", port: request.port, name: body?.name ?? Self.defaultName),
      let data = try? JSONEncoder().encode(result)
    else {
      return .text(
        401,
        "The pairing code is wrong, expired or already used. Start a new pairing in Dblore "
          + "(Settings > MCP).")
    }
    return MCPHTTPResponse(
      status: 200, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
      body: data)
  }

  private func hello(_ request: MCPHTTPRequest) -> MCPHTTPResponse {
    guard let body = try? JSONDecoder().decode(HelloRequest.self, from: request.body),
      let nonce = MCPTokenStoreFactory.data(base64URL: body.nonce), nonce.count == 32,
      let port = UInt16(exactly: request.port), let key = registry.proofKey(id: body.id),
      let data = try? JSONEncoder().encode(
        HelloResponse(
          proof: MCPTokenStoreFactory.base64URL(
            Array(Self.helloProof(key: key, nonce: nonce, port: port)))))
    else { return .text(401, "Unauthorized") }
    return MCPHTTPResponse(
      status: 200, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
      body: data)
  }
}

/// The valid CLI tokens, read by the request validator without touching the Keychain. Pair and
/// revoke update it in place; the server controller fills it at start (`reloadRegistry`).
nonisolated final class MCPCLITokenRegistry: Sendable {
  private struct Entry: Sendable {
    let token: String
    let proofKey: SymmetricKey
  }

  private let entries = OSAllocatedUnfairLock(initialState: [String: Entry]())

  func replaceAll(with credentials: [MCPCLICredential]) {
    let loaded = credentials.compactMap { credential in
      Self.entry(credential).map { (credential.id, $0) }
    }
    entries.withLock { $0 = Dictionary(loaded, uniquingKeysWith: { _, last in last }) }
  }

  func add(_ credential: MCPCLICredential) {
    guard let entry = Self.entry(credential) else { return }
    entries.withLock { $0[credential.id] = entry }
  }

  func remove(id: String) {
    _ = entries.withLock { $0.removeValue(forKey: id) }
  }

  func removeAll() {
    entries.withLock { $0.removeAll() }
  }

  /// The paired id whose token is `bearer`, nil when none. Every entry is compared in constant
  /// time, with no early exit.
  func pairedID(for bearer: String) -> String? {
    let snapshot = entries.withLock { $0 }
    var matched: String?
    for (id, entry) in snapshot
    where MCPRequestValidator.constantTimeEquals(bearer, entry.token) {
      matched = id
    }
    return matched
  }

  /// The `/cli/hello` HMAC key of a paired id
  func proofKey(id: String) -> SymmetricKey? {
    entries.withLock { $0[id]?.proofKey }
  }

  /// Nil for a malformed proof key: that entry cannot answer a hello, so it is not loaded.
  private static func entry(_ credential: MCPCLICredential) -> Entry? {
    guard !credential.token.isEmpty,
      let key = MCPTokenStoreFactory.data(base64URL: credential.proofKey), key.count == 32
    else { return nil }
    return Entry(token: credential.token, proofKey: SymmetricKey(data: key))
  }
}
