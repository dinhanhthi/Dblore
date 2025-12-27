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
  
  nonisolated init(
    maxResultHeight: CGFloat = 500,
    includeResultsOnSave: Bool = true,
    keyboardShortcuts: [String: String] = [:]
  ) {
    self.maxResultHeight = maxResultHeight
    self.includeResultsOnSave = includeResultsOnSave
    self.keyboardShortcuts = keyboardShortcuts
  }
}

// MARK: - Codable Support for CGFloat

extension NotebookSettings {
  enum CodingKeys: String, CodingKey {
    case maxResultHeight
    case includeResultsOnSave
    case keyboardShortcuts
  }
  
  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    
    // Decode CGFloat as Double
    let maxHeightDouble = try container.decodeIfPresent(Double.self, forKey: .maxResultHeight) ?? 500.0
    self.maxResultHeight = CGFloat(maxHeightDouble)
    
    self.includeResultsOnSave = try container.decodeIfPresent(Bool.self, forKey: .includeResultsOnSave) ?? true
    self.keyboardShortcuts = try container.decodeIfPresent([String: String].self, forKey: .keyboardShortcuts) ?? [:]
  }
  
  nonisolated func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    
    // Encode CGFloat as Double
    try container.encode(Double(maxResultHeight), forKey: .maxResultHeight)
    try container.encode(includeResultsOnSave, forKey: .includeResultsOnSave)
    try container.encode(keyboardShortcuts, forKey: .keyboardShortcuts)
  }
}

