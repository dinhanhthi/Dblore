// DuckDBTestPlugin.swift
// Loads the dev DuckDB plugin from .plugin-dev/ for gated suites (`.requiresDuckDBPlugin`).
// A quarantined, non-notarized file is never dlopen'd: that shows a Gatekeeper dialog.

import Darwin
import Foundation

@testable import Dblore

nonisolated enum DuckDBTestPlugin {
  private struct Catalog: Decodable {
    let version: String
    let sha256: String
    let notarized: Bool
  }

  struct Refused: Error, CustomStringConvertible { let description: String }

  private static let pluginDev = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".plugin-dev", isDirectory: true)

  /// Loaded (and hashed) once per test process.
  private static let loaded: Result<DuckDBLibrary, any Error> = Result {
    let data = try Data(contentsOf: pluginDev.appendingPathComponent("dev-catalog.json"))
    let catalog = try JSONDecoder().decode(Catalog.self, from: data)
    let url = pluginDev.appendingPathComponent("libduckdb.dylib")
    if !catalog.notarized, let value = quarantine(of: url) {
      throw Refused(description: "refused: \(url.lastPathComponent) quarantined (\(value))")
    }
    return try DuckDBLibrary.load(
      at: url, expectedSHA256: catalog.sha256, expectedVersion: catalog.version)
  }

  static func library() throws -> DuckDBLibrary {
    try loaded.get()
  }

  /// nil only when the attribute is absent (`ENOATTR`). Any other failure counts as quarantined.
  private static func quarantine(of url: URL) -> String? {
    var buffer = [CChar](repeating: 0, count: 256)
    let length = getxattr(url.path, "com.apple.quarantine", &buffer, buffer.count - 1, 0, 0)
    if length < 0 {
      let code = errno
      return code == ENOATTR ? nil : "getxattr failed: \(String(cString: strerror(code)))"
    }
    return String(cString: buffer)
  }
}
