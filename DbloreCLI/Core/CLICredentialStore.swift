// CLICredentialStore.swift
// The saved pairing (token, proof key, port, id): one JSON file, mode 0600, in a folder of its
// own, mode 0700, "~/Library/Application Support/Dblore CLI/credentials.json". Not the login
// Keychain: every app update re-signs this tool with a new code hash, and the Keychain then
// asks the user (or refuses) before the new binary may read the item the old one wrote.
// A save writes a new 0600 file next to the old one and renames it over, so a reader never
// sees half a file and the mode never widens. A file or folder that is a symbolic link or is
// owned by another user is refused, and so is a file other users could write (its port or
// proof key may have been swapped). A file other users may read, or a folder they may open, is
// set back to 0600 / 0700 and reported: its token may have been read, so the caller tells the
// user to revoke the pairing in Dblore and pair again.

import Foundation

nonisolated struct CLICredentialStore: Sendable {
  /// The pairing and whether the file or its folder had to be made private again
  struct Loaded: Equatable, Sendable {
    let credentials: CLICredentials
    let fixedPermissions: Bool
  }

  let directory: URL

  /// ~/Library/Application Support/Dblore CLI
  static var defaultDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dblore CLI", isDirectory: true)
  }

  init(directory: URL = Self.defaultDirectory) {
    self.directory = directory
  }

  var fileURL: URL { directory.appendingPathComponent("credentials.json") }

  /// Nil when nothing is saved.
  func load() throws -> Loaded? {
    let path = fileURL.path
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw failure("\(path) cannot be opened (\(String(cString: strerror(errno)))).")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid()
    else { throw failure("\(path) is not a file of yours.") }
    var fixed = try secureDirectory()
    if info.st_mode & 0o022 != 0 {
      throw CLIFailure(
        exitCode: .refused,
        message: "The credentials file was writable by other users; pair again: run the "
          + "command Settings > MCP shows.")
    }
    if info.st_mode & 0o077 != 0 {
      guard fchmod(descriptor, 0o600) == 0 else {
        throw failure("\(path) is readable by other users and cannot be made private.")
      }
      fixed = true
    }
    guard let data = try? handle.readToEnd(),
      let credentials = try? JSONDecoder().decode(CLICredentials.self, from: data)
    else { throw CLIClient.unreadableCredentials }
    return Loaded(credentials: credentials, fixedPermissions: fixed)
  }

  /// Replaces the saved pairing.
  func save(_ credentials: CLICredentials) throws {
    if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
      throw failure("\(directory.path) cannot be created (\(String(cString: strerror(errno)))).")
    }
    _ = try secureDirectory()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(credentials)
    let suffix = CLIClient.secureRandomBytes(8).map { String(format: "%02x", $0) }.joined()
    let temporary = directory.appendingPathComponent(".credentials-\(suffix).tmp").path
    let descriptor = open(
      temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else {
      throw failure("\(temporary) cannot be created (\(String(cString: strerror(errno)))).")
    }
    let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    let synced = fchmod(descriptor, 0o600) == 0 && fsync(descriptor) == 0
    close(descriptor)
    guard written == data.count, synced, rename(temporary, fileURL.path) == 0 else {
      unlink(temporary)
      throw failure("\(fileURL.path) cannot be written.")
    }
  }

  /// Refuses a folder that is a link or not the user's; sets an open one back to 0700. True
  /// when it did.
  private func secureDirectory() throws -> Bool {
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid()
    else { throw failure("\(directory.path) is not a folder of yours.") }
    guard info.st_mode & 0o077 != 0 else { return false }
    guard chmod(directory.path, 0o700) == 0 else {
      throw failure("\(directory.path) is open to other users and cannot be made private.")
    }
    return true
  }

  private func failure(_ message: String) -> CLIFailure {
    CLIFailure(exitCode: .usage, message: message)
  }
}
