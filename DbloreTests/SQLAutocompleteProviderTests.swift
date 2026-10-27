//
//  SQLAutocompleteProviderTests.swift
//  DbloreTests
//
//  The provider is fed from the already loaded schema (no own fetching)
//

import AppKit
import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("SQLAutocompleteProvider")
struct SQLAutocompleteProviderTests {
  private func table(_ name: String, columns: [String]) -> DatabaseTable {
    DatabaseTable(
      schema: "public", name: name,
      columns: columns.map { DatabaseColumn(name: $0, type: "text") })
  }

  @Test("update(tables:) indexes columns of all 80 tables")
  func indexesAllTables() {
    let provider = SQLAutocompleteProvider()
    let tables = (1...80).map { table("t\($0)", columns: ["col_\($0)"]) }
    provider.update(tables: tables)

    #expect(provider.tables.count == 80)
    #expect(provider.columnsByTable.count == 80)
    #expect(provider.columnsByTable["public.t80"]?.first?.name == "col_80")

    let text = "SELECT col_80 FROM t80"
    let suggestions = provider.getSuggestions(for: text, at: 13, dialect: .postgresql)
    #expect(suggestions.contains { $0.text == "col_80" })
  }

  @Test("after FROM t the column suggestions come from t")
  func columnsComeFromReferencedTable() {
    let provider = SQLAutocompleteProvider()
    provider.update(tables: [
      table("users", columns: ["zeta_name"]),
      table("orders", columns: ["zeta_total"]),
    ])
    let text = "SELECT zeta FROM users"
    let suggestions = provider.getSuggestions(for: text, at: 11, dialect: .postgresql)
    #expect(suggestions.contains { $0.text == "zeta_name" })
    #expect(!suggestions.contains { $0.text == "zeta_total" })
  }

  @Test("a snippet is offered by its trigger prefix in SQL, never on MongoDB")
  func snippetsByTriggerPrefix() {
    let provider = SQLAutocompleteProvider()
    let snippet = SQLSnippet(name: "Select from", trigger: "selfrom", body: "SELECT * FROM $0")
    provider.snippets = { [snippet] }
    let sql = provider.getSuggestions(for: "SELF", at: 4, dialect: .postgresql)
    let match = sql.first { $0.text == "selfrom" }
    guard case .snippet(let offered) = match?.type else {
      Issue.record("no snippet suggestion")
      return
    }
    #expect(offered == snippet)
    #expect(provider.getSuggestions(for: "selx", at: 4, dialect: .postgresql).isEmpty)
    let mongo = provider.getSuggestions(for: "self", at: 4, dialect: .mongodb)
    #expect(!mongo.contains { $0.text == "selfrom" })
  }

  // MARK: - UTF-16 cursor and statement window

  private func utf16Length(_ text: String) -> Int { (text as NSString).length }

  @Test("token after an emoji at a UTF-16 cursor")
  func tokenAfterEmoji() {
    let provider = SQLAutocompleteProvider()
    provider.update(tables: [
      table("users", columns: ["user_id"]),
      table("orders", columns: ["total"]),
    ])
    let text = "SELECT '😀' , us"
    let cursor = utf16Length(text)
    #expect(cursor > text.count)
    #expect(provider.extractCurrentToken(from: text, at: cursor) == "us")

    let suggestions = provider.getSuggestions(for: text, at: cursor, dialect: .postgresql)
    #expect(suggestions.contains { $0.text == "users" })
    #expect(suggestions.contains { $0.text == "user_id" })
    #expect(!suggestions.contains { $0.text == "orders" })
  }

  @Test("statement window gives the same suggestions as the full text for a multi-statement script")
  func statementWindowMatchesSingleStatement() {
    let provider = SQLAutocompleteProvider()
    provider.update(tables: [
      table("users", columns: ["name_u"]),
      table("orders", columns: ["name_o"]),
      table("items", columns: ["name_i"]),
    ])
    let statement = "SELECT na FROM users u"
    let script = "SELECT name_o FROM orders o;\n\(statement);\nSELECT name_i FROM items i;"
    let cursorInScript = (script as NSString).range(of: "na FROM users").location + 2
    let cursorInStatement = 9

    let alone = provider.getSuggestions(for: statement, at: cursorInStatement, dialect: .postgresql)
      .map(\.text)
    let windowed = provider.getSuggestions(for: script, at: cursorInScript, dialect: .postgresql)
      .map(\.text)
    #expect(windowed == alone)
    #expect(windowed.contains("name_u"))
    // Tables referenced only in other statements do not leak into this one
    #expect(!windowed.contains("name_o"))
    #expect(!windowed.contains("name_i"))
  }

  @Test("window is capped for huge statements")
  func windowIsCapped() {
    let provider = SQLAutocompleteProvider()
    provider.update(tables: [table("users", columns: ["user_id"])])
    let text = "SELECT " + String(repeating: "col_a, ", count: 30_000) + "us"
    #expect(utf16Length(text) > 200_000)
    let window = provider.statementWindow(in: text, at: utf16Length(text), dialect: .postgresql)
    #expect(utf16Length(window.text) <= SQLAutocompleteProvider.maxStatementWindow)
    #expect(window.cursor == utf16Length(window.text))

    let start = Date()
    let suggestions = provider.getSuggestions(
      for: text, at: utf16Length(text), dialect: .postgresql)
    #expect(Date().timeIntervalSince(start) < 0.25)
    #expect(suggestions.contains { $0.text == "users" })
  }

  // MARK: - CTE columns and ORDER BY / GROUP BY aliases

  /// Suggestion texts with the cursor at `|` in `sql`
  private func suggest(_ provider: SQLAutocompleteProvider, _ sql: String) -> [String] {
    let cursor = (sql as NSString).range(of: "|").location
    let text = sql.replacingOccurrences(of: "|", with: "")
    return provider.getSuggestions(for: text, at: cursor, dialect: .postgresql).map(\.text)
  }

  private func cteProvider() -> SQLAutocompleteProvider {
    let provider = SQLAutocompleteProvider()
    provider.update(tables: [
      table("users", columns: ["user_id", "user_name", "tag"]),
      table("orders", columns: ["id", "total", "zeta_total"]),
    ])
    return provider
  }

  @Test("a CTE column list names its columns")
  func cteColumnList() {
    let provider = cteProvider()
    let sql =
      "WITH recent (order_id, amount) AS (SELECT id, total FROM orders) SELECT am| FROM recent"
    #expect(suggest(provider, sql).contains("amount"))
    let scope = provider.statementScope(
      in: sql.replacingOccurrences(of: "|", with: ""), cursor: 0, dialect: .postgresql)
    #expect(scope.ctes.map(\.name) == ["recent"])
    #expect(scope.ctes.first?.columns == ["order_id", "amount"])
  }

  @Test("CTE columns come from the body's select list, aliases included")
  func cteSelectAliases() {
    let provider = cteProvider()
    let sql =
      "WITH stats AS (SELECT o.id, count(*) AS order_count, max(total) last_total, total + 1 "
      + "FROM orders o GROUP BY o.id) SELECT | FROM stats"
    let scope = provider.statementScope(
      in: sql.replacingOccurrences(of: "|", with: ""), cursor: 0, dialect: .postgresql)
    #expect(scope.ctes.first?.columns == ["id", "order_count", "last_total"])
    #expect(scope.referencedCTEs == ["stats"])
    #expect(
      suggest(provider, sql.replacingOccurrences(of: "|", with: "order|")).contains("order_count"))
    #expect(
      suggest(provider, sql.replacingOccurrences(of: "|", with: "last|")).contains("last_total"))
  }

  @Test("* and t.* expand from schema tables and earlier CTEs")
  func cteStarExpansion() {
    let provider = cteProvider()
    let sql =
      "WITH u AS (SELECT * FROM users), v AS (SELECT x.*, 1 AS extra FROM u AS x JOIN orders o ON 1=1), "
      + "w AS (SELECT o.* FROM v, orders o) SELECT * FROM w"
    let scope = provider.statementScope(in: sql, cursor: 0, dialect: .postgresql)
    #expect(scope.ctes.map(\.name) == ["u", "v", "w"])
    #expect(scope.ctes[0].columns == ["user_id", "user_name", "tag"])
    #expect(scope.ctes[1].columns == ["user_id", "user_name", "tag", "extra"])
    #expect(scope.ctes[2].columns == ["id", "total", "zeta_total"])
  }

  @Test("CTE names are offered as tables, their columns only when used as a source")
  func cteNamesAsTables() {
    let provider = cteProvider()
    let tables = provider.getSuggestions(
      for: "WITH active_users AS (SELECT 1 AS a) SELECT * FROM act", at: 54, dialect: .postgresql)
    let match = tables.first { $0.text == "active_users" }
    guard case .table = match?.type else {
      Issue.record("no CTE table suggestion")
      return
    }
    // A CTE source is table context: no fallback to every schema column
    let columns = suggest(provider, "WITH c AS (SELECT 1 AS zeta_c) SELECT zeta| FROM c")
    #expect(columns.contains("zeta_c"))
    #expect(!columns.contains("zeta_total"))
    // A CTE that is not a source offers no columns
    #expect(
      !suggest(provider, "WITH c AS (SELECT 1 AS zeta_c) SELECT zeta| FROM orders").contains(
        "zeta_c"))
  }

  @Test("nested, recursive and quoted CTEs")
  func nestedAndRecursiveCTEs() {
    let provider = cteProvider()
    let nested =
      "WITH outer_cte AS (WITH inner_cte AS (SELECT 1 AS deep) "
      + "SELECT deep, s.v AS shallow FROM inner_cte, (SELECT 2 AS v) s) SELECT * FROM outer_cte"
    let scope = provider.statementScope(in: nested, cursor: 0, dialect: .postgresql)
    #expect(scope.ctes.map(\.name) == ["inner_cte", "outer_cte"])
    #expect(scope.ctes[1].columns == ["deep", "shallow"])

    let recursive =
      "WITH RECURSIVE r AS MATERIALIZED (SELECT 1 AS n UNION ALL SELECT n + 1 FROM r), "
      + "q (k) AS (SELECT 1) SELECT * FROM r"
    let recursiveScope = provider.statementScope(in: recursive, cursor: 0, dialect: .postgresql)
    #expect(recursiveScope.ctes.map(\.columns) == [["n"], ["k"]])

    let quoted =
      "WITH `Recent Rows` AS (SELECT id AS `Row Id` FROM orders) SELECT * FROM `Recent Rows`"
    let quotedScope = provider.statementScope(in: quoted, cursor: 0, dialect: .mysql)
    #expect(quotedScope.ctes.first?.name == "Recent Rows")
    #expect(quotedScope.ctes.first?.columns == ["Row Id"])
    #expect(quotedScope.referencedCTEs == ["recent rows"])
  }

  @Test("after ORDER BY the select aliases come first, then columns")
  func orderByAliasesFirst() {
    let provider = cteProvider()
    let result = suggest(
      provider,
      "SELECT user_name AS name_label, count(*) AS total_orders FROM users ORDER BY t|")
    #expect(result.first == "total_orders")
    #expect(result.contains("tag"))
  }

  @Test("WITHIN GROUP and OVER items keep their aliases")
  func orderByAliasesAfterWindowSyntax() {
    let provider = cteProvider()
    func aliases(_ sql: String) -> [String]? {
      provider.statementScope(in: sql, cursor: utf16Length(sql), dialect: .postgresql)
        .orderByAliases
    }
    #expect(
      aliases(
        "SELECT user_name AS x, percentile_cont(0.5) WITHIN GROUP (ORDER BY total) AS med, "
          + "id AS z FROM orders ORDER BY ") == ["x", "med", "z"])
    #expect(
      aliases(
        "SELECT count(*) OVER w AS n, count(*) OVER w, sum(total) OVER (PARTITION BY id) win_sum "
          + "FROM orders WINDOW w AS (ORDER BY id) ORDER BY ") == ["n", "win_sum"])
    #expect(
      aliases(
        "SELECT a IS DISTINCT FROM b AS changed, total IS NOT DISTINCT FROM 0 c FROM orders "
          + "ORDER BY ") == ["changed", "c"])
    let cte = provider.statementScope(
      in: "WITH s AS (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY total) AS med, id "
        + "FROM orders) SELECT * FROM s", cursor: 0, dialect: .postgresql)
    #expect(cte.ctes.first?.columns == ["med", "id"])
  }

  @Test("chained * expansion is capped per CTE")
  func cteStarExpansionCapped() {
    let provider = cteProvider()
    var sql = "WITH c0 AS (SELECT * FROM users)"
    for index in 1...40 { sql += ", c\(index) AS (SELECT *, * FROM c\(index - 1))" }
    sql += " SELECT * FROM c40"
    let scope = provider.statementScope(in: sql, cursor: 0, dialect: .postgresql)
    #expect(scope.ctes.first?.columns == ["user_id", "user_name", "tag"])
    #expect(scope.ctes.last?.columns.count == SQLAutocompleteProvider.maxCTEColumns)
  }

  @Test("CTE column lists, * over unknown sources and CTE column suggestions are capped")
  func cteColumnListAndSuggestionsCapped() {
    let provider = cteProvider()
    let cap = SQLAutocompleteProvider.maxCTEColumns
    let names = (0..<600).map { "a\($0)" }
    let list = provider.statementScope(
      in: "WITH c0 (\(names.joined(separator: ", "))) AS (SELECT 1) SELECT * FROM c0", cursor: 0,
      dialect: .postgresql)
    #expect(list.ctes.first?.columns == Array(names.prefix(cap)))

    let unknown = provider.statementScope(
      in: "WITH c AS (SELECT *, *, x.* FROM nope, nope, nope x) SELECT * FROM c", cursor: 0,
      dialect: .postgresql)
    #expect(unknown.ctes.first?.columns == [])

    // c0 fills the total cap with long names: the shorter zq of a later CTE is not offered
    let wide = "c0 (\((0..<cap).map { "zz\($0)" }.joined(separator: ","))) AS (SELECT 1)"
    var chain = ""
    for index in 1...5 { chain += ", c\(index) AS (SELECT * FROM c\(index - 1))" }
    let capped = suggest(
      provider, "WITH \(wide)\(chain), q (zq) AS (SELECT 1) SELECT z| FROM c5, q")
    #expect(capped.count == 20)
    #expect(Set(capped).count == capped.count)
    #expect(!capped.contains("zq"))
    // Defined first, zq is offered first
    #expect(
      suggest(provider, "WITH q (zq) AS (SELECT 1), \(wide)\(chain) SELECT z| FROM c5, q").first
        == "zq")
  }

  @Test("after GROUP BY the select aliases come first")
  func groupByAliasesFirst() {
    let provider = cteProvider()
    let result = suggest(
      provider, "SELECT date_trunc('day', now()) day_bucket, tag FROM users GROUP BY da|")
    #expect(result.first == "day_bucket")
    #expect(result.contains("DATE"))
  }

  @Test("aliases come from the query level at the cursor, and only after ORDER BY or GROUP BY")
  func aliasesOfSameLevel() {
    let provider = cteProvider()
    let inner = suggest(
      provider,
      "SELECT tag AS al_outer FROM (SELECT tag AS al_inner FROM users ORDER BY al|) s")
    #expect(inner.first == "al_inner")
    #expect(!inner.contains("al_outer"))
    let outer = suggest(
      provider,
      "SELECT s.al_inner AS al_outer FROM (SELECT tag AS al_inner FROM users) s ORDER BY al|")
    #expect(outer.first == "al_outer")
    #expect(!outer.contains("al_inner"))
    #expect(!suggest(provider, "SELECT tag AS al_tag FROM users WHERE al|").contains("al_tag"))
  }

  // MARK: - extractTableReferences parity with the original implementation

  private func parityProvider() -> SQLAutocompleteProvider {
    let provider = SQLAutocompleteProvider()
    provider.update(
      tables: ["users", "orders", "products", "sessions", "persons", "items"].map {
        table($0, columns: ["id"])
      }
        + [
          DatabaseTable(
            schema: "audit", name: "users", columns: [DatabaseColumn(name: "id", type: "text")])
        ])
    return provider
  }

  private static let parityCases: [String] = [
    "SELECT * FROM users u",
    "SELECT * FROM users AS u WHERE u.id = 1",
    "select * from Users U join Orders o on o.id = u.id",
    "SELECT * FROM public.users u",
    "SELECT * FROM \"users\" u",
    "SELECT * FROM \"public\".\"users\" u",
    "SELECT * FROM users u, orders o, products p WHERE 1=1",
    "SELECT * FROM users, orders",
    "SELECT * FROM users u JOIN orders o ON o.uid = u.id LEFT JOIN products p ON p.id = o.pid",
    "SELECT * FROM users u INNER JOIN orders o ON 1=1 RIGHT JOIN items i ON 1=1 FULL JOIN sessions s ON 1=1 CROSS JOIN persons pp",
    "SELECT * FROM (SELECT * FROM users u) sub JOIN orders o ON 1=1",
    "SELECT * FROM users WHERE id IN (SELECT uid FROM orders o WHERE o.x = 1)",
    "WITH a AS (SELECT * FROM users u), b AS (SELECT * FROM orders o) SELECT * FROM a JOIN b ON 1=1",
    "UPDATE users SET x = 1 WHERE id IN (SELECT id FROM orders)",
    "DELETE FROM users u WHERE u.id = 1",
    "DELETE FROM users",
    "SELECT * FROM",
    "SELECT * FROM ",
    "SELECT * FROM users",
    "SELECT * FROM users\nu\nWHERE u.id = 1",
    "SELECT * FROM users\tu WHERE 1",
    "SELECT * FROM users u \t",
    "SELECT * FROM users\t \n",
    "SELECT * FROM users u GROUP BY u.id ORDER BY 1 LIMIT 5",
    "SELECT * FROM users u UNION SELECT * FROM orders o EXCEPT SELECT * FROM items i INTERSECT SELECT 1",
    "SELECT * FROM persons p",
    "SELECT * FROM fromage f",
    "SELECT * FROM users u FROM orders o FROM items",
    "SELECT * FROM users orders",
    "SELECT * FROM users audit",
    "SELECT * FROM orders users JOIN users orders ON 1=1",
    "SELECT * FROM audit.users a",
    "SELECT * FROM nothing n JOIN users u ON 1=1",
    "SELECT * FROM  users   u   JOIN   orders   o",
    "SELECT * FROM users \u{1F600} u JOIN orders",
    "SELECT stra\u{00DF}e FROM users u",
    "",
    "no keywords here",
  ]

  @Test("extractTableReferences equals the original on hand-written cases")
  func extractTableReferencesParityOnCases() {
    let provider = parityProvider()
    for sql in Self.parityCases {
      let expected = referenceExtractTableReferences(provider, from: sql)
      let actual = provider.extractTableReferences(from: sql)
      #expect(actual == expected, "mismatch for: \(sql.debugDescription)")
    }
  }

  /// Deterministic PRNG so failures reproduce
  private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }

  /// Verbatim copy of the original (quadratic) implementation, kept as the parity reference
  private func referenceExtractTableReferences(
    _ provider: SQLAutocompleteProvider, from text: String
  ) -> [String: String] {
    let upperText = text.uppercased()
    var tableRefs: [String: String] = [:]

    let keywords = [
      "FROM", "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN",
    ]

    for keyword in keywords {
      var searchRange = upperText.startIndex..<upperText.endIndex

      while let range = upperText.range(of: keyword, range: searchRange) {
        let afterKeyword = upperText[range.upperBound...]
        let afterKeywordString = String(afterKeyword)

        let stopKeywords = [
          "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "ON", "GROUP", "ORDER",
          "LIMIT", "UNION", "EXCEPT", "INTERSECT",
        ]
        var endIndex = afterKeywordString.endIndex

        for stopKeyword in stopKeywords {
          if let stopRange = afterKeywordString.range(of: stopKeyword) {
            let currentEnd = afterKeywordString.distance(
              from: afterKeywordString.startIndex, to: stopRange.lowerBound)
            let proposedEnd = afterKeywordString.distance(
              from: afterKeywordString.startIndex, to: endIndex)
            if currentEnd < proposedEnd {
              endIndex = stopRange.lowerBound
            }
          }
        }

        let tableRef = String(afterKeywordString[..<endIndex]).trimmingCharacters(
          in: .whitespacesAndNewlines)

        let parts = tableRef.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        if let tableName = parts.first, !tableName.isEmpty {
          let matchingTableKey = provider.findMatchingTableKey(for: tableName)

          if let tableKey = matchingTableKey {
            tableRefs[tableName.lowercased()] = tableKey

            if parts.count > 1 {
              let alias = parts[1]
              tableRefs[alias.lowercased()] = tableKey
            }
          }
        }

        searchRange = range.upperBound..<upperText.endIndex
      }
    }

    return tableRefs
  }
}

// MARK: - Debounce

@MainActor
private final class SpyProvider: SQLAutocompleteProvider {
  var calls = 0
  override func getSuggestions(
    for fullText: String, at fullCursorPosition: Int, dialect: SQLDialect
  ) -> [AutocompleteSuggestion] {
    calls += 1
    return []
  }
}

/// Test-controlled replacement for the debounce sleep: sleeps park until `open()`, later ones pass through
@MainActor
private final class SleepGate {
  private var waiters: [CheckedContinuation<Void, Error>] = []
  private var isOpen = false
  private(set) var requested: [Duration] = []

  func sleep(_ duration: Duration) async throws {
    requested.append(duration)
    if isOpen { return }
    try await withCheckedThrowingContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    let parked = waiters
    waiters = []
    for waiter in parked { waiter.resume() }
  }
}

@Suite("SQLTextView autocomplete debounce", .serialized)
@MainActor
struct SQLTextViewAutocompleteDebounceTests {
  private func makeHost() -> (OffscreenEditorHost, SpyProvider) {
    let host = OffscreenEditorHost(text: "SELECT us")
    let spy = SpyProvider()
    host.textView.autocompleteProvider = spy
    host.textView.setSelectedRange(NSRange(location: 9, length: 0))
    return (host, spy)
  }

  /// Installs a gate as the debounce sleep; restores the seam and releases parked sleeps afterwards
  private func withSleepGate(_ body: (SleepGate) async -> Void) async {
    let saved = SQLTextView.autocompleteSleep
    let gate = SleepGate()
    SQLTextView.autocompleteSleep = { try await gate.sleep($0) }
    defer {
      SQLTextView.autocompleteSleep = saved
      gate.open()
    }
    await body(gate)
  }

  @Test("rapid calls within the debounce window compute once")
  func rapidCallsComputeOnce() async {
    await withSleepGate { gate in
      let (host, spy) = makeHost()

      var tasks: [Task<Void, Never>?] = []
      for _ in 0..<5 {
        host.textView.updateAutocompleteSuggestions()
        tasks.append(host.textView.autocompleteTask)
      }
      #expect(spy.calls == 0)

      gate.open()
      for task in tasks { await task?.value }
      #expect(spy.calls == 1)
      #expect(gate.requested.allSatisfy { $0 == SQLTextView.autocompleteDebounce })
    }
  }

  @Test("accepting a suggestion while a debounce is pending suppresses the computation")
  func acceptingSuppressesPending() async {
    await withSleepGate { gate in
      let (host, spy) = makeHost()

      host.textView.updateAutocompleteSuggestions()
      let task = host.textView.autocompleteTask
      host.textView.setAcceptingSuggestionFlag(true)
      gate.open()
      await task?.value
      host.textView.setAcceptingSuggestionFlag(false)
      #expect(spy.calls == 0)
    }
  }
}
