// VaultClient.swift
// HashiCorp Vault HTTP API calls for leased database credentials: read `<mount>/creds/<role>`,
// renew and revoke a lease, AppRole login (fixed mount `auth/approle`), token lookup-self,
// renew-self and revoke-self. The address is https, or http only on this Mac (a Vault token is
// at stake, so no private-network http, and no proxy for it). The mount is never `sys`, `auth`
// or `identity`. One delegate refuses every redirect, so a token, role id or secret id never
// follows a 3xx, accepts a TLS challenge only for the address's host and, with a CA PEM, trusts
// only those anchors. Secrets travel in the X-Vault-Token header or the JSON body, never in a
// URL, and no error text carries them.

import Foundation
import Security

/// A Vault lease as created or renewed. `duration` is in seconds.
nonisolated struct VaultLease: Equatable, Sendable {
  let id: String
  let duration: Int
  let renewable: Bool
}

/// Database credentials read from `<mount>/creds/<role>`, valid while their lease lives.
nonisolated struct VaultLeasedCredentials: Equatable, Sendable {
  let lease: VaultLease
  let username: String
  let password: String
}

/// The `auth` answer of an AppRole login or a token renew-self. `duration` is the token TTL in
/// seconds.
nonisolated struct VaultAuth: Equatable, Sendable {
  let clientToken: String
  let duration: Int
  let renewable: Bool
}

/// Token lookup-self. `ttl` is 0 and `expireTime` nil for a token that never expires (root).
nonisolated struct VaultTokenInfo: Equatable, Sendable {
  let ttl: Int
  let expireTime: Date?
  let renewable: Bool
  /// Seconds, for a periodic token
  let period: Int?
}

nonisolated enum VaultClientError: Error, Equatable, Sendable, LocalizedError {
  case invalidAddress
  case insecureAddress
  case credentialsInAddress
  case invalidPath
  /// The mount is one of Vault's own (`sys`, `auth`, `identity`)
  case reservedMount
  case invalidCA
  case invalidSecret
  /// Any 3xx: never followed
  case redirect
  /// A non-2xx answer with Vault's `errors`, cleaned and with the call's secrets removed
  case http(status: Int, errors: [String])
  case untrustedCertificate
  case timedOut
  case network(code: Int)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .invalidAddress:
      return "The Vault address is not a valid URL."
    case .insecureAddress:
      return
        "The Vault address must use https; http works only for 127.0.0.1, localhost or ::1."
    case .credentialsInAddress:
      return "Remove the user name and password from the Vault address."
    case .invalidPath:
      return
        "The Vault mount and role may use only letters, digits, \"_\", \".\" and \"-\", with \"/\" between names."
    case .reservedMount:
      return "The Vault mount must be a database secrets engine, not sys, auth or identity."
    case .invalidCA:
      return "The Vault CA certificate is not a valid PEM certificate."
    case .invalidSecret:
      return
        "The Vault token, role ID or secret ID is empty or has characters Vault does not accept."
    case .redirect:
      return "Vault answered with a redirect; use the active node's address."
    case .http(let status, let errors):
      return errors.isEmpty
        ? "Vault answered HTTP \(status)."
        : "Vault answered HTTP \(status): \(errors.joined(separator: "; "))"
    case .untrustedCertificate:
      return "Vault's certificate is not trusted. Check the Vault address and its CA certificate."
    case .timedOut:
      return "Vault did not answer in time."
    case .network(let code):
      return "Could not reach Vault (network error \(code))."
    case .invalidResponse:
      return "Vault sent an answer Dblore could not read."
    }
  }

  /// A 400 saying the lease is gone: revoked (`lease not found`) or ended with the token that
  /// created it (`invalid lease`).
  var isLeaseGone: Bool {
    guard case .http(400, let errors) = self else { return false }
    return errors.contains {
      let text = $0.lowercased()
      return text.contains("lease not found") || text.contains("invalid lease")
    }
  }

  /// A 403: the token is revoked or expired, or lacks the policy (lookup-self tells them apart).
  var isForbidden: Bool {
    if case .http(403, _) = self { return true }
    return false
  }
}

/// The Vault calls a lease needs. Tokens are passed per call: an AppRole lease uses the token
/// its login returned.
nonisolated protocol VaultClient: Sendable {
  /// GET `/v1/<mount>/creds/<role>`
  func readCredentials(token: String) async throws -> VaultLeasedCredentials
  /// PUT `/v1/sys/leases/renew`; nil `increment` asks for the lease's default TTL
  func renewLease(id: String, increment: Int?, token: String) async throws -> VaultLease
  /// PUT `/v1/sys/leases/revoke`
  func revokeLease(id: String, token: String) async throws
  /// POST `/v1/auth/approle/login`, without a token
  func appRoleLogin(roleID: String, secretID: String) async throws -> VaultAuth
  /// GET `/v1/auth/token/lookup-self`
  func lookupSelf(token: String) async throws -> VaultTokenInfo
  /// POST `/v1/auth/token/renew-self`; nil `increment` asks for the token's default TTL
  func renewSelf(increment: Int?, token: String) async throws -> VaultAuth
  /// POST `/v1/auth/token/revoke-self`
  func revokeSelf(token: String) async throws
}

nonisolated final class URLSessionVaultClient: VaultClient {
  static let timeout: TimeInterval = 30
  static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
  /// Vault's own mounts: a lease read never goes there
  static let reservedMounts: Set<String> = ["sys", "auth", "identity"]
  static let maxTokenLength = 4096
  /// Vault's `errors` kept per answer, and characters kept per error
  static let errorLimit = 5
  static let errorLength = 200

  private let base: URL
  private let credentialsPath: String
  private let session: URLSession

  /// Throws, before any request, for an unsafe address, a mount or role that is not a plain
  /// path, a reserved mount, or a CA PEM without a certificate. `configuration` is for tests
  /// (stub protocols).
  init(source: VaultSource, configuration: URLSessionConfiguration = .ephemeral) throws {
    base = try Self.address(source.address)
    guard Self.isValidPath(source.mount), Self.isValidPath(source.role) else {
      throw VaultClientError.invalidPath
    }
    let firstName = source.mount.split(separator: "/").first.map { $0.lowercased() } ?? ""
    guard !Self.reservedMounts.contains(firstName) else {
      throw VaultClientError.reservedMount
    }
    credentialsPath = "\(source.mount)/creds/\(source.role)"
    var anchors: [SecCertificate]?
    if let pem = source.caPEM {
      anchors = Self.certificates(pem: pem)
      guard anchors?.isEmpty == false else { throw VaultClientError.invalidCA }
    }
    // http reaches only this Mac: never through a proxy
    if base.scheme == "http" { configuration.connectionProxyDictionary = [:] }
    configuration.timeoutIntervalForRequest = Self.timeout
    configuration.timeoutIntervalForResource = Self.timeout
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(
      configuration: configuration,
      delegate: VaultSessionDelegate(host: Self.bareHost(base), anchors: anchors),
      delegateQueue: nil)
  }

  deinit { session.invalidateAndCancel() }

  // MARK: - Calls

  func readCredentials(token: String) async throws -> VaultLeasedCredentials {
    let data = try await send("GET", credentialsPath, token: token, secrets: [token])
    let answer = try Self.decode(CredentialsAnswer.self, data)
    guard let credentials = answer.data, !credentials.username.isEmpty else {
      throw VaultClientError.invalidResponse
    }
    return VaultLeasedCredentials(
      lease: try answer.lease(), username: credentials.username,
      password: credentials.password)
  }

  func renewLease(id: String, increment: Int?, token: String) async throws -> VaultLease {
    var body: [String: Any] = ["lease_id": id]
    if let increment { body["increment"] = increment }
    let data = try await send(
      "PUT", "sys/leases/renew", token: token, body: body, secrets: [token])
    return try Self.decode(LeaseAnswer.self, data).lease()
  }

  func revokeLease(id: String, token: String) async throws {
    _ = try await send(
      "PUT", "sys/leases/revoke", token: token, body: ["lease_id": id], secrets: [token])
  }

  func appRoleLogin(roleID: String, secretID: String) async throws -> VaultAuth {
    guard !roleID.isEmpty, !secretID.isEmpty else { throw VaultClientError.invalidSecret }
    let data = try await send(
      "POST", "auth/approle/login", token: nil,
      body: ["role_id": roleID, "secret_id": secretID], secrets: [roleID, secretID])
    return try Self.decode(AuthAnswer.self, data).vaultAuth()
  }

  func lookupSelf(token: String) async throws -> VaultTokenInfo {
    let data = try await send("GET", "auth/token/lookup-self", token: token, secrets: [token])
    guard let info = try Self.decode(LookupAnswer.self, data).data else {
      throw VaultClientError.invalidResponse
    }
    return VaultTokenInfo(
      ttl: info.ttl, expireTime: info.expireTime.flatMap(Self.date), renewable: info.renewable,
      period: info.period)
  }

  func renewSelf(increment: Int?, token: String) async throws -> VaultAuth {
    var body: [String: Any] = [:]
    if let increment { body["increment"] = increment }
    let data = try await send(
      "POST", "auth/token/renew-self", token: token, body: body, secrets: [token])
    return try Self.decode(AuthAnswer.self, data).vaultAuth()
  }

  func revokeSelf(token: String) async throws {
    _ = try await send("POST", "auth/token/revoke-self", token: token, secrets: [token])
  }

  // MARK: - Transport

  /// The answer's body for a 2xx. A 3xx is `.redirect` (the delegate never follows it).
  private func send(
    _ method: String, _ path: String, token: String?, body: [String: Any]? = nil,
    secrets: [String]
  ) async throws -> Data {
    var request = URLRequest(url: base.appending(path: "v1/\(path)"))
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token {
      guard Self.isValidToken(token) else { throw VaultClientError.invalidSecret }
      request.setValue(token, forHTTPHeaderField: "X-Vault-Token")
    }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw mapped(error)
    }
    guard let http = response as? HTTPURLResponse else { throw VaultClientError.invalidResponse }
    switch http.statusCode {
    case 200..<300:
      return data
    case 300..<400:
      throw VaultClientError.redirect
    default:
      throw VaultClientError.http(
        status: http.statusCode, errors: Self.errors(in: data, removing: secrets))
    }
  }

  private func mapped(_ error: any Error) -> any Error {
    if error is VaultClientError || error is CancellationError { return error }
    guard let urlError = error as? URLError else { return VaultClientError.invalidResponse }
    switch urlError.code {
    case .timedOut:
      return VaultClientError.timedOut
    case .cancelled:
      // The delegate cancels a challenge it refuses; a cancelled task stays cancelled
      return Task.isCancelled ? CancellationError() : VaultClientError.untrustedCertificate
    case .serverCertificateUntrusted, .serverCertificateHasBadDate,
      .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
      return VaultClientError.untrustedCertificate
    default:
      return VaultClientError.network(code: urlError.code.rawValue)
    }
  }

  // MARK: - Checks

  /// The trimmed address, rebuilt from its checked scheme, host, port and path: https, or http
  /// to exactly 127.0.0.1, ::1 or localhost; no user name, password, query or fragment.
  static func address(_ text: String) throws -> URL {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let parsed = URLComponents(string: trimmed),
      let scheme = parsed.scheme?.lowercased(),
      let host = parsed.percentEncodedHost?.lowercased(), !host.isEmpty,
      parsed.percentEncodedQuery == nil, parsed.percentEncodedFragment == nil
    else { throw VaultClientError.invalidAddress }
    guard parsed.percentEncodedUser == nil, parsed.percentEncodedPassword == nil else {
      throw VaultClientError.credentialsInAddress
    }
    switch scheme {
    case "https":
      break
    case "http":
      let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      guard loopbackHosts.contains(bare) else { throw VaultClientError.insecureAddress }
    default:
      throw VaultClientError.insecureAddress
    }
    var rebuilt = URLComponents()
    rebuilt.scheme = scheme
    rebuilt.percentEncodedHost = host
    rebuilt.port = parsed.port
    rebuilt.percentEncodedPath = parsed.percentEncodedPath
    guard let url = rebuilt.url else { throw VaultClientError.invalidAddress }
    return url
  }

  /// `url`'s host, lowercased, without IPv6 brackets
  static func bareHost(_ url: URL) -> String {
    (url.host(percentEncoded: false) ?? "").lowercased()
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
  }

  /// Names of `[A-Za-z0-9_.-]` joined by `/`, none of them `.` or `..`.
  static func isValidPath(_ path: String) -> Bool {
    let names = path.split(separator: "/", omittingEmptySubsequences: false)
    return names.allSatisfy { name in
      !name.isEmpty && name != "." && name != ".."
        && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }
  }

  /// Visible ASCII (0x21-0x7E) only, so it cannot break the header.
  static func isValidToken(_ token: String) -> Bool {
    !token.isEmpty && token.utf8.count <= maxTokenLength
      && token.utf8.allSatisfy { (0x21...0x7E).contains($0) }
  }

  /// Every CERTIFICATE block of `pem`; empty when there is none or one does not parse.
  static func certificates(pem: String) -> [SecCertificate] {
    let begin = "-----BEGIN CERTIFICATE-----"
    let end = "-----END CERTIFICATE-----"
    var certificates: [SecCertificate] = []
    var rest = pem[...]
    while let start = rest.range(of: begin),
      let stop = rest.range(of: end, range: start.upperBound..<rest.endIndex)
    {
      let body = rest[start.upperBound..<stop.lowerBound]
      guard let der = Data(base64Encoded: String(body), options: .ignoreUnknownCharacters),
        let certificate = SecCertificateCreateWithData(nil, der as CFData)
      else { return [] }
      certificates.append(certificate)
      rest = rest[stop.upperBound...]
    }
    return certificates
  }

  /// Vault's `errors`, one line each, capped, with every secret of the call cut out.
  static func errors(in body: Data, removing secrets: [String]) -> [String] {
    guard let answer = try? JSONDecoder().decode(ErrorAnswer.self, from: body) else { return [] }
    return answer.errors.prefix(errorLimit).map { error in
      var text = error
      for secret in secrets where !secret.isEmpty {
        text = text.replacingOccurrences(of: secret, with: "[redacted]")
      }
      let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        .map { String($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }) }
      return String(words.joined(separator: " ").prefix(errorLength))
    }
  }

  /// RFC 3339 with any number of fractional digits (Vault writes nanoseconds).
  static func date(_ text: String) -> Date? {
    let whole = text.replacingOccurrences(
      of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: whole)
  }

  private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw VaultClientError.invalidResponse
    }
  }
}

// MARK: - Answers

nonisolated private struct LeaseAnswer: Decodable {
  let leaseID: String
  let leaseDuration: Int
  let renewable: Bool

  enum CodingKeys: String, CodingKey {
    case leaseID = "lease_id"
    case leaseDuration = "lease_duration"
    case renewable
  }

  func lease() throws -> VaultLease {
    guard !leaseID.isEmpty else { throw VaultClientError.invalidResponse }
    return VaultLease(id: leaseID, duration: leaseDuration, renewable: renewable)
  }
}

nonisolated private struct CredentialsAnswer: Decodable {
  struct Credentials: Decodable {
    let username: String
    let password: String
  }

  let leaseID: String
  let leaseDuration: Int
  let renewable: Bool
  let data: Credentials?

  enum CodingKeys: String, CodingKey {
    case leaseID = "lease_id"
    case leaseDuration = "lease_duration"
    case renewable, data
  }

  func lease() throws -> VaultLease {
    try LeaseAnswer(leaseID: leaseID, leaseDuration: leaseDuration, renewable: renewable).lease()
  }
}

nonisolated private struct AuthAnswer: Decodable {
  struct Auth: Decodable {
    let clientToken: String
    let leaseDuration: Int
    let renewable: Bool

    enum CodingKeys: String, CodingKey {
      case clientToken = "client_token"
      case leaseDuration = "lease_duration"
      case renewable
    }
  }

  let auth: Auth?

  func vaultAuth() throws -> VaultAuth {
    guard let auth, !auth.clientToken.isEmpty else { throw VaultClientError.invalidResponse }
    return VaultAuth(
      clientToken: auth.clientToken, duration: auth.leaseDuration, renewable: auth.renewable)
  }
}

nonisolated private struct LookupAnswer: Decodable {
  struct Info: Decodable {
    let ttl: Int
    let expireTime: String?
    let renewable: Bool
    let period: Int?

    enum CodingKeys: String, CodingKey {
      case ttl
      case expireTime = "expire_time"
      case renewable, period
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      ttl = try container.decode(Int.self, forKey: .ttl)
      expireTime = try container.decodeIfPresent(String.self, forKey: .expireTime)
      renewable = try container.decodeIfPresent(Bool.self, forKey: .renewable) ?? false
      period = (try? container.decodeIfPresent(Int.self, forKey: .period)) ?? nil
    }
  }

  let data: Info?
}

nonisolated private struct ErrorAnswer: Decodable {
  let errors: [String]
}

/// Refuses every redirect (the 3xx itself becomes the answer), a TLS challenge for another host
/// than the address's and, with a CA PEM, trusts only its certificates as anchors. Without one,
/// the system trust applies.
private nonisolated final class VaultSessionDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  /// Lowercased, without IPv6 brackets
  private let host: String
  private let anchors: [SecCertificate]?

  init(host: String, anchors: [SecCertificate]?) {
    self.host = host
    self.anchors = anchors
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?)
      -> Void
  ) {
    let space = challenge.protectionSpace
    guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
      return completionHandler(.performDefaultHandling, nil)
    }
    let challenged = space.host.lowercased().trimmingCharacters(
      in: CharacterSet(charactersIn: "[]"))
    guard challenged == host else { return completionHandler(.cancelAuthenticationChallenge, nil) }
    guard let anchors, let trust = space.serverTrust else {
      return completionHandler(.performDefaultHandling, nil)
    }
    guard SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
      SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
      SecTrustEvaluateWithError(trust, nil)
    else { return completionHandler(.cancelAuthenticationChallenge, nil) }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }
}
