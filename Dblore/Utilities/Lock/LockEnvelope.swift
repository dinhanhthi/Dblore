//
//  LockEnvelope.swift
//  Dblore
//

import CryptoKit
import Foundation

/// Envelope v1: the encrypted form of a locked workspace's files (.sqlws, .dblore, scripts, .md,
/// launch-snapshot overlays). Big-endian integers, AES-256-GCM (NIST SP 800-38D) via CryptoKit.
///
///     0..<8     magic 89 44 42 4C 4B 0D 0A 1A (0x89 is invalid UTF-8 and not JSON)
///     8..<10    format version, UInt16 = 1
///     10        payload kind (`Kind`)
///     11        flags = 0 (reserved; any bit set is refused)
///     12..<28   workspace id (RFC 4122 byte order)
///     -- password wrap block, identical in every file of one workspace --
///     28        KDF id: 1 = PBKDF2-HMAC-SHA256 (`SafeModePasswordRecord.derive`)
///     29..<33   iterations, UInt32 (600,000 written; 100,000...10,000,000 accepted)
///     33..<49   salt (16)
///     49..<61   wrap nonce (12)
///     61..<93   wrapped content key (32)
///     93..<109  wrap tag (16)
///     -- payload --
///     109..<121 payload nonce (12, random per write)
///     121..<121+N ciphertext of exactly the bytes the plaintext format would write
///     121+N..<137+N payload tag (16)
///
/// The wrap key is PBKDF2 over the UTF-8 bytes of the Lock password in Unicode NFC (canonical
/// composition), so a password typed decomposed (NFD) unwraps the same block.
///
/// Wrap AAD = bytes 0..<10 + 12..<49 (no kind or flags, so the block is copied verbatim into
/// every file and autosave never runs PBKDF2). Payload AAD = bytes 0..<121, the payload nonce
/// included: any header byte change fails authentication.
///
/// Readings of the layout fixed here: the wrap AAD binds the workspace id, so a `WrapBlock` carries
/// it and `seal` refuses a block of another workspace; header checks (version, flags, kind, KDF id,
/// iteration range) run before any decryption or PBKDF2, so a crafted iteration count cannot
/// stall the reader; a changed wrap block makes `unwrapKey` report a wrong password (AES-GCM
/// cannot tell the two apart) and `open` report tampering.
///
/// Pure and synchronous: PBKDF2 and large payloads run off the main actor in the callers.
nonisolated enum LockEnvelope {
  nonisolated enum Kind: UInt8, CaseIterable, Sendable {
    case workspace = 1
    case notebook = 2
    /// .sql and MongoDB .js scripts
    case script = 3
    case markdown = 4
    case launchOverlays = 5
  }

  /// The KDF parameters and wrapped content key of one workspace (bytes 28..<109)
  nonisolated struct WrapBlock: Equatable, Sendable {
    let workspaceId: UUID
    let bytes: Data
  }

  nonisolated struct Header: Equatable, Sendable {
    let kind: Kind
    let workspaceId: UUID
    let wrapBlock: WrapBlock
  }

  static let version: UInt16 = 1
  static let magic: [UInt8] = [0x89, 0x44, 0x42, 0x4C, 0x4B, 0x0D, 0x0A, 0x1A]
  static let acceptedIterations = 100_000...10_000_000
  static let headerLength = 121
  static let minimumLength = headerLength + 16

  private static let kdfPBKDF2: UInt8 = 1
  private static let wrapBlockRange = 28..<109
  private static let wrapKDFLength = 21  // KDF id, iterations, salt
  private static let wrapNonceRange = 21..<33  // within the wrap block
  private static let wrappedKeyRange = 33..<65
  private static let wrapTagRange = 65..<81

  /// The envelope header, or nil when `data` does not start with the magic (a plaintext file).
  /// Throws when the magic is there but the header is newer, unknown or cut short.
  static func sniff(_ data: Data) throws -> Header? {
    let start = data.startIndex
    guard data.count >= magic.count, data.prefix(magic.count).elementsEqual(magic) else {
      return nil
    }
    guard data.count >= 10 else { throw LockEnvelopeError.truncated }
    let fileVersion = UInt16(data[start + 8]) << 8 | UInt16(data[start + 9])
    guard fileVersion <= version else { throw LockEnvelopeError.newerVersion(fileVersion) }
    guard fileVersion == version else { throw LockEnvelopeError.unsupported }
    guard data.count >= minimumLength else { throw LockEnvelopeError.truncated }
    guard data[start + 11] == 0, let kind = Kind(rawValue: data[start + 10]) else {
      throw LockEnvelopeError.unsupported
    }
    let workspaceId = uuid(from: data[start + 12..<start + 28])
    let block = WrapBlock(
      workspaceId: workspaceId,
      bytes: Data(data[start + wrapBlockRange.lowerBound..<start + wrapBlockRange.upperBound]))
    _ = try iterations(of: block)
    return Header(kind: kind, workspaceId: workspaceId, wrapBlock: block)
  }

  /// A new wrap block: the content key sealed under PBKDF2(password, new random salt). Runs PBKDF2.
  static func makeWrapBlock(
    contentKey: SymmetricKey, password: String, workspaceId: UUID,
    iterations: Int = SafeModePasswordRecord.lockIterations
  ) throws -> WrapBlock {
    guard contentKey.bitCount == 256 else { throw LockEnvelopeError.invalidContentKey }
    guard acceptedIterations.contains(iterations) else { throw LockEnvelopeError.unsupported }
    let salt = SymmetricKey(size: SymmetricKeySize(bitCount: SafeModePasswordRecord.saltLength * 8))
      .withUnsafeBytes { Data($0) }
    var kdf = Data([kdfPBKDF2])
    kdf.append(bigEndianBytes(UInt32(iterations)))
    kdf.append(salt)
    let wrapKey = try passwordKey(password, salt: salt, iterations: iterations)
    let box = try AES.GCM.seal(
      contentKey.withUnsafeBytes { Data($0) }, using: wrapKey,
      authenticating: wrapAAD(workspaceId: workspaceId, kdf: kdf))
    return WrapBlock(
      workspaceId: workspaceId, bytes: kdf + Data(box.nonce) + box.ciphertext + box.tag)
  }

  /// The content key inside `block`. Runs PBKDF2 with the block's own parameters.
  static func unwrapKey(_ block: WrapBlock, password: String) throws -> SymmetricKey {
    let rounds = try iterations(of: block)
    let bytes = block.bytes
    let start = bytes.startIndex
    let kdf = bytes[start..<start + wrapKDFLength]
    let salt = bytes[start + 5..<start + wrapKDFLength]
    let wrapKey = try passwordKey(password, salt: Data(salt), iterations: rounds)
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: bytes[shifted(wrapNonceRange, by: start)]),
        ciphertext: bytes[shifted(wrappedKeyRange, by: start)],
        tag: bytes[shifted(wrapTagRange, by: start)])
      let key = try AES.GCM.open(
        box, using: wrapKey, authenticating: wrapAAD(workspaceId: block.workspaceId, kdf: kdf))
      return SymmetricKey(data: key)
    } catch {
      throw LockEnvelopeError.wrongPassword
    }
  }

  /// A complete envelope file of `payload`, with a new random payload nonce
  static func seal(
    _ payload: Data, kind: Kind, workspaceId: UUID, wrapBlock: WrapBlock, contentKey: SymmetricKey
  ) throws -> Data {
    guard contentKey.bitCount == 256 else { throw LockEnvelopeError.invalidContentKey }
    guard wrapBlock.workspaceId == workspaceId else { throw LockEnvelopeError.workspaceMismatch }
    _ = try iterations(of: wrapBlock)
    let nonce = AES.GCM.Nonce()
    var header = Data(magic)
    header.append(bigEndianBytes(version))
    header.append(contentsOf: [kind.rawValue, 0])
    header.append(uuidBytes(workspaceId))
    header.append(wrapBlock.bytes)
    header.append(Data(nonce))
    let box = try AES.GCM.seal(payload, using: contentKey, nonce: nonce, authenticating: header)
    return header + box.ciphertext + box.tag
  }

  /// The plaintext bytes of an envelope file
  static func open(_ data: Data, contentKey: SymmetricKey) throws -> Data {
    guard try sniff(data) != nil else { throw LockEnvelopeError.notAnEnvelope }
    let start = data.startIndex
    let end = data.endIndex
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: data[start + 109..<start + headerLength]),
        ciphertext: data[start + headerLength..<end - 16],
        tag: data[end - 16..<end])
      return try AES.GCM.open(
        box, using: contentKey, authenticating: data[start..<start + headerLength])
    } catch {
      throw LockEnvelopeError.tampered
    }
  }

  // MARK: - Private

  /// The block's PBKDF2 iteration count, refused before any derivation when out of range
  private static func iterations(of block: WrapBlock) throws -> Int {
    let bytes = [UInt8](block.bytes)
    guard bytes.count == wrapBlockRange.count, bytes[0] == kdfPBKDF2 else {
      throw LockEnvelopeError.unsupported
    }
    let rounds = bytes[1...4].reduce(0) { $0 << 8 | Int($1) }
    guard acceptedIterations.contains(rounds) else { throw LockEnvelopeError.unsupported }
    return rounds
  }

  /// PBKDF2 of the NFC form of `password` (part of the v1 contract)
  private static func passwordKey(
    _ password: String, salt: Data, iterations: Int
  ) throws
    -> SymmetricKey
  {
    guard
      let derived = SafeModePasswordRecord.derive(
        password: password.precomposedStringWithCanonicalMapping, salt: salt,
        iterations: iterations)
    else { throw LockEnvelopeError.keyDerivationFailed }
    return SymmetricKey(data: derived)
  }

  private static func wrapAAD(workspaceId: UUID, kdf: Data) -> Data {
    var aad = Data(magic)
    aad.append(bigEndianBytes(version))
    aad.append(uuidBytes(workspaceId))
    aad.append(kdf)
    return aad
  }

  private static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
  }

  private static func uuidBytes(_ id: UUID) -> Data {
    withUnsafeBytes(of: id.uuid) { Data($0) }
  }

  private static func uuid(from bytes: Data) -> UUID {
    let b = [UInt8](bytes)
    return UUID(
      uuid: (
        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13],
        b[14], b[15]
      ))
  }

  private static func shifted(_ range: Range<Int>, by offset: Int) -> Range<Int> {
    range.lowerBound + offset..<range.upperBound + offset
  }
}

/// Why an envelope could not be read or written. Never carries key or password material.
nonisolated enum LockEnvelopeError: Error, Equatable, LocalizedError, Sendable {
  /// The data does not start with the envelope magic
  case notAnEnvelope
  /// The magic is there but the file is shorter than its header and tag
  case truncated
  /// Written by a newer Dblore (format version above 1)
  case newerVersion(UInt16)
  /// Version 0, unknown kind or flag bits, unknown KDF or an iteration count outside the range
  case unsupported
  /// The content key is not 256 bits
  case invalidContentKey
  /// The wrap block belongs to another workspace
  case workspaceMismatch
  /// PBKDF2 failed
  case keyDerivationFailed
  /// The password does not unwrap the content key (or the wrap block was changed)
  case wrongPassword
  /// Authentication failed: a changed byte or the wrong content key
  case tampered

  var errorDescription: String? {
    switch self {
    case .notAnEnvelope: return "The file is not an encrypted Dblore file."
    case .truncated: return "The encrypted file is incomplete."
    case .newerVersion: return "The file was made by a newer version of Dblore."
    case .unsupported: return "The encrypted file uses an unsupported format."
    case .invalidContentKey: return "The workspace key is not valid."
    case .workspaceMismatch: return "The workspace key belongs to another workspace."
    case .keyDerivationFailed: return "The password could not be processed."
    case .wrongPassword: return "The Lock password is not correct."
    case .tampered: return "The encrypted file is damaged or was changed."
    }
  }
}
