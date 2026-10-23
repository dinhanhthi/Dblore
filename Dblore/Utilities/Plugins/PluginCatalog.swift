// PluginCatalog.swift
// The pinned plugins (id, version, release URL, SHA-256, size cap, and by kind the library file
// name or the bundle's name, identifier and cdhash), read from the bundled PluginCatalog.json
// (schema version 3). Decoding is strict: any invalid entry fails the whole catalog, so nothing is
// downloaded or loaded from a catalog that is only partly valid.

import Foundation

nonisolated enum PluginCatalogError: LocalizedError, Equatable {
  /// PluginCatalog.json is not in the bundle.
  case missingResource
  /// Not a JSON object, or a field is missing or has the wrong type.
  case malformed
  /// `schemaVersion` is missing or not 3.
  case unsupportedSchemaVersion
  /// The id is not `[a-z0-9][a-z0-9-]*` (it becomes a directory name).
  case invalidID(String)
  /// Two entries share an id.
  case duplicateID(String)
  /// The `kind` is neither "library" nor "bundle".
  case unsupportedKind(String)
  /// The URL is not an https github.com release asset under tag `plugin-<id>-v<version>`
  /// named after the entry's asset (`Kind.assetName`).
  case invalidURL(String)
  /// The SHA-256 is not 64 lowercase hex digits.
  case invalidSHA256(String)
  /// The version is not dot-separated digits (it becomes a directory name).
  case invalidVersion(String)
  /// The size cap is not in 1...256 MiB.
  case invalidMaxSize(String)
  /// The library file name is not a visible `.dylib` basename.
  case invalidLibraryFileName(String)
  /// The bundle name is not a visible `.bundle` basename.
  case invalidBundleName(String)
  /// The bundle identifier is not reverse-DNS (two or more components of letters, digits and "-").
  case invalidBundleIdentifier(String)
  /// The cdhash is not 40 lowercase hex digits.
  case invalidCDHash(String)

  var errorDescription: String? {
    switch self {
    case .missingResource: "The plugin catalog is missing from the app."
    case .malformed: "The plugin catalog is not valid JSON in the expected format."
    case .unsupportedSchemaVersion: "The plugin catalog has an unsupported schema version."
    case .invalidID(let id): "The plugin catalog has an invalid plugin id \"\(id)\"."
    case .duplicateID(let id): "The plugin catalog lists \"\(id)\" more than once."
    case .unsupportedKind(let id): "The plugin catalog has an unsupported kind for \"\(id)\"."
    case .invalidURL(let id): "The plugin catalog has an invalid download URL for \"\(id)\"."
    case .invalidSHA256(let id): "The plugin catalog has an invalid SHA-256 for \"\(id)\"."
    case .invalidVersion(let id): "The plugin catalog has an invalid version for \"\(id)\"."
    case .invalidMaxSize(let id): "The plugin catalog has an invalid size limit for \"\(id)\"."
    case .invalidLibraryFileName(let id):
      "The plugin catalog has an invalid library file name for \"\(id)\"."
    case .invalidBundleName(let id):
      "The plugin catalog has an invalid bundle name for \"\(id)\"."
    case .invalidBundleIdentifier(let id):
      "The plugin catalog has an invalid bundle identifier for \"\(id)\"."
    case .invalidCDHash(let id): "The plugin catalog has an invalid cdhash for \"\(id)\"."
    }
  }
}

/// One validated plugin of the catalog.
nonisolated struct PluginCatalogEntry: Sendable, Equatable {
  /// What the plugin is, so how it is installed and loaded.
  nonisolated enum Kind: Sendable, Equatable {
    /// A dylib opened with dlopen. `fileName` names the installed library and the release asset,
    /// e.g. "libduckdb.dylib".
    case library(fileName: String)
    /// A loadable bundle loaded into the app's process, e.g. "DbloreLocalAI.bundle". The release
    /// asset is the bundle zipped as `<Name>.zip`; `identifier` is its `CFBundleIdentifier` and
    /// `cdhash` the lowercase hex CDHash its code signature must have.
    case bundle(name: String, identifier: String, cdhash: String)

    /// File name of the release asset: the library itself, or `<Name>.zip` for `<Name>.bundle`.
    var assetName: String {
      switch self {
      case .library(let fileName): fileName
      case .bundle(let name, _, _):
        String(name.dropLast(PluginCatalogEntry.bundleSuffix.count)) + ".zip"
      }
    }
  }

  /// Lowercase id, e.g. "duckdb"; names the plugin's directory and its release tag.
  let id: String
  /// Bare version, e.g. "1.5.6"; for DuckDB it matches `duckdb_library_version()` without its "v".
  let version: String
  /// GitHub release asset (tag plugin-<id>-v<version>, file `kind.assetName`).
  let url: URL
  /// Lowercase hex SHA-256 of the release asset: the signed, notarized library, or the zip of the
  /// bundle.
  let sha256: String
  /// Largest download accepted, in bytes.
  let maxSize: Int64
  let kind: Kind

  /// Upper bound for `maxSize`: 256 MiB.
  static let maxAllowedSize: Int64 = 256 << 20
  static let bundleSuffix = ".bundle"

  /// Dot-separated ASCII digits, e.g. "1.5.6". Also names the plugin's version directory.
  static func isValidVersion(_ version: String) -> Bool {
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    return !parts.isEmpty
      && parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
  }

  /// `[a-z0-9][a-z0-9-]*`: never starts with "-", so it never reads as a command-line option.
  static func isValidID(_ id: String) -> Bool {
    !id.isEmpty && !id.hasPrefix("-")
      && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || isDigit($0) || $0 == "-" }
  }

  static func isValidSHA256(_ sha256: String) -> Bool { isLowercaseHex(sha256, count: 64) }

  /// A code signature's CDHash: 40 lowercase hex digits.
  static func isValidCDHash(_ cdhash: String) -> Bool { isLowercaseHex(cdhash, count: 40) }

  /// A visible `.dylib` basename of ASCII letters, digits, ".", "_" and "-" (so no "/" or NUL),
  /// without "..".
  static func isValidLibraryFileName(_ name: String) -> Bool {
    isVisibleBasename(name, suffix: ".dylib")
  }

  /// A visible `<Name>.bundle` basename, under the same rules as a library file name.
  static func isValidBundleName(_ name: String) -> Bool {
    isVisibleBasename(name, suffix: bundleSuffix)
  }

  /// Reverse-DNS, e.g. "ace.thi.Dblore.LocalAI": two or more non-empty dot-separated components
  /// of ASCII letters, digits and "-".
  static func isValidBundleIdentifier(_ identifier: String) -> Bool {
    let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count >= 2
      && parts.allSatisfy { part in
        !part.isEmpty
          && part.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || isDigit($0) || $0 == "-"
          }
      }
  }

  /// Exactly `https://github.com/<owner>/<repo>/releases/download/plugin-<id>-v<version>/<asset>`
  /// where `<asset>` is `assetName`. No userinfo, port, query, fragment or percent-encoding,
  /// and the parsed URL must print back as the same string.
  static func isValidReleaseURL(
    _ raw: String, id: String, version: String, assetName: String
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
      && segments[5] == "plugin-\(id)-v\(version)" && segments[6] == assetName
  }

  private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }

  private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
    value.unicodeScalars.count == count
      && value.unicodeScalars.allSatisfy { isDigit($0) || ("a"..."f").contains($0) }
  }

  private static func isVisibleBasename(_ name: String, suffix: String) -> Bool {
    name.hasSuffix(suffix) && name.count > suffix.count && !name.hasPrefix(".")
      && !name.contains("..") && name.unicodeScalars.allSatisfy(isNameCharacter)
  }

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
  static let supportedSchemaVersion = 3
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
    let kind = try validateKind(raw)
    guard
      PluginCatalogEntry.isValidReleaseURL(
        raw.url, id: id, version: raw.version, assetName: kind.assetName),
      let url = URL(string: raw.url)
    else { throw PluginCatalogError.invalidURL(id) }
    return PluginCatalogEntry(
      id: id, version: raw.version, url: url, sha256: raw.sha256, maxSize: raw.maxSize,
      kind: kind)
  }

  /// The kind and its own fields; a field the kind needs that is missing makes the catalog
  /// malformed.
  private static func validateKind(_ raw: RawEntry) throws -> PluginCatalogEntry.Kind {
    let id = raw.id
    switch raw.kind {
    case "library":
      guard let fileName = raw.libraryFileName else { throw PluginCatalogError.malformed }
      guard PluginCatalogEntry.isValidLibraryFileName(fileName) else {
        throw PluginCatalogError.invalidLibraryFileName(id)
      }
      return .library(fileName: fileName)
    case "bundle":
      guard let name = raw.bundleName, let identifier = raw.bundleIdentifier,
        let cdhash = raw.cdhash
      else { throw PluginCatalogError.malformed }
      guard PluginCatalogEntry.isValidBundleName(name) else {
        throw PluginCatalogError.invalidBundleName(id)
      }
      guard PluginCatalogEntry.isValidBundleIdentifier(identifier) else {
        throw PluginCatalogError.invalidBundleIdentifier(id)
      }
      guard PluginCatalogEntry.isValidCDHash(cdhash) else {
        throw PluginCatalogError.invalidCDHash(id)
      }
      return .bundle(name: name, identifier: identifier, cdhash: cdhash)
    default:
      throw PluginCatalogError.unsupportedKind(id)
    }
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
    let kind: String
    /// `library` only.
    let libraryFileName: String?
    /// `bundle` only.
    let bundleName: String?
    let bundleIdentifier: String?
    let cdhash: String?
  }
}
