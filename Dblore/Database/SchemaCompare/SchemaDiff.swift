// SchemaDiff.swift
// What differs between two `SchemaSnapshot`s of the same engine, as a list of items the user
// ticks: tables only in the source (create) or only in the target (drop); in tables of both,
// columns added / dropped / changed (type, nullability, default), indexes and foreign keys
// added / dropped / changed. Views, routines, types, primary keys, unique and check constraints,
// comments, identity and generated columns are not compared in v1. A renamed table, column or
// index shows as a drop plus an add.
//
// Names match per engine: PostgreSQL exactly as stored; MySQL columns, indexes and constraint
// names ignoring ASCII case, tables exactly unless the snapshot says `tableNamesIgnoreCase`;
// SQLite every name ignoring ASCII case. Types compare as the catalog prints them: PostgreSQL
// `format_type` text exactly (it never prints `int4`), MySQL `COLUMN_TYPE` and SQLite declared
// types ignoring ASCII case. Defaults compare as server-deparsed text.
// PostgreSQL snapshots are read with an empty search_path (`SchemaSnapshotLoader`), so types and
// defaults name every user type and sequence with its schema (`dev.mood`,
// `nextval('dev.orders_id_seq'::regclass)`); when the two schemas differ, each side's own
// schema prefix in types, defaults, index key expressions and predicates reads as the same
// prefix (`schemaPrefixReplaced`).
// Indexes that back the primary key or a unique constraint are left out (they follow their
// constraint). An index is matched by name and compared by key parts, uniqueness, method (when
// both report one) and partial predicate; a foreign
// key by name (by definition when unnamed, as on SQLite) and compared by columns, referenced
// table and columns, and ON UPDATE / ON DELETE. A reference to the snapshot's own schema counts
// as the same reference in the other snapshot's schema.
// Drops of tables, columns, indexes and foreign keys are unticked by default (a changed index or
// key, dropped and added again, is not a drop). Everything else is ticked. Items come in a stable order (tables by name; then columns, indexes, foreign keys)
// with stable ids built from names.

import Foundation

nonisolated struct SchemaDiffItem: Sendable, Equatable, Identifiable {
  typealias Column = TableStructure.Column
  typealias Index = TableStructure.Index
  typealias Constraint = TableStructure.Constraint

  /// Stable for the same pair of snapshots: the kind and the names
  var id: String
  /// The table as the target names it; the source name for a table to create
  var table: String
  var kind: Kind
  /// One line for the list (`Add column "orders"."note" (text)`)
  var description: String
  var isSelected: Bool

  enum Kind: Sendable, Equatable {
    /// The source table
    case createTable(TableStructure)
    /// The target table
    case dropTable(TableStructure)
    /// The source column
    case addColumn(Column)
    /// The target column
    case dropColumn(Column)
    case alterColumn(source: Column, target: Column)
    case addIndex(Index)
    case dropIndex(Index)
    case changeIndex(source: Index, target: Index)
    /// A `.foreignKey` constraint of the source table
    case addForeignKey(Constraint)
    case dropForeignKey(Constraint)
    case changeForeignKey(source: Constraint, target: Constraint)
  }
}

nonisolated struct SchemaDiffResult: Sendable, Equatable {
  var items: [SchemaDiffItem]
  /// Differences in kind the diff cannot cover (MySQL against MariaDB)
  var warnings: [String] = []
}

nonisolated enum SchemaDiff {
  private typealias Item = SchemaDiffItem

  /// - Throws: `SchemaCompareError.engineMismatch` unless both are the same engine
  static func diff(source: SchemaSnapshot, target: SchemaSnapshot) throws -> SchemaDiffResult {
    guard source.hasSameEngine(as: target) else { throw SchemaCompareError.engineMismatch }
    var warnings: [String] = []
    if let from = source.mysqlFlavor, let to = target.mysqlFlavor, from != to {
      warnings.append(
        "The source is \(flavorName(from)) and the target \(flavorName(to)): types and defaults "
          + "can read differently on each, and the script is written for the target.")
    }
    let names = Names(source: source, target: target)
    let sourceTables = keyed(source.tables) { names.table($0.name) }
    let targetTables = keyed(target.tables) { names.table($0.name) }
    var items: [Item] = []
    for key in Set(sourceTables.keys).union(targetTables.keys).sorted() {
      switch (sourceTables[key], targetTables[key]) {
      case (let from?, nil):
        items.append(
          Item(
            id: id("table.create", from.name), table: from.name, kind: .createTable(from),
            description: "Create table \(shown(from.name))", isSelected: true))
      case (nil, let to?):
        items.append(
          Item(
            id: id("table.drop", to.name), table: to.name, kind: .dropTable(to),
            description: "Drop table \(shown(to.name))", isSelected: false))
      case (let from?, let to?):
        items += columnItems(from, to, names: names)
        items += indexItems(from, to, names: names)
        items += foreignKeyItems(
          from, to, names: names, sourceSchema: source.schema, targetSchema: target.schema)
      case (nil, nil):
        break
      }
    }
    return SchemaDiffResult(items: items, warnings: warnings)
  }

  // MARK: - Columns

  private static func columnItems(
    _ from: TableStructure, _ to: TableStructure, names: Names
  ) -> [Item] {
    let table = to.name
    let sourceColumns = keyed(from.columns) { names.other($0.name) }
    let targetColumns = keyed(to.columns) { names.other($0.name) }
    var adds: [Item] = []
    var alters: [Item] = []
    var drops: [Item] = []
    for column in from.columns where targetColumns[names.other(column.name)] == nil {
      adds.append(
        Item(
          id: id("column.add", table, column.name), table: table, kind: .addColumn(column),
          description:
            "Add column \(shown(table)).\(shown(column.name)) (\(typeText(column)))",
          isSelected: true))
    }
    for column in to.columns {
      guard let source = sourceColumns[names.other(column.name)] else {
        drops.append(
          Item(
            id: id("column.drop", table, column.name), table: table, kind: .dropColumn(column),
            description: "Drop column \(shown(table)).\(shown(column.name))", isSelected: false))
        continue
      }
      var changes: [String] = []
      if !names.sameType(source, column) {
        changes.append("type \(typeText(column)) to \(typeText(source))")
      }
      if source.isNullable != column.isNullable {
        changes.append(source.isNullable ? "allow NULL" : "NOT NULL")
      }
      if !names.sameDefault(source, column) {
        changes.append(source.defaultExpression.map { "default \($0)" } ?? "no default")
      }
      guard !changes.isEmpty else { continue }
      alters.append(
        Item(
          id: id("column.alter", table, column.name), table: table,
          kind: .alterColumn(source: source, target: column),
          description:
            "Change column \(shown(table)).\(shown(column.name)): "
            + changes.joined(separator: "; "),
          isSelected: true))
    }
    return adds + alters + drops
  }

  /// MySQL `COLUMN_TYPE` (`int unsigned`), the display type elsewhere
  static func typeText(_ column: TableStructure.Column) -> String {
    column.columnType ?? column.dataType
  }

  /// True when the diff reads the source column's type as the target column's
  static func sameType(
    _ source: TableStructure.Column, _ target: TableStructure.Column,
    in snapshots: (source: SchemaSnapshot, target: SchemaSnapshot)
  ) -> Bool {
    Names(source: snapshots.source, target: snapshots.target).sameType(source, target)
  }

  /// True when the diff reads the source column's default as the target column's
  static func sameDefault(
    _ source: TableStructure.Column, _ target: TableStructure.Column,
    in snapshots: (source: SchemaSnapshot, target: SchemaSnapshot)
  ) -> Bool {
    Names(source: snapshots.source, target: snapshots.target).sameDefault(source, target)
  }

  // MARK: - Indexes

  private static func indexItems(
    _ from: TableStructure, _ to: TableStructure, names: Names
  ) -> [Item] {
    let table = to.name
    let sourceIndexes = keyed(comparedIndexes(from, names: names)) { names.other($0.name) }
    let targetIndexes = keyed(comparedIndexes(to, names: names)) { names.other($0.name) }
    var adds: [Item] = []
    var changes: [Item] = []
    var drops: [Item] = []
    for key in Set(sourceIndexes.keys).union(targetIndexes.keys).sorted() {
      switch (sourceIndexes[key], targetIndexes[key]) {
      case (let index?, nil):
        adds.append(
          Item(
            id: id("index.add", table, index.name), table: table, kind: .addIndex(index),
            description: "Add index \(shown(index.name)) on \(shown(table)) \(keyText(index))",
            isSelected: true))
      case (nil, let index?):
        drops.append(
          Item(
            id: id("index.drop", table, index.name), table: table, kind: .dropIndex(index),
            description: "Drop index \(shown(index.name)) on \(shown(table))", isSelected: false))
      case (let source?, let target?):
        guard !sameIndex(source, target, names: names) else { continue }
        changes.append(
          Item(
            id: id("index.change", table, target.name), table: table,
            kind: .changeIndex(source: source, target: target),
            description:
              "Change index \(shown(target.name)) on \(shown(table)) to "
              + "\(source.isUnique ? "unique " : "")\(keyText(source))",
            isSelected: true))
      case (nil, nil):
        break
      }
    }
    return adds + changes + drops
  }

  /// The indexes that are not the primary key's or a unique constraint's
  private static func comparedIndexes(
    _ table: TableStructure, names: Names
  ) -> [TableStructure.Index] {
    let constraintNames = Set(
      table.constraints.compactMap { constraint -> String? in
        guard case .unique = constraint.kind else { return nil }
        return constraint.name.map(names.other)
      })
    return table.indexes.filter { !$0.isPrimary && !constraintNames.contains(names.other($0.name)) }
  }

  private static func sameIndex(
    _ a: TableStructure.Index, _ b: TableStructure.Index, names: Names
  ) -> Bool {
    func sameKey(_ x: TableStructure.Index.Key, _ y: TableStructure.Index.Key) -> Bool {
      switch (x, y) {
      case (.column(let p), .column(let q)): names.other(p) == names.other(q)
      case (.expression(let p), .expression(let q)): names.sameExpression(p, q)
      default: false
      }
    }
    let sameMethod =
      a.method == nil || b.method == nil
      || SQLTokenizer.asciiLowercased(a.method ?? "")
        == SQLTokenizer.asciiLowercased(b.method ?? "")
    return a.isUnique == b.isUnique && sameMethod && a.keys.count == b.keys.count
      && zip(a.keys, b.keys).allSatisfy(sameKey) && a.isPartial == b.isPartial
      && names.sameExpression(a.predicate, b.predicate)
  }

  private static func keyText(_ index: TableStructure.Index) -> String {
    let parts = index.keys.map { key -> String in
      switch key {
      case .column(let name): name
      case .expression(let text): text ?? "expression"
      }
    }
    return "(" + parts.joined(separator: ", ") + ")"
  }

  // MARK: - Foreign keys

  private static func foreignKeyItems(
    _ from: TableStructure, _ to: TableStructure, names: Names, sourceSchema: String,
    targetSchema: String
  ) -> [Item] {
    let table = to.name
    func keyed(_ table: TableStructure, schema: String) -> [String: TableStructure.Constraint] {
      SchemaDiff.keyed(foreignKeys(table)) { constraint in
        constraint.name.map { "name " + names.other($0) }
          ?? "definition " + definition(constraint, names: names, ownSchema: schema)
      }
    }
    let sourceKeys = keyed(from, schema: sourceSchema)
    let targetKeys = keyed(to, schema: targetSchema)
    var adds: [Item] = []
    var changes: [Item] = []
    var drops: [Item] = []
    for key in Set(sourceKeys.keys).union(targetKeys.keys).sorted() {
      switch (sourceKeys[key], targetKeys[key]) {
      case (let constraint?, nil):
        adds.append(
          Item(
            id: id("fk.add", table, foreignKeyName(constraint)), table: table,
            kind: .addForeignKey(constraint),
            description: "Add foreign key \(foreignKeyText(constraint, table: table))",
            isSelected: true))
      case (nil, let constraint?):
        drops.append(
          Item(
            id: id("fk.drop", table, foreignKeyName(constraint)), table: table,
            kind: .dropForeignKey(constraint),
            description: "Drop foreign key \(foreignKeyText(constraint, table: table))",
            isSelected: false))
      case (let source?, let target?):
        guard
          definition(source, names: names, ownSchema: sourceSchema)
            != definition(target, names: names, ownSchema: targetSchema)
        else { continue }
        changes.append(
          Item(
            id: id("fk.change", table, foreignKeyName(target)), table: table,
            kind: .changeForeignKey(source: source, target: target),
            description: "Change foreign key \(foreignKeyText(source, table: table))",
            isSelected: true))
      case (nil, nil):
        break
      }
    }
    return adds + changes + drops
  }

  private static func foreignKeys(_ table: TableStructure) -> [TableStructure.Constraint] {
    table.constraints.filter {
      if case .foreignKey = $0.kind { true } else { false }
    }
  }

  /// Columns, referenced schema (empty for the snapshot's own), table and columns, and actions
  private static func definition(
    _ constraint: TableStructure.Constraint, names: Names, ownSchema: String
  ) -> String {
    guard case .foreignKey(let reference) = constraint.kind else { return "" }
    let schema =
      names.table(reference.schema) == names.table(ownSchema) ? "" : names.table(reference.schema)
    return [
      constraint.columns.map(names.other).joined(separator: ","),
      schema, names.table(reference.table),
      reference.columns.map(names.other).joined(separator: ","),
      reference.onUpdate.rawValue, reference.onDelete.rawValue,
    ].map { "\($0.count):\($0)" }.joined()
  }

  /// The name, or the columns and reference of an unnamed key (SQLite)
  private static func foreignKeyName(_ constraint: TableStructure.Constraint) -> String {
    if let name = constraint.name { return name }
    var text = "(" + constraint.columns.joined(separator: ", ") + ")"
    if case .foreignKey(let reference) = constraint.kind {
      text += " -> \(reference.table) (\(reference.columns.joined(separator: ", ")))"
    }
    return text
  }

  private static func foreignKeyText(
    _ constraint: TableStructure.Constraint, table: String
  ) -> String {
    guard case .foreignKey(let reference) = constraint.kind else { return "" }
    return (constraint.name.map { shown($0) + " " } ?? "") + "on \(shown(table)) "
      + "(\(constraint.columns.joined(separator: ", "))) to \(shown(reference.table)) "
      + "(\(reference.columns.joined(separator: ", ")))"
      + " ON UPDATE \(reference.onUpdate.displayName) ON DELETE \(reference.onDelete.displayName)"
  }

  // MARK: - Helpers

  /// How names match on the target's engine
  private struct Names {
    var foldsTables: Bool
    var foldsOthers: Bool
    /// PostgreSQL with two schema names: each side's schema prefix in types and defaults
    var schemas: (source: String, target: String)?

    init(source: SchemaSnapshot, target: SchemaSnapshot) {
      let ignoreCase = source.tableNamesIgnoreCase || target.tableNamesIgnoreCase
      switch target.engine {
      case .mysql: (foldsTables, foldsOthers) = (ignoreCase, true)
      case .sqlite: (foldsTables, foldsOthers) = (true, true)
      case .postgresql, .duckdb: (foldsTables, foldsOthers) = (ignoreCase, false)
      }
      if case .postgresql = target.engine, source.schema != target.schema {
        schemas = (source.schema, target.schema)
      }
    }

    /// Table and schema names
    func table(_ name: String) -> String {
      foldsTables ? SQLTokenizer.asciiLowercased(name) : name
    }

    /// Column, index and constraint names
    func other(_ name: String) -> String {
      foldsOthers ? SQLTokenizer.asciiLowercased(name) : name
    }

    /// PostgreSQL `format_type` text exactly; MySQL and SQLite type text ignoring ASCII case
    func sameType(_ source: TableStructure.Column, _ target: TableStructure.Column) -> Bool {
      comparable(other(SchemaDiff.typeText(source)), schemas?.source)
        == comparable(other(SchemaDiff.typeText(target)), schemas?.target)
    }

    func sameDefault(_ source: TableStructure.Column, _ target: TableStructure.Column) -> Bool {
      sameExpression(source.defaultExpression, target.defaultExpression)
    }

    /// Server-deparsed text of the source and the target (a default, an index key expression or
    /// predicate), each side's own schema prefix read as the other's
    func sameExpression(_ source: String?, _ target: String?) -> Bool {
      source.map { comparable($0, schemas?.source) }
        == target.map { comparable($0, schemas?.target) }
    }

    /// The side's own schema prefix as one placeholder; the text as is when it cannot be
    /// rewritten safely (then only identical text matches)
    private func comparable(_ text: String, _ schema: String?) -> String {
      guard let schema else { return text }
      return SchemaDiff.schemaPrefixReplaced(in: text, schema: schema, with: "\u{1}.") ?? text
    }
  }

  // MARK: - Schema prefixes

  /// `text` (a PostgreSQL type or deparsed default) with every `schema.` prefix of a name
  /// replaced by `replacement` (which ends with its own `.`). The prefix is matched as the server
  /// prints it: `dev.` (only for a lowercase simple name) or `"Dev".`, outside string literals,
  /// and at the start of a `'…'::regclass` literal (`nextval('dev.seq'::regclass)`). Nil when the
  /// prefix also appears where it cannot be rewritten safely (inside any other literal, or later
  /// in a regclass literal) or the text is not well formed.
  static func schemaPrefixReplaced(
    in text: String, schema: String, with replacement: String
  ) -> String? {
    let chars = Array(text)
    let quoted = Array("\"" + schema.replacingOccurrences(of: "\"", with: "\"\"") + "\".")
    let bare: [Character]? = isSimpleName(schema) ? Array(schema + ".") : nil
    func isNameCharacter(_ c: Character) -> Bool {
      c.isLetter || c.isNumber || c == "_" || c == "$"
    }
    /// The prefix that starts at `i` in `chars`, if any, after a boundary
    func prefix(at i: Int, in chars: [Character]) -> Int? {
      if i > 0, isNameCharacter(chars[i - 1]) || chars[i - 1] == "." || chars[i - 1] == "\"" {
        return nil
      }
      for form in [quoted] + (bare.map { [$0] } ?? [])
      where chars.count - i >= form.count && Array(chars[i..<i + form.count]) == form {
        return form.count
      }
      return nil
    }
    /// True when the prefix appears anywhere in `chars`
    func mentions(_ chars: [Character]) -> Bool {
      chars.indices.contains { prefix(at: $0, in: chars) != nil }
    }
    var out = ""
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if c == "'" || c == "\"", prefix(at: i, in: chars) == nil {
        // A literal or a quoted name: up to its closing quote (a doubled quote is part of it)
        var content: [Character] = []
        var j = i + 1
        while j < chars.count {
          if chars[j] == c {
            guard j + 1 < chars.count, chars[j + 1] == c else { break }
            j += 1
          }
          content.append(chars[j])
          j += 1
        }
        guard j < chars.count else { return nil }
        if c == "'" {
          var literal = content
          if Array(chars[(j + 1)...]).starts(with: Array("::regclass")),
            let length = prefix(at: 0, in: content)
          {
            literal = Array(replacement) + content[length...]
            guard !mentions(Array(content[length...])) else { return nil }
          } else if mentions(content) {
            return nil
          }
          out += "'" + String(literal).replacingOccurrences(of: "'", with: "''") + "'"
        } else {
          out += String(chars[i...j])
        }
        i = j + 1
      } else if let length = prefix(at: i, in: chars) {
        out += replacement
        i += length
      } else {
        out.append(c)
        i += 1
      }
    }
    return out
  }

  /// A name PostgreSQL prints without quotes (keywords aside, which it quotes)
  private static func isSimpleName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, first == "_" || ("a"..."z").contains(first)
    else { return false }
    return name.unicodeScalars.allSatisfy {
      $0 == "_" || $0 == "$" || ("a"..."z").contains($0) || ("0"..."9").contains($0)
    }
  }

  /// The first element for each key (names are unique per engine rules)
  private static func keyed<T>(_ elements: [T], by key: (T) -> String) -> [String: T] {
    Dictionary(elements.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// `kind "part"."part"`, each part quoted with `"` doubled: distinct names give distinct ids
  private static func id(_ kind: String, _ parts: String...) -> String {
    kind + " " + parts.map(shown).joined(separator: ".")
  }

  private static func shown(_ name: String) -> String {
    "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  private static func flavorName(_ flavor: MySQLServerInfo.Flavor) -> String {
    switch flavor {
    case .mysql: "MySQL"
    case .mariadb: "MariaDB"
    }
  }
}
