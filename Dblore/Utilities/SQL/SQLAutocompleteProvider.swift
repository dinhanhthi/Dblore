//
//  SQLAutocompleteProvider.swift
//  Dblore
//
//  Provides autocomplete suggestions for SQL keywords, table names, and column names
//
//  NOTE: This file has been split into focused modules:
//  - SQLAutocompleteProvider+Keywords.swift (SQL keyword definitions)
//  - SQLAutocompleteProvider+ContextParsing.swift (context detection and parsing)
//

import Foundation

// MARK: - Autocomplete Suggestion Types

enum AutocompleteSuggestionType {
  case keyword
  case table
  case column(tableName: String)
  /// Accepting it inserts the snippet's expanded body (see SQLTextView+Snippets.swift)
  case snippet(SQLSnippet)
}

struct AutocompleteSuggestion: Identifiable, Equatable {
  let id = UUID()
  let text: String
  let type: AutocompleteSuggestionType
  let description: String?

  static func == (lhs: AutocompleteSuggestion, rhs: AutocompleteSuggestion) -> Bool {
    lhs.text == rhs.text
  }
}

// MARK: - SQL Autocomplete Provider

@MainActor
class SQLAutocompleteProvider {
  // Schema cache (tables and their index)
  private(set) var tables: [DatabaseTable] = []
  private(set) var index = SQLAutocompleteIndex.empty
  /// Columns of each table keyed "schema.table"
  var columnsByTable: [String: [DatabaseColumn]] { index.columnsByTable }
  /// Snippets offered by trigger prefix in SQL; tests swap in their own
  var snippets: @MainActor () -> [SQLSnippet] = { SQLSnippetStore.shared.snippets }

  /// Suggestions a popup shows
  static let suggestionLimit = 20

  // MARK: - Schema

  /// Feed the provider from the already loaded schema (tables with their columns and the
  /// foreign keys between them)
  func update(tables: [DatabaseTable], foreignKeys: [ForeignKey] = []) {
    update(tables: tables, index: SQLAutocompleteIndex(tables: tables, foreignKeys: foreignKeys))
  }

  /// Feed the provider with the index of `tables` built off the main actor
  func update(tables: [DatabaseTable], index: SQLAutocompleteIndex) {
    assert(index.tableNames.count == tables.count, "the index must be built from these tables")
    self.tables = tables
    self.index = index
  }

  /// Columns of each table keyed "schema.table"
  nonisolated static func columnIndex(of tables: [DatabaseTable]) -> [String: [DatabaseColumn]] {
    var index: [String: [DatabaseColumn]] = [:]
    index.reserveCapacity(tables.count)
    for table in tables {
      index["\(table.schema).\(table.name)"] = table.columns
    }
    return index
  }

  /// Clear the schema cache (10.1.4 & 10.1.8 optimization)
  func clearCache() {
    tables = []
    index = .empty
  }

  // MARK: - Autocomplete Suggestions

  /// Get autocomplete suggestions based on current input
  /// - Parameters:
  ///   - fullText: Full text content
  ///   - fullCursorPosition: Current cursor position in text (UTF-16 offset)
  ///   - dialect: connection dialect, used to find the statement around the cursor
  /// - Returns: Array of suggestions
  func getSuggestions(
    for fullText: String, at fullCursorPosition: Int, dialect: SQLDialect
  ) -> [AutocompleteSuggestion] {
    if dialect == .mongodb {
      return MongoshAutocompleteProvider.suggestions(
        for: fullText, at: fullCursorPosition, tables: tables)
    }

    // Only the current statement matters (bounded scan, see statementWindow)
    let (text, cursorPosition) = statementWindow(
      in: fullText, at: fullCursorPosition, dialect: dialect)

    // Find the word being typed (token at cursor position)
    let token = extractCurrentToken(from: text, at: cursorPosition)
    let lowerToken = token.lowercased()

    // If token is empty or too short, don't show suggestions (the popup would take Return)
    guard !token.isEmpty else { return [] }

    // Right after `JOIN t [alias] ON` the foreign key conditions come first
    let joinOn = joinOnContext(in: text, before: cursorPosition, dialect: dialect)
    let conditions = joinOn.map { joinConditions($0, lowerToken: lowerToken, dialect: dialect) }

    let scope = statementScope(in: text, cursor: cursorPosition, dialect: dialect)

    // After ORDER BY / GROUP BY, the SELECT-list aliases of that query come first and replace
    // the suggestions with their text, so those are left out of the selection
    let aliases = (scope.orderByAliases ?? []).filter {
      $0.lowercased().hasPrefix(lowerToken)
    }
    // Only the first 20 by relevance are shown: select them instead of sorting every match
    var selection = SuggestionSelection(
      limit: Self.suggestionLimit, lowerToken: lowerToken, excluded: Set(aliases))
    // Offer order breaks ties, as the stable sort over the appended list did
    var order = 0

    // Add keyword suggestions
    for keyword in Self.sqlKeywords {
      let lower = keyword.lowercased()
      guard lower.hasPrefix(lowerToken) else { continue }
      selection.offer(text: keyword, lower: lower, length: keyword.count, order: order) {
        AutocompleteSuggestion(text: keyword, type: .keyword, description: "SQL Keyword")
      }
      order += 1
    }

    // Add table suggestions (lowercased names from the index)
    for (position, name) in index.tableNames.enumerated() where name.lower.hasPrefix(lowerToken) {
      let table = tables[position]
      selection.offer(text: table.name, lower: name.lower, length: name.length, order: order) {
        AutocompleteSuggestion(
          text: table.name,
          type: .table,
          description: "Table (\(table.schema))"
        )
      }
      order += 1
    }

    // CTEs of this statement are tables too
    for cte in scope.ctes {
      let lower = cte.name.lowercased()
      guard lower.hasPrefix(lowerToken) else { continue }
      selection.offer(text: cte.name, lower: lower, length: cte.name.count, order: order) {
        AutocompleteSuggestion(text: cte.name, type: .table, description: "CTE")
      }
      order += 1
    }

    // Add snippet suggestions (trigger prefix, any case)
    for snippet in snippets() {
      let lower = snippet.trigger.lowercased()
      guard lower.hasPrefix(lowerToken) else { continue }
      selection.offer(
        text: snippet.trigger, lower: lower, length: snippet.trigger.count, order: order
      ) {
        AutocompleteSuggestion(
          text: snippet.trigger, type: .snippet(snippet), description: snippet.name)
      }
      order += 1
    }

    // Add column suggestions (context-aware)
    // Try to be smart: if we're after FROM/JOIN, prioritize tables
    // If we're after SELECT/WHERE, prioritize columns
    let context = joinOn ?? detectContext(in: text, before: cursorPosition)
    // Where the column suggestions came from: the referenced tables' keys, nil for every column
    var columnTables: [String]? = []

    if context != .afterFromOrJoin {
      // Extract table references from FROM/JOIN clauses
      let tableRefs = extractTableReferences(from: text)

      if !tableRefs.isEmpty || !scope.referencedCTEs.isEmpty {
        columnTables = Array(tableRefs.values)
        // We have table context - only show columns from referenced tables and CTEs
        // (CTE columns deduped by name, at most maxCTEColumns in all)
        var cteColumnNames: Set<String> = []
        cteLoop: for cte in scope.ctes where scope.referencedCTEs.contains(cte.name.lowercased()) {
          for column in cte.columns {
            guard cteColumnNames.count < Self.maxCTEColumns else { break cteLoop }
            let lowerColumn = column.lowercased()
            guard lowerColumn.hasPrefix(lowerToken), cteColumnNames.insert(lowerColumn).inserted
            else { continue }
            selection.offer(text: column, lower: lowerColumn, length: column.count, order: order) {
              AutocompleteSuggestion(
                text: column, type: .column(tableName: cte.name), description: "CTE (\(cte.name))")
            }
            order += 1
          }
        }
        for (_, tableKey) in tableRefs {
          for column in columnsByTable[tableKey] ?? [] {
            let lower = column.name.lowercased()
            guard lower.hasPrefix(lowerToken) else { continue }
            selection.offer(
              text: column.name, lower: lower, length: column.name.count, order: order
            ) {
              AutocompleteSuggestion(
                text: column.name,
                type: .column(tableName: tableKey),
                description: "\(column.type) (\(tableKey))"
              )
            }
            order += 1
          }
        }
      } else {
        columnTables = nil
        // No table context - show columns from all tables (fallback), one index group per
        // column name, so a name shared by thousands of tables is compared once
        for group in index.columnGroups where group.name.lower.hasPrefix(lowerToken) {
          // Entries are in table order: once one is not kept, the later ones are not either
          for entry in group.entries {
            let kept = selection.offer(
              text: group.text, lower: group.name.lower, length: group.name.length,
              order: order + Int(entry.order)
            ) {
              let tableKey = index.tableKeys[Int(entry.table)]
              let column = index.columnsByTable[tableKey]?[Int(entry.column)]
              return AutocompleteSuggestion(
                text: group.text,
                type: .column(tableName: tableKey),
                description: "\(column?.type ?? "") (\(tableKey))"
              )
            }
            if !kept { break }
          }
        }
      }
    }

    // Contains tier: table and column names holding the token past their start rank after every
    // prefix match, and run only when the prefix tier left room and the token has 2+ characters
    if selection.count < Self.suggestionLimit, lowerToken.count >= 2 {
      offerContains(
        Array(lowerToken.utf8), columnTables: columnTables, to: &selection, order: &order)
    }

    let lead =
      aliases.sorted { $0.lowercased() < $1.lowercased() }.map {
        AutocompleteSuggestion(text: $0, type: .column(tableName: ""), description: "Alias")
      } + (conditions ?? [])
    if lead.isEmpty { return selection.suggestions }
    return Array((lead + selection.suggestions).prefix(Self.suggestionLimit))
  }

  /// The foreign key conditions between the table `JOIN` just named and each table before it,
  /// in either direction, written new table first with the aliases as typed (one condition per
  /// key, a composite key's columns joined with AND). Only those starting with the token: one
  /// typed on the earlier table's alias gets the condition written from that side.
  private func joinConditions(
    _ context: SQLContext, lowerToken: String, dialect: SQLDialect
  ) -> [AutocompleteSuggestion] {
    guard case .joinOn(let earlier, let joined) = context else { return [] }
    let keys = index.foreignKeysByTable[joined.key] ?? []
    var seen: Set<String> = []
    var suggestions: [AutocompleteSuggestion] = []
    for table in earlier {
      for key in keys {
        let source = "\(key.sourceSchema).\(key.sourceTable)"
        let target = "\(key.targetSchema).\(key.targetTable)"
        for joinedIsTarget in [true, false] {
          let (joinedSide, earlierSide) = joinedIsTarget ? (target, source) : (source, target)
          guard joinedSide == joined.key, earlierSide == table.key else { continue }
          func condition(joinedFirst: Bool) -> String? {
            let text = try? JoinQueryBuilder.joinCondition(
              fk: key, leftAlias: joinedFirst ? joined.alias : table.alias,
              rightAlias: joinedFirst ? table.alias : joined.alias,
              leftIsTarget: joinedFirst == joinedIsTarget, dialect: dialect)
            return text.flatMap { $0.lowercased().hasPrefix(lowerToken) ? $0 : nil }
          }
          guard
            let text = condition(joinedFirst: true) ?? condition(joinedFirst: false),
            seen.insert(text).inserted
          else { continue }
          suggestions.append(
            AutocompleteSuggestion(
              text: text, type: .column(tableName: joined.key),
              description: "Join (\(key.constraintName))"))
        }
      }
    }
    return suggestions
  }

  /// The contains tier: tables, then the columns of `columnTables` (every column when nil),
  /// whose lowercased name holds `needle` past its start. Prefix hits were offered already.
  private func offerContains(
    _ needle: [UInt8], columnTables: [String]?, to selection: inout SuggestionSelection,
    order: inout Int
  ) {
    for (position, name) in index.tableNames.enumerated()
    where Self.containsPastStart(name.lower, needle) {
      let table = tables[position]
      selection.offer(
        text: table.name, lower: name.lower, length: name.length, order: order, tier: 1
      ) {
        AutocompleteSuggestion(
          text: table.name, type: .table, description: "Table (\(table.schema))")
      }
      order += 1
    }
    guard let columnTables else {
      // Entries are in table order: once one is not kept, the later ones are not either
      for group in index.columnGroups where Self.containsPastStart(group.name.lower, needle) {
        for entry in group.entries {
          let kept = selection.offer(
            text: group.text, lower: group.name.lower, length: group.name.length,
            order: order + Int(entry.order), tier: 1
          ) {
            let tableKey = index.tableKeys[Int(entry.table)]
            let column = index.columnsByTable[tableKey]?[Int(entry.column)]
            return AutocompleteSuggestion(
              text: group.text, type: .column(tableName: tableKey),
              description: "\(column?.type ?? "") (\(tableKey))")
          }
          if !kept { break }
        }
      }
      return
    }
    for tableKey in columnTables {
      for column in columnsByTable[tableKey] ?? [] {
        let lower = column.name.lowercased()
        guard Self.containsPastStart(lower, needle) else { continue }
        selection.offer(
          text: column.name, lower: lower, length: column.name.count, order: order, tier: 1
        ) {
          AutocompleteSuggestion(
            text: column.name, type: .column(tableName: tableKey),
            description: "\(column.type) (\(tableKey))")
        }
        order += 1
      }
    }
  }

  /// Whether the UTF-8 of `text` holds `needle` somewhere after its first byte, and does not
  /// start with it (a prefix hit belongs to the prefix tier). Bytes, so a keystroke over a large
  /// catalog compares stored keys without building strings.
  nonisolated static func containsPastStart(_ text: String, _ needle: [UInt8]) -> Bool {
    let found = text.utf8.withContiguousStorageIfAvailable { hay in
      needle.withUnsafeBufferPointer { needle in
        let count = needle.count
        guard count > 0, hay.count > count else { return false }
        func matches(at start: Int) -> Bool {
          var offset = 0
          while offset < count, hay[start + offset] == needle[offset] { offset += 1 }
          return offset == count
        }
        if matches(at: 0) { return false }
        let first = needle[0]
        var start = 1
        while start <= hay.count - count {
          if hay[start] == first, matches(at: start) { return true }
          start += 1
        }
        return false
      }
    }
    if let found { return found }
    let token = String(decoding: needle, as: UTF8.self)
    return !text.hasPrefix(token) && text.contains(token)
  }
}

// MARK: - Index

/// Lowercased names of a loaded schema, built once per schema load (off the main actor for a
/// large catalog), so a keystroke compares stored keys instead of lowercasing every name
nonisolated struct SQLAutocompleteIndex: Sendable {
  /// Columns of each table keyed "schema.table"
  var columnsByTable: [String: [DatabaseColumn]] = [:]
  /// Lowercased name of each table, in `tables` order
  var tableNames: [Name] = []
  /// "schema.table" keys of `columnsByTable`, in table order (the fallback's entries point here)
  var tableKeys: [String] = []
  /// Every column of `columnsByTable`, one group per exact name, for the no-FROM fallback
  var columnGroups: [ColumnGroup] = []
  /// Foreign keys under the "schema.table" of their source and of their target (once for a
  /// self-reference), in load order, for the conditions after `JOIN t ON`
  var foreignKeysByTable: [String: [ForeignKey]] = [:]

  static let empty = SQLAutocompleteIndex()

  nonisolated struct Name: Sendable {
    /// Lowercased text
    let lower: String
    /// Character count of the original text
    let length: Int
  }

  /// The columns named `text`, in table order
  nonisolated struct ColumnGroup: Sendable {
    let text: String
    let name: Name
    var entries: [ColumnEntry] = []
  }

  nonisolated struct ColumnEntry: Sendable {
    /// Position among all columns in table order (breaks ties between equal names)
    let order: Int32
    /// Index in `tableKeys`
    let table: Int32
    /// Index in that table's `columnsByTable` list
    let column: Int32
  }

  init() {}

  init(tables: [DatabaseTable], foreignKeys: [ForeignKey] = []) {
    for key in foreignKeys {
      let source = "\(key.sourceSchema).\(key.sourceTable)"
      let target = "\(key.targetSchema).\(key.targetTable)"
      foreignKeysByTable[source, default: []].append(key)
      if target != source { foreignKeysByTable[target, default: []].append(key) }
    }
    columnsByTable = SQLAutocompleteProvider.columnIndex(of: tables)
    tableNames = tables.map { Name(lower: $0.name.lowercased(), length: $0.name.count) }
    var seenKeys: Set<String> = []
    var groupByText: [String: Int] = [:]
    var order: Int32 = 0
    for table in tables {
      let key = "\(table.schema).\(table.name)"
      // A repeated key lists the columns `columnsByTable` kept, once
      guard seenKeys.insert(key).inserted, let columns = columnsByTable[key] else { continue }
      let tableIndex = Int32(tableKeys.count)
      tableKeys.append(key)
      for (columnIndex, column) in columns.enumerated() {
        let entry = ColumnEntry(order: order, table: tableIndex, column: Int32(columnIndex))
        order += 1
        if let group = groupByText[column.name] {
          columnGroups[group].entries.append(entry)
        } else {
          groupByText[column.name] = columnGroups.count
          columnGroups.append(
            ColumnGroup(
              text: column.name,
              name: Name(lower: column.name.lowercased(), length: column.name.count),
              entries: [entry]))
        }
      }
    }
  }
}

// MARK: - Selection

/// The first `limit` suggestions in relevance order (exact match first, then shorter, then
/// alphabetical, then offer order, as the stable sort of every match gave) kept while matches
/// are offered, so a large catalog is never sorted whole
private struct SuggestionSelection {
  private struct Key {
    let exact: Bool
    /// 0 for a prefix hit, 1 for a contains hit (ranked after every prefix hit)
    let tier: Int
    let length: Int
    let lower: String
    let order: Int
  }

  let limit: Int
  let lowerToken: String
  /// Texts left out (the ORDER BY aliases that replace them)
  let excluded: Set<String>
  private var kept: [(key: Key, suggestion: AutocompleteSuggestion)] = []

  init(limit: Int, lowerToken: String, excluded: Set<String>) {
    self.limit = limit
    self.lowerToken = lowerToken
    self.excluded = excluded
  }

  var suggestions: [AutocompleteSuggestion] { kept.map(\.suggestion) }

  /// Suggestions kept so far
  var count: Int { kept.count }

  /// Keeps the suggestion `make` builds when it ranks among the first `limit`. False when it
  /// does not (then a later offer with the same text and a higher order is not kept either).
  @discardableResult
  mutating func offer(
    text: String, lower: String, length: Int, order: Int, tier: Int = 0,
    _ make: () -> AutocompleteSuggestion
  ) -> Bool {
    guard excluded.isEmpty || !excluded.contains(text) else { return false }
    let key = Key(
      exact: lower == lowerToken, tier: tier, length: length, lower: lower, order: order)
    if kept.count >= limit {
      guard let last = kept.last, Self.precedes(key, last.key) else { return false }
      kept.removeLast()
    }
    let position = kept.firstIndex { Self.precedes(key, $0.key) } ?? kept.count
    kept.insert((key, make()), at: position)
    return true
  }

  private static func precedes(_ lhs: Key, _ rhs: Key) -> Bool {
    if lhs.exact != rhs.exact { return lhs.exact }
    if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
    if lhs.length != rhs.length { return lhs.length < rhs.length }
    if lhs.lower != rhs.lower { return lhs.lower < rhs.lower }
    return lhs.order < rhs.order
  }
}
