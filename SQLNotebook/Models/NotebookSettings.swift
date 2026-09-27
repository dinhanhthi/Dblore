//
//  NotebookSettings.swift
//  SQLNotebook
//

import Foundation

/// Settings for a notebook document
/// NOTE: Most settings have been moved to AppSettings (global app settings).
/// This struct is kept for backward compatibility and future per-notebook settings.
struct NotebookSettings: Codable, Sendable {
  /// Custom keyboard shortcuts (to be expanded in the future)
  /// Format: ["action": "keyEquivalent"]
  var keyboardShortcuts: [String: String]

  nonisolated init(
    keyboardShortcuts: [String: String] = [:]
  ) {
    self.keyboardShortcuts = keyboardShortcuts
  }
}

// MARK: - Codable Support

extension NotebookSettings {
  enum CodingKeys: String, CodingKey {
    case keyboardShortcuts
    // Legacy keys for backward compatibility (will be ignored when loading)
    case maxResultHeight
    case includeResultsOnSave
  }

  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    keyboardShortcuts =
      try container.decodeIfPresent([String: String].self, forKey: .keyboardShortcuts) ?? [:]

    // Ignore legacy settings (they're now in AppSettings)
    // Keep them in CodingKeys for backward compatibility when reading old files
  }

  nonisolated func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(keyboardShortcuts, forKey: .keyboardShortcuts)
    // Don't encode legacy settings
  }
}
