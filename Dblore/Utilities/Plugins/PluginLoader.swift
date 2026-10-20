// PluginLoader.swift
// Verifies a plugin library (SHA-256, size cap, code-signature Team ID) and only then dlopens it,
// returning the handle. Symbol lookup is left to the plugin's own wrapper (e.g. DuckDBLibrary).

import CryptoKit
import Darwin
import Foundation
import Security

nonisolated enum PluginLoaderError: Error, Equatable {
  /// dlopen failed, or the file could not be opened or read; carries the error text.
  case loadFailed(String)
  /// The URL is not an absolute file path; carries the URL's relative path.
  case invalidPath(String)
  /// The file's SHA-256 does not match the expected digest, or it is over the size cap; dlopen
  /// did not run.
  case integrityMismatch
  /// The file's code signature Team ID differs from the expected one (nil: ad-hoc or unsigned);
  /// dlopen did not run.
  case teamIDMismatch(expected: String, actual: String?)
}

nonisolated enum PluginLoader {
  /// Team ID every plugin must be signed with (same as the app).
  static let teamIdentifier = "86H6CNLN4C"

  /// dlopens the library only if the file hashes to `expectedSHA256` (hex, any case). With
  /// `expectedTeamID`, the code signature must be valid, chain to Apple and carry that Team ID
  /// before dlopen, so an ad-hoc or foreign dylib never reaches Gatekeeper. `maxSize` caps the
  /// bytes hashed. The handle is never dlclose'd by Dblore.
  ///
  /// The file is opened once (no symlink, regular file only), hashed through that descriptor,
  /// and dlopen'd by the path `F_GETPATH` returns for it. Right before dlopen the path must still
  /// name the same file, unmodified (device, inode, size and mtime match the descriptor's
  /// pre-hash `fstat`). This narrows but does not close the check-to-load race: the signature
  /// check and dlopen still open by path, and a swap after the final `stat` is not detected.
  /// Hardened-runtime library validation (same Team ID) is the primary guard; the hash binds
  /// the file to the catalog entry.
  static func open(
    at url: URL, expectedSHA256: String, expectedTeamID: String?, maxSize: Int64?
  ) throws -> UnsafeMutableRawPointer {
    guard url.isFileURL, url.relativePath.hasPrefix("/") else {
      throw PluginLoaderError.invalidPath(url.relativePath)
    }
    let path = url.path
    let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
      throw PluginLoaderError.loadFailed("\(path): \(String(cString: strerror(errno)))")
    }
    defer { Darwin.close(fd) }
    var opened = stat()
    guard fstat(fd, &opened) == 0 else {
      throw PluginLoaderError.loadFailed("\(path): \(String(cString: strerror(errno)))")
    }
    guard opened.st_mode & S_IFMT == S_IFREG else {
      throw PluginLoaderError.loadFailed("\(path): not a regular file")
    }
    if let maxSize, opened.st_size > maxSize { throw PluginLoaderError.integrityMismatch }

    guard try sha256Hex(of: fd, path: path, maxSize: maxSize) == expectedSHA256.lowercased()
    else {
      throw PluginLoaderError.integrityMismatch
    }
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard fcntl(fd, F_GETPATH, &resolved) != -1 else {
      throw PluginLoaderError.loadFailed("\(path): \(String(cString: strerror(errno)))")
    }
    let verifiedPath = String(
      decoding: resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    if let expectedTeamID {
      try checkTeamID(ofPath: verifiedPath, expected: expectedTeamID)
    }
    var current = stat()
    guard stat(verifiedPath, &current) == 0, isSameFile(opened, current) else {
      throw PluginLoaderError.integrityMismatch
    }
    guard let handle = dlopen(verifiedPath, RTLD_NOW | RTLD_LOCAL) else {
      let message = dlerror().map { String(cString: $0) } ?? "dlopen failed for \(verifiedPath)"
      throw PluginLoaderError.loadFailed(message)
    }
    return handle
  }

  /// Same inode, unmodified: device, inode, size and modification time all match.
  private static func isSameFile(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
      && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
      && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
  }

  /// Throws `teamIDMismatch` unless the file's code signature is valid, anchored at Apple and its
  /// leaf certificate's OU is `expected`. `actual` is the unvalidated Team ID read from the
  /// signature (nil when ad-hoc signed or unsigned).
  private static func checkTeamID(ofPath path: String, expected: String) throws {
    var code: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
      let code
    else { throw PluginLoaderError.teamIDMismatch(expected: expected, actual: nil) }
    let actual = teamIdentifier(of: code)
    let isWellFormed =
      expected.utf8.count == 10
      && expected.utf8.allSatisfy { (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }
    var requirement: SecRequirement?
    guard isWellFormed, actual == expected,
      SecRequirementCreateWithString(
        "anchor apple generic and certificate leaf[subject.OU] = \"\(expected)\"" as CFString,
        [], &requirement) == errSecSuccess,
      let requirement,
      SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    else { throw PluginLoaderError.teamIDMismatch(expected: expected, actual: actual) }
  }

  /// Team ID from the code signature, not validated; nil when ad-hoc signed or unsigned.
  private static func teamIdentifier(of code: SecStaticCode) -> String? {
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        == errSecSuccess,
      let values = info as? [String: Any]
    else { return nil }
    return values[kSecCodeInfoTeamIdentifier as String] as? String
  }

  private static func sha256Hex(of fd: Int32, path: String, maxSize: Int64?) throws -> String {
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    var total: Int64 = 0
    while true {
      let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        throw PluginLoaderError.loadFailed("\(path): \(String(cString: strerror(errno)))")
      }
      if count == 0 { break }
      total += Int64(count)
      if let maxSize, total > maxSize { throw PluginLoaderError.integrityMismatch }
      buffer.withUnsafeBytes {
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count]))
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
