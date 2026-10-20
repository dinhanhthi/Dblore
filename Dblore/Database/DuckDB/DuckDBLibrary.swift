// DuckDBLibrary.swift
// Loads the optional libduckdb plugin through PluginLoader (hash, Team ID, dlopen) and resolves
// the small part of the DuckDB C API (duckdb.h v1.5.6) that Dblore uses, via dlsym.

import Darwin
import Foundation

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

extension DuckDBLibraryError {
  /// The same refusal under the DuckDB error type (the payloads are unchanged).
  nonisolated init(_ error: PluginLoaderError) {
    switch error {
    case .loadFailed(let message): self = .loadFailed(message)
    case .invalidPath(let path): self = .invalidPath(path)
    case .integrityMismatch: self = .integrityMismatch
    case .teamIDMismatch(let expected, let actual):
      self = .teamIDMismatch(expected: expected, actual: actual)
    }
  }
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
/// pass `expectedTeamID` (`PluginManager.loadLibrary` always passes
/// `PluginLoader.teamIdentifier`): dlopen of a quarantined, non-notarized dylib fails ("library
/// load disallowed by system policy") and shows a Gatekeeper dialog, and a wrong-team dylib fails
/// library validation.
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
  /// must be valid, chain to Apple and carry that Team ID before dlopen. `maxSize` caps the bytes
  /// hashed. Every check before dlopen is `PluginLoader.open`'s; see there for the order and the
  /// check-to-load race it narrows. On a version mismatch the library stays loaded (it is never
  /// dlclose'd) but is not returned.
  static func load(
    at url: URL, expectedSHA256: String, expectedVersion: String, expectedTeamID: String? = nil,
    maxSize: Int64? = nil
  ) throws -> DuckDBLibrary {
    let handle: UnsafeMutableRawPointer
    do {
      handle = try PluginLoader.open(
        at: url, expectedSHA256: expectedSHA256, expectedTeamID: expectedTeamID, maxSize: maxSize)
    } catch let error as PluginLoaderError {
      throw DuckDBLibraryError(error)
    }
    return try bind(handle: handle, expectedVersion: expectedVersion)
  }

  /// Resolves the C API from a handle `PluginLoader.open` returned and checks that
  /// `duckdb_library_version()` (without its "v") is `expectedVersion`.
  static func bind(handle: UnsafeMutableRawPointer, expectedVersion: String) throws -> DuckDBLibrary
  {
    let library = try DuckDBLibrary(handle: handle)
    let version = library.version
    let actual = version.hasPrefix("v") ? String(version.dropFirst()) : version
    guard actual == expectedVersion else {
      throw DuckDBLibraryError.versionMismatch(expected: expectedVersion, actual: actual)
    }
    return library
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

extension PluginManager {
  /// The DuckDB plugin's library, verified and loaded once per manager (see `loadLibrary`).
  nonisolated func loadDuckDBLibrary() throws -> DuckDBLibrary {
    try loadLibrary { handle, entry in
      try DuckDBLibrary.bind(handle: handle, expectedVersion: entry.version)
    }
  }
}
