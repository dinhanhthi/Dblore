//
//  ColumnValueFilter.swift
//  Dblore
//
//  Category filter of a result grid. Hiding a value drops those rows from the grid only:
//  the loaded result, its row count and the query LIMIT stay as they were.
//

import Foundation

/// One distinct value in a result column, with how many loaded rows have it
struct ColumnCategory: Identifiable, Equatable {
  let key: String
  let label: String
  let count: Int
  var id: String { key }
}

/// Result column index → category keys hidden in the grid. A missing or empty set shows every
/// value.
struct ColumnValueFilter: Equatable {
  var hiddenKeys: [Int: Set<String>] = [:]

  var isEmpty: Bool { hiddenKeys.values.allSatisfy(\.isEmpty) }

  func isActive(_ columnIndex: Int) -> Bool {
    hiddenKeys[columnIndex]?.isEmpty == false
  }

  /// Replace the hidden keys of result column `columnIndex` (an empty set clears that column's filter)
  func settingHidden(_ keys: Set<String>, for columnIndex: Int) -> ColumnValueFilter {
    var copy = self
    if keys.isEmpty {
      copy.hiddenKeys.removeValue(forKey: columnIndex)
    } else {
      copy.hiddenKeys[columnIndex] = keys
    }
    return copy
  }

  /// False when a column's value is one of that column index's hidden categories
  func includes(row: [CellValue], columns: [ColumnInfo]) -> Bool {
    for index in columns.indices {
      guard let hidden = hiddenKeys[index], !hidden.isEmpty else { continue }
      let value = index < row.count ? row[index] : .null
      if hidden.contains(Self.categoryKey(for: value)) { return false }
    }
    return true
  }

  /// Distinct values of result column `columnIndex`, label order, NULL last.
  /// Counts rows in the loaded result, so a hidden value stays listed and can be shown again.
  static func categories(in result: CellResult, columnIndex: Int) -> [ColumnCategory] {
    guard result.columns.indices.contains(columnIndex) else { return [] }
    var counts: [String: Int] = [:]
    var labels: [String: String] = [:]
    var order: [String] = []
    for row in result.rows {
      let value = columnIndex < row.count ? row[columnIndex] : .null
      let key = categoryKey(for: value)
      if counts[key] == nil {
        order.append(key)
        labels[key] = categoryLabel(for: value)
      }
      counts[key, default: 0] += 1
    }
    return order.map { ColumnCategory(key: $0, label: labels[$0] ?? $0, count: counts[$0] ?? 0) }
      .sorted { lhs, rhs in
        if (lhs.key == nullKey) != (rhs.key == nullKey) { return rhs.key == nullKey }
        let order = lhs.label.localizedStandardCompare(rhs.label)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.key < rhs.key
      }
  }

  /// Checkboxes the filter popover mounts. A unique column has one value per loaded row
  /// (up to the row cap); listing every one stalls the click that opens the popover.
  static let listedCategoryLimit = 200

  /// The categories the popover lists, in `categories` order. Search stays inside this prefix.
  static func listedCategories(_ categories: [ColumnCategory]) -> [ColumnCategory] {
    guard categories.count > listedCategoryLimit else { return categories }
    return Array(categories.prefix(listedCategoryLimit))
  }

  /// Identity of a cell value, the text the grid and the checkbox show. Two loaded values
  /// that draw the same (a `%.2f` double, a medium date, JSON truncated at 60 characters)
  /// are one category. Bytea is the bytes themselves: a hash can collide and changes per process.
  static func categoryKey(for value: CellValue) -> String {
    switch value {
    case .data(let bytes):
      return "x:\(bytes.base64EncodedString())"
    default:
      return categoryLabel(for: value)
    }
  }

  static func categoryLabel(for value: CellValue) -> String {
    switch value {
    case .null: return "NULL"
    case .string(let value) where value.isEmpty: return "(empty)"
    case .json(let value):
      let flat = value.replacingOccurrences(of: "\n", with: " ")
      return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    default:
      let text = value.displayString
      return text.isEmpty ? "(empty)" : text
    }
  }

  /// `categoryLabel` of NULL, so the null category sorts last and matches the grid text
  private static let nullKey = "NULL"
}
