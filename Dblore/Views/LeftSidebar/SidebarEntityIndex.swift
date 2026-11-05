//
//  SidebarEntityIndex.swift
//  Dblore
//
//  The Public tab filter's view of the catalog: lowercased names of the tables, views,
//  functions, procedures and triggers (a trigger with its table) and of the columns, in one
//  bucket per schema. Built off the main actor after each schema load and published with the
//  catalog arrays; hidden schemas and the temporary split are applied per query. Sequences and
//  types (read on expand) are filtered from their own arrays. A PostgreSQL partition is listed
//  under its parent table (`DatabaseTable.parentID`), not at the top.
//

import Foundation

nonisolated struct SidebarEntityIndex: Sendable {
  /// A table or view the filter keeps: its position in the workspace's array, the offsets of
  /// the columns to show (nil: every column) and whether the row opens to show them
  struct RelationMatch: Equatable, Sendable {
    let position: Int
    let columns: [Int]?
    let expandForMatch: Bool
    /// The partitions a filter hit on (or below) shows under this table, drawn opened; nil when
    /// none (opened by hand, the row lists every partition, `Result.partitions`)
    var partitions: [RelationMatch]? = nil
  }

  /// What the filter keeps, in array order. Functions, procedures and triggers are positions
  /// in their arrays.
  struct Matches: Equatable, Sendable {
    var tables: [RelationMatch] = []
    var views: [RelationMatch] = []
    var functions: [Int] = []
    var procedures: [Int] = []
    var triggers: [Int] = []

    var isEmpty: Bool {
      tables.isEmpty && views.isEmpty && functions.isEmpty && procedures.isEmpty
        && triggers.isEmpty
    }
  }

  struct Result: Sendable {
    /// The listed schemas' objects (neither hidden nor temporary)
    var listed = Matches()
    /// The same, per listed schema
    var bySchema: [String: Matches] = [:]
    /// The session's temporary objects (`SidebarSectionModel.temporarySplit`), never hidden
    var temporary = Matches()
    /// Partitions of each partitioned table, positions in array order (the tables lists hold
    /// only the tables not listed under a parent)
    var partitions: [Int: [Int]] = [:]

    func inSchema(_ schema: String) -> Matches {
      bySchema[schema] ?? Matches()
    }

    /// Without the objects `filter` leaves out of the `hidden` schemas (a temporary table
    /// stays), read in the arrays the positions point into: what a result of other hidden or
    /// temporary schemas draws until the filter for these lands. A position out of range stays
    /// (the sidebar skips it).
    func hiding(
      _ hidden: Set<String>, temporarySchemas: Set<String>, tables: [DatabaseTable],
      views: [DatabaseView], functions: [DatabaseFunction], procedures: [DatabaseProcedure],
      triggers: [DatabaseTrigger]
    ) -> Result {
      let gone = hidden.subtracting(temporarySchemas)
      guard !gone.isEmpty else { return self }
      func shown<Item>(_ all: [Item], _ position: Int, _ schema: (Item) -> String) -> Bool {
        !all.indices.contains(position) || !gone.contains(schema(all[position]))
      }
      func keepsPartition(_ position: Int) -> Bool {
        shown(tables, position, \.schema) || tables[position].isTemporary
      }
      // A partition a filter showed under a listed parent leaves with its schema too
      func pruned(_ match: RelationMatch) -> RelationMatch {
        guard let children = match.partitions else { return match }
        var match = match
        let kept = children.filter { keepsPartition($0.position) }.map(pruned)
        match.partitions = kept.isEmpty ? nil : kept
        return match
      }
      func kept(_ matches: Matches, keepsTable: (Int) -> Bool) -> Matches {
        Matches(
          tables: matches.tables.filter { keepsTable($0.position) }.map(pruned),
          views: matches.views.filter { shown(views, $0.position, \.schema) },
          functions: matches.functions.filter { shown(functions, $0, \.schema) },
          procedures: matches.procedures.filter { shown(procedures, $0, \.schema) },
          triggers: matches.triggers.filter { shown(triggers, $0, \.schema) })
      }
      var result = self
      result.bySchema = bySchema.filter { !gone.contains($0.key) }.mapValues {
        kept($0) { _ in true }
      }
      result.listed = kept(listed) { shown(tables, $0, \.schema) }
      result.temporary = kept(temporary) { position in
        shown(tables, position, \.schema) || tables[position].isTemporary
      }
      result.partitions = partitions.compactMapValues { children in
        let kept = children.filter(keepsPartition)
        return kept.isEmpty ? nil : kept
      }
      return result
    }
  }

  private struct Entry: Sendable {
    let position: Int
    /// Lowercased name; a trigger's "name table"
    let text: String
    /// Offsets in `columnNames`, in column order
    let columns: [Int]
    let isTemporary: Bool
  }

  private struct Bucket: Sendable {
    var tables: [Entry] = []
    var views: [Entry] = []
    var functions: [Entry] = []
    var procedures: [Entry] = []
    var triggers: [Entry] = []
  }

  private let buckets: [String: Bucket]
  /// The buckets' schemas, and per kind each object's schema (an offset in `schemaNames`) in
  /// array order: no filter lists everything without scoring or sorting
  private let schemaNames: [String]
  private let schemaOffsets: [[Int]]
  private let isTemporaryTable: [Bool]
  /// Position of each table's parent (-1: none); empty when no table is a partition, so the
  /// other engines pay nothing per query
  private let parentOf: [Int32]
  /// Partitions of each partitioned table, in array order
  private let partitionsOf: [Int: [Int]]
  /// Distinct lowercased column names: a column name is scored once per keystroke
  private let columnNames: [String]
  /// Counts of the tables, views, functions, procedures and triggers it was built from
  let counts: [Int]
  /// Tells one build from the next (the sidebar keys its filter result on it)
  let id = UUID()

  static let empty = SidebarEntityIndex(
    tables: [], views: [], functions: [], procedures: [], triggers: [])

  init(
    tables: [DatabaseTable], views: [DatabaseView], functions: [DatabaseFunction],
    procedures: [DatabaseProcedure], triggers: [DatabaseTrigger]
  ) {
    var buckets: [String: Bucket] = [:]
    var columnNames: [String] = []
    var columnOffsets: [String: Int] = [:]
    func offsets(_ columns: [DatabaseColumn]) -> [Int] {
      columns.map { column in
        let name = column.name.lowercased()
        if let offset = columnOffsets[name] { return offset }
        columnOffsets[name] = columnNames.count
        columnNames.append(name)
        return columnNames.count - 1
      }
    }
    for (position, table) in tables.enumerated() {
      buckets[table.schema, default: Bucket()].tables.append(
        Entry(
          position: position, text: table.name.lowercased(), columns: offsets(table.columns),
          isTemporary: table.isTemporary))
    }
    for (position, view) in views.enumerated() {
      buckets[view.schema, default: Bucket()].views.append(
        Entry(
          position: position, text: view.name.lowercased(), columns: offsets(view.columns),
          isTemporary: false))
    }
    for (position, function) in functions.enumerated() {
      buckets[function.schema, default: Bucket()].functions.append(
        Entry(
          position: position, text: function.name.lowercased(), columns: [], isTemporary: false))
    }
    for (position, procedure) in procedures.enumerated() {
      buckets[procedure.schema, default: Bucket()].procedures.append(
        Entry(
          position: position, text: procedure.name.lowercased(), columns: [], isTemporary: false))
    }
    // A keyword may hit the trigger name or its table
    for (position, trigger) in triggers.enumerated() {
      buckets[trigger.schema, default: Bucket()].triggers.append(
        Entry(
          position: position, text: "\(trigger.name) \(trigger.table)".lowercased(), columns: [],
          isTemporary: false))
    }
    self.buckets = buckets
    self.columnNames = columnNames
    let schemaNames = Array(buckets.keys)
    let offsetOf = Dictionary(uniqueKeysWithValues: schemaNames.enumerated().map { ($1, $0) })
    func schemaOffsets(_ schemas: [String]) -> [Int] { schemas.map { offsetOf[$0] ?? 0 } }
    self.schemaNames = schemaNames
    self.schemaOffsets = [
      schemaOffsets(tables.map(\.schema)), schemaOffsets(views.map(\.schema)),
      schemaOffsets(functions.map(\.schema)), schemaOffsets(procedures.map(\.schema)),
      schemaOffsets(triggers.map(\.schema)),
    ]
    self.isTemporaryTable = tables.map(\.isTemporary)
    // Parent → partitions, once per catalog load (a parent that is not listed leaves the
    // partition at the top)
    var parentOf: [Int32] = []
    var partitionsOf: [Int: [Int]] = [:]
    if tables.contains(where: { $0.parentID != nil }) {
      var positionOf: [UUID: Int] = [:]
      positionOf.reserveCapacity(tables.count)
      for (position, table) in tables.enumerated() { positionOf[table.id] = position }
      parentOf = [Int32](repeating: -1, count: tables.count)
      for (position, table) in tables.enumerated() {
        guard let id = table.parentID, let parent = positionOf[id], parent != position else {
          continue
        }
        parentOf[position] = Int32(parent)
        partitionsOf[parent, default: []].append(position)
      }
    }
    self.parentOf = parentOf
    self.partitionsOf = partitionsOf
    self.counts = [tables.count, views.count, functions.count, procedures.count, triggers.count]
  }

  /// The objects every keyword (`SidebarEntityFilter.keywords`) hits, as
  /// `SidebarEntityFilter.matchesAll` and `matchColumns` keep them. Tables of a `hidden`
  /// schema leave unless temporary; other objects of a `hidden` schema leave unless it is one
  /// of `temporarySchemas`.
  func filter(
    keywords: [String], hidden: Set<String>, temporarySchemas: Set<String>
  ) -> Result {
    guard !keywords.isEmpty else {
      return everything(hidden: hidden, temporarySchemas: temporarySchemas)
    }
    var hits = ColumnHits(keywords: keywords, names: columnNames)
    var result = Result()
    for (schema, bucket) in buckets {
      // A newer keystroke cancelled the run: its result is dropped
      if Task.isCancelled { return Result() }
      let isTemporarySchema = temporarySchemas.contains(schema)
      let isHidden = hidden.contains(schema) && !isTemporarySchema
      var kept = Matches()
      for (offset, entry) in bucket.tables.enumerated() {
        if offset % 512 == 511, Task.isCancelled { return Result() }
        let isTemporary = entry.isTemporary || isTemporarySchema
        guard isTemporary || !isHidden,
          let match = match(
            entry, keywords, &hits,
            literal: nests(entry.position, hidden: hidden, temporarySchemas: temporarySchemas))
        else {
          continue
        }
        if isTemporary {
          result.temporary.tables.append(match)
        } else {
          kept.tables.append(match)
        }
      }
      if !isHidden {
        kept.views = bucket.views.compactMap { match($0, keywords, &hits) }
        kept.functions = Self.positions(bucket.functions, keywords)
        kept.procedures = Self.positions(bucket.procedures, keywords)
        kept.triggers = Self.positions(bucket.triggers, keywords)
      }
      if isTemporarySchema {
        result.temporary.views += kept.views
        result.temporary.functions += kept.functions
        result.temporary.procedures += kept.procedures
        result.temporary.triggers += kept.triggers
      } else if !isHidden {
        result.bySchema[schema] = kept
        result.listed.tables += kept.tables
        result.listed.views += kept.views
        result.listed.functions += kept.functions
        result.listed.procedures += kept.procedures
        result.listed.triggers += kept.triggers
      }
    }
    // Buckets come in no order: back to the arrays' order
    result.listed = Self.inArrayOrder(result.listed)
    result.temporary = Self.inArrayOrder(result.temporary)
    return underParents(result, hidden: hidden, temporarySchemas: temporarySchemas)
  }

  /// Whether the table at `position` is listed under its parent: it has one, and the parent is
  /// listed (temporary, or of a schema not hidden)
  private func nests(_ position: Int, hidden: Set<String>, temporarySchemas: Set<String>) -> Bool {
    guard !parentOf.isEmpty, parentOf[position] >= 0 else { return false }
    let parent = Int(parentOf[position])
    let schema = schemaNames[schemaOffsets[0][parent]]
    return isTemporaryTable[parent] || temporarySchemas.contains(schema) || !hidden.contains(schema)
  }

  /// `partitionsOf` without the partitions `hidden` leaves out (temporary ones stay), so an
  /// opened parent neither lists nor counts them
  private func partitionMap(hidden: Set<String>, temporarySchemas: Set<String>) -> [Int: [Int]] {
    let gone = hidden.subtracting(temporarySchemas)
    guard !partitionsOf.isEmpty, !gone.isEmpty else { return partitionsOf }
    return partitionsOf.compactMapValues { children in
      let shown = children.filter { child in
        isTemporaryTable[child] || !gone.contains(schemaNames[schemaOffsets[0][child]])
      }
      return shown.isEmpty ? nil : shown
    }
  }

  /// `result` with each kept partition moved under its parent, and the parents of a kept
  /// partition added (opened down to it) where the filter did not keep them
  private func underParents(
    _ result: Result, hidden: Set<String>, temporarySchemas: Set<String>
  ) -> Result {
    guard !parentOf.isEmpty else { return result }
    var kept: [Int: RelationMatch] = [:]
    for match in result.listed.tables + result.temporary.tables { kept[match.position] = match }
    var shown: [Int: Set<Int>] = [:]
    var tops: Set<Int> = []
    for position in kept.keys {
      var child = position
      var joinedKnownBranch = false
      while nests(child, hidden: hidden, temporarySchemas: temporarySchemas) {
        let parent = Int(parentOf[child])
        // The branch above was walked from another kept partition
        guard shown[parent, default: []].insert(child).inserted else {
          joinedKnownBranch = true
          break
        }
        child = parent
      }
      if !joinedKnownBranch { tops.insert(child) }
    }
    // Each row once, so a parent cycle in a bad catalog cannot recurse forever
    var visited: Set<Int> = []
    func row(_ position: Int) -> RelationMatch {
      visited.insert(position)
      let match = kept[position]
      return RelationMatch(
        position: position, columns: match?.columns, expandForMatch: match?.expandForMatch ?? false,
        partitions: shown[position].map { $0.sorted().filter { !visited.contains($0) }.map(row) })
    }
    var grouped = result
    grouped.listed.tables = []
    grouped.temporary.tables = []
    for schema in grouped.bySchema.keys { grouped.bySchema[schema]?.tables = [] }
    for top in tops.sorted() {
      let schema = schemaNames[schemaOffsets[0][top]]
      if isTemporaryTable[top] || temporarySchemas.contains(schema) {
        grouped.temporary.tables.append(row(top))
      } else if !hidden.contains(schema) {
        let match = row(top)
        grouped.listed.tables.append(match)
        grouped.bySchema[schema, default: Matches()].tables.append(match)
      }
    }
    grouped.partitions = partitionMap(hidden: hidden, temporarySchemas: temporarySchemas)
    return grouped
  }

  /// `filter` with no keyword, in one pass over the arrays' order: cheap enough for the main
  /// actor, which draws it until the first result lands
  private func everything(hidden: Set<String>, temporarySchemas: Set<String>) -> Result {
    let isTemporarySchema = schemaNames.map(temporarySchemas.contains)
    let isListed = schemaNames.indices.map { offset in
      !isTemporarySchema[offset] && !hidden.contains(schemaNames[offset])
    }
    var bySchema = [Matches](repeating: Matches(), count: schemaNames.count)
    var result = Result()
    // Each object of a kind to the temporary ones, or to the listed ones and its schema's
    func place(_ kind: Int, _ add: (inout Matches, Int) -> Void) {
      for (position, schema) in schemaOffsets[kind].enumerated() {
        // A partition is listed under its parent
        if kind == 0, nests(position, hidden: hidden, temporarySchemas: temporarySchemas) {
          continue
        }
        if isTemporarySchema[schema] || (kind == 0 && isTemporaryTable[position]) {
          add(&result.temporary, position)
        } else if isListed[schema] {
          add(&result.listed, position)
          add(&bySchema[schema], position)
        }
      }
    }
    func relation(_ position: Int) -> RelationMatch {
      RelationMatch(position: position, columns: nil, expandForMatch: false)
    }
    place(0) { $0.tables.append(relation($1)) }
    place(1) { $0.views.append(relation($1)) }
    place(2) { $0.functions.append($1) }
    place(3) { $0.procedures.append($1) }
    place(4) { $0.triggers.append($1) }
    for (offset, schema) in schemaNames.enumerated() where isListed[offset] {
      result.bySchema[schema] = bySchema[offset]
    }
    result.partitions = partitionMap(hidden: hidden, temporarySchemas: temporarySchemas)
    return result
  }

  /// `filter` off the main actor: the sidebar awaits it for each applied filter
  @concurrent func filterInBackground(
    keywords: [String], hidden: Set<String>, temporarySchemas: Set<String>
  ) async -> Result {
    filter(keywords: keywords, hidden: hidden, temporarySchemas: temporarySchemas)
  }

  private static func inArrayOrder(_ matches: Matches) -> Matches {
    Matches(
      tables: matches.tables.sorted { $0.position < $1.position },
      views: matches.views.sorted { $0.position < $1.position },
      functions: matches.functions.sorted(), procedures: matches.procedures.sorted(),
      triggers: matches.triggers.sorted())
  }

  private static func positions(_ entries: [Entry], _ keywords: [String]) -> [Int] {
    entries.compactMap { entry in
      keywords.allSatisfy { SidebarEntityFilter.score(lowercased: $0, in: entry.text) != nil }
        ? entry.position : nil
    }
  }

  /// `SidebarEntityFilter.matchColumns` on the entry: a name hit keeps every column, a hit
  /// covered by columns opens the row on the columns some keyword hits. A `literal` entry (a
  /// partition listed under its parent) needs a literal hit on its name: siblings' names differ
  /// by a character or two, so a typo or an abbreviation would hit them all, and the columns it
  /// shares with its parent show on the parent.
  private func match(
    _ entry: Entry, _ keywords: [String], _ hits: inout ColumnHits, literal: Bool = false
  ) -> RelationMatch? {
    let least = literal ? SidebarEntityFilter.literalScore : Int.min
    let nameHits = keywords.map {
      SidebarEntityFilter.score(lowercased: $0, in: entry.text).map { $0 >= least } ?? false
    }
    if !nameHits.contains(false) {
      return RelationMatch(position: entry.position, columns: nil, expandForMatch: false)
    }
    if literal { return nil }
    for (keyword, nameHit) in nameHits.enumerated() where !nameHit {
      guard entry.columns.contains(where: { hits.hit(keyword, $0) }) else { return nil }
    }
    let visible = entry.columns.indices.filter { offset in
      keywords.indices.contains { hits.hit($0, entry.columns[offset]) }
    }
    return RelationMatch(position: entry.position, columns: visible, expandForMatch: true)
  }

  /// Per keyword, whether it hits each distinct column name, scored on first use
  private struct ColumnHits {
    let keywords: [String]
    let names: [String]
    private var known: [[Bool?]]

    init(keywords: [String], names: [String]) {
      self.keywords = keywords
      self.names = names
      known = keywords.map { _ in [Bool?](repeating: nil, count: names.count) }
    }

    mutating func hit(_ keyword: Int, _ column: Int) -> Bool {
      if let known = known[keyword][column] { return known }
      let hit = SidebarEntityFilter.score(lowercased: keywords[keyword], in: names[column]) != nil
      known[keyword][column] = hit
      return hit
    }
  }
}
