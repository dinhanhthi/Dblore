//
//  NotebookSettings.swift
//  SQLNotebook
//

import Foundation

/// Settings for a notebook document
struct NotebookSettings: Codable, Sendable {
  /// Maximum height for result table view (in points)
  var maxResultHeight: CGFloat

  /// Whether to include results when saving the notebook
  var includeResultsOnSave: Bool

  /// Custom keyboard shortcuts (to be expanded in the future)
  /// Format: ["action": "keyEquivalent"]
  var keyboardShortcuts: [String: String]

  /// Maximum number of rows to fetch from database (default 50, max 200)
  var maxRowLimit: Int

  nonisolated init(
    maxResultHeight: CGFloat = 500,
    includeResultsOnSave: Bool = true,
    keyboardShortcuts: [String: String] = [:],
    maxRowLimit: Int = 50
  ) {
    self.maxResultHeight = maxResultHeight
    self.includeResultsOnSave = includeResultsOnSave
    self.keyboardShortcuts = keyboardShortcuts
    // Clamp maxRowLimit between 1 and 200
    self.maxRowLimit = min(max(maxRowLimit, 1), 200)
  }
}

// MARK: - Codable Support for CGFloat

extension NotebookSettings {
  enum CodingKeys: String, CodingKey {
    case maxResultHeight
    case includeResultsOnSave
    case keyboardShortcuts
    case maxRowLimit
  }

  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    // Decode CGFloat as Double
    let maxHeightDouble = try container.decodeIfPresent(Double.self, forKey: .maxResultHeight) ?? 500.0
    self.maxResultHeight = CGFloat(maxHeightDouble)

    self.includeResultsOnSave = try container.decodeIfPresent(Bool.self, forKey: .includeResultsOnSave) ?? true
    self.keyboardShortcuts = try container.decodeIfPresent([String: String].self, forKey: .keyboardShortcuts) ?? [:]

    let decodedMaxRowLimit = try container.decodeIfPresent(Int.self, forKey: .maxRowLimit) ?? 50
    // Clamp maxRowLimit between 1 and 200
    self.maxRowLimit = min(max(decodedMaxRowLimit, 1), 200)
  }

  nonisolated func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    // Encode CGFloat as Double
    try container.encode(Double(maxResultHeight), forKey: .maxResultHeight)
    try container.encode(includeResultsOnSave, forKey: .includeResultsOnSave)
    try container.encode(keyboardShortcuts, forKey: .keyboardShortcuts)
    try container.encode(maxRowLimit, forKey: .maxRowLimit)
  }
}

