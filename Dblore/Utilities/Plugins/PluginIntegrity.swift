// PluginIntegrity.swift
// Streaming SHA-256 of a plugin file off the main actor, with a size cap.

import CryptoKit
import Darwin
import Foundation

nonisolated enum PluginIntegrityError: Error, Equatable {
  /// The path is a symlink, directory or other non-regular file.
  case notRegularFile
  /// The file is larger than the allowed size.
  case tooLarge
  /// open/read failed; carries the errno text.
  case io(String)
}

nonisolated enum PluginIntegrity {
  /// Lowercase hex SHA-256 of the regular file at `url`. Symlinks (final component) are refused
  /// via O_NOFOLLOW; the size is checked before and while reading, since the file may grow.
  @concurrent static func sha256(of url: URL, maxSize: Int64) async throws -> String {
    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
      if errno == ELOOP { throw PluginIntegrityError.notRegularFile }
      throw PluginIntegrityError.io(String(cString: strerror(errno)))
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0 else {
      throw PluginIntegrityError.io(String(cString: strerror(errno)))
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw PluginIntegrityError.notRegularFile }
    guard info.st_size <= maxSize else { throw PluginIntegrityError.tooLarge }

    var hasher = SHA256()
    var total: Int64 = 0
    while true {
      try Task.checkCancellation()
      let chunk: Data
      do {
        chunk = try handle.read(upToCount: 1 << 20) ?? Data()
      } catch {
        throw PluginIntegrityError.io(error.localizedDescription)
      }
      if chunk.isEmpty { break }
      total += Int64(chunk.count)
      guard total <= maxSize else { throw PluginIntegrityError.tooLarge }
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
