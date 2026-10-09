// DuckDBPluginCatalog.swift
// The pinned DuckDB plugin (version, release URL, SHA-256, size cap), read from the bundled
// DuckDBPluginCatalog.json. scripts/release-plugin.sh --publish rewrites version, url and sha256.

import Foundation

nonisolated enum DuckDBPluginCatalogError: Error, Equatable {
  /// DuckDBPluginCatalog.json is not in the bundle.
  case missingResource
  /// The URL is not https on github.com.
  case invalidURL
  /// The SHA-256 is not 64 hex digits.
  case invalidSHA256
  /// The version is not dot-separated digits (it becomes a directory name).
  case invalidVersion
  /// The size cap is not positive.
  case invalidMaxSize
}

nonisolated struct DuckDBPluginCatalog: Decodable, Sendable, Equatable {
  /// Bare DuckDB version, e.g. "1.5.6"; matches `duckdb_library_version()` without its "v".
  let version: String
  /// GitHub release asset (tag plugin-duckdb-v<version>).
  let url: URL
  /// Lowercase hex SHA-256 of the signed, notarized libduckdb.dylib.
  let sha256: String
  /// Largest download accepted, in bytes.
  let maxSize: Int64

  static let resourceName = "DuckDBPluginCatalog"

  /// Reads and validates the catalog shipped in `bundle`.
  static func bundled(_ bundle: Bundle = .main) throws -> DuckDBPluginCatalog {
    guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
      throw DuckDBPluginCatalogError.missingResource
    }
    return try decode(Data(contentsOf: url))
  }

  /// Decodes and validates catalog JSON; the SHA-256 is lowercased.
  static func decode(_ data: Data) throws -> DuckDBPluginCatalog {
    let raw = try JSONDecoder().decode(DuckDBPluginCatalog.self, from: data)
    let catalog = DuckDBPluginCatalog(
      version: raw.version, url: raw.url, sha256: raw.sha256.lowercased(), maxSize: raw.maxSize)
    try catalog.validate()
    return catalog
  }

  /// Dot-separated ASCII digits, e.g. "1.5.6". Also names the plugin's version directory.
  static func isValidVersion(_ version: String) -> Bool {
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    return !parts.isEmpty
      && parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
  }

  func validate() throws {
    guard url.scheme == "https", url.host == "github.com" else {
      throw DuckDBPluginCatalogError.invalidURL
    }
    guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }) else {
      throw DuckDBPluginCatalogError.invalidSHA256
    }
    guard Self.isValidVersion(version) else { throw DuckDBPluginCatalogError.invalidVersion }
    guard maxSize > 0 else { throw DuckDBPluginCatalogError.invalidMaxSize }
  }
}
