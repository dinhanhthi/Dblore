// PluginCatalog.swift
// The pinned plugins (id, version, release URL, SHA-256, size cap, library file name), read from
// the bundled PluginCatalog.json (schema version 2). Decoding is strict: any invalid entry fails
// the whole catalog, so nothing is downloaded or loaded from a catalog that is only partly valid.

import Foundation

nonisolated enum PluginCatalogError: LocalizedError, Equatable {
  /// PluginCatalog.json is not in the bundle.
  case missingResource
  /// Not a JSON object, or a field is missing or has the wrong type.
  case malformed
  /// `schemaVersion` is missing or not 2.
  case unsupportedSchemaVersion
  /// The id is not `[a-z0-9-]+` (it becomes a directory name).
  case invalidID(String)
  /// Two entries share an id.
  case duplicateID(String)
  /// The URL is not an https github.com release asset under tag `plugin-<id>-v<version>`
  /// named `libraryFileName`.
  case invalidURL(String)
  /// The SHA-256 is not 64 lowercase hex digits.
  case invalidSHA256(String)
  /// The version is not dot-separated digits (it becomes a directory name).
  case invalidVersion(String)
  /// The size cap is not in 1...256 MiB.
  case invalidMaxSize(String)
  /// The library file name is not a visible `.dylib` basename.
  case invalidLibraryFileName(String)

  var errorDescription: String? {
    switch self {
    case .missingResource: "The plugin catalog is missing from the app."
    case .malformed: "The plugin catalog is not valid JSON in the expected format."
    case .unsupportedSchemaVersion: "The plugin catalog has an unsupported schema version."
    case .invalidID(let id): "The plugin catalog has an invalid plugin id \"\(id)\"."
    case .duplicateID(let id): "The plugin catalog lists \"\(id)\" more than once."
    case .invalidURL(let id): "The plugin catalog has an invalid download URL for \"\(id)\"."
    case .invalidSHA256(let id): "The plugin catalog has an invalid SHA-256 for \"\(id)\"."
    case .invalidVersion(let id): "The plugin catalog has an invalid version for \"\(id)\"."
    case .invalidMaxSize(let id): "The plugin catalog has an invalid size limit for \"\(id)\"."
    case .invalidLibraryFileName(let id):
      "The plugin catalog has an invalid library file name for \"\(id)\"."
    }
  }
}

/// One validated plugin of the catalog.
nonisolated struct PluginCatalogEntry: Sendable, Equatable {
  /// Lowercase id, e.g. "duckdb"; names the plugin's directory and its release tag.
  let id: String
  /// Bare version, e.g. "1.5.6"; for DuckDB it matches `duckdb_library_version()` without its "v".
  let version: String
  /// GitHub release asset (tag plugin-<id>-v<version>).
  let url: URL
  /// Lowercase hex SHA-256 of the signed, notarized library.
  let sha256: String
  /// Largest download accepted, in bytes.
  let maxSize: Int64
  /// File name of the installed library, e.g. "libduckdb.dylib".
  let libraryFileName: String

  /// Upper bound for `maxSize`: 256 MiB.
  static let maxAllowedSize: Int64 = 256 << 20

  /// Dot-separated ASCII digits, e.g. "1.5.6". Also names the plugin's version directory.
  static func isValidVersion(_ version: String) -> Bool {
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    return !parts.isEmpty
      && parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
  }

  static func isValidID(_ id: String) -> Bool {
    !id.isEmpty
      && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || isDigit($0) || $0 == "-" }
  }

  static func isValidSHA256(_ sha256: String) -> Bool {
    sha256.unicodeScalars.count == 64
      && sha256.unicodeScalars.allSatisfy { isDigit($0) || ("a"..."f").contains($0) }
  }

  /// A visible `.dylib` basename of ASCII letters, digits, ".", "_" and "-" (so no "/" or NUL),
  /// without "..".
  static func isValidLibraryFileName(_ name: String) -> Bool {
    name.hasSuffix(".dylib") && name.count > ".dylib".count && !name.hasPrefix(".")
      && !name.contains("..") && name.unicodeScalars.allSatisfy(isNameCharacter)
  }

  /// Exactly `https://github.com/<owner>/<repo>/releases/download/plugin-<id>-v<version>/<asset>`
  /// where `<asset>` is `libraryFileName`. No userinfo, port, query, fragment or percent-encoding,
  /// and the parsed URL must print back as the same string.
  static func isValidReleaseURL(
    _ raw: String, id: String, version: String, libraryFileName: String
  ) -> Bool {
    guard !raw.contains("%"), let parts = URLComponents(string: raw),
      parts.scheme == "https", parts.host == "github.com",
      parts.user == nil, parts.password == nil, parts.port == nil,
      parts.query == nil, parts.fragment == nil,
      parts.url?.absoluteString == raw
    else { return false }
    let segments = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
    return segments.count == 7 && segments[0].isEmpty
      && isSafePathSegment(segments[1]) && isSafePathSegment(segments[2])
      && segments[3] == "releases" && segments[4] == "download"
      && segments[5] == "plugin-\(id)-v\(version)" && segments[6] == libraryFileName
  }

  private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }

  private static func isNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || isDigit(scalar)
      || scalar == "." || scalar == "_" || scalar == "-"
  }

  private static func isSafePathSegment(_ segment: Substring) -> Bool {
    !segment.isEmpty && segment != "." && segment != ".."
      && segment.unicodeScalars.allSatisfy(isNameCharacter)
  }
}

nonisolated struct PluginCatalog: Sendable, Equatable {
  /// The only schema version this build reads.
  static let supportedSchemaVersion = 2
  static let resourceName = "PluginCatalog"

  let schemaVersion: Int
  let plugins: [PluginCatalogEntry]

  func entry(id: String) -> PluginCatalogEntry? {
    plugins.first { $0.id == id }
  }

  /// Reads and validates the catalog shipped in `bundle`.
  static func bundled(_ bundle: Bundle = .main) throws -> PluginCatalog {
    guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
      throw PluginCatalogError.missingResource
    }
    return try decode(Data(contentsOf: url))
  }

  /// Decodes and validates catalog JSON. Throws on the first violation; never returns a partial
  /// catalog.
  static func decode(_ data: Data) throws -> PluginCatalog {
    let decoder = JSONDecoder()
    guard let header = try? decoder.decode(RawHeader.self, from: data) else {
      throw PluginCatalogError.malformed
    }
    guard header.schemaVersion == supportedSchemaVersion else {
      throw PluginCatalogError.unsupportedSchemaVersion
    }
    guard let raw = try? decoder.decode(RawCatalog.self, from: data) else {
      throw PluginCatalogError.malformed
    }
    var seen = Set<String>()
    let plugins = try raw.plugins.map { entry in
      let validated = try validate(entry)
      guard seen.insert(validated.id).inserted else {
        throw PluginCatalogError.duplicateID(validated.id)
      }
      return validated
    }
    return PluginCatalog(schemaVersion: supportedSchemaVersion, plugins: plugins)
  }

  private static func validate(_ raw: RawEntry) throws -> PluginCatalogEntry {
    let id = raw.id
    guard PluginCatalogEntry.isValidID(id) else { throw PluginCatalogError.invalidID(id) }
    guard PluginCatalogEntry.isValidVersion(raw.version) else {
      throw PluginCatalogError.invalidVersion(id)
    }
    guard PluginCatalogEntry.isValidSHA256(raw.sha256) else {
      throw PluginCatalogError.invalidSHA256(id)
    }
    guard raw.maxSize > 0, raw.maxSize <= PluginCatalogEntry.maxAllowedSize else {
      throw PluginCatalogError.invalidMaxSize(id)
    }
    guard PluginCatalogEntry.isValidLibraryFileName(raw.libraryFileName) else {
      throw PluginCatalogError.invalidLibraryFileName(id)
    }
    guard
      PluginCatalogEntry.isValidReleaseURL(
        raw.url, id: id, version: raw.version, libraryFileName: raw.libraryFileName),
      let url = URL(string: raw.url)
    else { throw PluginCatalogError.invalidURL(id) }
    return PluginCatalogEntry(
      id: id, version: raw.version, url: url, sha256: raw.sha256, maxSize: raw.maxSize,
      libraryFileName: raw.libraryFileName)
  }

  private nonisolated struct RawHeader: Decodable {
    let schemaVersion: Int?
  }

  private nonisolated struct RawCatalog: Decodable {
    let plugins: [RawEntry]
  }

  private nonisolated struct RawEntry: Decodable {
    let id: String
    let version: String
    let url: String
    let sha256: String
    let maxSize: Int64
    let libraryFileName: String
  }
}
