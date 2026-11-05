// SidebarEntityIndexTests.swift
// The Public tab filter on SidebarEntityIndex keeps the same objects, in the same order, with the
// same columns and row opening as the per-object path it replaces (SidebarEntityFilter.matchesAll
// and matchColumns over the catalog arrays, after SidebarSectionModel.temporarySplit).

import Foundation
import Testing

@testable import Dblore

@Suite("Sidebar entity index")
@MainActor
struct SidebarEntityIndexTests {
  /// One kept table or view: "schema.name", the columns shown and whether the row opens
  private struct Row: Equatable {
    let name: String
    let columns: [String]
    let expandForMatch: Bool
  }

  private struct Kept: Equatable {
    var tables: [Row] = []
    var views: [Row] = []
    var functions: [String] = []
    var procedures: [String] = []
    var triggers: [String] = []
  }

  private static func columns(_ names: String...) -> [DatabaseColumn] {
    names.map { DatabaseColumn(name: $0, type: "int4") }
  }

  private static let hidden: Set<String> = ["audit", "pg_temp_3"]
  private static let temporarySchemas: Set<String> = ["pg_temp_3"]

  private static let tables = [
    DatabaseTable(schema: "public", name: "orders", columns: columns("id", "Amount", "note")),
    DatabaseTable(schema: "audit", name: "orders_log", columns: columns("id", "amount")),
    DatabaseTable(schema: "public", name: "customers", columns: columns("id", "name")),
    // A session table outside a temporary schema (MySQL) stays, its schema hidden or not
    DatabaseTable(
      schema: "audit", name: "scratch", columns: columns("amount"), isTemporary: true),
    DatabaseTable(
      schema: "pg_temp_3", name: "tmp_orders", columns: columns("amount_due"), isTemporary: true),
    DatabaseTable(schema: "sales", name: "invoices", columns: columns("id", "total_amount")),
    DatabaseTable(schema: "public", name: "line_items", columns: columns("order_id", "price")),
  ]
  private static let views = [
    DatabaseView(schema: "public", name: "order_totals", columns: columns("order_id", "amount")),
    DatabaseView(schema: "audit", name: "orders_view", columns: columns("amount")),
    DatabaseView(schema: "pg_temp_3", name: "tmp_view", columns: columns("amount")),
  ]
  private static let functions = [
    DatabaseFunction(schema: "public", name: "order_amount", returnType: "numeric"),
    DatabaseFunction(schema: "audit", name: "order_amount", returnType: "numeric"),
  ]
  private static let procedures = [
    DatabaseProcedure(schema: "sales", name: "refresh_orders")
  ]
  private static let triggers = [
    DatabaseTrigger(
      schema: "public", table: "orders", name: "stamp", timing: .before, events: [.insert],
      enabled: true),
    DatabaseTrigger(
      schema: "audit", table: "orders_log", name: "stamp", timing: .after, events: [.update],
      enabled: true),
    DatabaseTrigger(
      schema: "pg_temp_3", table: "tmp_orders", name: "tmp_stamp", timing: .after,
      events: [.delete], enabled: true),
  ]

  /// The sidebar's filter before the index, object by object over the arrays
  private static func expected(_ keywords: [String]) -> (listed: Kept, temporary: Kept) {
    func shown(_ schema: String) -> Bool {
      !hidden.contains(schema) || temporarySchemas.contains(schema)
    }
    func row(_ schema: String, _ name: String, _ columns: [DatabaseColumn]) -> Row? {
      SidebarEntityFilter.matchColumns(name: name, columns: columns, keywords: keywords).map {
        Row(
          name: "\(schema).\(name)", columns: $0.columns.map(\.name),
          expandForMatch: $0.expandForMatch)
      }
    }
    func kept(_ inTemporary: Bool) -> Kept {
      func keeps(_ schema: String) -> Bool { temporarySchemas.contains(schema) == inTemporary }
      func hits(_ schema: String, _ text: String) -> Bool {
        keeps(schema) && shown(schema) && SidebarEntityFilter.matchesAll(text, keywords: keywords)
      }
      let split = SidebarSectionModel.temporarySplit(tables, temporarySchemas: temporarySchemas)
      return Kept(
        tables: inTemporary
          ? split.temporary.compactMap { row($0.schema, $0.name, $0.columns) }
          : split.regular.filter { !hidden.contains($0.schema) }.compactMap {
            row($0.schema, $0.name, $0.columns)
          },
        views: views.filter { keeps($0.schema) && shown($0.schema) }.compactMap {
          row($0.schema, $0.name, $0.columns)
        },
        functions: functions.filter { hits($0.schema, $0.name) }.map(\.qualifiedName),
        procedures: procedures.filter { hits($0.schema, $0.name) }.map(\.qualifiedName),
        triggers: triggers.filter { hits($0.schema, "\($0.name) \($0.table)") }.map {
          "\($0.schema).\($0.name)"
        })
    }
    return (kept(false), kept(true))
  }

  private static func resolved(_ matches: SidebarEntityIndex.Matches) -> Kept {
    typealias Match = SidebarEntityIndex.RelationMatch
    func row(_ match: Match, _ columns: [DatabaseColumn], _ name: String) -> Row {
      Row(
        name: name, columns: (match.columns?.map { columns[$0] } ?? columns).map(\.name),
        expandForMatch: match.expandForMatch)
    }
    return Kept(
      tables: matches.tables.map {
        row($0, tables[$0.position].columns, tables[$0.position].qualifiedName)
      },
      views: matches.views.map {
        row($0, views[$0.position].columns, views[$0.position].qualifiedName)
      },
      functions: matches.functions.map { functions[$0].qualifiedName },
      procedures: matches.procedures.map { procedures[$0].qualifiedName },
      triggers: matches.triggers.map { "\(triggers[$0].schema).\(triggers[$0].name)" })
  }

  private static func inSchema(_ kept: Kept, _ schema: String) -> Kept {
    let prefix = "\(schema)."
    return Kept(
      tables: kept.tables.filter { $0.name.hasPrefix(prefix) },
      views: kept.views.filter { $0.name.hasPrefix(prefix) },
      functions: kept.functions.filter { $0.hasPrefix(prefix) },
      procedures: kept.procedures.filter { $0.hasPrefix(prefix) },
      triggers: kept.triggers.filter { $0.hasPrefix(prefix) })
  }

  /// A column-only hit, a trigger hit by its table, a hidden and a temporary schema
  @Test("The index keeps the objects, order, columns and row opening of the per-object filter")
  func indexMatchesPerObjectFilter() throws {
    let index = SidebarEntityIndex(
      tables: Self.tables, views: Self.views, functions: Self.functions,
      procedures: Self.procedures, triggers: Self.triggers)
    for query in ["", "amount", "orders", "ord amount", "stmp", "amout", "zzzz"] {
      let keywords = SidebarEntityFilter.keywords(in: query)
      let expected = Self.expected(keywords)
      let result = index.filter(
        keywords: keywords, hidden: Self.hidden, temporarySchemas: Self.temporarySchemas)
      let listed = Self.resolved(result.listed)
      #expect(listed == expected.listed, "listed, query \"\(query)\"")
      #expect(Self.resolved(result.temporary) == expected.temporary, "temporary, \"\(query)\"")
      for schema in ["public", "sales"] {
        #expect(
          Self.resolved(result.inSchema(schema)) == Self.inSchema(expected.listed, schema),
          "schema \(schema), query \"\(query)\"")
      }
      #expect(result.inSchema("audit").isEmpty)
    }

    // The cases themselves: a column-only hit opens the row on that column, a trigger is
    // hit by its table, the hidden schema's session table and the temporary schema still show
    let amount = Self.resolved(
      index.filter(
        keywords: ["amount"], hidden: Self.hidden, temporarySchemas: Self.temporarySchemas
      ).listed)
    #expect(
      amount.tables.first == Row(name: "public.orders", columns: ["Amount"], expandForMatch: true))
    let orders = index.filter(
      keywords: ["orders"], hidden: Self.hidden, temporarySchemas: Self.temporarySchemas)
    #expect(Self.resolved(orders.listed).triggers == ["public.stamp"])
    #expect(
      Self.resolved(orders.temporary).tables.map(\.name) == ["pg_temp_3.tmp_orders"])
    let all = Self.resolved(
      index.filter(keywords: [], hidden: Self.hidden, temporarySchemas: Self.temporarySchemas)
        .temporary)
    #expect(all.tables.map(\.name) == ["audit.scratch", "pg_temp_3.tmp_orders"])
    #expect(all.views.map(\.name) == ["pg_temp_3.tmp_view"])
  }

  /// The hidden "audit" schema: its session table "scratch" still shows (Temporary), its view
  /// "orders_view" does not, from the filter and from a result drawn before it was hidden
  @Test("A hidden schema's temporary table stays and its view leaves")
  func hiddenSchemaKeepsTemporaryTableDropsView() {
    let index = SidebarEntityIndex(
      tables: Self.tables, views: Self.views, functions: Self.functions,
      procedures: Self.procedures, triggers: Self.triggers)
    for keywords in [[], ["amount"]] {
      let hidden = index.filter(
        keywords: keywords, hidden: Self.hidden, temporarySchemas: Self.temporarySchemas)
      #expect(Self.resolved(hidden.temporary).tables.map(\.name).contains("audit.scratch"))
      #expect(!Self.resolved(hidden.listed).views.map(\.name).contains("audit.orders_view"))
      #expect(!Self.resolved(hidden.temporary).views.map(\.name).contains("audit.orders_view"))

      let before = index.filter(
        keywords: keywords, hidden: [], temporarySchemas: Self.temporarySchemas)
      #expect(Self.resolved(before.listed).views.map(\.name).contains("audit.orders_view"))
      let drawn = before.hiding(
        Self.hidden, temporarySchemas: Self.temporarySchemas, tables: Self.tables,
        views: Self.views, functions: Self.functions, procedures: Self.procedures,
        triggers: Self.triggers)
      #expect(Self.resolved(drawn.listed) == Self.resolved(hidden.listed), "\(keywords)")
      #expect(Self.resolved(drawn.temporary) == Self.resolved(hidden.temporary), "\(keywords)")
      #expect(Set(drawn.bySchema.keys) == Set(hidden.bySchema.keys), "\(keywords)")
    }
  }

  // MARK: - Partitions

  /// `events` partitioned three ways, `events_nov` partitioned again; `orphan_part`'s parent is
  /// not listed
  private static let partitioned = [
    DatabaseTable(schema: "public", name: "events"),
    DatabaseTable(schema: "public", name: "events_sep", parent: ("public", "events")),
    DatabaseTable(schema: "public", name: "events_oct", parent: ("public", "events")),
    DatabaseTable(schema: "public", name: "events_nov", parent: ("public", "events")),
    DatabaseTable(schema: "public", name: "events_nov_eu", parent: ("public", "events_nov")),
    DatabaseTable(schema: "public", name: "users"),
    DatabaseTable(schema: "public", name: "orphan_part", parent: ("hidden", "gone")),
  ]

  private static func partitionedFilter(_ query: String) -> SidebarEntityIndex.Result {
    SidebarEntityIndex(
      tables: partitioned, views: [], functions: [], procedures: [], triggers: []
    ).filter(keywords: SidebarEntityFilter.keywords(in: query), hidden: [], temporarySchemas: [])
  }

  @Test("Partitions list under their parent, nested ones under theirs")
  func partitionsGroupUnderParent() {
    let all = Self.partitionedFilter("")
    #expect(all.listed.tables.map(\.position) == [0, 5, 6])
    #expect(all.inSchema("public").tables.map(\.position) == [0, 5, 6])
    #expect(all.partitions[0] == [1, 2, 3])
    #expect(all.partitions[3] == [4])
    #expect(all.partitions[5] == nil)
  }

  @Test("A filter hit on a partition shows its parents opened down to it")
  func filterOnPartitionRevealsParent() {
    typealias Match = SidebarEntityIndex.RelationMatch
    func row(_ position: Int, _ partitions: [Match]? = nil) -> Match {
      Match(position: position, columns: nil, expandForMatch: false, partitions: partitions)
    }
    let october = Self.partitionedFilter("oct")
    #expect(october.listed.tables == [row(0, [row(2)])])
    #expect(october.inSchema("public").tables == [row(0, [row(2)])])
    #expect(Self.partitionedFilter("eu").listed.tables == [row(0, [row(3, [row(4)])])])
    // A table without a parent is listed as before
    #expect(Self.partitionedFilter("users").listed.tables == [row(5)])
  }
}

extension SidebarEntityIndexTests {
  /// Monthly partitions whose names differ by a character or two, so one typo of a keyword hits
  /// every sibling; `events_2026_11` is partitioned again, `events_archive` lives in "archive"
  private static let monthly = [
    DatabaseTable(schema: "public", name: "events", columns: columns("id", "user_id")),
    DatabaseTable(
      schema: "public", name: "events_2026_09", columns: columns("id", "user_id"),
      parent: ("public", "events")),
    DatabaseTable(
      schema: "public", name: "events_2026_10", columns: columns("id", "user_id"),
      parent: ("public", "events")),
    DatabaseTable(
      schema: "public", name: "events_2026_11", columns: columns("id", "user_id"),
      parent: ("public", "events")),
    DatabaseTable(
      schema: "public", name: "events_2026_11_eu", columns: columns("id", "user_id"),
      parent: ("public", "events_2026_11")),
    DatabaseTable(
      schema: "public", name: "events_2026_11_us", columns: columns("id", "user_id"),
      parent: ("public", "events_2026_11")),
    DatabaseTable(
      schema: "archive", name: "events_archive", columns: columns("id", "user_id"),
      parent: ("public", "events")),
  ]

  private static func monthlyFilter(
    _ query: String, hidden: Set<String> = []
  ) -> SidebarEntityIndex.Result {
    SidebarEntityIndex(
      tables: monthly, views: [], functions: [], procedures: [], triggers: []
    ).filter(
      keywords: SidebarEntityFilter.keywords(in: query), hidden: hidden, temporarySchemas: [])
  }

  @Test("A filter reveals only the path down to the partitions it hits, not their siblings")
  func filterRevealsOnlyHitPartitions() {
    typealias Match = SidebarEntityIndex.RelationMatch
    func row(_ position: Int, _ partitions: [Match]? = nil) -> Match {
      Match(position: position, columns: nil, expandForMatch: false, partitions: partitions)
    }
    #expect(Self.monthlyFilter("2026_10").listed.tables == [row(0, [row(2)])])
    #expect(Self.monthlyFilter("11_eu").listed.tables == [row(0, [row(3, [row(4)])])])
    // A column hit shows on the parent; its partitions share the column and stay closed
    let column = Self.monthlyFilter("user_id").listed.tables
    #expect(column.map(\.position) == [0])
    #expect(column.first?.partitions == nil)
  }

  @Test("A partition in a hidden schema is neither listed, counted nor revealed")
  func hiddenSchemaPartitionLeaves() {
    #expect(Self.monthlyFilter("").partitions[0] == [1, 2, 3, 6])
    let hidden: Set<String> = ["archive"]
    #expect(Self.monthlyFilter("", hidden: hidden).partitions[0] == [1, 2, 3])
    #expect(Self.monthlyFilter("events_2026_10", hidden: hidden).partitions[0] == [1, 2, 3])
    #expect(Self.monthlyFilter("archive", hidden: hidden).listed.tables.isEmpty)
    // A result drawn before the schema was hidden drops it too
    let drawn = Self.monthlyFilter("").hiding(
      hidden, temporarySchemas: [], tables: Self.monthly, views: [], functions: [],
      procedures: [], triggers: [])
    #expect(drawn.partitions[0] == [1, 2, 3])
    // So does a hidden partition a keyword result showed under its listed parent
    let revealed = Self.monthlyFilter("archive")
    #expect(revealed.listed.tables.first?.partitions?.map(\.position) == [6])
    let hid = revealed.hiding(
      hidden, temporarySchemas: [], tables: Self.monthly, views: [], functions: [],
      procedures: [], triggers: [])
    #expect(hid.listed.tables.map(\.position) == [0])
    #expect(hid.listed.tables.first?.partitions == nil)
    #expect(hid.inSchema("public").tables.first?.partitions == nil)
  }
}
