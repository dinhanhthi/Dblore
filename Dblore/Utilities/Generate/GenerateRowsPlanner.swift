// GenerateRowsPlanner.swift
// What a Generate Rows run sends for one table, from its `TableStructure`. Identity, generated
// and defaulted columns are left out: the server fills them. A foreign key takes its values from
// up to `maxSampledKeys` referenced keys, a composite key as one whole tuple; with no parent row
// it is NULL when its columns are all nullable and refuses the run otherwise. Every other column
// gets a `ColumnValueGenerator`, or NULL when it is nullable and no generator fits its type.
// Each primary key, unique constraint and unique index of plain columns gets one column that
// never repeats: of its generated columns (an integer key starts after the table's MAX) and the
// foreign keys inside it (which then take their sampled keys in order, each once), the one that
// holds the most distinct values (after the table's MAX, or as many distinct keys as were
// sampled), the first in key order on a tie. A key holding an identity, sequence or random UUID
// column, or of only server-filled columns, is left to the server; a constant or `now()`
// default does not keep a key that also has sent columns distinct.
// The reads (referenced keys, then the MAX of each integer or decimal column a unique key could
// keep distinct) are built here and pass `ReadOnlyQueryGuard`; the caller runs them, all before
// the never-repeat columns are picked. Rows come from `Plan.nextRow`, drawn from one seeded
// source (foreign keys first, then columns in table order), so a seed and the same samples give
// the same rows.

import Foundation

nonisolated enum GenerateRowsPlanner {
  /// Referenced keys read per foreign key
  static let maxSampledKeys = 10_000
  /// Default expressions that give each row its own value: a sequence, a UUID function
  /// (`gen_random_uuid()`, `uuid()`, `uuidv7()`, `uuid_generate_v1mc()`...) or random bytes
  private static let distinctDefaults = [
    "nextval(", "uuid(", "uuidv", "uuid_generate_v", "randomblob(",
  ]

  /// Why the run can't be generated (refused before any row is made)
  enum Error: Swift.Error, Equatable, LocalizedError {
    /// The server fills every column
    case nothingToGenerate
    /// A NOT NULL column no generator fits
    case unsupportedColumn(column: String, type: String)
    /// A NOT NULL foreign key whose referenced table has no rows
    case noParentRows(column: String, table: String)
    /// A foreign key the server fills part of, a column in two foreign keys, or a key whose
    /// column lists differ in length
    case unsupportedForeignKey(column: String)
    /// A unique key whose columns can't be made distinct
    case cannotKeepUnique(columns: [String])
    case readRefused(ReadOnlyQueryGuard.Refusal)

    var errorDescription: String? {
      switch self {
      case .nothingToGenerate: "The database fills every column of this table."
      case .unsupportedColumn(let column, let type):
        "Values of type \(type) can't be generated for \(column), which can't be NULL."
      case .noParentRows(let column, let table):
        "\(column) must reference a row of \(table), which has none."
      case .unsupportedForeignKey(let column):
        "The foreign key on \(column) can't be filled: the database fills part of it, or the "
          + "column is in another foreign key."
      case .cannotKeepUnique(let columns):
        "Values that never repeat can't be generated for (\(columns.joined(separator: ", ")))."
      case .readRefused(let refusal): refusal.errorDescription
      }
    }
  }

  /// One read of the plan, with no binds: `currentMax` returns one row of one value,
  /// `referencedKeys` up to `maxSampledKeys` rows of the reference's columns
  struct Read: Sendable, Equatable {
    enum Purpose: Sendable, Equatable {
      case currentMax(column: String)
      case referencedKeys(TableStructure.ForeignKeyReference)
    }

    var purpose: Purpose
    var statement: BoundStatement
  }

  struct Plan: Sendable {
    /// The columns the INSERT sends, in table order
    let columns: [String]
    fileprivate var sources: [Source]
    fileprivate var generators: [ColumnValueGenerator]
    fileprivate var foreignKeys: [ForeignKeyPick]

    /// The next row's bind text in `columns` order; nil is NULL
    mutating func nextRow(using random: inout some RandomNumberGenerator) throws -> [String?] {
      var tuples: [[String]?] = []
      tuples.reserveCapacity(foreignKeys.count)
      for index in foreignKeys.indices {
        tuples.append(try foreignKeys[index].next(using: &random))
      }
      var row: [String?] = []
      row.reserveCapacity(sources.count)
      for source in sources {
        switch source {
        case .null: row.append(nil)
        case .generator(let index): row.append(try generators[index].next(using: &random))
        case .foreignKey(let index, let part): row.append(tuples[index]?[part])
        }
      }
      return row
    }
  }

  /// Where a sent column's value comes from
  fileprivate enum Source: Sendable {
    case null
    case generator(Int)
    /// Part `part` of foreign key `index`'s tuple
    case foreignKey(index: Int, part: Int)
  }

  /// A foreign key's sampled tuples; nil (NULL) when there are none
  fileprivate struct ForeignKeyPick: Sendable {
    var column: String
    var keys: [[String]]
    var isUnique: Bool
    var nullRatio: Double
    var taken = 0

    mutating func next(using random: inout some RandomNumberGenerator) throws -> [String]? {
      guard !keys.isEmpty else { return nil }
      if nullRatio > 0, Double.random(in: 0..<1, using: &random) < nullRatio { return nil }
      guard isUnique else { return keys[Int.random(in: 0..<keys.count, using: &random)] }
      guard taken < keys.count else {
        throw ColumnValueGenerator.Error.uniqueValuesExhausted(column: column)
      }
      taken += 1
      return keys[taken - 1]
    }
  }

  /// The plan for `structure`. `kinds` overrides a column's default generator (not a foreign
  /// key's), `nullRatio` is the share of NULLs in nullable columns that need not be unique, and
  /// `enumLabels` gives a PostgreSQL enum column's labels by column name. Refusals that need no
  /// read are thrown before `read` runs.
  static func plan(
    structure: TableStructure, dialect: SQLDialect,
    kinds: [String: ColumnValueGenerator.Kind] = [:], nullRatio: Double = 0,
    enumLabels: [String: [String]] = [:],
    read: (Read) async throws -> [[CellValue]]
  ) async throws -> Plan {
    let sent = structure.columns.filter {
      $0.identity == nil && $0.generated == nil && $0.defaultExpression == nil
    }
    guard !sent.isEmpty else { throw Error.nothingToGenerate }
    let sentNames = Set(sent.map(\.name))

    // Foreign keys over sent columns; one the server fills entirely is left to it
    var references: [(columns: [String], reference: TableStructure.ForeignKeyReference)] = []
    var foreignKeyOf: [String: (index: Int, part: Int)] = [:]
    for constraint in structure.constraints {
      guard case .foreignKey(let reference) = constraint.kind,
        constraint.columns.contains(where: sentNames.contains)
      else { continue }
      for (part, name) in constraint.columns.enumerated() {
        guard sentNames.contains(name), foreignKeyOf[name] == nil,
          constraint.columns.count == reference.columns.count
        else { throw Error.unsupportedForeignKey(column: name) }
        foreignKeyOf[name] = (references.count, part)
      }
      references.append((constraint.columns, reference))
    }

    var kindOf: [String: ColumnValueGenerator.Kind] = [:]
    for column in sent where foreignKeyOf[column.name] == nil {
      let labels = enumLabels[column.name] ?? []
      if let kind = kinds[column.name]
        ?? ColumnValueGenerator.defaultKind(for: column, enumLabels: labels)
      {
        kindOf[column.name] = kind
      } else if !column.isNullable {
        throw Error.unsupportedColumn(
          column: column.name, type: column.columnType ?? column.dataType)
      }
    }

    // Each unique key with what could keep it distinct, in key order: its generated columns and
    // the foreign keys inside it. A key holding a column the server makes distinct, or one the
    // server fills entirely, is left to it; a key with a sent column and nothing to keep it
    // distinct refuses the run before any read.
    var keys: [(columns: [String], candidates: [(name: String, foreignKey: Int?)])] = []
    for key in uniqueKeys(structure).sorted(by: { $0.count < $1.count }) {
      guard
        !structure.columns.contains(where: {
          key.contains($0.name) && !sentNames.contains($0.name) && isDistinctOnItsOwn($0)
        })
      else { continue }
      let candidates = key.compactMap { name -> (name: String, foreignKey: Int?)? in
        if kindOf[name] != nil { return (name, nil) }
        guard let index = foreignKeyOf[name]?.index,
          references[index].columns.allSatisfy(key.contains)
        else { return nil }
        return (name, index)
      }
      guard !candidates.isEmpty else {
        // The run can't change a key the server fills entirely (`lower(email)`, a default)
        if key.allSatisfy({ !sentNames.contains($0) }) { continue }
        throw Error.cannotKeepUnique(columns: key)
      }
      keys.append((key, candidates))
    }

    // Distinct referenced keys, in their sorted order
    var samples: [[[String]]] = []
    for entry in references {
      let rows = try await read(
        Read(
          purpose: .referencedKeys(entry.reference),
          statement: try keysRead(entry.reference, dialect: dialect)))
      var sample: [[String]] = []
      for row in rows.prefix(maxSampledKeys) where row.count == entry.columns.count {
        let text = row.compactMap { CellUpdateStatement.inputText($0, dialect: dialect) }
        // The order puts a repeated key next to its twin
        if text.count == row.count, text != sample.last { sample.append(text) }
      }
      let columns = sent.filter { entry.columns.contains($0.name) }
      if sample.isEmpty, let required = columns.first(where: { !$0.isNullable }) {
        throw Error.noParentRows(column: required.name, table: entry.reference.table)
      }
      samples.append(sample)
    }

    // The MAX of every integer or decimal column that could keep a key distinct, once each
    let keyed = Set(keys.flatMap { $0.candidates.map(\.name) })
    var currentMax: [String: Int] = [:]
    for column in sent where keyed.contains(column.name) {
      guard kindOf[column.name] == .integer || kindOf[column.name] == .decimal else { continue }
      let rows = try await read(
        Read(
          purpose: .currentMax(column: column.name),
          statement: try maxRead(column.name, structure: structure, dialect: dialect)))
      currentMax[column.name] = integer(rows.first?.first)
    }

    // One distinct column per unique key, the one holding the most values; a key holding a
    // smaller one is already distinct
    func capacity(_ candidate: (name: String, foreignKey: Int?)) -> Int {
      if let index = candidate.foreignKey { return samples[index].count }
      guard let kind = kindOf[candidate.name],
        let column = sent.first(where: { $0.name == candidate.name })
      else { return 0 }
      return uniqueCapacity(
        kind, column: column, enumLabels: enumLabels[candidate.name] ?? [],
        currentMax: currentMax[candidate.name])
    }
    var uniqueColumns: Set<String> = []
    var uniqueForeignKeys: Set<Int> = []
    for key in keys {
      guard !key.columns.contains(where: uniqueColumns.contains),
        !key.candidates.contains(where: { $0.foreignKey.map(uniqueForeignKeys.contains) ?? false })
      else { continue }
      var best = key.candidates[0]
      var most = capacity(best)
      for candidate in key.candidates.dropFirst() {
        let held = capacity(candidate)
        if held > most { (best, most) = (candidate, held) }
      }
      if let index = best.foreignKey {
        uniqueForeignKeys.insert(index)
      } else {
        uniqueColumns.insert(best.name)
      }
    }

    var foreignKeys: [ForeignKeyPick] = []
    for (index, entry) in references.enumerated() {
      let columns = sent.filter { entry.columns.contains($0.name) }
      let isUnique = uniqueForeignKeys.contains(index)
      let nullable = columns.allSatisfy(\.isNullable) && !isUnique
      foreignKeys.append(
        ForeignKeyPick(
          column: entry.columns[0], keys: samples[index], isUnique: isUnique,
          nullRatio: nullable ? min(max(nullRatio, 0), 1) : 0))
    }

    var sources: [Source] = []
    var generators: [ColumnValueGenerator] = []
    for column in sent {
      if let foreignKey = foreignKeyOf[column.name] {
        sources.append(.foreignKey(index: foreignKey.index, part: foreignKey.part))
        continue
      }
      guard let kind = kindOf[column.name] else {
        sources.append(.null)
        continue
      }
      let isUnique = uniqueColumns.contains(column.name)
      sources.append(.generator(generators.count))
      generators.append(
        ColumnValueGenerator(
          column: column, kind: kind, isUnique: isUnique, nullRatio: nullRatio,
          currentMax: isUnique ? currentMax[column.name] : nil,
          enumLabels: enumLabels[column.name] ?? []))
    }
    return Plan(
      columns: sent.map(\.name), sources: sources, generators: generators,
      foreignKeys: foreignKeys)
  }

  /// Whether the server fills `column` with a value no other row has: an identity or
  /// auto-increment column, or a sequence or random UUID default
  private static func isDistinctOnItsOwn(_ column: TableStructure.Column) -> Bool {
    if column.identity != nil { return true }
    guard let expression = column.defaultExpression?.lowercased() else { return false }
    return distinctDefaults.contains(where: expression.contains)
  }

  /// How many distinct values a unique column of `kind` gives before it runs out, as
  /// `ColumnValueGenerator` makes them; `Int.max` when its type sets no small limit. An integer
  /// or decimal key counts up from after `currentMax` (else from 1) to its type's top, a text of
  /// length n holds 10^n - 1 and a decimal of n integer digits stops below 10^n.
  private static func uniqueCapacity(
    _ kind: ColumnValueGenerator.Kind, column: TableStructure.Column, enumLabels: [String],
    currentMax: Int?
  ) -> Int {
    let type = ColumnValueGenerator.ColumnType(column.columnType ?? column.dataType)
    func digits(_ count: Int?) -> Int {
      guard let count, count < 18 else { return .max }
      return (0..<max(count, 0)).reduce(1) { value, _ in value * 10 } - 1
    }
    switch kind {
    case .boolean: return 2
    case .enumLabel: return enumLabels.isEmpty ? type.labels.count : enumLabels.count
    case .time: return 86_400
    case .date, .timestamp, .uuidV4, .uuidV7, .json: return .max
    case .integer, .decimal:
      // The key before the first one, and the last one the type holds
      var last = currentMax ?? 0
      var top = Int.max
      if kind == .decimal {
        top = digits(type.decimalDigits?.integer)
      } else if let bounds = type.integerBounds {
        top = bounds.upperBound
        if bounds.lowerBound > last { last = bounds.lowerBound - 1 }
      }
      let (count, overflow) = top.subtractingReportingOverflow(last)
      return overflow ? .max : max(count, 0)
    case .firstName, .lastName, .fullName, .email, .phone, .address, .city, .url, .text:
      return digits(type.maxLength)
    }
  }

  /// Column lists of the primary key, unique constraints and unique indexes of plain columns
  /// (partial ones too: their rows must not repeat either)
  private static func uniqueKeys(_ structure: TableStructure) -> [[String]] {
    var keys = structure.constraints.compactMap { constraint -> [String]? in
      switch constraint.kind {
      case .primaryKey, .unique: constraint.columns
      default: nil
      }
    }
    for index in structure.indexes where index.isUnique {
      let columns = index.keys.compactMap { key -> String? in
        if case .column(let name) = key { name } else { nil }
      }
      if columns.count == index.keys.count { keys.append(columns) }
    }
    return keys.filter { !$0.isEmpty }
  }

  /// `SELECT k1, k2 FROM parent WHERE k1 IS NOT NULL AND ... ORDER BY k1, k2 LIMIT n`: the
  /// referenced key is indexed, and the order makes the sample the same on every run
  private static func keysRead(
    _ reference: TableStructure.ForeignKeyReference, dialect: SQLDialect
  ) throws -> BoundStatement {
    let relation = try dialect.qualified(schema: reference.schema, name: reference.table)
    let names = try reference.columns.map { try dialect.quoteIdentifier($0) }
    let list = names.joined(separator: ", ")
    let present = names.map { "\($0) IS NOT NULL" }.joined(separator: " AND ")
    return try guarded(
      "SELECT \(list) FROM \(relation) WHERE \(present) ORDER BY \(list) LIMIT \(maxSampledKeys)",
      dialect: dialect)
  }

  private static func maxRead(
    _ column: String, structure: TableStructure, dialect: SQLDialect
  ) throws -> BoundStatement {
    let relation = try dialect.qualified(schema: structure.schema, name: structure.name)
    return try guarded(
      "SELECT MAX(\(try dialect.quoteIdentifier(column))) FROM \(relation)", dialect: dialect)
  }

  private static func guarded(_ sql: String, dialect: SQLDialect) throws -> BoundStatement {
    let classified: [ClassifiedStatement]
    do {
      classified = try ReadOnlyQueryGuard.check(sql, dialect: dialect)
    } catch let refusal as ReadOnlyQueryGuard.Refusal {
      throw Error.readRefused(refusal)
    }
    return BoundStatement(sql: sql, values: [], expectedRows: nil, classified: classified.first)
  }

  /// A MAX as a whole number, rounded down; nil for NULL (an empty table). A value past `Int`
  /// (or one that is not a number) gives `.max`, so the key runs out rather than repeats.
  private static func integer(_ value: CellValue?) -> Int? {
    switch value {
    case .null, nil: nil
    case .int(let number): number
    case .double(let number): Int(exactly: number.rounded(.down)) ?? .max
    case .string(let text):
      Int(text) ?? Double(text).flatMap { Int(exactly: $0.rounded(.down)) } ?? .max
    default: .max
    }
  }
}
