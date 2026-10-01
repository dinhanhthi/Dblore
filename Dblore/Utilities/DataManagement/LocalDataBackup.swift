// LocalDataBackup.swift
// A .dblorebackup directory package. The package is deleted if it would contain a secret.

import Foundation

/// `manifest.json` at the root of a backup package.
nonisolated struct BackupManifest: Codable, Equatable, Sendable {
  var formatVersion: Int
  var appVersion: String
  var created: String
  var categories: [Category]

  nonisolated struct Category: Codable, Equatable, Sendable {
    var id: String
    var itemCount: Int
    var byteSize: Int64
  }
}

nonisolated enum LocalDataBackupError: Error, Equatable, Sendable {
  /// The package's `formatVersion` is not 1.
  case unsupportedVersion(Int)
  /// A selected category has no directory in the package.
  case missingCategory(LocalDataCategory)
  /// A selected category directory is unreadable or does not contain its exported file.
  case corruptCategory(LocalDataCategory)
  /// Export or import was asked for a category that has no provider.
  case missingProvider(LocalDataCategory)
  /// A file in the package matched a secret pattern. The package was removed.
  case secretDetected
}

/// Writes and reads a `.dblorebackup` directory package.
///
/// Local AI models (`LocalDataCategory.isLarge`) are left out of `exportAllCategories()`
/// unless that category is passed in `including`.
nonisolated enum LocalDataBackup {
  static let formatVersion = 1
  static let manifestFileName = "manifest.json"

  /// Every category except large ones. Categories in `including` are kept even when large.
  static func exportAllCategories(
    including large: Set<LocalDataCategory> = []
  ) -> [LocalDataCategory] {
    LocalDataCategory.allCases.filter { !$0.isLarge || large.contains($0) }
  }

  /// Writes `packageURL` as a directory package: `manifest.json` plus one folder per category.
  /// Category counts come from `summary()` after that category's export.
  /// If any file contains a secret, the package is deleted and this throws `secretDetected`.
  static func export(
    categories: [LocalDataCategory],
    providers: [any LocalDataProvider],
    to packageURL: URL,
    appVersion: String? = nil,
    created: Date = Date()
  ) async throws {
    let selected = unique(categories)
    let indexed = try index(providers, required: selected)
    let version = appVersion ?? currentAppVersion()
    var committed = false
    defer {
      if !committed {
        try? FileManager.default.removeItem(at: packageURL)
      }
    }
    if FileManager.default.fileExists(atPath: packageURL.path) {
      try FileManager.default.removeItem(at: packageURL)
    }
    let package = try LocalDataBackupPackage(url: packageURL)
    var entries: [BackupManifest.Category] = []
    for category in selected {
      let provider = indexed[category]!
      try await provider.export(to: package.folder(category))
      let summary = await provider.summary()
      entries.append(
        BackupManifest.Category(
          id: category.rawValue, itemCount: summary.itemCount, byteSize: summary.bytes))
    }
    let manifest = BackupManifest(
      formatVersion: formatVersion,
      appVersion: version,
      created: Self.iso8601(created),
      categories: entries
    )
    try package.write(manifest)
    try package.scanForSecrets()
    committed = true
  }

  /// Reads `manifest.json` and nothing else in the package.
  static func inspect(_ url: URL) throws -> BackupManifest {
    try LocalDataBackupPackage(existing: url).readManifest()
  }

  /// Replaces each selected category from a package.
  ///
  /// Checks `formatVersion` and every selected category folder before replacing anything.
  /// A missing or corrupt folder throws, and existing data is left unchanged.
  ///
  /// After that check, categories are replaced in order. If one provider's `importData`
  /// throws, categories earlier in `categories` may already have been replaced.
  static func `import`(
    _ url: URL,
    categories: [LocalDataCategory],
    providers: [any LocalDataProvider]
  ) async throws {
    let manifest = try inspect(url)
    guard manifest.formatVersion == formatVersion else {
      throw LocalDataBackupError.unsupportedVersion(manifest.formatVersion)
    }
    let selected = unique(categories)
    let indexed = try index(providers, required: selected)
    let package = LocalDataBackupPackage(existing: url)
    for category in selected {
      try package.validate(category, manifest: manifest)
    }
    for category in selected {
      try await indexed[category]!.importData(from: package.folder(category))
    }
  }

  private static func unique(_ categories: [LocalDataCategory]) -> [LocalDataCategory] {
    var seen: Set<LocalDataCategory> = []
    return categories.filter { seen.insert($0).inserted }
  }

  private static func index(
    _ providers: [any LocalDataProvider], required: [LocalDataCategory]
  ) throws -> [LocalDataCategory: any LocalDataProvider] {
    var map: [LocalDataCategory: any LocalDataProvider] = [:]
    for provider in providers {
      map[provider.category] = provider
    }
    for category in required where map[category] == nil {
      throw LocalDataBackupError.missingProvider(category)
    }
    return map
  }

  private static func currentAppVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
  }

  private static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }
}

/// Directory package on disk. Callers use `LocalDataBackup`; this type only touches files.
private nonisolated struct LocalDataBackupPackage {
  var url: URL

  init(url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    self.url = url
  }

  init(existing url: URL) {
    self.url = url
  }

  func folder(_ category: LocalDataCategory) -> URL {
    url.appendingPathComponent(category.rawValue, isDirectory: true)
  }

  func write(_ manifest: BackupManifest) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    try data.write(
      to: url.appendingPathComponent(LocalDataBackup.manifestFileName), options: .atomic)
  }

  func readManifest() throws -> BackupManifest {
    let data = try Data(contentsOf: url.appendingPathComponent(LocalDataBackup.manifestFileName))
    return try JSONDecoder().decode(BackupManifest.self, from: data)
  }

  /// The folder must exist, be listable, and hold a file when the manifest recorded content.
  func validate(_ category: LocalDataCategory, manifest: BackupManifest) throws {
    let folder = folder(category)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else {
      throw LocalDataBackupError.missingCategory(category)
    }
    guard isDirectory.boolValue else {
      throw LocalDataBackupError.corruptCategory(category)
    }
    let children: [URL]
    do {
      children = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles])
    } catch {
      throw LocalDataBackupError.corruptCategory(category)
    }
    let entry = manifest.categories.first { $0.id == category.rawValue }
    let recordedContent = (entry?.itemCount ?? 0) > 0 || (entry?.byteSize ?? 0) > 0
    if recordedContent && !Self.containsFile(children) {
      throw LocalDataBackupError.corruptCategory(category)
    }
  }

  func scanForSecrets() throws {
    for file in try Self.regularFiles(in: url) {
      let data = try Data(contentsOf: file)
      if Self.containsSecretMarker(data) || Self.containsJWT(in: data)
        || Self.containsCredential(data)
      {
        throw LocalDataBackupError.secretDetected
      }
    }
  }

  private static let credentialKeys: Set<String> = ["password", "apiKey", "api_key", "token"]

  /// `sk-ant-` is covered by `sk-`, and both byte sequences are rejected on their own.
  private static func containsSecretMarker(_ data: Data) -> Bool {
    data.range(of: Data("sk-".utf8)) != nil || data.range(of: Data("sk-ant-".utf8)) != nil
  }

  private static func containsJWT(in data: Data) -> Bool {
    let text = String(decoding: data, as: UTF8.self)
    guard
      let expression = try? NSRegularExpression(
        pattern: "[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}")
    else { return false }
    let range = NSRange(text.startIndex..., in: text)
    return expression.firstMatch(in: text, range: range) != nil
  }

  private static func containsCredential(_ data: Data) -> Bool {
    guard looksLikeJSON(data), let object = try? JSONSerialization.jsonObject(with: data) else {
      return false
    }
    return valueHasCredential(object)
  }

  private static func looksLikeJSON(_ data: Data) -> Bool {
    guard
      let first = data.first(where: { byte in
        byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D
      })
    else { return false }
    return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
  }

  private static func valueHasCredential(_ value: Any) -> Bool {
    if let dictionary = value as? NSDictionary {
      for key in dictionary.allKeys {
        guard let name = key as? String else { continue }
        let nested = dictionary[key] as Any
        if credentialKeys.contains(name), let text = nested as? String, !text.isEmpty {
          return true
        }
        if valueHasCredential(nested) { return true }
      }
      return false
    }
    if let array = value as? NSArray {
      for item in array where valueHasCredential(item) {
        return true
      }
      return false
    }
    return false
  }

  private static func containsFile(_ children: [URL]) -> Bool {
    for child in children {
      let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
      if values?.isRegularFile == true { return true }
      if values?.isDirectory == true {
        let nested =
          (try? FileManager.default.contentsOfDirectory(
            at: child, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        if containsFile(nested) { return true }
      }
    }
    return false
  }

  private static func regularFiles(in directory: URL) throws -> [URL] {
    let children = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
      options: [.skipsHiddenFiles])
    var files: [URL] = []
    for child in children {
      let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
      if values.isDirectory == true {
        files.append(contentsOf: try regularFiles(in: child))
      } else if values.isRegularFile == true {
        files.append(child)
      }
    }
    return files
  }
}
