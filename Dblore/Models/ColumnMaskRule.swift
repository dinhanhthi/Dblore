//
//  ColumnMaskRule.swift
//  Dblore
//

import Foundation
import os

/// A per-connection rule that hides a result column's values in what Dblore shows. A display
/// guard matched on names, not access control: a query that renames or computes a column is not
/// masked.
///
/// The pattern is `column`, `table.column` or `schema.table.column`, compared case-insensitively.
/// `*` may stand for a whole schema or table segment (`*.email`), never for the column: a column
/// wildcard would match every column of an unresolved result, the data viewer's `dblore_` helper
/// columns included. Such a pattern is refused when typed, imported or decoded as one rule; a
/// stored list reads rule by rule (`Lenient`) and drops it.
nonisolated struct ColumnMaskRule: Codable, Hashable, Sendable {
  enum Style: String, Codable, CaseIterable, Sendable {
    /// `••••`
    case full
    /// `••••1234`: the last four characters (grapheme clusters, so none is split); values of
    /// fewer than five characters show `••••`
    case lastFour
    /// `j•••@example.com`: the first character of the local part and the domain; text that is
    /// not one `@` between a non-empty local part and a domain without whitespace shows `••••`
    case email
    /// The value becomes NULL
    case null

    /// How much a style hides, for the strictest matching rule: `null` and `full` hide the whole
    /// value (`null` ranks first), `email` keeps a character and the domain, `lastFour` the end.
    var strictness: Int {
      switch self {
      case .null: 3
      case .full: 2
      case .email: 1
      case .lastFour: 0
      }
    }
  }

  enum PatternError: Error, Equatable, Sendable {
    case empty, tooLong, tooManySegments, emptySegment, wildcardColumn, partialWildcard
  }

  /// The table a result column comes from, when it is known. A nil `schema` is unknown, so a
  /// rule's schema segment matches any.
  struct Origin: Hashable, Sendable {
    var schema: String?
    var table: String
  }

  static let maxRules = 100
  static let patternLimit = 255
  static let maskText = "\u{2022}\u{2022}\u{2022}\u{2022}"

  /// Trimmed segments joined with `.`, in the case typed
  let pattern: String
  var style: Style

  init(pattern: String, style: Style) throws {
    self.pattern = try Self.parse(pattern).joined(separator: ".")
    self.style = style
  }

  /// Lowercased: rules with the same normalized pattern target the same columns.
  var normalizedPattern: String { pattern.lowercased() }

  /// The trimmed segments of a valid pattern (1 to 3, the column last).
  static func parse(_ pattern: String) throws -> [String] {
    let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw PatternError.empty }
    guard trimmed.count <= patternLimit else { throw PatternError.tooLong }
    let segments = trimmed.split(separator: ".", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard segments.count <= 3 else { throw PatternError.tooManySegments }
    guard !segments.contains(where: \.isEmpty) else { throw PatternError.emptySegment }
    guard segments.last != "*" else { throw PatternError.wildcardColumn }
    guard !segments.contains(where: { $0 != "*" && $0.contains("*") }) else {
      throw PatternError.partialWildcard
    }
    return segments
  }

  private enum CodingKeys: String, CodingKey { case pattern, style }

  /// Refuses an invalid pattern and an unknown style (never a weaker fallback; a stored list falls
  /// back through `Lenient`, failing closed).
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawStyle = try container.decode(String.self, forKey: .style)
    guard let style = Style(rawValue: rawStyle) else {
      throw DecodingError.dataCorruptedError(
        forKey: .style, in: container, debugDescription: "Unknown mask style")
    }
    do {
      try self.init(pattern: container.decode(String.self, forKey: .pattern), style: style)
    } catch let error as PatternError {
      throw DecodingError.dataCorruptedError(
        forKey: .pattern, in: container, debugDescription: "Invalid mask pattern: \(error)")
    }
  }

  /// `primary`, then the rules of `extra` whose normalized pattern `primary` lacks (`primary`'s
  /// style wins), at most `maxRules` with `primary`'s first.
  static func union(_ primary: [ColumnMaskRule], _ extra: [ColumnMaskRule]) -> [ColumnMaskRule] {
    var seen = Set(primary.map(\.normalizedPattern))
    var merged = primary
    for rule in extra where seen.insert(rule.normalizedPattern).inserted {
      merged.append(rule)
    }
    return Array(merged.prefix(maxRules))
  }
}

nonisolated extension ColumnMaskRule {
  /// One element of a stored rule list, read failing closed so one rule never makes a workspace
  /// or connection unreadable: an unknown or missing style masks fully, and a rule without a
  /// valid pattern is nil (dropped). A single `ColumnMaskRule` decodes strictly.
  struct Lenient: Decodable, Sendable {
    let rule: ColumnMaskRule?

    init(from decoder: Decoder) {
      let container = try? decoder.container(keyedBy: CodingKeys.self)
      let style = ((try? container?.decodeIfPresent(String.self, forKey: .style)) ?? nil)
        .flatMap(Style.init(rawValue:))
      rule = ((try? container?.decodeIfPresent(String.self, forKey: .pattern)) ?? nil)
        .flatMap { try? ColumnMaskRule(pattern: $0, style: style ?? .full) }
    }
  }
}

nonisolated extension ColumnMaskRule.Style {
  /// What a masked cell shows. NULL and non-text values become mask text too (a NULL shows
  /// `••••`, so a masked column never tells NULL from a value), except with `.null`.
  func masked(_ value: CellValue) -> CellValue {
    let mask = ColumnMaskRule.maskText
    guard self != .null else { return .null }
    guard self != .full, let text = Self.text(of: value) else { return .string(mask) }
    switch self {
    case .lastFour:
      return .string(text.count < 5 ? mask : mask + text.suffix(4))
    case .email:
      let parts = text.split(separator: "@", omittingEmptySubsequences: false)
      guard parts.count == 2, let first = parts[0].first, !parts[1].isEmpty,
        !parts[1].contains(where: \.isWhitespace)
      else {
        return .string(mask)
      }
      return .string("\(first)\u{2022}\u{2022}\u{2022}@\(parts[1])")
    case .full, .null:
      return .string(mask)
    }
  }

  /// The text a partial style keeps part of. Nil for NULL and bytes.
  private static func text(of value: CellValue) -> String? {
    switch value {
    case .string(let text), .decimal(let text), .json(let text): return text
    case .null, .data: return nil
    case .int, .double, .bool, .date: return value.displayString
    }
  }
}

/// Rules compiled once, so a result matches each column once rather than each cell.
nonisolated struct ColumnMaskRuleSet: Sendable {
  private struct Compiled: Sendable {
    var rule: ColumnMaskRule
    /// Lowercased; nil is `*` or absent
    var schema: String?
    var table: String?
    var column: String
  }

  private let compiled: [Compiled]

  init(_ rules: [ColumnMaskRule]) {
    // A rule's pattern is already parsed (trimmed segments joined with `.`), so every rule
    // compiles: none is dropped
    let compiled = rules.map { rule -> Compiled in
      let segments = rule.normalizedPattern.split(separator: ".").map(String.init)
      func literal(_ index: Int) -> String? {
        index >= 0 && segments[index] != "*" ? segments[index] : nil
      }
      let column = segments.count - 1
      return Compiled(
        rule: rule, schema: literal(column - 2), table: literal(column - 1),
        column: segments[column])
    }
    // Strictest style first, then the most specific (a named table outranks a named schema),
    // then the list order
    func rank(_ item: Compiled) -> (Int, Int) {
      (item.rule.style.strictness, (item.table != nil ? 2 : 0) + (item.schema != nil ? 1 : 0))
    }
    self.compiled = compiled.enumerated().sorted {
      let (lhs, rhs) = (rank($0.element), rank($1.element))
      return lhs != rhs ? lhs > rhs : $0.offset < $1.offset
    }.map(\.element)
  }

  var isEmpty: Bool { compiled.isEmpty }

  /// A rule that names a table or schema names one of `columns`, so matching them needs their
  /// origins
  func needsOrigin(forColumns columns: [String]) -> Bool {
    let names = Set(columns.map { $0.lowercased() })
    return compiled.contains { ($0.table != nil || $0.schema != nil) && names.contains($0.column) }
  }

  /// The strictest rule that matches `column` of a table `origin` (`Style.strictness`; ties: the
  /// most specific, then the first in the list). Masking is a display guard, so a narrower rule
  /// never weakens a broader one: `users.email` showing the last four never outranks `email`
  /// masked fully. Fails closed: without an origin a qualified rule matches on its column
  /// segment alone, and an origin without a schema matches any schema segment.
  func matchingRule(column: String, origin: ColumnMaskRule.Origin?) -> ColumnMaskRule? {
    let column = column.lowercased()
    let table = origin?.table.lowercased()
    let schema = origin?.schema?.lowercased()
    return compiled.first { item in
      guard item.column == column else { return false }
      if let wanted = item.table, let table, wanted != table { return false }
      if let wanted = item.schema, let schema, wanted != schema { return false }
      return true
    }?.rule
  }
}

/// The mask rules of the saved rows, read at use time so every live manager masks with rules
/// saved in another window or the Welcome editor. Process-wide, lock-protected and nonisolated
/// (the connection manager actor reads it). Filled lazily from the history in `UserDefaults`,
/// without passwords (never the Keychain), and reset by `SessionManager` at every write of the
/// history key.
nonisolated enum SavedMaskRules {
  private struct State {
    /// Bumped by `reset`: a fill that read the history before a reset is not cached
    var generation = 0
    /// Held strongly, so another instance at the same address never reads this cache
    var defaults: UserDefaults?
    /// Saved rows that have mask rules
    var rows: [ConnectionHistoryEntry] = []
  }

  private static let state = OSAllocatedUnfairLock(uncheckedState: State())

  /// The rules of every saved row `ConnectionHistoryEntry.isSavedRow(of:)` matches for `config`.
  static func rules(
    for config: ConnectionConfig, defaults: UserDefaults = .standard
  ) -> [ColumnMaskRule] {
    rows(in: defaults).filter { $0.isSavedRow(of: config) }
      .reduce(into: []) { $0 = ColumnMaskRule.union($0, $1.config.maskRules) }
  }

  /// Forgets the cached rows: the next read loads the history again.
  static func reset() {
    state.withLockUnchecked {
      $0.generation += 1
      $0.defaults = nil
      $0.rows = []
    }
  }

  private static func rows(in defaults: UserDefaults) -> [ConnectionHistoryEntry] {
    let cached = state.withLockUnchecked { state in
      (state.defaults === defaults ? state.rows : nil, state.generation)
    }
    if let rows = cached.0 { return rows }
    let rows = SessionManager.savedRowsWithoutPasswords(defaults: defaults)
      .filter { !$0.config.maskRules.isEmpty }
    state.withLockUnchecked { state in
      guard state.generation == cached.1 else { return }
      state.defaults = defaults
      state.rows = rows
    }
    return rows
  }
}
