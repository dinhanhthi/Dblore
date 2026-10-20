//
//  TableHighlight.swift
//  Dblore
//

import AppKit
import SwiftUI

/// Preset paint colors of a highlight. Raw values are what saved highlights store.
enum HighlightColor: String, Codable, CaseIterable {
  case yellow, green, blue, red, purple, orange, pink, cyan, gray

  var displayName: String { rawValue.capitalized }

  /// The palette color of the same name; nil for yellow and red, which use the semantic tokens
  var accent: AccentColor? {
    switch self {
    case .blue: .blue
    case .purple: .purple
    case .green: .green
    case .orange: .orange
    case .pink: .pink
    case .cyan: .cyan
    case .gray: .gray
    case .yellow, .red: nil
    }
  }

  var color: Color {
    if let accent { return accent.tagColor }
    return self == .red ? .destructive : .warning
  }

  var nsColor: NSColor { NSColor(color) }
}

extension HighlightColor {
  /// A stored name this build does not know reads as yellow, so the other saved highlights load
  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = HighlightColor(rawValue: raw.lowercased()) ?? .yellow
  }
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
struct TableHighlight: Codable, Hashable, Identifiable {
  /// Session identity of an applied rule (not stored)
  var id = UUID()
  var filter: TableFilter
  var color: HighlightColor = .yellow
  var style: HighlightStyle = .cell
  /// Applied rules can be switched off without removing them (not stored)
  var isEnabled = true

  enum CodingKeys: String, CodingKey {
    case filter, color, style
  }

  var isEmpty: Bool { filter.isEmpty }

  /// At least one condition the matcher evaluates: complete, and an `in` list with an item (the
  /// conditions `TableFilter.whereClause` keeps). A rule without one paints nothing, so it is
  /// never applied, saved or counted as active.
  var hasCompleteCondition: Bool {
    filter.conditions.contains { condition in
      condition.isComplete
        && (condition.op != .in
          || condition.value.split(separator: ",").contains {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
          })
    }
  }

  /// Same conditions (ignoring their ids), color and style, whatever the id and enabled state
  func isSameRule(as other: TableHighlight) -> Bool {
    color == other.color && style == other.style
      && filter.conditions.count == other.filter.conditions.count
      && zip(filter.conditions, other.filter.conditions).allSatisfy { lhs, rhs in
        lhs.column == rhs.column && lhs.op == rhs.op && lhs.value == rhs.value
          && lhs.connector == rhs.connector && lhs.emptyStringIsValue == rhs.emptyStringIsValue
      }
  }
}

/// The colors several highlight rules paint on the loaded rows, compiled once per rule set so a
/// cell lookup is two dictionary reads. Rules apply in order: the first matching rule wins, and a
/// matching cell rule beats a matching row rule for that cell.
struct HighlightPaint {
  /// Row -> column -> color of the first cell rule matching that cell
  private(set) var cells: [Int: [Int: HighlightColor]] = [:]
  /// Row -> color of the first row rule matching that row
  private(set) var rows: [Int: HighlightColor] = [:]

  init() {}

  /// Enabled `rules` with a complete condition, evaluated over `rows`
  init(rules: [TableHighlight], rows values: [[CellValue]], columns: [String], dialect: SQLDialect)
  {
    for rule in rules where rule.isEnabled && rule.hasCompleteCondition {
      let matches = rule.matches(rows: values, columns: columns, dialect: dialect)
      for (row, hits) in matches {
        switch rule.style {
        case .row:
          if rows[row] == nil { rows[row] = rule.color }
        case .cell:
          for column in hits where cells[row]?[column] == nil {
            cells[row, default: [:]][column] = rule.color
          }
        }
      }
    }
  }

  func color(row: Int, column: Int) -> HighlightColor? {
    cells[row]?[column] ?? rows[row]
  }
}
