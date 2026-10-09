// DuckDBLibrary.swift
// Loads the optional libduckdb plugin with dlopen and resolves the small part
// of the DuckDB C API (duckdb.h v1.5.6) that Dblore uses, via dlsym.

import CryptoKit
import Darwin
import Foundation
import Security

#if !arch(arm64)
  // `fetchChunk` relies on the AAPCS64 rule for by-value structs larger than 16 bytes.
  #error("DuckDBLibrary passes duckdb_result by value as a pointer; arm64 only")
#endif

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
  /// The file's code signature Team ID differs from the expected one (nil: ad-hoc or unsigned);
  /// dlopen did not run.
  case teamIDMismatch(expected: String, actual: String?)
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
/// pass `expectedTeamID` to `load(at:expectedSHA256:expectedVersion:expectedTeamID:)`: dlopen of a
/// quarantined, non-notarized dylib fails ("library load disallowed by system policy") and shows a
/// Gatekeeper dialog, and a wrong-team dylib fails library validation.
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
  let interrupt: @convention(c) (Handle) -> Void
  let prepare: @convention(c) (Handle, CString, UnsafeMutablePointer<Handle>?) -> Int32
  let prepareError: @convention(c) (Handle) -> CString
  let destroyPrepare: @convention(c) (UnsafeMutablePointer<Handle>?) -> Void
  let bindVarchar: @convention(c) (Handle, UInt64, CString) -> Int32
  let bindNull: @convention(c) (Handle, UInt64) -> Int32
  let executePrepared: @convention(c) (Handle, ResultPointer) -> Int32
  /// Deprecated in the C API since v1.0 but exported by v1.5.6; the only C entry point that
  /// yields a streaming result, which `fetchChunk` reads one chunk at a time.
  let pendingPreparedStreaming: @convention(c) (Handle, UnsafeMutablePointer<Handle>?) -> Int32
  let pendingError: @convention(c) (Handle) -> CString
  let destroyPending: @convention(c) (UnsafeMutablePointer<Handle>?) -> Void
  let executePending: @convention(c) (Handle, ResultPointer) -> Int32
  let rowsChanged: @convention(c) (ResultPointer) -> UInt64
  let columnName: @convention(c) (ResultPointer, UInt64) -> CString
  let columnLogicalType: @convention(c) (ResultPointer, UInt64) -> Handle
  /// `duckdb_fetch_chunk(duckdb_result result)` takes the 48-byte struct by value. AAPCS64
  /// passes a composite larger than 16 bytes as a pointer to a caller-owned copy, so callers
  /// pass a pointer to a copy of their `DuckDBResult`. Valid on arm64 only (ARCHS = arm64).
  let fetchChunk: @convention(c) (ResultPointer) -> Handle
  let destroyDataChunk: @convention(c) (UnsafeMutablePointer<Handle>?) -> Void
  let dataChunkSize: @convention(c) (Handle) -> UInt64
  let dataChunkVector: @convention(c) (Handle, UInt64) -> Handle
  let vectorData: @convention(c) (Handle) -> UnsafeMutableRawPointer?
  let vectorValidity: @convention(c) (Handle) -> UnsafeMutablePointer<UInt64>?
  let listVectorChild: @convention(c) (Handle) -> Handle
  let structVectorChild: @convention(c) (Handle, UInt64) -> Handle
  let arrayVectorChild: @convention(c) (Handle) -> Handle
  let typeID: @convention(c) (Handle) -> Int32
  let destroyLogicalType: @convention(c) (UnsafeMutablePointer<Handle>?) -> Void
  let logicalTypeAlias: @convention(c) (Handle) -> UnsafeMutablePointer<CChar>?
  let decimalWidth: @convention(c) (Handle) -> UInt8
  let decimalScale: @convention(c) (Handle) -> UInt8
  let decimalInternalType: @convention(c) (Handle) -> Int32
  let enumInternalType: @convention(c) (Handle) -> Int32
  let enumDictionarySize: @convention(c) (Handle) -> UInt32
  let enumDictionaryValue: @convention(c) (Handle, UInt64) -> UnsafeMutablePointer<CChar>?
  let listTypeChild: @convention(c) (Handle) -> Handle
  let arrayTypeChild: @convention(c) (Handle) -> Handle
  let arrayTypeSize: @convention(c) (Handle) -> UInt64
  let mapTypeKey: @convention(c) (Handle) -> Handle
  let mapTypeValue: @convention(c) (Handle) -> Handle
  let structTypeChildCount: @convention(c) (Handle) -> UInt64
  let structTypeChildName: @convention(c) (Handle, UInt64) -> UnsafeMutablePointer<CChar>?
  let structTypeChildType: @convention(c) (Handle, UInt64) -> Handle
  let unionMemberCount: @convention(c) (Handle) -> UInt64
  let unionMemberName: @convention(c) (Handle, UInt64) -> UnsafeMutablePointer<CChar>?
  let unionMemberType: @convention(c) (Handle, UInt64) -> Handle

  private let handle: UnsafeMutableRawPointer

  /// `duckdb_library_version()`, e.g. "v1.5.6".
  var version: String {
    libraryVersion().map { String(cString: $0) } ?? ""
  }

  /// Loads the library only if the file hashes to `expectedSHA256` (hex, any case) and then
  /// reports `expectedVersion` (bare, e.g. "1.5.6"). With `expectedTeamID`, the code signature
  /// must be valid, chain to Apple and carry that Team ID before dlopen, so an ad-hoc or foreign
  /// dylib never reaches Gatekeeper. `maxSize` caps the bytes hashed.
  ///
  /// The file is opened once (no symlink, regular file only), hashed through that descriptor,
  /// and dlopen'd by the path `F_GETPATH` returns for it. Right before dlopen the path must still
  /// name the same file, unmodified (device, inode, size and mtime match the descriptor's
  /// pre-hash `fstat`). This narrows but does not close the check-to-load race: the signature
  /// check and dlopen still open by path, and a swap after the final `stat` is not detected.
  /// Hardened-runtime library validation (same Team ID) is the primary guard; the hash binds
  /// the file to the catalog entry. On a version mismatch the library stays loaded (it is never
  /// dlclose'd) but is not returned.
  static func load(
    at url: URL, expectedSHA256: String, expectedVersion: String, expectedTeamID: String? = nil,
    maxSize: Int64? = nil
  ) throws -> DuckDBLibrary {
    guard url.isFileURL, url.relativePath.hasPrefix("/") else {
      throw DuckDBLibraryError.invalidPath(url.relativePath)
    }
    let path = url.path
    let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
      throw DuckDBLibraryError.loadFailed("\(path): \(String(cString: strerror(errno)))")
    }
    defer { Darwin.close(fd) }
    var opened = stat()
    guard fstat(fd, &opened) == 0 else {
      throw DuckDBLibraryError.loadFailed("\(path): \(String(cString: strerror(errno)))")
    }
    guard opened.st_mode & S_IFMT == S_IFREG else {
      throw DuckDBLibraryError.loadFailed("\(path): not a regular file")
    }
    if let maxSize, opened.st_size > maxSize { throw DuckDBLibraryError.integrityMismatch }

    guard try sha256Hex(of: fd, path: path, maxSize: maxSize) == expectedSHA256.lowercased()
    else {
      throw DuckDBLibraryError.integrityMismatch
    }
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard fcntl(fd, F_GETPATH, &resolved) != -1 else {
      throw DuckDBLibraryError.loadFailed("\(path): \(String(cString: strerror(errno)))")
    }
    let verifiedPath = String(
      decoding: resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    if let expectedTeamID {
      try checkTeamID(ofPath: verifiedPath, expected: expectedTeamID)
    }
    var current = stat()
    guard stat(verifiedPath, &current) == 0, isSameFile(opened, current) else {
      throw DuckDBLibraryError.integrityMismatch
    }
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
    else { throw DuckDBLibraryError.teamIDMismatch(expected: expected, actual: nil) }
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
    else { throw DuckDBLibraryError.teamIDMismatch(expected: expected, actual: actual) }
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
        throw DuckDBLibraryError.loadFailed("\(path): \(String(cString: strerror(errno)))")
      }
      if count == 0 { break }
      total += Int64(count)
      if let maxSize, total > maxSize { throw DuckDBLibraryError.integrityMismatch }
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
    interrupt = try symbol("duckdb_interrupt")
    prepare = try symbol("duckdb_prepare")
    prepareError = try symbol("duckdb_prepare_error")
    destroyPrepare = try symbol("duckdb_destroy_prepare")
    bindVarchar = try symbol("duckdb_bind_varchar")
    bindNull = try symbol("duckdb_bind_null")
    executePrepared = try symbol("duckdb_execute_prepared")
    pendingPreparedStreaming = try symbol("duckdb_pending_prepared_streaming")
    pendingError = try symbol("duckdb_pending_error")
    destroyPending = try symbol("duckdb_destroy_pending")
    executePending = try symbol("duckdb_execute_pending")
    rowsChanged = try symbol("duckdb_rows_changed")
    columnName = try symbol("duckdb_column_name")
    columnLogicalType = try symbol("duckdb_column_logical_type")
    fetchChunk = try symbol("duckdb_fetch_chunk")
    destroyDataChunk = try symbol("duckdb_destroy_data_chunk")
    dataChunkSize = try symbol("duckdb_data_chunk_get_size")
    dataChunkVector = try symbol("duckdb_data_chunk_get_vector")
    vectorData = try symbol("duckdb_vector_get_data")
    vectorValidity = try symbol("duckdb_vector_get_validity")
    listVectorChild = try symbol("duckdb_list_vector_get_child")
    structVectorChild = try symbol("duckdb_struct_vector_get_child")
    arrayVectorChild = try symbol("duckdb_array_vector_get_child")
    typeID = try symbol("duckdb_get_type_id")
    destroyLogicalType = try symbol("duckdb_destroy_logical_type")
    logicalTypeAlias = try symbol("duckdb_logical_type_get_alias")
    decimalWidth = try symbol("duckdb_decimal_width")
    decimalScale = try symbol("duckdb_decimal_scale")
    decimalInternalType = try symbol("duckdb_decimal_internal_type")
    enumInternalType = try symbol("duckdb_enum_internal_type")
    enumDictionarySize = try symbol("duckdb_enum_dictionary_size")
    enumDictionaryValue = try symbol("duckdb_enum_dictionary_value")
    listTypeChild = try symbol("duckdb_list_type_child_type")
    arrayTypeChild = try symbol("duckdb_array_type_child_type")
    arrayTypeSize = try symbol("duckdb_array_type_array_size")
    mapTypeKey = try symbol("duckdb_map_type_key_type")
    mapTypeValue = try symbol("duckdb_map_type_value_type")
    structTypeChildCount = try symbol("duckdb_struct_type_child_count")
    structTypeChildName = try symbol("duckdb_struct_type_child_name")
    structTypeChildType = try symbol("duckdb_struct_type_child_type")
    unionMemberCount = try symbol("duckdb_union_type_member_count")
    unionMemberName = try symbol("duckdb_union_type_member_name")
    unionMemberType = try symbol("duckdb_union_type_member_type")
  }
}
