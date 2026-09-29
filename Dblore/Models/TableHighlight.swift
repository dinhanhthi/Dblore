//
//  TableHighlight.swift
//  Dblore
//

import AppKit
import SwiftUI

/// Preset paint colors of a highlight
enum HighlightColor: String, Codable, CaseIterable {
  case yellow, green, blue, red, purple, orange

  var displayName: String { rawValue.capitalized }

  var nsColor: NSColor {
    switch self {
    case .yellow: return .systemYellow
    case .green: return .systemGreen
    case .blue: return .systemBlue
    case .red: return .systemRed
    case .purple: return .systemPurple
    case .orange: return .systemOrange
    }
  }

  var color: Color { Color(nsColor: nsColor) }
}

/// What a matching row paints
enum HighlightStyle: String, Codable, CaseIterable {
  case cell, row

  var displayName: String {
    switch self {
    case .cell: return "Matching cell"
    case .row: return "Whole row"
    }
  }
}

/// A filter-like rule that paints matching rows of the loaded page instead of hiding the others
struct TableHighlight: Codable, Hashable {
  var filter: TableFilter
  var color: HighlightColor = .yellow
  var style: HighlightStyle = .cell

  var isEmpty: Bool { filter.isEmpty }
}
