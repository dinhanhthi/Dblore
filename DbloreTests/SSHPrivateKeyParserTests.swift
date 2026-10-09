// SSHPrivateKeyParserTests.swift
// Inline throwaway keys generated once with ssh-keygen (OpenSSH 10.3) and openssl; they never
// protect anything. Expected fingerprints are `ssh-keygen -lf` output for the same keys.

import Foundation
import NIOSSH
import Testing

@testable import Dblore

struct SSHPrivateKeyParserTests {
  struct Expected: Sendable, CustomTestStringConvertible {
    let name: String
    let pem: String
    let algorithm: String
    let fingerprint: String
    let comment: String

    var testDescription: String { name }
  }

  static let rsaMessage =
    "RSA keys are not supported; use an ed25519 or ECDSA key (ssh-keygen -t ed25519)"
  static let encryptedPEMMessage =
    "encrypted PEM keys are not supported; convert with ssh-keygen -p -f key"

  static let unencrypted: [Expected] = [
    Expected(
      name: "openssh ed25519", pem: Fixtures.ed25519, algorithm: "ssh-ed25519",
      fingerprint: "SHA256:9ulJ9dylfq2c4xbA1GreqvEcDo+Qj6YNmzKiEP+Ed3Y",
      comment: "dblore-test-ed25519"),
    Expected(
      name: "openssh P-256", pem: Fixtures.p256, algorithm: "ecdsa-sha2-nistp256",
      fingerprint: "SHA256:YrX3wqDt+RL4RyHEvqr/WonsJX/X//UmznB+SfVXb4g",
      comment: "dblore-test-p256"),
    Expected(
      name: "openssh P-384", pem: Fixtures.p384, algorithm: "ecdsa-sha2-nistp384",
      fingerprint: "SHA256:AYeY3lDJSmjUq4iWeNm0qbS+A+ZlQegIaHm5USJzoF4",
      comment: "dblore-test-p384"),
    Expected(
      name: "openssh P-521", pem: Fixtures.p521, algorithm: "ecdsa-sha2-nistp521",
      fingerprint: "SHA256:Px/IjadbAJfvARyhM+4TLfF2DEl0hPThOwWWrCS1Dl0",
      comment: "dblore-test-p521"),
    Expected(
      name: "PEM SEC1 P-256", pem: Fixtures.p256SEC1, algorithm: "ecdsa-sha2-nistp256",
      fingerprint: "SHA256:z5Af9McGzG3by8k+XVB6T/31CBE65wb5BK+V3ZYAuJs", comment: ""),
    Expected(
      name: "PEM SEC1 P-256 explicit parameters", pem: Fixtures.p256SEC1ExplicitParameters,
      algorithm: "ecdsa-sha2-nistp256",
      fingerprint: "SHA256:0Ev2/+iga7+2NLM5YJkTnF/DE+8yc5+nQKFRKI0hH9M", comment: ""),
    Expected(
      name: "PEM PKCS#8 P-256", pem: Fixtures.p256PKCS8, algorithm: "ecdsa-sha2-nistp256",
      fingerprint: "SHA256:/bCMoq5pODu+3oY/mznpF0i0e/RK/Hm7gAfQ+GSNVzQ", comment: ""),
  ]

  private static func parse(_ pem: String, passphrase: String? = nil) throws -> ParsedSSHKey {
    try SSHPrivateKeyParser.parse(Data(pem.utf8), passphrase: passphrase)
  }

  @Test(arguments: unencrypted)
  func parsesUnencryptedKey(_ expected: Expected) throws {
    let key = try Self.parse(expected.pem, passphrase: "ignored for unencrypted keys")
    #expect(key.algorithm == expected.algorithm)
    #expect(key.fingerprint == expected.fingerprint)
    #expect(key.comment == expected.comment)
  }

  @Test func decryptsEncryptedEd25519WithPassphrase() throws {
    let key = try Self.parse(Fixtures.ed25519Encrypted, passphrase: "dblore-test-pass")
    #expect(key.algorithm == "ssh-ed25519")
    #expect(key.fingerprint == "SHA256:mbX+D1WUPnKOhPRdP4PPx1LI0oSDw2+mvazOgb2AIoc")
    #expect(key.comment == "dblore-test-ed25519-enc")
  }

  @Test func wrongPassphraseIsReported() {
    #expect(throws: SSHPrivateKeyError.wrongPassphrase) {
      try Self.parse(Fixtures.ed25519Encrypted, passphrase: "not-the-passphrase")
    }
  }

  @Test(arguments: [nil, ""] as [String?])
  func missingPassphraseIsReported(_ passphrase: String?) {
    #expect(throws: SSHPrivateKeyError.passphraseRequired) {
      try Self.parse(Fixtures.ed25519Encrypted, passphrase: passphrase)
    }
  }

  @Test(arguments: [Fixtures.rsa, Fixtures.rsaEncrypted, Fixtures.rsaPEM, Fixtures.rsaPKCS8])
  func rsaKeysAreRejectedWithClearMessage(_ pem: String) {
    let error = #expect(throws: SSHPrivateKeyError.rsaNotSupported) { try Self.parse(pem) }
    #expect(error?.errorDescription == Self.rsaMessage)
  }

  @Test(arguments: [Fixtures.p256SEC1Encrypted, Fixtures.p256PKCS8Encrypted])
  func encryptedPEMIsUnsupported(_ pem: String) {
    #expect(throws: SSHPrivateKeyError.unsupportedFormat(Self.encryptedPEMMessage)) {
      try Self.parse(pem, passphrase: "pempass")
    }
  }

  /// Cuts the decoded key at fixed offsets and re-armors it, so every length field in the
  /// binary format gets exercised against a short buffer.
  @Test(arguments: [Fixtures.ed25519, Fixtures.ed25519Encrypted, Fixtures.p521])
  func truncatedKeyIsMalformed(_ pem: String) throws {
    let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
    let decoded = try #require(Data(base64Encoded: body))
    for length in [0, 1, 14, 15, 20, 30, 45, 60, 100, 150, 200, decoded.count - 1] {
      let armored =
        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        + decoded.prefix(length).base64EncodedString(options: .lineLength64Characters)
        + "\n-----END OPENSSH PRIVATE KEY-----\n"
      #expect(Self.isMalformed { try Self.parse(armored, passphrase: "dblore-test-pass") })
    }
  }

  @Test func garbageIsMalformed() {
    let inputs: [Data] = [
      Data(),
      Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }),
      Data("hello".utf8),
      Data(String(Fixtures.ed25519.dropLast(40)).utf8),
      Data("-----BEGIN OPENSSH PRIVATE KEY-----\n!!!!\n-----END OPENSSH PRIVATE KEY-----".utf8),
      Data("-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----".utf8),
    ]
    for input in inputs {
      #expect(Self.isMalformed { try SSHPrivateKeyParser.parse(input, passphrase: nil) })
    }
  }

  @Test(arguments: unencrypted)
  func restoreRoundTripsStoredKey(_ expected: Expected) throws {
    let parsed = try Self.parse(expected.pem)
    let restored = try SSHPrivateKeyParser.restore(from: parsed.keychainRepresentation)
    #expect(restored.algorithm == expected.algorithm)
    #expect(restored.fingerprint == expected.fingerprint)
    #expect(SSHTunnel.fingerprint(of: restored.privateKey.publicKey) == expected.fingerprint)
  }

  @Test func restoreRejectsGarbage() {
    let stored = try? Self.parse(Fixtures.ed25519).keychainRepresentation
    for input in [Data(), Data("junk".utf8), stored.map { $0.dropLast() } ?? Data()] {
      #expect(Self.isMalformed { try SSHPrivateKeyParser.restore(from: Data(input)) })
    }
  }

  // MARK: - Tampered openssh-key-v1 files

  /// Content ranges of the header strings, in file order: cipher, kdf, kdfOptions, public
  /// blob, private section. Each string's uint32 length sits just before its range.
  private static func fields(_ bytes: [UInt8]) throws -> [Range<Int>] {
    var offset = 15  // "openssh-key-v1\0"
    var ranges: [Range<Int>] = []
    func next() throws -> Range<Int> {
      let length = try #require(
        bytes.count >= offset + 4
          ? bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } : nil)
      defer { offset += 4 + length }
      return offset + 4..<offset + 4 + length
    }
    for _ in 0..<3 { ranges.append(try next()) }
    offset += 4  // number of keys
    for _ in 0..<2 { ranges.append(try next()) }
    return ranges
  }

  private static func decode(_ pem: String) throws -> [UInt8] {
    let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
    return Array(try #require(Data(base64Encoded: body)))
  }

  private static func armor(_ bytes: [UInt8]) -> String {
    "-----BEGIN OPENSSH PRIVATE KEY-----\n"
      + Data(bytes).base64EncodedString(options: .lineLength64Characters)
      + "\n-----END OPENSSH PRIVATE KEY-----\n"
  }

  private static func uint32(_ value: Int) -> [UInt8] {
    [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
  }

  @Test func tooManyBcryptRoundsIsUnsupported() throws {
    var bytes = try Self.decode(Fixtures.ed25519Encrypted)
    let options = try Self.fields(bytes)[2]
    bytes.replaceSubrange(options.upperBound - 4..<options.upperBound, with: Self.uint32(1001))
    #expect(
      throws: SSHPrivateKeyError.unsupportedFormat(
        "keys protected with more than 1000 bcrypt rounds are not supported; "
          + "re-encrypt with ssh-keygen -p -a 100 -f key")
    ) { try Self.parse(Self.armor(bytes), passphrase: "dblore-test-pass") }
  }

  @Test func longBcryptSaltIsUnsupported() throws {
    var bytes = try Self.decode(Fixtures.ed25519Encrypted)
    let options = try Self.fields(bytes)[2]
    let salt = Self.uint32(65) + [UInt8](repeating: 7, count: 65)
    let replacement = salt + Self.uint32(16)
    bytes.replaceSubrange(
      options.lowerBound - 4..<options.upperBound,
      with: Self.uint32(replacement.count) + replacement)
    #expect(
      throws: SSHPrivateKeyError.unsupportedFormat(
        "bcrypt salts longer than 64 bytes are not supported; re-encrypt with ssh-keygen -p -f key")
    ) { try Self.parse(Self.armor(bytes), passphrase: "dblore-test-pass") }
  }

  @Test func unknownCipherIsUnsupported() throws {
    var bytes = try Self.decode(Fixtures.ed25519Encrypted)
    let cipher = try Self.fields(bytes)[0]
    bytes.replaceSubrange(cipher, with: Array("aes256-cbc".utf8))
    #expect(throws: SSHPrivateKeyError.unsupportedCipher("aes256-cbc")) {
      try Self.parse(Self.armor(bytes), passphrase: "dblore-test-pass")
    }
  }

  /// Single-byte edits to the unencrypted ed25519 fixture, each caught by its own check.
  @Test(arguments: [
    ("public blob", "public key does not match private key"),
    ("check int", "check values differ"),
    ("padding", "bad padding"),
  ])
  func tamperedFieldIsMalformed(_ field: String, _ reason: String) throws {
    var bytes = try Self.decode(Fixtures.ed25519)
    let fields = try Self.fields(bytes)
    let index =
      switch field {
      case "public blob": fields[3].upperBound - 1
      case "check int": fields[4].lowerBound
      default: fields[4].upperBound - 1
      }
    bytes[index] ^= 0x01
    #expect(throws: SSHPrivateKeyError.malformed(reason)) {
      try Self.parse(Self.armor(bytes))
    }
  }

  @Test func trailingBytesAfterPrivateSectionAreMalformed() throws {
    let bytes = try Self.decode(Fixtures.ed25519) + [0]
    #expect(throws: SSHPrivateKeyError.malformed("trailing data")) {
      try Self.parse(Self.armor(bytes))
    }
  }

  @Test func oversizedKeyFileIsMalformed() {
    #expect(throws: SSHPrivateKeyError.malformed("key file is too large")) {
      try SSHPrivateKeyParser.parse(Data(count: (1 << 20) + 1), passphrase: nil)
    }
  }

  private static func isMalformed(_ body: () throws -> ParsedSSHKey) -> Bool {
    do {
      _ = try body()
      return false
    } catch SSHPrivateKeyError.malformed {
      return true
    } catch {
      return false
    }
  }
}

enum Fixtures {
  static let ed25519 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACCf8eydD3SqXP9xidB7YUEiNsIF0Jeg9gvbV55N/VQa7wAAAJiM9j3ZjPY9
    2QAAAAtzc2gtZWQyNTUxOQAAACCf8eydD3SqXP9xidB7YUEiNsIF0Jeg9gvbV55N/VQa7w
    AAAEAtZ1oLf3PSZcR3aF6LcX7wIrMXjxKuhQ32WDcHdAAHgp/x7J0PdKpc/3GJ0HthQSI2
    wgXQl6D2C9tXnk39VBrvAAAAE2RibG9yZS10ZXN0LWVkMjU1MTkBAg==
    -----END OPENSSH PRIVATE KEY-----
    """

  static let ed25519Encrypted = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBmDBhs86
    yQ4rOkTw2aYUUQAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIOCGvaRIQu6kUP10
    IDJ/Q5MjHwviIzOn9rCKAE1RR+uyAAAAoDr1pUcsNRGglDuJVn6Ds51x8xb954NpOVKu4D
    WNiK7U/uiD00Dz6UOUgUbJjOCQcq+xja5DXufIco8OFlcRVjl/Hb26t9LeRvQuSrxv2AGU
    0obUQZaelvAz2zgzvwHYR6kWmb7GdIlKhkwG5wFRtLvkiaCkAQSA63wQh+WIuaWGUA5brg
    bfd2z3xI60Xqnrp3dVxJic4sQqb6o3jPkLQdg=
    -----END OPENSSH PRIVATE KEY-----
    """

  static let p256 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
    1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQTR0f93x1EUqvDOeTHxb7flri48wjdm
    v37wIhhdq0HaMwfYLIdxQVsfr+Yt6l3dADAYJ2A5CP/jcGSLP7Z1SIYrAAAAsHXzHKJ18x
    yiAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBNHR/3fHURSq8M55
    MfFvt+WuLjzCN2a/fvAiGF2rQdozB9gsh3FBWx+v5i3qXd0AMBgnYDkI/+NwZIs/tnVIhi
    sAAAAhANvzTxn8N+2wKJ4eIdz9U74xJ9bKfYYqmoBC/QZf9zCCAAAAEGRibG9yZS10ZXN0
    LXAyNTYBAgMEBQYH
    -----END OPENSSH PRIVATE KEY-----
    """

  static let p384 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAiAAAABNlY2RzYS
    1zaGEyLW5pc3RwMzg0AAAACG5pc3RwMzg0AAAAYQRnaklTNSn92K3cDBoQLDBvjBlQDHZw
    DKX3DfY4ATU3LCVmbmqnK1wm3VGwz5pZwoUOf+KGjA8tXDXPjH1qBAJ4SqxtUI5s30+0QS
    5h2qjU0sMz/iBaORriJuHQWWHV+gMAAADYMcYeeDHGHngAAAATZWNkc2Etc2hhMi1uaXN0
    cDM4NAAAAAhuaXN0cDM4NAAAAGEEZ2pJUzUp/dit3AwaECwwb4wZUAx2cAyl9w32OAE1Ny
    wlZm5qpytcJt1RsM+aWcKFDn/ihowPLVw1z4x9agQCeEqsbVCObN9PtEEuYdqo1NLDM/4g
    Wjka4ibh0Flh1foDAAAAMBhggf8IaVB+3j5laFdGCkFR9T8lKKRFye+FVx+3HDNW6t21yD
    gtAXrblxHBL6Cp5QAAABBkYmxvcmUtdGVzdC1wMzg0
    -----END OPENSSH PRIVATE KEY-----
    """

  static let p521 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAArAAAABNlY2RzYS
    1zaGEyLW5pc3RwNTIxAAAACG5pc3RwNTIxAAAAhQQBVxFjYOIlf69COBPZhQAn4neTXcNe
    t5BLlpxvGEU9mxuxxX6UO99ZRDErb8BeTHx9yG9F52Ns+uP7ltvBztWQCP8BYzQr9T3omv
    uhdplhrSjwijgd5s6kI/FCOFrsJipMu7yF97QYhucr3bHT6f8YYr4Ekulngq3B4xsOFtyS
    wjH3THoAAAEQ/L0Btvy9AbYAAAATZWNkc2Etc2hhMi1uaXN0cDUyMQAAAAhuaXN0cDUyMQ
    AAAIUEAVcRY2DiJX+vQjgT2YUAJ+J3k13DXreQS5acbxhFPZsbscV+lDvfWUQxK2/AXkx8
    fchvRedjbPrj+5bbwc7VkAj/AWM0K/U96Jr7oXaZYa0o8Io4HebOpCPxQjha7CYqTLu8hf
    e0GIbnK92x0+n/GGK+BJLpZ4KtweMbDhbcksIx90x6AAAAQgHl7D40K0k7s9KnjQ79ZZc1
    Hd92MczL7qZDgD5modUPV0wR6/X9elwdkipjFuywx9wn0ONfI/kxKhbcjlbRH2dphwAAAB
    BkYmxvcmUtdGVzdC1wNTIxAQI=
    -----END OPENSSH PRIVATE KEY-----
    """

  static let p256SEC1 = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIJag4wWjbuex9MKg5DN7Yqkmlp/G0+OYPMAwUMOH83kqoAoGCCqGSM49
    AwEHoUQDQgAElDEIhwrWCmXvrdcPObWWVwDOXzM1JzyZCbWS6AjrsWLlasgk41Ag
    v/1x/ECnDgE3bbYSoNCzzWoLiLQ/5r4nug==
    -----END EC PRIVATE KEY-----
    """

  static let p256SEC1ExplicitParameters = """
    -----BEGIN EC PRIVATE KEY-----
    MIIBaAIBAQQggdjztYpMk07MZ3n7uQEY5cW4HOA5P0s5r1jfiO4rlQKggfowgfcC
    AQEwLAYHKoZIzj0BAQIhAP////8AAAABAAAAAAAAAAAAAAAA////////////////
    MFsEIP////8AAAABAAAAAAAAAAAAAAAA///////////////8BCBaxjXYqjqT57Pr
    vVV2mIa8ZR0GsMxTsPY7zjw+J9JgSwMVAMSdNgiG5wSTamZ44ROdJreBn36QBEEE
    axfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n60p8D54W
    K84zV2sxXs7LtkBoN79R9QIhAP////8AAAAA//////////+85vqtpxeehPO5ysL8
    YyVRAgEBoUQDQgAE4vgaRItoty82a+lEScVX/wFfhVO5hak/w2yHdDPbJgEheOa+
    7QG8m78tacZAJu+/RGf/Mcoz0ZOR5yGgsQv5Ig==
    -----END EC PRIVATE KEY-----
    """

  static let p256PKCS8 = """
    -----BEGIN PRIVATE KEY-----
    MIIBeQIBADCCAQMGByqGSM49AgEwgfcCAQEwLAYHKoZIzj0BAQIhAP////8AAAAB
    AAAAAAAAAAAAAAAA////////////////MFsEIP////8AAAABAAAAAAAAAAAAAAAA
    ///////////////8BCBaxjXYqjqT57PrvVV2mIa8ZR0GsMxTsPY7zjw+J9JgSwMV
    AMSdNgiG5wSTamZ44ROdJreBn36QBEEEaxfR8uEsQkf4vOblY6RA8ncDfYEt6zOg
    9KE5RdiYwpZP40Li/hp/m47n60p8D54WK84zV2sxXs7LtkBoN79R9QIhAP////8A
    AAAA//////////+85vqtpxeehPO5ysL8YyVRAgEBBG0wawIBAQQgjmZyMPqlrAnt
    PbFnQTvm9YszpwmZQLtvto1AKPWI4GyhRANCAAQROknVs6Lv1MmtL88fxQ0Ka9Bn
    5iSux7F9cFj0cr23eDlnwlgI55zbLcfXiPF4HaanrZnonqsWzuDQBlJqgZEB
    -----END PRIVATE KEY-----
    """

  static let p256SEC1Encrypted = """
    -----BEGIN EC PRIVATE KEY-----
    Proc-Type: 4,ENCRYPTED
    DEK-Info: AES-128-CBC,625E943422979A35E1A2DCF503425FE1

    x/6ILT4IIx0ScjsJ77mEB4bIpjX6rYQFSbhcuzfoho9Dd2BL1G9wkWpC5IcNoZLy
    6dwhznt/W70WET+ycBHB4JoYHezqnv+yrhXZh1ONZH0GrUYOOlFmo8F/ODKzDb28
    lysTA9ZZx/CYczv8zAEgaXsW74bi080Bc5WmZ5xdTUVNVTIWi7RGcRU66VNuiwT8
    Pe92ounmrqRingx/VBTFRpQO3ugpGsBsyJwJ4c1D0XEvvq8u3KZkHzLEsnvMQSvY
    OCvOaoV3FYDsgIpCdrLv6efcOfZOJ7fZ/t6AI1oMQQFmzL1t5oIU1TD1zsM6IEvD
    NwClLzb1dnnOGMaZf0cXS6Lwq7HHgIQ35HuvMAbYQwMrPIQjWfLBBKd/dkV9wY7R
    IbBddJ8grH/IJKYENT7QK0yNPmsqGHSp6SZEbnw9+vvkWrkomZ6T11saH2eNjtzr
    C3YsiyiNAn8W2k+w3YSbYeNJcgwhP7ehe9ygz6poZCc=
    -----END EC PRIVATE KEY-----
    """

  static let p256PKCS8Encrypted = """
    -----BEGIN ENCRYPTED PRIVATE KEY-----
    MIIBzzBJBgkqhkiG9w0BBQ0wPDAbBgkqhkiG9w0BBQwwDgQIe8eRwrZZDT8CAggA
    MB0GCWCGSAFlAwQBAgQQJf0P+CRjX3qe7SY4ptFfKASCAYB2GutLgFbYJ9lKWnnT
    wxrujAWZSDkRTU56FRgN9/eK2FaRThr23y+MUCLvED/TUkzcHiREWUr7PSpg7/Za
    xQGbtRWNAW7JlvQ5ZnPDyuoQwCAWSI4suMyqmHLV0vsWSCcLEuiydWLiA19wnXcv
    8tVRRZImBe2mgPLek19eSBUHkvkhrH94pnc/7TG/KZir8lSF1Ar4hpPx2/Nb5dzA
    SJTB6HE0mE+YkiBOnmsKhkO4k09MgfJXHdOdnxsyO2AVW1EdEdoVqpJMkdNhrkyK
    cyHLLN3loMVguPXfsF/O3cEtubFyoJVknREXdNXIrBUn/JYhwfdjvk+S7/GB0X2L
    zEQLeWCL8El8vaAfaY8ZfqqtT1h5C2uskW/WxPYB/OS5DffAbCFAwMg93B5oZ16f
    0kel2/ETJpVKXQDOLBK5wtCcTLeCr2WUKgOI5hhJoCAQTlvOfqVtSOnmIqGl606H
    ptjYLteuaP1zGeooo1E08I9OwfOaolpqRcgmAmUPdSQSkJw=
    -----END ENCRYPTED PRIVATE KEY-----
    """

  static let rsa = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAlwAAAAdzc2gtcn
    NhAAAAAwEAAQAAAIEA08LG3kQEztExHw/paV7C54D/BKnoaFX3+/ikHzZYOHnDI4qQsCvL
    x6ALPOLwMA6cszMxMVweBaZrfNmqPRP3q9WHBduHe9diMt/UdcWt0JNzbOYzbJl4R99lBg
    wfkxq+rLpCsB1zvxVIVYkF85KtMjVgEA3dLUCWagHqGX9hrLsAAAIIn7QkQ5+0JEMAAAAH
    c3NoLXJzYQAAAIEA08LG3kQEztExHw/paV7C54D/BKnoaFX3+/ikHzZYOHnDI4qQsCvLx6
    ALPOLwMA6cszMxMVweBaZrfNmqPRP3q9WHBduHe9diMt/UdcWt0JNzbOYzbJl4R99lBgwf
    kxq+rLpCsB1zvxVIVYkF85KtMjVgEA3dLUCWagHqGX9hrLsAAAADAQABAAAAgB6dg2jxBo
    zsG6D1CPbt91nHAZeoBOzIuRCZ0wicL8cCe57w0phVzKFw1w8XdEhOZINX/F25hrGkbNfh
    FEa+U0kmEkSXBmjMz+ykKkSdzwQ0vVUUFiUOWflgbIQ6ye3TkTS7s7oSGCK1D4BT7eUg2k
    +okY1mcC74a/UPXO4/l5ThAAAAQQDB+iG2Th7ZsjuWWy3w4xIoOx+M06diV5TDQytFZkre
    mgULWJMAT9NUkXoiOUXNR7vMFN+YVBMAXHnaehZFOQOyAAAAQQD7LFZ70WkA4vobUu0+97
    4rC/bg50QTMBHycybvxzx2r7KX9eIYH4cphuuclQSuJh1einQqsmNC0AVVs2OFu4CLAAAA
    QQDX1IwpMB7ovetbdevYEuFEkCffOPG+pEwEE1RqqtYS1VasuvAtT4yzF5eZpolIdQTttp
    6d0m12titNyM9pl1qRAAAAD2RibG9yZS10ZXN0LXJzYQECAw==
    -----END OPENSSH PRIVATE KEY-----
    """

  static let rsaEncrypted = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCdWRnnfE
    VOnV6Dcb6jFJcTAAAABAAAAAEAAACXAAAAB3NzaC1yc2EAAAADAQABAAAAgQC52ic8Xaxe
    wgMWFUpM3l6UYUuwPBsUJVh/hQNwzW7NQLlL8okvRrIznRb4Y331I7ivI8EOetNnPuSiMR
    kCJU76UCKdGBAmqcYNaXJlgahjpGR8XwcBNgSZtkgLhU7beIRPLg6/soCQvJOtryhTtNql
    71nfvgk+CY7yxdRsriOoHwAAAgDlrI4mQafTPIxBaiPY5PQi8zDHAzDNgj5QAEPuc3eF3S
    1doCHJVH/JUHPOrFA6WK+aRHIN3DLVJP1xbsHcT6I51wopOZf7QT/t18Rpagt6GzTpayK+
    YBW14iFoBkxhNN4I5kkn29OObgk4SQlrrB3J+Hq0JkqqmHnL/u7rrZmNHUeo6vjf44eiOz
    WyuENztM66gpgEOGsKBqWdXLISmogiiE0V1VMpnHLk+FGA946qioXIj2WvK/2Xl2TkODub
    Wb5OHeEqqtqzIGIOfmWxbP5IV7kS95NafIG9V3Q8rGmBxV9fczc3B6GHxxZvTUHYjIOUSk
    U9Lob+veIGjFbEPvOEkPG8vuksOakWSSSqyS3pSYMQO9eEk5iyrHnZxxkYy0Zx66BGlOmC
    SPqX8K0Nua7OfNP9FtvELoiXUWs8rZW6ls+Sgxb8145UF7g0uyTnTYxlaIRJ/2Hk/PI3xR
    cVh9YoalMslOcyC69e9CPqJtxg9CQT4pxgyOqtEmqJ5Ej6Muqk+jvcmxmss5ZDKoRiu+Re
    rTEyV1BgSrShlxVNhmEmk/iZ5zWgFAGD3V9jXKb2yyj+hNfuroz1ndz36TBR3dFlBI50lY
    GyIs2Z1rS600VBaN1n9I3rIhuDZ5Ib8Ge6xlUr1Z/ZGEHCvrwedD46BAet4LAa7J/X0LPU
    vQ1NvtVVig==
    -----END OPENSSH PRIVATE KEY-----
    """

  static let rsaPEM = """
    -----BEGIN RSA PRIVATE KEY-----
    MIICXgIBAAKBgQDDFPh5Z9qXo81ron09ls7GKbfTIoBbpAqSrLksithgUA4T2rvA
    b5X2NS00zjznoKb+vFl0NGquGBk7x1FJfX0X95YBICHoYJmd05+1DXn0Q+LiHjBR
    mMiMeMZU32m7c4VwpN5Y5WiabEoOqC9zjfFvCtFHBX4EQQujPzZrKn+1dQIDAQAB
    AoGBAILdwoHPBXjMTbVy34k9baDJw6NDddAED4OtktsqmVSi3466IVFKidMMgTL3
    VywbPWuNdoTZ1ObNC8BqSUF/iTYpZcs5N8BzZRdbNPd/ML4L2xQ2B8ArGxwKJqDE
    HKWypOn9mF1n8g7lqW5LG4sW0Jq7Ed3vL3Oc9BRLndtjj6SBAkEA908GO6avu+zv
    XqII05F5GpOy/sjFAsVNvSyo/kAwuVU1HsA2BHEPeIN6Hkk/4Unf8fI4MCpSgsz6
    C6qogPPeKQJBAMnwEyUfO3du02ViLzHq62anP/q+UlEMxr/e1L2cXB/jb5EBKsXb
    wy4knAMfTO6qTGQxhz7miF/kPCanLj0g7m0CQQDQwQvp3lIIt392yh/ZNrqbDIHT
    P3XNWO69+KzNsTFvv9UPGACAz07X02OJnRsm+Ezo1iVHwvHTJ2MJ5gxGjZPBAkEA
    tRlesg3+cK+tWeDh3myFzDv1/tMsU4+Xtn8KXzmYzOhVJ7/aMjNSKVGfsJUjk26a
    r8hTOC/a4dR3tVp890lPSQJASO2n+UGecSszhtd0V8/pSjT7n3zzNS16cSMuowoj
    aW/6MKw2I1vTjXSYNOaR5qdlf6MGEACd6M05slLe5MomzA==
    -----END RSA PRIVATE KEY-----
    """

  static let rsaPKCS8 = """
    -----BEGIN PRIVATE KEY-----
    MIICdwIBADANBgkqhkiG9w0BAQEFAASCAmEwggJdAgEAAoGBALFSRh/y38hGCIEs
    8MdXfkRHuruKwMiXAOsyoGo0UB7GdZ93mJqO1ySFpa3k+lK8ptJAdIXgJHVBfb8R
    mhgBZu6e2AJUjJhVqCaWu8//KgKwdBQCIb+vO5nMhfitofpieTlDhsEBd9TtDyZl
    4aCTQWiktfbPHagj0bkK8VIJhZrZAgMBAAECgYAIXa1ZTIgqVsOH9KrXfNVEO24f
    8wftbtJoRlczK4ysJwjdoTLd9+dGndeXQLpetO/Z85iLyGtv7MsV/Kqcf1Rv0Xcl
    vRPzLfCNEq7kiI4Kz2HCawSjB3jw35NbtlzT95YXTh5riK3/V7Tlkt0KvgfZ7hY5
    xye5rrJ0rUFbCVbiAQJBAOkfXR79DltWIe3jx9PPmGO7HWkHeArVAZrNiKMfqmDU
    GJK+cK0/qJwQD4IviJB5LsEC152UUJGYnjTzQR4fXNECQQDCuQrcqlfQSH7tZoDD
    e0Edpe/o/p9lJfx/hya1WgwUrtLYtksazInmAaIA9DJAKpbKL6fa+Yqz/eA90Fbn
    7b+JAkEAhomBNmcYqAGXZzDzm/vMmJHeMUUMNEQlvu8rEekubN86p0WcxX9dkWN7
    b8h66dXl86HuSZTUwpHvi+NvCzFSYQJACbBlbvd26SFCV5O7In72jYAdQO2yhrju
    KHZUIb/6S+krCqd/czTsQ6qfIgcEnRbBbAwVARtboHsodkrwmBfHaQJBANKiCttM
    Ewm0k6cYaB3jEoHO6eey3VjikuMzE+WyRq9oaToyOfn9Is1I2qDBJmQ65MFG4cg1
    YJSrAGARsgPCcNY=
    -----END PRIVATE KEY-----
    """
}
