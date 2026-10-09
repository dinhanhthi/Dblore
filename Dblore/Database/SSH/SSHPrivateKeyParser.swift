// SSHPrivateKeyParser.swift
// Reads a user-supplied private key file into a NIOSSHPrivateKey. Supports openssh-key-v1
// (unencrypted, or aes256-ctr + bcrypt_pbkdf) and unencrypted PEM SEC1 / PKCS#8 ECDSA, for
// ed25519 and ECDSA P-256/384/521. swift-nio-ssh has no RSA type, so RSA keys are rejected.
// The file is untrusted input: every length is bounds-checked and garbage throws, never traps.
// The passphrase is used once to decrypt; only the decrypted key leaves this type.

import CommonCrypto
import CryptoKit
import Foundation
import NIOSSH

nonisolated enum SSHPrivateKeyError: Error, Equatable, LocalizedError {
  case rsaNotSupported
  case passphraseRequired
  case wrongPassphrase
  case unsupportedCipher(String)
  case unsupportedKeyType(String)
  case malformed(String)
  case unsupportedFormat(String)

  // Messages carry only static text and sanitized algorithm names, never key material.
  var errorDescription: String? {
    switch self {
    case .rsaNotSupported:
      "RSA keys are not supported; use an ed25519 or ECDSA key (ssh-keygen -t ed25519)"
    case .passphraseRequired:
      "This private key is encrypted; enter its passphrase."
    case .wrongPassphrase:
      "The passphrase for this private key is incorrect."
    case .unsupportedCipher(let cipher):
      "Private keys encrypted with \(cipher) are not supported; "
        + "re-encrypt with ssh-keygen -p -Z aes256-ctr -f key"
    case .unsupportedKeyType(let type):
      "Unsupported key type \(type); use an ed25519 or ECDSA key (ssh-keygen -t ed25519)"
    case .malformed(let reason):
      "The private key file is malformed: \(reason)."
    case .unsupportedFormat(let message):
      message
    }
  }
}

/// A decrypted private key ready for SSH authentication and Keychain storage.
nonisolated struct ParsedSSHKey: Sendable {
  let privateKey: NIOSSHPrivateKey
  /// SSH algorithm name: "ssh-ed25519" or "ecdsa-sha2-nistp256/384/521".
  let algorithm: String
  /// OpenSSH-style public key fingerprint ("SHA256:..."), as `ssh-keygen -lf` prints it.
  let fingerprint: String
  /// The key comment from an OpenSSH file; empty for PEM files and restored keys.
  let comment: String
  /// Secret. The DECRYPTED key for the Keychain: SSH string(algorithm) || string(raw private
  /// bytes), where the raw bytes are the CryptoKit rawRepresentation (ed25519 seed or ECDSA
  /// scalar). Rebuild with `SSHPrivateKeyParser.restore(from:)`.
  let keychainRepresentation: Data
}

nonisolated enum SSHPrivateKeyParser {
  /// Upper bound on bcrypt_pbkdf rounds, so a hostile file cannot stall the import for hours.
  /// ssh-keygen defaults to 16.
  static let maxBcryptRounds = 1000
  /// OpenSSH writes 16-byte salts; a longer one only makes the KDF slower.
  static let maxBcryptSaltLength = 64
  /// Real key files are a few KiB; anything larger is not a key.
  static let maxKeyFileSize = 1 << 20

  static func parse(_ data: Data, passphrase: String?) throws -> ParsedSSHKey {
    guard data.count <= maxKeyFileSize else {
      throw SSHPrivateKeyError.malformed("key file is too large")
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw SSHPrivateKeyError.malformed("not a text key file")
    }
    if text.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
      return try parseOpenSSH(armoredBody(text, label: "OPENSSH PRIVATE KEY"), passphrase)
    }
    if text.contains("-----BEGIN RSA PRIVATE KEY-----") {
      throw SSHPrivateKeyError.rsaNotSupported
    }
    if text.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----")
      || text.contains("Proc-Type: 4,ENCRYPTED")
    {
      throw SSHPrivateKeyError.unsupportedFormat(
        "encrypted PEM keys are not supported; convert with ssh-keygen -p -f key")
    }
    if text.contains("-----BEGIN EC PRIVATE KEY-----") {
      return try parseSEC1(armoredBody(text, label: "EC PRIVATE KEY"))
    }
    if text.contains("-----BEGIN PRIVATE KEY-----") {
      return try parsePKCS8(armoredBody(text, label: "PRIVATE KEY"))
    }
    if text.contains("-----BEGIN DSA PRIVATE KEY-----") {
      throw SSHPrivateKeyError.unsupportedKeyType("DSA")
    }
    throw SSHPrivateKeyError.malformed("no private key block found")
  }

  /// Rebuilds a key from `ParsedSSHKey.keychainRepresentation`.
  static func restore(from data: Data) throws -> ParsedSSHKey {
    var reader = ByteReader(Array(data))
    let algorithm = String(decoding: try reader.string(), as: UTF8.self)
    var raw = try reader.string()
    defer { BcryptPBKDF.wipe(&raw) }
    guard reader.isAtEnd else { throw SSHPrivateKeyError.malformed("trailing data") }
    guard let kind = KeyKind(algorithm: algorithm) else {
      throw SSHPrivateKeyError.malformed("unknown stored algorithm")
    }
    return try makeParsedKey(KeyMaterial(kind: kind, raw: raw), comment: "")
  }

  // MARK: - openssh-key-v1

  private static let openSSHMagic = Array("openssh-key-v1".utf8) + [0]

  private static func parseOpenSSH(
    _ bytes: [UInt8], _ passphrase: String?
  ) throws
    -> ParsedSSHKey
  {
    var reader = ByteReader(bytes)
    guard try reader.bytes(openSSHMagic.count) == openSSHMagic else {
      throw SSHPrivateKeyError.malformed("not an openssh-key-v1 key")
    }
    let cipher = String(decoding: try reader.string(), as: UTF8.self)
    let kdf = String(decoding: try reader.string(), as: UTF8.self)
    let kdfOptions = try reader.string()
    guard try reader.uint32() == 1 else {
      throw SSHPrivateKeyError.malformed("expected exactly one key")
    }
    let publicBlob = try reader.string()
    let privateSection = try reader.string()
    guard reader.isAtEnd else { throw SSHPrivateKeyError.malformed("trailing data") }

    // The public key is stored in the clear: classify it before asking for a passphrase.
    var publicReader = ByteReader(publicBlob)
    let keyType = String(decoding: try publicReader.string(), as: UTF8.self)
    if keyType == "ssh-rsa" { throw SSHPrivateKeyError.rsaNotSupported }
    guard let kind = KeyKind(algorithm: keyType) else {
      throw SSHPrivateKeyError.unsupportedKeyType(displayName(keyType))
    }

    var plain: [UInt8]
    let blockSize: Int
    switch cipher {
    case "none":
      guard kdf == "none" else { throw SSHPrivateKeyError.malformed("unexpected KDF") }
      plain = privateSection
      blockSize = 8
    case "aes256-ctr":
      guard kdf == "bcrypt" else {
        throw SSHPrivateKeyError.unsupportedFormat(
          "key derivation \(displayName(kdf)) is not supported; "
            + "re-encrypt with ssh-keygen -p -f key"
        )
      }
      guard let passphrase, !passphrase.isEmpty else {
        throw SSHPrivateKeyError.passphraseRequired
      }
      plain = try decryptAES256CTR(privateSection, kdfOptions: kdfOptions, passphrase: passphrase)
      blockSize = 16
    default:
      throw SSHPrivateKeyError.unsupportedCipher(displayName(cipher))
    }
    defer { BcryptPBKDF.wipe(&plain) }
    guard plain.count % blockSize == 0 else {
      throw SSHPrivateKeyError.malformed("private section is not block aligned")
    }

    var section = ByteReader(plain)
    guard try section.uint32() == (try section.uint32()) else {
      if cipher == "none" { throw SSHPrivateKeyError.malformed("check values differ") }
      throw SSHPrivateKeyError.wrongPassphrase
    }
    guard String(decoding: try section.string(), as: UTF8.self) == keyType else {
      throw SSHPrivateKeyError.malformed("private key type does not match public key")
    }
    let (material, innerPublic) = try readPrivateKey(kind, from: &section)
    let comment = String(decoding: try section.string(), as: UTF8.self)
    // Padding is 1, 2, 3, ... up to the cipher block size.
    let padding = try section.bytes(section.remaining)
    guard padding.count < blockSize,
      padding.enumerated().allSatisfy({ Int($0.element) == $0.offset + 1 })
    else { throw SSHPrivateKeyError.malformed("bad padding") }

    guard material.publicBlob == publicBlob, material.publicKeyBytes == innerPublic else {
      throw SSHPrivateKeyError.malformed("public key does not match private key")
    }
    return try makeParsedKey(material, comment: comment)
  }

  /// Reads the type-specific private fields (after the key type string).
  private static func readPrivateKey(
    _ kind: KeyKind, from section: inout ByteReader
  ) throws
    -> (KeyMaterial, [UInt8])
  {
    switch kind {
    case .ed25519:
      let publicKey = try section.string()
      var secret = try section.string()  // 32-byte seed || 32-byte public key
      defer { BcryptPBKDF.wipe(&secret) }
      guard publicKey.count == 32, secret.count == 64, Array(secret[32...]) == publicKey else {
        throw SSHPrivateKeyError.malformed("invalid ed25519 key")
      }
      var seed = Array(secret[..<32])
      defer { BcryptPBKDF.wipe(&seed) }
      return (try KeyMaterial(kind: kind, raw: seed), publicKey)
    case .p256, .p384, .p521:
      guard String(decoding: try section.string(), as: UTF8.self) == kind.curveName else {
        throw SSHPrivateKeyError.malformed("curve does not match key type")
      }
      let publicKey = try section.string()
      var mpint = try section.string()
      defer { BcryptPBKDF.wipe(&mpint) }
      guard mpint.first.map({ $0 & 0x80 == 0 }) ?? false else {
        throw SSHPrivateKeyError.malformed("invalid ECDSA scalar")
      }
      // mpint: drop the sign/leading zero bytes, then left-pad to the curve size.
      let significant = mpint.drop { $0 == 0 }
      guard significant.count <= kind.scalarSize else {
        throw SSHPrivateKeyError.malformed("invalid ECDSA scalar")
      }
      var scalar = [UInt8](repeating: 0, count: kind.scalarSize - significant.count) + significant
      defer { BcryptPBKDF.wipe(&scalar) }
      return (try KeyMaterial(kind: kind, raw: scalar), publicKey)
    }
  }

  private static func decryptAES256CTR(
    _ ciphertext: [UInt8], kdfOptions: [UInt8], passphrase: String
  ) throws -> [UInt8] {
    var options = ByteReader(kdfOptions)
    let salt = try options.string()
    let rounds = Int(try options.uint32())
    guard options.isAtEnd, !salt.isEmpty else {
      throw SSHPrivateKeyError.malformed("invalid bcrypt options")
    }
    guard salt.count <= maxBcryptSaltLength else {
      throw SSHPrivateKeyError.unsupportedFormat(
        "bcrypt salts longer than \(maxBcryptSaltLength) bytes are not supported; "
          + "re-encrypt with ssh-keygen -p -f key")
    }
    guard (1...maxBcryptRounds).contains(rounds) else {
      throw SSHPrivateKeyError.unsupportedFormat(
        "keys protected with more than \(maxBcryptRounds) bcrypt rounds are not supported; "
          + "re-encrypt with ssh-keygen -p -a 100 -f key")
    }
    guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else {
      throw SSHPrivateKeyError.malformed("private section is not block aligned")
    }

    var password = Array(passphrase.utf8)
    var keyAndIV = try BcryptPBKDF.derive(
      password: password, salt: salt, rounds: rounds,
      keyLength: kCCKeySizeAES256 + kCCBlockSizeAES128)
    defer {
      BcryptPBKDF.wipe(&password)
      BcryptPBKDF.wipe(&keyAndIV)
    }

    var cryptor: CCCryptorRef?
    let created = keyAndIV.withUnsafeBytes { secret in
      CCCryptorCreateWithMode(
        CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
        CCPadding(ccNoPadding), secret.baseAddress! + kCCKeySizeAES256, secret.baseAddress!,
        kCCKeySizeAES256, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
    }
    guard created == kCCSuccess, let cryptor else {
      throw SSHPrivateKeyError.malformed("could not start decryption")
    }
    defer { CCCryptorRelease(cryptor) }

    var plain = [UInt8](repeating: 0, count: ciphertext.count)
    var moved = 0
    let updated = ciphertext.withUnsafeBytes { input in
      plain.withUnsafeMutableBytes { output in
        CCCryptorUpdate(
          cryptor, input.baseAddress, input.count, output.baseAddress, output.count, &moved)
      }
    }
    guard updated == kCCSuccess, moved == ciphertext.count else {
      BcryptPBKDF.wipe(&plain)
      throw SSHPrivateKeyError.malformed("decryption failed")
    }
    return plain
  }

  // MARK: - PEM

  private static let rsaEncryptionOID: [UInt8] = [
    0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
  ]
  private static let ecPublicKeyOID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]

  /// PKCS#8 PrivateKeyInfo: SEQUENCE { INTEGER version, SEQUENCE { OID algorithm, ... }, ... }.
  private static func parsePKCS8(_ der: [UInt8]) throws -> ParsedSSHKey {
    var outer = ByteReader(der)
    var info = ByteReader(try outer.derElement(tag: 0x30))
    _ = try info.derElement(tag: 0x02)
    var algorithm = ByteReader(try info.derElement(tag: 0x30))
    let oid = try algorithm.derElement(tag: 0x06)
    if oid == rsaEncryptionOID { throw SSHPrivateKeyError.rsaNotSupported }
    guard oid == ecPublicKeyOID else {
      throw SSHPrivateKeyError.unsupportedKeyType("PKCS#8 key that is not ECDSA")
    }
    if let material = cryptoKitECDSA(der) { return try makeParsedKey(material, comment: "") }
    throw SSHPrivateKeyError.unsupportedKeyType("ECDSA curve other than P-256, P-384 or P-521")
  }

  /// SEC1 ECPrivateKey: SEQUENCE { INTEGER 1, OCTET STRING d, [0] params?, [1] BIT STRING Q? }.
  /// CryptoKit only reads named-curve parameters; ssh-keygen linked against LibreSSL writes
  /// explicit ones, so for those the curve is picked by scalar size and must match `[1] Q`.
  private static func parseSEC1(_ der: [UInt8]) throws -> ParsedSSHKey {
    var outer = ByteReader(der)
    var key = ByteReader(try outer.derElement(tag: 0x30))
    guard try key.derElement(tag: 0x02) == [1] else {
      throw SSHPrivateKeyError.malformed("unknown EC key version")
    }
    var scalar = try key.derElement(tag: 0x04)
    defer { BcryptPBKDF.wipe(&scalar) }
    var publicPoint: [UInt8]?
    if key.peekTag == 0xA0 { _ = try key.derElement(tag: 0xA0) }
    if key.peekTag == 0xA1 {
      var wrapper = ByteReader(try key.derElement(tag: 0xA1))
      let bits = try wrapper.derElement(tag: 0x03)
      guard bits.first == 0 else { throw SSHPrivateKeyError.malformed("invalid EC public key") }
      publicPoint = Array(bits.dropFirst())
    }

    if let material = cryptoKitECDSA(der) { return try makeParsedKey(material, comment: "") }
    guard let kind = [KeyKind.p256, .p384, .p521].first(where: { $0.scalarSize == scalar.count })
    else {
      throw SSHPrivateKeyError.unsupportedKeyType("ECDSA curve other than P-256, P-384 or P-521")
    }
    // Without a named curve, the embedded public key is what proves the curve.
    let material = try KeyMaterial(kind: kind, raw: scalar)
    guard let publicPoint, publicPoint == material.publicKeyBytes else {
      throw SSHPrivateKeyError.unsupportedKeyType("ECDSA curve other than P-256, P-384 or P-521")
    }
    return try makeParsedKey(material, comment: "")
  }

  /// CryptoKit's DER reader accepts SEC1 and PKCS#8 with a named P-256/384/521 curve.
  private static func cryptoKitECDSA(_ der: [UInt8]) -> KeyMaterial? {
    if let key = try? P256.Signing.PrivateKey(derRepresentation: der) { return .p256(key) }
    if let key = try? P384.Signing.PrivateKey(derRepresentation: der) { return .p384(key) }
    if let key = try? P521.Signing.PrivateKey(derRepresentation: der) { return .p521(key) }
    return nil
  }

  /// Base64 payload between the BEGIN and END lines of `label`.
  private static func armoredBody(_ text: String, label: String) throws -> [UInt8] {
    guard let begin = text.range(of: "-----BEGIN \(label)-----"),
      let end = text.range(of: "-----END \(label)-----", range: begin.upperBound..<text.endIndex)
    else { throw SSHPrivateKeyError.malformed("missing BEGIN or END line") }
    let body = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
    guard !body.isEmpty, let data = Data(base64Encoded: String(body)) else {
      throw SSHPrivateKeyError.malformed("invalid base64")
    }
    return Array(data)
  }

  // MARK: - Shared

  private static func makeParsedKey(
    _ material: KeyMaterial, comment: String
  ) throws
    -> ParsedSSHKey
  {
    let privateKey = material.nioKey
    guard let fingerprint = SSHTunnel.fingerprint(of: privateKey.publicKey) else {
      throw SSHPrivateKeyError.malformed("public key cannot be encoded")
    }
    var raw = Array(material.rawRepresentation)
    defer { BcryptPBKDF.wipe(&raw) }
    var stored = sshString(Array(material.kind.algorithm.utf8)) + sshString(raw)
    defer { BcryptPBKDF.wipe(&stored) }
    return ParsedSSHKey(
      privateKey: privateKey, algorithm: material.kind.algorithm, fingerprint: fingerprint,
      comment: comment, keychainRepresentation: Data(stored))
  }

  private static func sshString(_ bytes: [UInt8]) -> [UInt8] {
    let count = UInt32(bytes.count)
    return [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: count >> $0) } + bytes
  }

  /// Printable ASCII only, capped, so file content cannot inject text into error messages.
  private static func displayName(_ name: String) -> String {
    let scalars = name.unicodeScalars.prefix(40).filter { (0x21...0x7E).contains($0.value) }
    let cleaned = String(String.UnicodeScalarView(scalars))
    return cleaned.isEmpty ? "(unknown)" : cleaned
  }

  // MARK: - Key types

  private enum KeyKind {
    case ed25519, p256, p384, p521

    init?(algorithm: String) {
      switch algorithm {
      case "ssh-ed25519": self = .ed25519
      case "ecdsa-sha2-nistp256": self = .p256
      case "ecdsa-sha2-nistp384": self = .p384
      case "ecdsa-sha2-nistp521": self = .p521
      default: return nil
      }
    }

    var algorithm: String {
      switch self {
      case .ed25519: "ssh-ed25519"
      case .p256: "ecdsa-sha2-nistp256"
      case .p384: "ecdsa-sha2-nistp384"
      case .p521: "ecdsa-sha2-nistp521"
      }
    }

    var curveName: String {
      switch self {
      case .ed25519: ""
      case .p256: "nistp256"
      case .p384: "nistp384"
      case .p521: "nistp521"
      }
    }

    /// Length of the raw private representation (ed25519 seed or ECDSA scalar).
    var scalarSize: Int {
      switch self {
      case .ed25519, .p256: 32
      case .p384: 48
      case .p521: 66
      }
    }
  }

  private enum KeyMaterial {
    case ed25519(Curve25519.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)

    init(kind: KeyKind, raw: [UInt8]) throws {
      guard raw.count == kind.scalarSize else {
        throw SSHPrivateKeyError.malformed("invalid private key length")
      }
      do {
        switch kind {
        case .ed25519: self = .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: raw))
        case .p256: self = .p256(try P256.Signing.PrivateKey(rawRepresentation: raw))
        case .p384: self = .p384(try P384.Signing.PrivateKey(rawRepresentation: raw))
        case .p521: self = .p521(try P521.Signing.PrivateKey(rawRepresentation: raw))
        }
      } catch {
        throw SSHPrivateKeyError.malformed("invalid private key")
      }
    }

    var kind: KeyKind {
      switch self {
      case .ed25519: .ed25519
      case .p256: .p256
      case .p384: .p384
      case .p521: .p521
      }
    }

    var nioKey: NIOSSHPrivateKey {
      switch self {
      case .ed25519(let key): NIOSSHPrivateKey(ed25519Key: key)
      case .p256(let key): NIOSSHPrivateKey(p256Key: key)
      case .p384(let key): NIOSSHPrivateKey(p384Key: key)
      case .p521(let key): NIOSSHPrivateKey(p521Key: key)
      }
    }

    var rawRepresentation: Data {
      switch self {
      case .ed25519(let key): key.rawRepresentation
      case .p256(let key): key.rawRepresentation
      case .p384(let key): key.rawRepresentation
      case .p521(let key): key.rawRepresentation
      }
    }

    /// ed25519: the 32-byte public key; ECDSA: the uncompressed point (x9.63).
    var publicKeyBytes: [UInt8] {
      switch self {
      case .ed25519(let key): Array(key.publicKey.rawRepresentation)
      case .p256(let key): Array(key.publicKey.x963Representation)
      case .p384(let key): Array(key.publicKey.x963Representation)
      case .p521(let key): Array(key.publicKey.x963Representation)
      }
    }

    /// The SSH wire-format public key blob, as stored in the openssh-key-v1 header.
    var publicBlob: [UInt8] {
      let algorithm = SSHPrivateKeyParser.sshString(Array(kind.algorithm.utf8))
      if case .ed25519 = self {
        return algorithm + SSHPrivateKeyParser.sshString(publicKeyBytes)
      }
      return algorithm + SSHPrivateKeyParser.sshString(Array(kind.curveName.utf8))
        + SSHPrivateKeyParser.sshString(publicKeyBytes)
    }
  }
}

/// Bounds-checked reader over untrusted bytes (SSH wire format and minimal DER).
private nonisolated struct ByteReader {
  private let storage: [UInt8]
  private var offset = 0

  init(_ bytes: [UInt8]) { storage = bytes }

  var remaining: Int { storage.count - offset }
  var isAtEnd: Bool { remaining == 0 }
  var peekTag: UInt8? { isAtEnd ? nil : storage[offset] }

  mutating func bytes(_ count: Int) throws -> [UInt8] {
    guard count >= 0, count <= remaining else { throw SSHPrivateKeyError.malformed("truncated") }
    defer { offset += count }
    return Array(storage[offset..<offset + count])
  }

  mutating func uint32() throws -> UInt32 {
    try bytes(4).reduce(0) { $0 << 8 | UInt32($1) }
  }

  /// SSH string: uint32 length followed by that many bytes.
  mutating func string() throws -> [UInt8] {
    try bytes(Int(try uint32()))
  }

  /// DER TLV with the given tag; returns the contents. Lengths up to 3 bytes (16 MiB).
  mutating func derElement(tag: UInt8) throws -> [UInt8] {
    guard try bytes(1) == [tag] else { throw SSHPrivateKeyError.malformed("unexpected DER tag") }
    let first = try bytes(1)[0]
    var length = Int(first)
    if first & 0x80 != 0 {
      let count = Int(first & 0x7F)
      guard (1...3).contains(count) else {
        throw SSHPrivateKeyError.malformed("unsupported DER length")
      }
      length = try bytes(count).reduce(0) { $0 << 8 | Int($1) }
    }
    return try bytes(length)
  }
}
