// DuckDBLibrary.swift
// Loads the optional libduckdb plugin with dlopen and resolves the small part
// of the DuckDB C API (duckdb.h v1.5.6) that Dblore uses, via dlsym.

import CryptoKit
import Darwin
import Foundation

nonisolated enum DuckDBLibraryError: Error, Equatable {
  /// dlopen failed; carries the dlerror() text.
  case loadFailed(String)
  /// A required C API symbol is not exported by the library.
  case missingSymbol(String)
  /// The URL is not an absolute file path; carries the URL's relative path.
  case invalidPath(String)
  /// The file's SHA-256 does not match the expected digest; dlopen did not run.
  case integrityMismatch
  /// `duckdb_library_version()` (without its leading "v") differs from the expected version.
  case versionMismatch(expected: String, actual: String)
}

/// `duckdb_state`: DuckDBSuccess = 0, DuckDBError = 1.
nonisolated enum DuckDBState {
  static let success: Int32 = 0
  static let error: Int32 = 1
}

/// Mirror of `struct duckdb_result` (duckdb.h v1.5.6). Only DuckDB reads or
/// frees these fields; Swift passes the struct by pointer.
nonisolated struct DuckDBResult {
  var deprecatedColumnCount: UInt64 = 0
  var deprecatedRowCount: UInt64 = 0
  var deprecatedRowsChanged: UInt64 = 0
  var deprecatedColumns: UnsafeMutableRawPointer? = nil
  var deprecatedErrorMessage: UnsafeMutablePointer<CChar>? = nil
  var internalData: UnsafeMutableRawPointer? = nil
}

/// Spike finding (task 2.5): files the sandboxed app writes are auto-quarantined
/// (`com.apple.quarantine = 0082;…;Dblore;`) and the app cannot remove the xattr
/// (EPERM). A downloaded plugin must therefore be notarized, and callers must
/// check quarantine/notarization before `load(at:expectedSHA256:expectedVersion:)`: dlopen of a quarantined,
/// non-notarized dylib fails ("library load disallowed by system policy") and
/// shows a Gatekeeper dialog.
///
/// The loaded library and its C function table. Opaque DuckDB handles
/// (`duckdb_database`, `duckdb_connection`, `duckdb_config`) are `OpaquePointer?`.
/// The handle is never dlclose'd: libduckdb keeps static C++ state.
nonisolated final class DuckDBLibrary: @unchecked Sendable {
  typealias Handle = OpaquePointer?
  typealias CString = UnsafePointer<CChar>?
  /// `duckdb_result *`. A Swift struct pointer is not @convention(c)-representable,
  /// so callers pass `&result` (a `DuckDBResult`) as a raw pointer.
  typealias ResultPointer = UnsafeMutableRawPointer?

  let libraryVersion: @convention(c) () -> CString
  let open: @convention(c) (CString, UnsafeMutablePointer<Handle>?) -> Int32
  let openExt:
    @convention(c) (
      CString, UnsafeMutablePointer<Handle>?, Handle,
      UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32
  let close: @convention(c) (UnsafeMutablePointer<Handle>?) -> Void
  let connect: @convention(c) (Handle, UnsafeMutablePointer<Handle>?) -> Int32
  let disconnect: @convention(c) (UnsafeMutablePointer<Handle>?) -> Void
  let createConfig: @convention(c) (UnsafeMutablePointer<Handle>?) -> Int32
  let setConfig: @convention(c) (Handle, CString, CString) -> Int32
  let destroyConfig: @convention(c) (UnsafeMutablePointer<Handle>?) -> Void
  let query: @convention(c) (Handle, CString, ResultPointer) -> Int32
  let destroyResult: @convention(c) (ResultPointer) -> Void
  let resultError: @convention(c) (ResultPointer) -> CString
  let rowCount: @convention(c) (ResultPointer) -> UInt64
  let columnCount: @convention(c) (ResultPointer) -> UInt64
  let valueInt64: @convention(c) (ResultPointer, UInt64, UInt64) -> Int64
  let valueVarchar:
    @convention(c) (ResultPointer, UInt64, UInt64) -> UnsafeMutablePointer<
      CChar
    >?
  let free: @convention(c) (UnsafeMutableRawPointer?) -> Void

  private let handle: UnsafeMutableRawPointer

  /// `duckdb_library_version()`, e.g. "v1.5.6".
  var version: String {
    libraryVersion().map { String(cString: $0) } ?? ""
  }

  /// Loads the library only if the file hashes to `expectedSHA256` (hex, any case) and then
  /// reports `expectedVersion` (bare, e.g. "1.5.6").
  ///
  /// The file is opened once, hashed through that descriptor, and dlopen'd by the path
  /// `F_GETPATH` returns for it while the descriptor stays open. This narrows but does not
  /// close the check-to-load race: dlopen still opens by path, so a swap of the directory
  /// entry in between is not detected. Hardened-runtime library validation (same Team ID) is
  /// the primary guard; the hash binds the file to the catalog entry. On a version mismatch
  /// the library stays loaded (it is never dlclose'd) but is not returned.
  static func load(
    at url: URL, expectedSHA256: String, expectedVersion: String
  ) throws -> DuckDBLibrary {
    guard url.isFileURL, url.relativePath.hasPrefix("/") else {
      throw DuckDBLibraryError.invalidPath(url.relativePath)
    }
    let path = url.path
    let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else {
      throw DuckDBLibraryError.loadFailed("\(path): \(String(cString: strerror(errno)))")
    }
    defer { Darwin.close(fd) }

    guard try sha256Hex(of: fd, path: path) == expectedSHA256.lowercased() else {
      throw DuckDBLibraryError.integrityMismatch
    }
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard fcntl(fd, F_GETPATH, &resolved) != -1 else {
      throw DuckDBLibraryError.loadFailed("\(path): \(String(cString: strerror(errno)))")
    }
    let verifiedPath = String(cString: resolved)
    guard let handle = dlopen(verifiedPath, RTLD_NOW | RTLD_LOCAL) else {
      let message = dlerror().map { String(cString: $0) } ?? "dlopen failed for \(verifiedPath)"
      throw DuckDBLibraryError.loadFailed(message)
    }
    let library = try DuckDBLibrary(handle: handle)
    let version = library.version
    let actual = version.hasPrefix("v") ? String(version.dropFirst()) : version
    guard actual == expectedVersion else {
      throw DuckDBLibraryError.versionMismatch(expected: expectedVersion, actual: actual)
    }
    return library
  }

  private static func sha256Hex(of fd: Int32, path: String) throws -> String {
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        throw DuckDBLibraryError.loadFailed("\(path): \(String(cString: strerror(errno)))")
      }
      if count == 0 { break }
      buffer.withUnsafeBytes {
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count]))
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private init(handle: UnsafeMutableRawPointer) throws {
    func symbol<T>(_ name: String) throws -> T {
      guard let pointer = dlsym(handle, name) else {
        throw DuckDBLibraryError.missingSymbol(name)
      }
      return unsafeBitCast(pointer, to: T.self)
    }
    self.handle = handle
    libraryVersion = try symbol("duckdb_library_version")
    open = try symbol("duckdb_open")
    openExt = try symbol("duckdb_open_ext")
    close = try symbol("duckdb_close")
    connect = try symbol("duckdb_connect")
    disconnect = try symbol("duckdb_disconnect")
    createConfig = try symbol("duckdb_create_config")
    setConfig = try symbol("duckdb_set_config")
    destroyConfig = try symbol("duckdb_destroy_config")
    query = try symbol("duckdb_query")
    destroyResult = try symbol("duckdb_destroy_result")
    resultError = try symbol("duckdb_result_error")
    rowCount = try symbol("duckdb_row_count")
    columnCount = try symbol("duckdb_column_count")
    valueInt64 = try symbol("duckdb_value_int64")
    valueVarchar = try symbol("duckdb_value_varchar")
    free = try symbol("duckdb_free")
  }
}
