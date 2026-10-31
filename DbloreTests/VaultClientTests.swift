// VaultClientTests.swift
// Vault HTTP client against a URLProtocol stub (answers as recorded from a Vault 2.2 dev
// server): request shapes, answer parsing, the address rule, redirect refusal and error text.
// No live Vault.

import Foundation
import Testing

@testable import Dblore

@Suite("Vault client", .serialized)
struct VaultClientTests {
  private static let token = "hvs.CAESIStubVaultToken0123456789"
  private static let leaseID = "database/creds/qa_vault_ro/AbCdEf123"

  private func source(
    address: String = "https://vault.example.com:8200", mount: String = "database",
    role: String = "qa_vault_ro"
  ) -> VaultSource {
    VaultSource(address: address, mount: mount, role: role, authMethod: .token, caPEM: nil)
  }

  private func client(_ source: VaultSource? = nil) throws -> URLSessionVaultClient {
    try URLSessionVaultClient(
      source: source ?? self.source(), configuration: VaultStubURLProtocol.configuration())
  }

  private static func json(_ text: String) -> Data { Data(text.utf8) }

  private func bodyObject(_ seen: VaultStubURLProtocol.Seen) throws -> [String: Any] {
    let body = try #require(seen.body)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
  }

  @Test("A creds answer parses its lease, username and password")
  func credentialsParse() async throws {
    VaultStubURLProtocol.reset { _ in
      .respond(
        status: 200,
        body: Self.json(
          """
          {"request_id":"r1","lease_id":"\(Self.leaseID)","renewable":true,"lease_duration":120,
           "data":{"username":"v-token-qa_vault-x1-1761700000","password":"A1b2C3d4E5f6G7h8I9j0"},
           "wrap_info":null,"warnings":null,"auth":null,"mount_type":"database"}
          """))
    }
    let credentials = try await client().readCredentials(token: Self.token)
    #expect(credentials.lease == VaultLease(id: Self.leaseID, duration: 120, renewable: true))
    #expect(credentials.username == "v-token-qa_vault-x1-1761700000")
    #expect(credentials.password == "A1b2C3d4E5f6G7h8I9j0")
    let seen = try #require(VaultStubURLProtocol.seen.first)
    #expect(VaultStubURLProtocol.seen.count == 1)
    #expect(seen.method == "GET")
    #expect(seen.url.path() == "/v1/database/creds/qa_vault_ro")
    #expect(seen.url.query == nil)
    #expect(seen.headers["X-Vault-Token"] == Self.token)
  }

  @Test("Renew is a PUT with the lease id and token; Vault's data null answer parses")
  func renewRequest() async throws {
    VaultStubURLProtocol.reset { _ in
      .respond(
        status: 200,
        body: Self.json(
          """
          {"lease_id":"\(Self.leaseID)","renewable":true,"lease_duration":300,"data":null,
           "mount_type":"system"}
          """))
    }
    let lease = try await client().renewLease(id: Self.leaseID, increment: 300, token: Self.token)
    #expect(lease == VaultLease(id: Self.leaseID, duration: 300, renewable: true))
    let seen = try #require(VaultStubURLProtocol.seen.first)
    #expect(seen.method == "PUT")
    #expect(seen.url.path() == "/v1/sys/leases/renew")
    #expect(seen.headers["X-Vault-Token"] == Self.token)
    let body = try bodyObject(seen)
    #expect(body["lease_id"] as? String == Self.leaseID)
    #expect(body["increment"] as? Int == 300)
  }

  @Test("Revoke is a PUT with the lease id and token, and a 204 with no body succeeds")
  func revokeRequest() async throws {
    VaultStubURLProtocol.reset { _ in .respond(status: 204, body: Data()) }
    try await client().revokeLease(id: Self.leaseID, token: Self.token)
    let seen = try #require(VaultStubURLProtocol.seen.first)
    #expect(VaultStubURLProtocol.seen.count == 1)
    #expect(seen.method == "PUT")
    #expect(seen.url.path() == "/v1/sys/leases/revoke")
    #expect(seen.headers["X-Vault-Token"] == Self.token)
    #expect(try bodyObject(seen).keys.sorted() == ["lease_id"])
  }

  @Test("Revoke-self is a POST with the token, and a 204 with no body succeeds")
  func revokeSelfRequest() async throws {
    VaultStubURLProtocol.reset { _ in .respond(status: 204, body: Data()) }
    try await client().revokeSelf(token: Self.token)
    let seen = try #require(VaultStubURLProtocol.seen.first)
    #expect(VaultStubURLProtocol.seen.count == 1)
    #expect(seen.method == "POST")
    #expect(seen.url.path() == "/v1/auth/token/revoke-self")
    #expect(seen.headers["X-Vault-Token"] == Self.token)
  }

  @Test("Requests go to the address rebuilt from its checked scheme, host, port and path")
  func rebuiltAddress() async throws {
    VaultStubURLProtocol.reset { _ in .respond(status: 204, body: Data()) }
    try await client(source(address: " HTTPS://Vault.Example.COM:8443/prefix ")).revokeLease(
      id: Self.leaseID, token: Self.token)
    let seen = try #require(VaultStubURLProtocol.seen.first)
    #expect(seen.url.scheme == "https")
    #expect(seen.url.host() == "vault.example.com")
    #expect(seen.url.port == 8443)
    #expect(seen.url.path() == "/prefix/v1/sys/leases/revoke")
  }

  @Test("AppRole login, renew-self and lookup-self send and parse Vault's shapes")
  func authCalls() async throws {
    VaultStubURLProtocol.reset { request in
      switch request.url?.path() {
      case "/v1/auth/approle/login", "/v1/auth/token/renew-self":
        return .respond(
          status: 200,
          body: Self.json(
            """
            {"auth":{"client_token":"\(Self.token)","accessor":"a","lease_duration":120,
             "renewable":true,"token_type":"service","orphan":true},"data":null}
            """))
      default:
        return .respond(
          status: 200,
          body: Self.json(
            """
            {"data":{"ttl":300,"expire_time":"2026-10-29T12:34:56.123456789Z","period":300,
             "renewable":true,"explicit_max_ttl":0}}
            """))
      }
    }
    let client = try client()
    let login = try await client.appRoleLogin(roleID: "role-1234", secretID: "secret-5678")
    #expect(login == VaultAuth(clientToken: Self.token, duration: 120, renewable: true))
    let renewed = try await client.renewSelf(increment: 240, token: Self.token)
    #expect(renewed.duration == 120)
    let info = try await client.lookupSelf(token: Self.token)
    #expect(info.ttl == 300)
    #expect(info.period == 300)
    #expect(info.renewable)
    #expect(info.expireTime == ISO8601DateFormatter().date(from: "2026-10-29T12:34:56Z"))

    let seen = VaultStubURLProtocol.seen
    #expect(seen.map(\.method) == ["POST", "POST", "GET"])
    #expect(
      seen.map { $0.url.path() }
        == ["/v1/auth/approle/login", "/v1/auth/token/renew-self", "/v1/auth/token/lookup-self"])
    #expect(seen[0].headers["X-Vault-Token"] == nil)
    let loginBody = try bodyObject(seen[0])
    #expect(loginBody["role_id"] as? String == "role-1234")
    #expect(loginBody["secret_id"] as? String == "secret-5678")
    #expect(seen[1].headers["X-Vault-Token"] == Self.token)
    #expect(try bodyObject(seen[1])["increment"] as? Int == 240)
  }

  @Test("A dev root token's lookup-self has no expiry")
  func rootLookup() async throws {
    VaultStubURLProtocol.reset { _ in
      .respond(
        status: 200,
        body: Self.json(
          #"{"data":{"ttl":0,"expire_time":null,"renewable":false,"policies":["root"]}}"#))
    }
    let info = try await client().lookupSelf(token: Self.token)
    #expect(info == VaultTokenInfo(ttl: 0, expireTime: nil, renewable: false, period: nil))
  }

  @Test("Remote http, credentials in the address and path tricks are refused before any request")
  func unsafeAddressesRefused() throws {
    VaultStubURLProtocol.reset { _ in .respond(status: 200, body: Data()) }
    let refused: [(VaultSource, VaultClientError)] = [
      (source(address: "http://vault.example.com:8200"), .insecureAddress),
      (source(address: "http://192.168.64.1:8200"), .insecureAddress),
      (source(address: "http://10.0.0.5"), .insecureAddress),
      (source(address: "ftp://vault.example.com"), .insecureAddress),
      (source(address: "https://user:pw@vault.example.com"), .credentialsInAddress),
      (source(address: "https://vault.example.com/?x=1"), .invalidAddress),
      (source(address: ""), .invalidAddress),
      (source(mount: "../sys"), .invalidPath),
      (source(mount: "database", role: "ro?x=1"), .invalidPath),
      (source(role: ""), .invalidPath),
      (source(mount: "sys"), .reservedMount),
      (source(mount: "auth/token"), .reservedMount),
      (source(mount: "Identity"), .reservedMount),
    ]
    for (source, expected) in refused {
      #expect(throws: expected) { _ = try client(source) }
    }
    var badCA = source()
    badCA.caPEM = "not a certificate"
    #expect(throws: VaultClientError.invalidCA) { _ = try client(badCA) }
    #expect(VaultStubURLProtocol.seen.isEmpty)

    for address in ["http://127.0.0.1:8200", "http://localhost:8200", "http://[::1]:8200"] {
      #expect((try? client(source(address: address))) != nil)
    }
  }

  @Test("Error text never carries the token, role id or secret id")
  func secretsNeverInErrors() async throws {
    let roleID = "role-id-7f3a9c"
    let secretID = "secret-id-2b8e1d"
    VaultStubURLProtocol.reset { request in
      let echoed =
        request.url?.path() == "/v1/auth/approle/login"
        ? "invalid role ID \(roleID) or secret ID \(secretID)"
        : "2 errors occurred:\n\t* permission denied\n\t* invalid token \(Self.token)\n\n"
      let status = request.url?.path() == "/v1/auth/approle/login" ? 400 : 403
      let body = try! JSONSerialization.data(withJSONObject: ["errors": [echoed]])
      return .respond(status: status, body: body)
    }
    let client = try client()

    let renew = await #expect(throws: VaultClientError.self) {
      _ = try await client.renewLease(id: Self.leaseID, increment: nil, token: Self.token)
    }
    let renewError = try #require(renew)
    #expect(renewError.isForbidden)
    #expect(!renewError.isLeaseGone)
    let renewText = renewError.localizedDescription + String(describing: renewError)
    #expect(!renewText.contains(Self.token))
    #expect(renewText.contains("permission denied"))

    let login = await #expect(throws: VaultClientError.self) {
      _ = try await client.appRoleLogin(roleID: roleID, secretID: secretID)
    }
    let loginText = try #require(login).localizedDescription + String(describing: login)
    #expect(!loginText.contains(roleID))
    #expect(!loginText.contains(secretID))
  }

  @Test("A 400 lease not found or invalid lease is a gone lease; other 400s are not")
  func leaseGoneClassification() async throws {
    for (message, gone) in [
      ("lease not found", true), ("invalid lease", true), ("lease is not renewable", false),
    ] {
      VaultStubURLProtocol.reset { _ in
        .respond(
          status: 400,
          body: try! JSONSerialization.data(withJSONObject: ["errors": [message]]))
      }
      let error = await #expect(throws: VaultClientError.self) {
        _ = try await client().renewLease(id: Self.leaseID, increment: nil, token: Self.token)
      }
      #expect(try #require(error) == .http(status: 400, errors: [message]))
      #expect(error?.isLeaseGone == gone)
    }
  }

  @Test("A 307 on renew and on AppRole login is refused: one request, the redirect error")
  func redirectRefused() async throws {
    let elsewhere = try #require(URL(string: "https://attacker.example.net/v1/x"))
    VaultStubURLProtocol.reset { _ in .redirect(status: 307, to: elsewhere) }
    let client = try client()
    await #expect(throws: VaultClientError.redirect) {
      _ = try await client.renewLease(id: Self.leaseID, increment: nil, token: Self.token)
    }
    #expect(VaultStubURLProtocol.seen.count == 1)

    VaultStubURLProtocol.reset { _ in .redirect(status: 307, to: elsewhere) }
    await #expect(throws: VaultClientError.redirect) {
      _ = try await client.appRoleLogin(roleID: "role-1234", secretID: "secret-5678")
    }
    #expect(VaultStubURLProtocol.seen.count == 1)
    #expect(VaultClientError.redirect.localizedDescription.contains("active node's address"))
  }
}

/// URLProtocol stub for the Vault client. State is static: the suite is `.serialized`.
private final class VaultStubURLProtocol: URLProtocol, @unchecked Sendable {
  enum Reply: Sendable {
    case respond(status: Int, body: Data)
    /// A 3xx to this URL. After telling the client, the stub still delivers the 3xx and
    /// finishes, as a server does once the redirect is refused; a followed redirect starts a
    /// new load (a second request).
    case redirect(status: Int, to: URL)
  }

  struct Seen: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?
  }

  typealias Handler = @Sendable (URLRequest) -> Reply

  private nonisolated(unsafe) static var storedHandler: Handler?
  private nonisolated(unsafe) static var storedSeen: [Seen] = []
  private static let lock = NSLock()

  /// Every request since the last reset, in order
  static var seen: [Seen] { lock.withLock { storedSeen } }

  static func reset(_ handler: @escaping Handler) {
    lock.withLock {
      storedHandler = handler
      storedSeen = []
    }
  }

  static func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VaultStubURLProtocol.self]
    return configuration
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let handler = Self.lock.withLock({ Self.storedHandler }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let seen = Seen(
      method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:],
      body: request.httpBody ?? request.httpBodyStream.map(Self.readAll))
    Self.lock.withLock { Self.storedSeen.append(seen) }
    switch handler(request) {
    case .respond(let status, let body):
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    case .redirect(let status, let target):
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Location": target.absoluteString])!
      var next = request
      next.url = target
      client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}

  private static func readAll(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
