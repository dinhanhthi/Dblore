//
//  SafeModePasswordRecord.swift
//  SQLNotebook
//

import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Salted, iterated hash of the Safe Mode password (PBKDF2, HMAC-SHA-256 PRF), stored as JSON in the
/// password store. Never contains the plaintext.
nonisolated struct SafeModePasswordRecord: Codable, Equatable, Sendable {
  static let defaultIterations = 210_000
  static let saltLength = 16
  static let hashLength = 32

  let salt: Data
  let iterations: Int
  let hash: Data

  /// New record with a random salt; nil if the system RNG or key derivation fails
  static func make(password: String, iterations: Int = defaultIterations) -> SafeModePasswordRecord?
  {
    var salt = [UInt8](repeating: 0, count: saltLength)
    guard SecRandomCopyBytes(kSecRandomDefault, saltLength, &salt) == errSecSuccess,
      let hash = derive(password: password, salt: Data(salt), iterations: iterations)
    else { return nil }
    return SafeModePasswordRecord(salt: Data(salt), iterations: iterations, hash: hash)
  }

  /// True if `password` derives the stored hash (constant-time compare)
  func matches(_ password: String) -> Bool {
    guard let candidate = Self.derive(password: password, salt: salt, iterations: iterations)
    else { return false }
    return Self.constantTimeEquals(candidate, hash)
  }

  static func derive(password: String, salt: Data, iterations: Int) -> Data? {
    guard iterations > 0, let rounds = UInt32(exactly: iterations) else { return nil }
    let passwordBytes = Array(password.utf8)
    let saltBytes = [UInt8](salt)
    var derived = [UInt8](repeating: 0, count: hashLength)
    let status = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
      passwordBuffer.withMemoryRebound(to: Int8.self) { passwordChars in
        CCKeyDerivationPBKDF(
          CCPBKDFAlgorithm(kCCPBKDF2), passwordChars.baseAddress, passwordBytes.count,
          saltBytes, saltBytes.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
          &derived, hashLength)
      }
    }
    return status == kCCSuccess ? Data(derived) : nil
  }

  /// Compares every byte regardless of where the first difference is
  static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(lhs, rhs) {
      difference |= left ^ right
    }
    return difference == 0
  }

  // MARK: - Legacy (migration only)

  /// True if `password` matches the legacy unsalted SHA-256 hex stored in UserDefaults by
  /// builds before the Keychain migration (constant-time compare)
  static func matchesLegacyHash(_ password: String, legacyHex: String) -> Bool {
    guard let stored = bytes(fromHex: legacyHex) else { return false }
    let digest = Data(SHA256.hash(data: Data(password.utf8)))
    return constantTimeEquals(digest, stored)
  }

  private static func bytes(fromHex hex: String) -> Data? {
    let chars = Array(hex.utf8)
    guard chars.count == hashLength * 2 else { return nil }
    var bytes = Data(capacity: hashLength)
    var index = 0
    while index < chars.count {
      guard let high = nibble(chars[index]), let low = nibble(chars[index + 1]) else { return nil }
      bytes.append(high << 4 | low)
      index += 2
    }
    return bytes
  }

  private static func nibble(_ char: UInt8) -> UInt8? {
    switch char {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return char - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return char - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return char - UInt8(ascii: "A") + 10
    default: return nil
    }
  }
}
