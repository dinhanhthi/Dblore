// ClickHouseHTTP.swift
// The HTTP(S) transport of the ClickHouse engine: one ephemeral URLSession per connection, one
// POST per statement (the SQL is the body), the reply streamed and split into lines.
//
// TLS (`open.tls.mode`):
// - off → plain HTTP, only to a local host (`LocalNetwork.isLocalHost`: localhost, `.local`
//   names, loopback / private / link-local / CGNAT IP literals, which covers the SSH tunnel's
//   127.0.0.1). Any other host is refused at open, so a password never crosses the Internet in
//   clear; the bundle adds no App Transport Security exception.
// - request, require, verifyCA, verifyFull → HTTPS with full verification: the chain against the
//   connection's CA (`open.tls.caPEM`, the only anchor then) or the system anchors, and the host
//   name against `tlsServerName` (the real host also behind a tunnel, where the URL host is
//   127.0.0.1). Never a fallback to plain HTTP.
//
// Credentials go in the X-ClickHouse-User / X-ClickHouse-Key headers, never in the URL. Redirects
// are not followed, so those headers never reach another host.

import Foundation
import Security

// MARK: - Local hosts

/// Hosts that may be reached over plain HTTP. The same set as the app's `AIEndpoint.isLocalHost`
/// (the plugin cannot import the app), but checked on parsed addresses: an IP literal must parse
/// (`inet_pton`; IPv4 in its canonical dotted form only, so `010.0.0.1` cannot read as octal
/// elsewhere), and a name must be letters, digits, dots and hyphens.
enum LocalNetwork {
  /// localhost, mDNS `.local`, or a loopback / private / link-local / CGNAT IP literal
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

// MARK: - Endpoint

/// Where and how one connection talks to the server, checked once at open
struct ClickHouseEndpoint: Sendable {
  let baseURL: URL
  let usesTLS: Bool
  /// The host name the certificate must carry
  let serverName: String
  /// The connection's CA, the only anchor when set
  let anchors: [SecCertificate]?
  let username: String
  let password: String

  init(_ open: EngineRequest.Open) throws {
    guard (1...65535).contains(open.port) else {
      throw EngineFailure(code: .connect, message: "The port must be between 1 and 65535.")
    }
    let host = open.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    guard !host.isEmpty else { throw EngineFailure(code: .connect, message: "The host is empty.") }
    usesTLS = open.tls.mode != .off
    // Checked before any I/O: plain HTTP only inside the local network
    guard usesTLS || LocalNetwork.isLocalHost(host) else {
      throw EngineFailure(code: .connect, message: "Use HTTPS (Verify full) for this server")
    }
    var components = URLComponents()
    components.scheme = usesTLS ? "https" : "http"
    components.host = host.contains(":") ? "[\(host)]" : host
    components.port = open.port
    components.path = "/"
    // Fail closed: the URL must reach exactly the host that was checked
    guard let url = components.url,
      url.host(percentEncoded: false)?.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        .lowercased() == host.lowercased()
    else {
      throw EngineFailure(code: .connect, message: "The host is not a valid host name or address.")
    }
    baseURL = url
    serverName = open.tlsServerName.isEmpty ? host : open.tlsServerName
    if usesTLS, let caPEM = open.tls.caPEM, !caPEM.isEmpty {
      let certificates = Self.certificates(fromPEM: caPEM)
      guard !certificates.isEmpty else {
        throw EngineFailure(
          code: .connect, message: "The certificate authority could not be read.")
      }
      anchors = certificates
    } else {
      anchors = nil
    }
    // Header values: a line break would start another header
    let refused = CharacterSet.newlines.union(CharacterSet(charactersIn: "\u{0}"))
    guard open.username.unicodeScalars.allSatisfy({ !refused.contains($0) }),
      open.password.unicodeScalars.allSatisfy({ !refused.contains($0) })
    else {
      throw EngineFailure(
        code: .connect, message: "The user name or password holds characters that are not allowed.")
    }
    username = open.username
    password = open.password
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

// MARK: - Transport

/// One connection's URLSession. Requests may start on any thread; the reply of each is read
/// through its `ClickHouseResponse`.
final class ClickHouseHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  /// A statement's idle limit on the wire: none in practice, `max_execution_time` brakes it
  static let statementTimeout: TimeInterval = 7 * 24 * 3600

  let endpoint: ClickHouseEndpoint
  private let lock = NSLock()
  /// Replies by task, guarded by `lock`
  private var responses: [Int: ClickHouseResponse] = [:]
  private var session: URLSession!

  /// `configuration`: the base of the session (tests add `protocolClasses`); it is copied and
  /// stripped of caches, cookies and stored credentials.
  init(endpoint: ClickHouseEndpoint, configuration: URLSessionConfiguration) {
    self.endpoint = endpoint
    super.init()
    let configuration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = Self.statementTimeout
    configuration.timeoutIntervalForResource = Self.statementTimeout
    // One statement at a time per session, plus a cancel
    configuration.httpMaximumConnectionsPerHost = 2
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = "ace.thi.Dblore.ClickHouse.http"
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
  }

  /// A POST of `sql` with the URL `parameters` (settings, `session_id`, `query_id`, binds).
  /// `timeout` bounds the wait between packets (the open probe); nil means none in practice.
  func request(
    _ sql: String, parameters: [(String, String)], timeout: TimeInterval? = nil
  ) throws -> URLRequest {
    var request = URLRequest(url: try Self.url(endpoint.baseURL, parameters))
    request.httpMethod = "POST"
    request.httpBody = Data(sql.utf8)
    request.timeoutInterval = timeout ?? Self.statementTimeout
    request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
    if !endpoint.username.isEmpty {
      request.setValue(endpoint.username, forHTTPHeaderField: "X-ClickHouse-User")
    }
    // Also without a user name: the server's default user may have a password
    if !endpoint.password.isEmpty {
      request.setValue(endpoint.password, forHTTPHeaderField: "X-ClickHouse-Key")
    }
    return request
  }

  /// Starts `request`; its reply streams into the returned response
  func start(_ request: URLRequest) -> ClickHouseResponse {
    let task = session.dataTask(with: request)
    let response = ClickHouseResponse(task: task)
    lock.withLock { responses[task.taskIdentifier] = response }
    task.resume()
    return response
  }

  /// Ends every request and the session; nothing is sent afterwards
  func invalidate() {
    session.invalidateAndCancel()
  }

  /// `base` with the query string, each name and value percent-encoded in full (a bare `+`
  /// would read as a space). Throws rather than send a request without its parameters.
  static func url(_ base: URL, _ parameters: [(String, String)]) throws -> URL {
    guard !parameters.isEmpty else { return base }
    let query = parameters.map { "\(encode($0))=\(encode($1))" }.joined(separator: "&")
    guard let url = URL(string: base.absoluteString + "?" + query) else {
      throw EngineFailure(code: .invalid, message: "The request URL could not be built.")
    }
    return url
  }

  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  private static func encode(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
  }

  private func response(of task: URLSessionTask) -> ClickHouseResponse? {
    lock.withLock { responses[task.taskIdentifier] }
  }

  // MARK: URLSessionDataDelegate

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    self.response(of: dataTask)?.received(response as? HTTPURLResponse)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    self.response(of: dataTask)?.received(data)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    let response = lock.withLock { responses.removeValue(forKey: task.taskIdentifier) }
    response?.finished(error)
  }

  /// Redirects are refused: the credential headers would follow them
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  /// The server certificate, checked against `serverName` and the anchors. Task-level, so a
  /// refusal is recorded on the task's response and reads as a certificate failure, not as a
  /// cancel. Any other challenge (HTTP authentication, a client certificate) is declined without
  /// a credential (never the system's own), so a 401 arrives as a response with the server's text.
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?)
      -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust
    else {
      return completionHandler(.rejectProtectionSpace, nil)
    }
    guard Self.evaluate(trust, serverName: endpoint.serverName, anchors: endpoint.anchors) else {
      response(of: task)?.refusedTrust()
      return completionHandler(.cancelAuthenticationChallenge, nil)
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }

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
}

// MARK: - Response

/// The reply of one request: its status and headers, then its body as lines. The delegate queue
/// fills it; one reader (the connection's queue) drains it. The body is held to `highWater`
/// bytes: past it the task is suspended until the reader catches up.
final class ClickHouseResponse: @unchecked Sendable {
  static let highWater = 8 << 20
  static let lowWater = 2 << 20
  /// The longest line read (one row): the largest value the app takes. A longer one stops the
  /// request, so a server that never ends a line cannot fill the app's memory.
  static let maxLineBytes = EnginePluginProtocol.maxValueBytes

  private let task: URLSessionDataTask
  private let condition = NSCondition()
  private var head: HTTPURLResponse?
  /// Received bytes; those before `offset` are read already (dropped now and then)
  private var buffer = Data()
  private var offset = 0
  /// Bytes from `offset` on already known to hold no line feed
  private var scanned = 0
  private var suspended = false
  private var complete = false
  private var failure: (any Error)?
  private var cancelled = false
  /// The server's certificate was refused
  private var untrusted = false
  /// A line passed `maxLineBytes`; the request was stopped
  private var oversized = false

  init(task: URLSessionDataTask) {
    self.task = task
  }

  // MARK: Writer (delegate queue)

  fileprivate func received(_ response: HTTPURLResponse?) {
    condition.withLock {
      head = response
      condition.broadcast()
    }
  }

  fileprivate func received(_ data: Data) {
    condition.withLock {
      buffer.append(data)
      if buffer.count - offset > Self.highWater, !suspended, !complete {
        suspended = true
        task.suspend()
      }
      condition.broadcast()
    }
  }

  fileprivate func refusedTrust() {
    condition.withLock { untrusted = true }
  }

  fileprivate func finished(_ error: (any Error)?) {
    condition.withLock {
      complete = true
      failure = error
      condition.broadcast()
    }
  }

  // MARK: Reader

  /// Any thread: stops the request; the reader then fails with `ClickHouseTransportError.cancelled`
  func cancel() {
    condition.withLock {
      cancelled = true
      condition.broadcast()
    }
    task.cancel()
  }

  /// Whether the reply ended without a transport failure or a cancel
  var isFinished: Bool {
    condition.withLock { complete && failure == nil && !cancelled && !oversized }
  }

  /// Whether the status and headers arrived
  var hasHead: Bool { condition.withLock { head != nil } }

  /// The transport failure that ended the reply, if any (not a cancel)
  var transportFailure: ClickHouseTransportError? {
    condition.withLock { failureLocked() }
  }

  /// Waits until the reply ends, at most `timeout` seconds
  func waitForEnd(timeout: TimeInterval) {
    let deadline = Date(timeIntervalSinceNow: timeout)
    condition.lock()
    defer { condition.unlock() }
    while !complete && !cancelled {
      // A kill's reply is small; drop it as it comes so the task never suspends
      buffer.removeAll()
      offset = 0
      scanned = 0
      guard condition.wait(until: deadline) else { return }
    }
  }

  /// Waits for the status and headers
  func waitForHead() throws -> HTTPURLResponse {
    condition.lock()
    defer { condition.unlock() }
    while head == nil && !complete && !cancelled { condition.wait() }
    try throwIfFailedLocked()
    guard let head else { throw ClickHouseTransportError.noResponse }
    return head
  }

  /// The next line without its line feed, nil at the end of the body. A last line without a
  /// line feed is returned too. A line over `maxLineBytes` stops the request and throws
  /// `lineTooLong`.
  func nextLine() throws -> Data? {
    condition.lock()
    defer { condition.unlock() }
    while true {
      try throwIfStoppedLocked()
      if let newline = lineFeedLocked() {
        guard newline - offset <= Self.maxLineBytes else { try stopOversizedLocked() }
        let line = takeLocked(upTo: newline, next: newline + 1)
        scanned = 0
        compactLocked()
        resumeIfDrainedLocked()
        return line
      }
      scanned = buffer.count - offset
      if scanned > Self.maxLineBytes { try stopOversizedLocked() }
      if complete {
        // Bytes before a broken connection still come first (an exception text, say)
        guard offset < buffer.count else {
          try throwIfFailedLocked()
          return nil
        }
        let line = takeLocked(upTo: buffer.count, next: buffer.count)
        scanned = 0
        return line
      }
      resumeIfDrainedLocked()
      condition.wait()
    }
  }

  /// Stops the request over a line past `maxLineBytes`; always throws `lineTooLong`
  private func stopOversizedLocked() throws -> Never {
    oversized = true
    buffer = Data()
    offset = 0
    scanned = 0
    task.cancel()
    throw ClickHouseTransportError.lineTooLong
  }

  /// The bytes from `offset` to `end`; reading goes on at `next`. A line that is the whole
  /// buffer is handed over without a copy (a big value is held once, not twice).
  private func takeLocked(upTo end: Int, next: Int) -> Data {
    guard offset == 0, next == buffer.count else {
      defer { offset = next }
      return buffer.subdata(in: offset..<end)
    }
    var line = buffer
    buffer = Data()
    offset = 0
    if end < line.count { line.removeLast(line.count - end) }
    return line
  }

  /// The rest of the body, at most `limit` bytes (an error text)
  func remainingBody(limit: Int) -> Data {
    var body = Data()
    while body.count < limit, let line = try? nextLine() {
      body.append(line)
      body.append(0x0A)
    }
    return body.prefix(limit)
  }

  /// The unread bytes, at most `limit`, once the reply ended or `limit` bytes arrived, or after
  /// `wait` seconds at most (an error text that ends the reply, without waiting on a reply that
  /// goes on). Nothing is read after them.
  func bufferedBody(limit: Int, wait: TimeInterval) -> Data {
    let deadline = Date(timeIntervalSinceNow: wait)
    condition.lock()
    defer { condition.unlock() }
    while !complete, !cancelled, !oversized, buffer.count - offset < limit {
      resumeIfDrainedLocked()
      guard condition.wait(until: deadline) else { break }
    }
    let end = min(buffer.count, offset + limit)
    let body = buffer.subdata(in: offset..<end)
    offset = end
    scanned = 0
    return body
  }

  /// The index of the next unread line feed in `buffer`
  private func lineFeedLocked() -> Int? {
    let start = offset + scanned
    guard start < buffer.count else { return nil }
    return buffer.withUnsafeBytes { raw -> Int? in
      guard let base = raw.baseAddress,
        let found = memchr(base + start, 0x0A, raw.count - start)
      else { return nil }
      return base.distance(to: UnsafeRawPointer(found))
    }
  }

  /// Drops the bytes read so far once they are many
  private func compactLocked() {
    guard offset >= 1 << 20 || offset == buffer.count else { return }
    buffer = offset == buffer.count ? Data() : buffer.subdata(in: offset..<buffer.count)
    offset = 0
  }

  private func resumeIfDrainedLocked() {
    // A line longer than the high water mark must still arrive whole
    let pending = buffer.count - offset
    guard suspended, pending < Self.lowWater || scanned == pending else { return }
    suspended = false
    task.resume()
  }

  private func throwIfStoppedLocked() throws {
    if oversized { throw ClickHouseTransportError.lineTooLong }
    if cancelled { throw ClickHouseTransportError.cancelled }
  }

  private func throwIfFailedLocked() throws {
    try throwIfStoppedLocked()
    if let failure = failureLocked() { throw failure }
  }

  private func failureLocked() -> ClickHouseTransportError? {
    guard let failure else { return nil }
    return untrusted ? .tls : ClickHouseTransportError(failure)
  }
}

/// A transport failure, as plain text without the URL (it holds the bind values)
enum ClickHouseTransportError: Error, Equatable {
  case cancelled
  case noResponse
  /// The server could not be reached, or the connection broke
  case unreachable(String)
  /// The certificate was refused
  case tls
  /// A line (row) passed `ClickHouseResponse.maxLineBytes`
  case lineTooLong
  case other(String)

  init(_ error: any Error) {
    guard let error = error as? URLError else {
      self = .other("The request failed.")
      return
    }
    switch error.code {
    case .cancelled: self = .cancelled
    case .serverCertificateUntrusted, .serverCertificateHasBadDate,
      .serverCertificateHasUnknownRoot,
      .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected,
      .clientCertificateRequired:
      self = .tls
    case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
      .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
      self = .unreachable(Self.text(of: error.code))
    default: self = .other("The request failed (URL error \(error.code.rawValue)).")
    }
  }

  var failure: EngineFailure {
    switch self {
    case .cancelled: EngineFailure(code: .query, message: "The statement was cancelled.")
    case .noResponse: EngineFailure(code: .query, message: "The server sent no answer.")
    case .unreachable(let text): EngineFailure(code: .connect, message: text)
    case .tls:
      EngineFailure(
        code: .connect,
        message:
          "The server's certificate was refused (TLS verification with the server name and certificate authority)."
      )
    case .lineTooLong:
      EngineFailure(code: .tooLarge, message: "A row of the result is over 256 MiB.")
    case .other(let text): EngineFailure(code: .query, message: text)
    }
  }

  private static func text(of code: URLError.Code) -> String {
    switch code {
    case .cannotFindHost, .dnsLookupFailed: "The server's host name could not be found."
    case .cannotConnectToHost: "Could not connect to the server."
    case .networkConnectionLost: "The connection to the server was lost."
    case .timedOut: "The server did not answer in time."
    default: "The network is not available."
    }
  }
}
