// RedisTransport.swift
// The Redis engine's socket: an NWConnection on its own private serial queue (never the
// handler's connection queue) and a blocking NSCondition adapter over it for the connection
// queue: connect, read a line, read exactly N bytes, skip bytes, write all, close. `interrupt`
// wakes a blocked read, which then throws `interrupted` without consuming anything.
//
// Reads are pulled: a receive is asked for only while fewer than `highWater` bytes wait unread
// (or a read needs more), so a reader that waits for credit stops the server through TCP.
//
// TLS (`open.tls.mode`):
// - off → plain RESP, only to a local host (`RedisLocalNetwork.isLocalHost`: localhost, `.local`
//   names, loopback / private / link-local / CGNAT IP literals, which covers the SSH forwarder's
//   127.0.0.1). Any other host is refused before dialing, so a password never crosses the
//   Internet in clear.
// - request, require, verifyCA, verifyFull → TLS with full verification: the chain against the
//   connection's CA (`open.tls.caPEM`, the only anchor then) or the system anchors, and the host
//   name against `tlsServerName` (the real host also behind a tunnel, where the dialed host is
//   127.0.0.1), also sent as SNI. Never a fallback to plain RESP.

import Foundation
import Network
import Security

// MARK: - Local hosts

/// Hosts that may be reached over plain RESP: localhost, mDNS `.local`, or a loopback / private /
/// link-local / CGNAT IP literal. An IP literal must parse (`inet_pton`; IPv4 in its canonical
/// dotted form only), and a name must be letters, digits, dots and hyphens.
enum RedisLocalNetwork {
  static func isLocalHost(_ rawHost: String) -> Bool {
    var host = rawHost.lowercased()
    if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    if host.contains(":") {
      // A zone (`fe80::1%en0`) only picks the interface
      let address = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
      return ipv6(address).map(isLocalIPv6) ?? false
    }
    if let octets = ipv4(host) { return isLocalIPv4(octets) }
    guard isHostName(host) else { return false }
    return host == "localhost" || host.hasSuffix(".local")
  }

  /// The 4 bytes of a canonical dotted IPv4 literal
  private static func ipv4(_ text: String) -> [UInt8]? {
    var address = in_addr()
    guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
    let octets = withUnsafeBytes(of: &address) { Array($0) }
    guard octets.map(String.init).joined(separator: ".") == text else { return nil }
    return octets
  }

  /// The 16 bytes of an IPv6 literal
  private static func ipv6(_ text: String) -> [UInt8]? {
    var address = in6_addr()
    guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
    return withUnsafeBytes(of: &address) { Array($0) }
  }

  private static func isLocalIPv4(_ octets: [UInt8]) -> Bool {
    let (a, b) = (octets[0], octets[1])
    return a == 127 || a == 10 || (a == 172 && (16...31).contains(b))
      || (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
  }

  private static func isLocalIPv6(_ bytes: [UInt8]) -> Bool {
    if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }  // ::1
    // IPv4-mapped ::ffff:a.b.c.d
    if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
      return isLocalIPv4(Array(bytes[12..<16]))
    }
    return (bytes[0] & 0xFE) == 0xFC  // fc00::/7
      || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80)  // fe80::/10
  }

  /// Letters, digits, dots and hyphens; no empty label, no trailing dot
  private static func isHostName(_ host: String) -> Bool {
    guard !host.isEmpty, host.utf8.count <= 253,
      host.unicodeScalars.allSatisfy({
        ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-"
      })
    else { return false }
    return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-")
    }
  }
}

// MARK: - Trust

enum RedisTrust {
  /// Full verification: chain to the anchors (the system's when nil) and host name
  static func evaluate(_ trust: SecTrust, serverName: String, anchors: [SecCertificate]?) -> Bool {
    let policy = SecPolicyCreateSSL(true, serverName as CFString)
    guard SecTrustSetPolicies(trust, policy) == errSecSuccess else { return false }
    if let anchors {
      guard SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
        SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
      else { return false }
    }
    return SecTrustEvaluateWithError(trust, nil)
  }

  /// Every certificate of a PEM bundle
  static func certificates(fromPEM pem: String) -> [SecCertificate] {
    let begin = "-----BEGIN CERTIFICATE-----"
    let end = "-----END CERTIFICATE-----"
    var certificates: [SecCertificate] = []
    var rest = pem[...]
    while let start = rest.range(of: begin),
      let stop = rest.range(of: end, range: start.upperBound..<rest.endIndex)
    {
      let base64 = rest[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
      if let der = Data(base64Encoded: String(base64)),
        let certificate = SecCertificateCreateWithData(nil, der as CFData)
      {
        certificates.append(certificate)
      }
      rest = rest[stop.upperBound...]
    }
    return certificates
  }
}

// MARK: - Endpoint

/// Where and how one connection reaches the server, checked once at open before any I/O
struct RedisEndpoint: Sendable {
  let host: String
  let port: UInt16
  let usesTLS: Bool
  /// The host name the certificate must carry, also sent as SNI
  let serverName: String
  /// The connection's CA, the only anchor when set
  let anchors: [SecCertificate]?

  init(_ open: EngineRequest.Open) throws {
    guard (1...65535).contains(open.port) else {
      throw EngineFailure(code: .connect, message: "The port must be between 1 and 65535.")
    }
    let host = open.host.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\n"))
    guard !host.isEmpty else { throw EngineFailure(code: .connect, message: "The host is empty.") }
    usesTLS = open.tls.mode != .off
    // Plain RESP only inside the local network (the SSH forwarder dials 127.0.0.1)
    guard usesTLS || RedisLocalNetwork.isLocalHost(host) else {
      throw EngineFailure(code: .connect, message: "Use TLS (Verify full) for this server.")
    }
    self.host = host
    port = UInt16(open.port)
    serverName = open.tlsServerName.isEmpty ? host : open.tlsServerName
    if usesTLS, let caPEM = open.tls.caPEM, !caPEM.isEmpty {
      let certificates = RedisTrust.certificates(fromPEM: caPEM)
      guard !certificates.isEmpty else {
        throw EngineFailure(code: .connect, message: "The certificate authority could not be read.")
      }
      anchors = certificates
    } else {
      anchors = nil
    }
  }
}

// MARK: - Errors

enum RedisTransportError: Error, Equatable {
  /// `interrupt` stopped a read or a write that had not started; nothing was consumed or sent
  case interrupted
  case timedOut
  /// The server ended the connection
  case closedByServer
  /// `close` ended the connection
  case closed
  case unreachable(String)
  /// The certificate was refused
  case untrusted
  case tls(String)
  /// The bytes are not RESP (a line without CRLF, or over `maxLineBytes`)
  case malformed
  /// A drain passed its byte cap
  case drainCap

  var failure: EngineFailure {
    switch self {
    case .interrupted: EngineFailure(code: .query, message: "The command was cancelled.")
    case .timedOut: EngineFailure(code: .connect, message: "The server did not answer in time.")
    case .closedByServer:
      EngineFailure(code: .connect, message: "The server closed the connection.")
    case .closed: EngineFailure(code: .connect, message: "The connection is closed.")
    case .unreachable(let text): EngineFailure(code: .connect, message: text)
    case .untrusted:
      EngineFailure(
        code: .connect,
        message:
          "The server's certificate was refused (TLS verification with the server name and certificate authority)."
      )
    case .tls(let text): EngineFailure(code: .connect, message: text)
    case .malformed:
      EngineFailure(code: .query, message: "The server's reply could not be read.")
    case .drainCap:
      EngineFailure(code: .query, message: "The rest of the reply was too long to skip.")
    }
  }

  static func from(_ error: NWError, untrusted: Bool) -> RedisTransportError {
    if untrusted { return .untrusted }
    switch error {
    case .dns: return .unreachable("The server's host name could not be found.")
    case .tls(let status):
      return .tls("The TLS handshake with the server failed (OSStatus \(status)).")
    case .posix(let code):
      switch code {
      case .ECONNREFUSED:
        return .unreachable("Could not connect to the server (connection refused).")
      case .ETIMEDOUT: return .timedOut
      case .ECONNRESET, .EPIPE, .ECONNABORTED:
        return .unreachable("The connection to the server was lost.")
      case .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EHOSTDOWN:
        return .unreachable("The server cannot be reached on this network.")
      case .ECANCELED: return .closed
      default:
        return .unreachable(
          "Could not connect to the server (\(String(cString: strerror(code.rawValue)))).")
      }
    default: return .unreachable("Could not connect to the server.")
    }
  }
}

// MARK: - Transport

/// One socket. `connect`, the reads, `write` and `close` run on the connection queue;
/// `interrupt` / `resetInterrupt` on any thread. Network callbacks run on `queue`.
final class RedisTransport: @unchecked Sendable {
  /// Unread bytes past which no more are asked for
  static let highWater = 4 << 20
  /// Bytes per receive at most
  static let receiveBytes = 1 << 20
  /// The longest header or simple line
  static let maxLineBytes = 1 << 20
  /// How long a write may still take once interrupted
  static let interruptedWriteGrace: TimeInterval = 3

  /// Whether the verify block refused the certificate
  private final class TrustRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var refused = false
    var isRefused: Bool { lock.withLock { refused } }
    func refuse() { lock.withLock { refused = true } }
  }

  private let connection: NWConnection
  private let queue = DispatchQueue(label: "ace.thi.Dblore.Redis.socket")
  private let trust = TrustRecord()
  private let condition = NSCondition()

  // Guarded by `condition`
  /// Received bytes; those before `offset` are read already
  private var buffer = Data()
  private var offset = 0
  private var receiving = false
  private var ready = false
  /// The server ended the stream
  private var ended = false
  private var failure: RedisTransportError?
  private var closed = false
  private var interrupted = false
  private var writesSent = 0
  private var writesDone = 0

  init(endpoint: RedisEndpoint, connectTimeoutSeconds: Int) {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.connectionTimeout = max(1, connectTimeoutSeconds)
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 60
    let parameters: NWParameters
    if endpoint.usesTLS {
      let tls = NWProtocolTLS.Options()
      let options = tls.securityProtocolOptions
      sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
      sec_protocol_options_set_tls_server_name(options, endpoint.serverName)
      let serverName = endpoint.serverName
      let anchors = endpoint.anchors
      let record = trust
      sec_protocol_options_set_verify_block(
        options,
        { _, secTrust, complete in
          let trusted = RedisTrust.evaluate(
            sec_trust_copy_ref(secTrust).takeRetainedValue(), serverName: serverName,
            anchors: anchors)
          if !trusted { record.refuse() }
          complete(trusted)
        }, queue)
      parameters = NWParameters(tls: tls, tcp: tcp)
    } else {
      parameters = NWParameters(tls: nil, tcp: tcp)
    }
    connection = NWConnection(
      host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port) ?? 6379,
      using: parameters)
  }

  deinit {
    connection.stateUpdateHandler = nil
    connection.cancel()
  }

  // MARK: Connect and close

  /// Dials and waits until the connection (and its TLS handshake) is ready, by `deadline`
  func connect(deadline: Date) throws {
    connection.stateUpdateHandler = { [weak self] state in self?.changed(state) }
    connection.start(queue: queue)
    condition.lock()
    defer { condition.unlock() }
    while !ready {
      if let failure { throw failure }
      if closed { throw RedisTransportError.closed }
      if !condition.wait(until: deadline), !ready, failure == nil {
        failure = .timedOut
        connection.cancel()
        throw RedisTransportError.timedOut
      }
    }
  }

  private func changed(_ state: NWConnection.State) {
    var cancel = false
    condition.withLock {
      switch state {
      case .ready:
        ready = true
      case .waiting(let error):
        // Before `ready` a wait is a failure (a refused port, an unreachable host, a refused
        // certificate): the connection would only retry until the deadline
        if !ready {
          failure = failure ?? .from(error, untrusted: trust.isRefused)
          cancel = true
        }
      case .failed(let error):
        failure = failure ?? .from(error, untrusted: trust.isRefused)
      case .cancelled:
        failure = failure ?? .closed
      default: break
      }
      condition.broadcast()
    }
    if cancel { connection.cancel() }
  }

  /// Ends the connection; every read and write fails from now on
  func close() {
    condition.withLock {
      closed = true
      buffer = Data()
      offset = 0
      condition.broadcast()
    }
    connection.cancel()
  }

  // MARK: Interrupt

  func interrupt() {
    condition.withLock {
      interrupted = true
      condition.broadcast()
    }
  }

  func resetInterrupt() {
    condition.withLock { interrupted = false }
  }

  // MARK: Write

  /// Sends `data` whole and waits until the stack took it. Throws `interrupted` (nothing sent)
  /// when interrupted before the send; once sent, an interrupt only bounds the wait.
  func write(_ data: Data, deadline: Date?) throws {
    let sequence: Int = try condition.withLock {
      try throwIfBrokenLocked()
      if interrupted { throw RedisTransportError.interrupted }
      writesSent += 1
      return writesSent
    }
    connection.send(
      content: data,
      completion: .contentProcessed { [self] error in
        condition.withLock {
          writesDone = max(writesDone, sequence)
          if let error { failure = failure ?? .from(error, untrusted: false) }
          condition.broadcast()
        }
      })
    condition.lock()
    defer { condition.unlock() }
    var limit = deadline
    while writesDone < sequence {
      try throwIfBrokenLocked()
      if interrupted {
        let grace = Date(timeIntervalSinceNow: Self.interruptedWriteGrace)
        limit = min(limit ?? grace, grace)
      }
      if let limit {
        if !condition.wait(until: limit), writesDone < sequence {
          throw RedisTransportError.timedOut
        }
      } else {
        condition.wait()
      }
    }
    if let failure { throw failure }
  }

  // MARK: Read

  /// The next line without its CRLF
  func readLine(deadline: Date?, interruptible: Bool) throws -> Data {
    condition.lock()
    defer { condition.unlock() }
    while true {
      if let end = try lineEndLocked() {
        let line = buffer.subdata(in: offset..<end)
        consumeLocked(end + 2 - offset)
        return line
      }
      guard buffer.count - offset <= Self.maxLineBytes else { throw RedisTransportError.malformed }
      try waitLocked(deadline: deadline, interruptible: interruptible)
    }
  }

  /// Exactly `count` bytes
  func read(count: Int, deadline: Date?, interruptible: Bool) throws -> Data {
    condition.lock()
    defer { condition.unlock() }
    while buffer.count - offset < count {
      try waitLocked(deadline: deadline, interruptible: interruptible)
    }
    let data: Data
    if offset == 0, count == buffer.count {
      // The whole buffer: handed over without a copy
      data = buffer
      buffer = Data()
    } else {
      data = buffer.subdata(in: offset..<offset + count)
    }
    consumeLocked(count, taken: offset == 0 && buffer.isEmpty)
    return data
  }

  /// Drops at least one and at most `limit` bytes; returns how many
  func skip(upTo limit: Int, deadline: Date?, interruptible: Bool) throws -> Int {
    condition.lock()
    defer { condition.unlock() }
    while buffer.count - offset == 0 {
      try waitLocked(deadline: deadline, interruptible: interruptible)
    }
    let count = min(limit, buffer.count - offset)
    consumeLocked(count)
    return count
  }

  /// The index of the CR of the next CRLF from `offset`
  private func lineEndLocked() throws -> Int? {
    guard offset < buffer.count else { return nil }
    let start = offset
    let found: Int? = buffer.withUnsafeBytes { raw -> Int? in
      guard let base = raw.baseAddress, let hit = memchr(base + start, 0x0A, raw.count - start)
      else { return nil }
      return base.distance(to: UnsafeRawPointer(hit))
    }
    guard let found else { return nil }
    guard found > offset, buffer[buffer.startIndex + found - 1] == 0x0D else {
      throw RedisTransportError.malformed
    }
    return found - 1
  }

  /// Marks `count` bytes from `offset` read and asks for more when few wait
  private func consumeLocked(_ count: Int, taken: Bool = false) {
    if !taken { offset += count }
    if offset >= buffer.count {
      buffer = Data()
      offset = 0
    } else if offset >= Self.receiveBytes {
      buffer = buffer.subdata(in: offset..<buffer.count)
      offset = 0
    }
    if buffer.count - offset < Self.highWater { receiveLocked() }
  }

  /// Waits for more bytes. Throws when the connection broke or ended, at `deadline`, or (when
  /// `interruptible`) once interrupted.
  private func waitLocked(deadline: Date?, interruptible: Bool) throws {
    if interruptible && interrupted { throw RedisTransportError.interrupted }
    try throwIfBrokenLocked()
    if ended { throw RedisTransportError.closedByServer }
    receiveLocked()
    if let deadline {
      if !condition.wait(until: deadline), Date() >= deadline { throw RedisTransportError.timedOut }
    } else {
      condition.wait()
    }
  }

  private func throwIfBrokenLocked() throws {
    if closed { throw RedisTransportError.closed }
    if let failure { throw failure }
  }

  /// Asks for the next bytes unless a receive is pending or the stream is over
  private func receiveLocked() {
    guard ready, !receiving, !ended, !closed, failure == nil else { return }
    receiving = true
    connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveBytes) {
      [self] data, _, isComplete, error in
      condition.withLock {
        receiving = false
        if !closed, let data, !data.isEmpty { buffer.append(data) }
        if let error {
          failure = failure ?? .from(error, untrusted: false)
        } else if isComplete {
          ended = true
        } else if buffer.count - offset < Self.highWater {
          receiveLocked()
        }
        condition.broadcast()
      }
    }
  }
}

// MARK: - Reader

/// The bytes of a reply from a transport, with one read policy: a deadline, whether an
/// interrupt stops a read, and a byte budget (a drain's cap)
final class RedisReader: RESPSource {
  private let transport: RedisTransport
  private let deadline: Date?
  private let interruptible: Bool
  private var budget: Int?

  init(_ transport: RedisTransport, deadline: Date?, interruptible: Bool, budget: Int? = nil) {
    self.transport = transport
    self.deadline = deadline
    self.interruptible = interruptible
    self.budget = budget
  }

  func line() throws -> Data {
    let line = try transport.readLine(deadline: deadline, interruptible: interruptible)
    try spend(line.count + 2)
    return line
  }

  func bytes(_ count: Int) throws -> Data {
    if let budget, count > budget { throw RedisTransportError.drainCap }
    let data = try transport.read(count: count, deadline: deadline, interruptible: interruptible)
    try spend(count)
    return data
  }

  func skip(_ count: inout Int) throws {
    guard count > 0 else { return }
    let limit = min(count, budget ?? count)
    guard limit > 0 else { throw RedisTransportError.drainCap }
    let skipped = try transport.skip(
      upTo: limit, deadline: deadline, interruptible: interruptible)
    count -= skipped
    try spend(skipped)
  }

  private func spend(_ count: Int) throws {
    guard let budget else { return }
    self.budget = budget - count
    if budget - count < 0 { throw RedisTransportError.drainCap }
  }
}
