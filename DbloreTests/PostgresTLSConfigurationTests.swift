import Foundation
import NIOSSL
import Testing

@testable import Dblore

@MainActor
@Suite("PostgreSQL TLS configuration")
struct PostgresTLSConfigurationTests {
  @Test("Connection metadata round-trips without PEM material")
  func connectionMetadata() throws {
    let info = ClientCertificateInfo(
      subject: "CN=client.test", expiry: Date(timeIntervalSince1970: 1_700_000_000), hasCA: true)
    let config = ConnectionConfig(clientCertificate: info)
    let data = try JSONEncoder().encode(config)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains("CN=client.test"))
    #expect(!text.contains("BEGIN CERTIFICATE"))
    #expect(!text.contains("BEGIN PRIVATE KEY"))
    #expect(try JSONDecoder().decode(ConnectionConfig.self, from: data).clientCertificate == info)

    let legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var withoutCertificate = legacy
    withoutCertificate.removeValue(forKey: "clientCertificate")
    let oldData = try JSONSerialization.data(withJSONObject: withoutCertificate)
    #expect(try JSONDecoder().decode(ConnectionConfig.self, from: oldData).clientCertificate == nil)
  }

  @Test("Client certificate and CA are loaded from inline PEM")
  func clientMaterial() throws {
    let material = ClientCertificateMaterial(
      certificatePEM: Self.certificate,
      privateKeyPEM: Self.privateKey,
      caPEM: Self.certificate)
    let tls = try PostgresSession.tlsConfiguration(sslMode: .verifyFull, material: material)
    #expect(tls.certificateChain.count == 1)
    #expect(tls.privateKey != nil)
    guard case .certificates(let roots) = tls.trustRoots else {
      Issue.record("Expected PEM CA trust roots")
      return
    }
    #expect(roots.count == 1)
    guard case .fullVerification = tls.certificateVerification else {
      Issue.record("verify-full must check the hostname")
      return
    }
    _ = try NIOSSLContext(configuration: tls)
  }

  @Test("Encrypted private key uses the stored passphrase")
  func encryptedKey() throws {
    let material = ClientCertificateMaterial(
      certificatePEM: Self.certificate,
      privateKeyPEM: Self.encryptedPrivateKey,
      passphrase: "fixture-pass")
    let tls = try PostgresSession.tlsConfiguration(sslMode: .require, material: material)
    #expect(tls.privateKey != nil)
    _ = try NIOSSLContext(configuration: tls)
  }

  @Test("verify-ca verifies the chain without hostname verification")
  func verifyCA() throws {
    let ca = ClientCertificateMaterial(
      certificatePEM: Self.certificate, privateKeyPEM: Self.privateKey,
      caPEM: Self.certificate)
    let verifyCA = try PostgresSession.tlsConfiguration(sslMode: .verifyCa, material: ca)
    let verifyFull = try PostgresSession.tlsConfiguration(sslMode: .verifyFull, material: ca)
    guard case .noHostnameVerification = verifyCA.certificateVerification else {
      Issue.record("verify-ca must skip hostname verification")
      return
    }
    guard case .fullVerification = verifyFull.certificateVerification else {
      Issue.record("verify-full must check the hostname")
      return
    }
    let required = try PostgresSession.tlsConfiguration(sslMode: .require, material: nil)
    guard case .fullVerification = required.certificateVerification else {
      Issue.record("require mode must retain its existing verification setting")
      return
    }
  }

  @Test("Open and probe fail before transport when configured certificate is missing")
  func missingMaterial() async {
    let config = ConnectionConfig(
      host: "missing-client-certificate.invalid", database: "db", username: "test",
      sslMode: .require,
      clientCertificate: ClientCertificateInfo(subject: "CN=missing", expiry: nil, hasCA: false))
    for isProbe in [false, true] {
      let session = PostgresSession(config: config)
      do {
        if isProbe { _ = try await session.probe() } else { try await session.open() }
        Issue.record("A connection with missing client material should fail")
      } catch let error as DatabaseError {
        guard case .connectionFailed(let reason) = error else {
          Issue.record("Expected a connection error")
          continue
        }
        #expect(reason.contains("Client certificate is missing"))
      } catch {
        Issue.record("Expected a connection error: \(error)")
      }
    }
  }

  @Test("Connection form extracts display metadata from PEM without retaining bytes")
  func formCertificateMetadata() throws {
    let info = try ConnectionFormContent.certificateInfo(from: Self.certificate, hasCA: true)
    #expect(info.subject.contains("client.test"))
    #expect(info.expiry != nil)
    #expect(info.hasCA)
    let encoded = try #require(String(data: JSONEncoder().encode(info), encoding: .utf8))
    #expect(!encoded.contains("BEGIN CERTIFICATE"))
  }

  private static let certificate = """
    -----BEGIN CERTIFICATE-----
    MIIBgjCCASegAwIBAgIUAklrIK0F2veiAbCErW8IIR+ZS1QwCgYIKoZIzj0EAwIw
    FjEUMBIGA1UEAwwLY2xpZW50LnRlc3QwHhcNMjYxMDA0MTQwNjMwWhcNMjYxMDA1
    MTQwNjMwWjAWMRQwEgYDVQQDDAtjbGllbnQudGVzdDBZMBMGByqGSM49AgEGCCqG
    SM49AwEHA0IABIIXWTq/3uC4Z3xskTXVizF9urCEWVXVp8tyxOvVEQiC+BcTimWD
    c8mszL2Fz/12ngJixTobVvZdJlt80Bs/l2WjUzBRMB0GA1UdDgQWBBQtGYAEI4GY
    0EbttySa29pM7EVk8DAfBgNVHSMEGDAWgBQtGYAEI4GY0EbttySa29pM7EVk8DAP
    BgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQC0XrIbvKvzTcQAgu0y
    IAWvaCI96Cay7ETrVmdVfTE0VwIhALNoktIitpdCRKM+LeLBg7GV3/xGeNM81Vbi
    Awghat2J
    -----END CERTIFICATE-----
    """

  private static let privateKey = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgYFtkXJAH5hZJCwd4
    2df3AfXwthSsYdaA+8sdieUnwcahRANCAASCF1k6v97guGd8bJE11YsxfbqwhFlV
    1afLcsTr1REIgvgXE4plg3PJrMy9hc/9dp4CYsU6G1b2XSZbfNAbP5dl
    -----END PRIVATE KEY-----
    """

  private static let encryptedPrivateKey = """
    -----BEGIN ENCRYPTED PRIVATE KEY-----
    MIH0MF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBDm+zAR5dLHmhZQTnkr
    SVxmAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQvjpnyOP1Am+BXNGS
    HC2+iASBkNSop5IFNcAJJFlz4zXdvT1QgzLujhhVJpSXTq9ZwIZ2melTENNtiXjl
    a1eiwZzSnMfRLvs9jBut/kOEc4fOgjiUKt8SOs2o32BjMMtUXi2h/GOU6f+bkeQR
    2GJNK9jwqk9Y1Vu8fz5iZC/hsx4hPJmz65W2mfJYkSeKd7tzUt9GxO3c+AyH5kHb
    sdN8IOPE9Q==
    -----END ENCRYPTED PRIVATE KEY-----
    """
}
