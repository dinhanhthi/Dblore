//
//  SQLAutocompleteProviderTests.swift
//  SQLNotebookTests
//
//  The provider is fed from the already loaded schema (no own fetching)
//

import AppKit
import Foundation
import Testing

@testable import SQLNotebook

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
    let suggestions = provider.getSuggestions(for: text, at: 13)
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
    let suggestions = provider.getSuggestions(for: text, at: 11)
    #expect(suggestions.contains { $0.text == "zeta_name" })
    #expect(!suggestions.contains { $0.text == "zeta_total" })
  }

  @Test("clearCache empties tables and columns")
  func clearCacheEmpties() {
    let provider = SQLAutocompleteProvider()
    provider.update(tables: [table("users", columns: ["id"])])
    provider.clearCache()
    #expect(provider.tables.isEmpty)
    #expect(provider.columnsByTable.isEmpty)
  }

  @Test("update replaces the previous schema")
  func updateReplaces() {
    let provider = SQLAutocompleteProvider()
    provider.update(tables: [table("old_table", columns: ["old_col"])])
    provider.update(tables: [table("new_table", columns: ["new_col"])])
    #expect(provider.tables.map(\.name) == ["new_table"])
    #expect(provider.columnsByTable.keys.sorted() == ["public.new_table"])
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

    let suggestions = provider.getSuggestions(for: text, at: cursor)
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

    let alone = provider.getSuggestions(for: statement, at: cursorInStatement).map(\.text)
    let windowed = provider.getSuggestions(for: script, at: cursorInScript).map(\.text)
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
    let window = provider.statementWindow(in: text, at: utf16Length(text))
    #expect(utf16Length(window.text) <= SQLAutocompleteProvider.maxStatementWindow)
    #expect(window.cursor == utf16Length(window.text))

    let start = Date()
    let suggestions = provider.getSuggestions(for: text, at: utf16Length(text))
    #expect(Date().timeIntervalSince(start) < 0.25)
    #expect(suggestions.contains { $0.text == "users" })
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

  @Test("extractTableReferences equals the original on 2,000 seeded random strings")
  func extractTableReferencesParityOnRandomStrings() {
    let provider = parityProvider()
    let alphabet: [String] = [
      "SELECT", "select", "FROM", "from", "From", "JOIN", "join", "INNER JOIN", "LEFT JOIN",
      "RIGHT JOIN", "FULL JOIN", "CROSS JOIN", "INNER", "LEFT", "WHERE", "ON", "AS", "GROUP BY",
      "ORDER BY", "LIMIT", "UNION", "EXCEPT", "INTERSECT", "UPDATE", "DELETE", "WITH", "SET",
      "users", "Orders", "products", "sessions", "persons", "items", "public.users",
      "audit.users", "\"users\"", "\"my table\"", "'users'", "fromage", "leftover", "onward",
      "a", "b", "u", "o", "p", "x1", "\u{00E9}t\u{00E9}", "\u{1F600}", "stra\u{00DF}e",
      ",", ",", ".", "(", ")", "(", ")", "\"", "'", "=", "*", ";",
      " ", " ", " ", " ", "\n", "\t", "\r\n",
    ]
    var rng = SplitMix64(seed: 0xC0FFEE)
    for _ in 0..<2_000 {
      let count = Int(rng.next() % 40)
      var sql = ""
      for _ in 0..<count {
        sql += alphabet[Int(rng.next() % UInt64(alphabet.count))]
        if rng.next() % 3 != 0 { sql += " " }
      }
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
    for fullText: String, at fullCursorPosition: Int
  )
    -> [AutocompleteSuggestion]
  {
    calls += 1
    return []
  }
}

@Suite("SQLTextView autocomplete debounce", .serialized)
@MainActor
struct SQLTextViewAutocompleteDebounceTests {
  /// Large enough that scheduling delays under a loaded parallel run cannot let a second compute fire
  private static let debounce: Duration = .milliseconds(200)
  /// Negative assertions wait well over 3x the debounce
  private static let negativeWaitMs = 800

  private func makeHost() -> (OffscreenEditorHost, SpyProvider) {
    let host = OffscreenEditorHost(text: "SELECT us")
    let spy = SpyProvider()
    host.textView.autocompleteProvider = spy
    host.textView.setSelectedRange(NSRange(location: 9, length: 0))
    return (host, spy)
  }

  private func pause(_ ms: Int) async {
    try? await Task.sleep(for: .milliseconds(ms))
  }

  /// Polls until the spy has computed at least once; false after the deadline (never hangs)
  private func waitForFirstCompute(_ spy: SpyProvider, timeoutSeconds: Int = 30) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
    while spy.calls == 0 {
      if ContinuousClock.now >= deadline { return false }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return true
  }

  @Test("rapid calls within the debounce window compute once")
  func rapidCallsComputeOnce() async {
    let saved = SQLTextView.autocompleteDebounce
    SQLTextView.autocompleteDebounce = Self.debounce
    defer { SQLTextView.autocompleteDebounce = saved }
    let (host, spy) = makeHost()

    // One synchronous main-actor block: no suspension, so scheduling can never split the calls
    for _ in 0..<5 { host.textView.updateAutocompleteSuggestions() }
    #expect(spy.calls == 0)

    let computed = await waitForFirstCompute(spy)
    #expect(computed, "no autocomplete compute within 30 s (main actor starved?)")
    // A wrongly surviving earlier task would fire in the same window: give it time to show up
    await pause(Self.negativeWaitMs)
    #expect(spy.calls == 1)
  }

  @Test("hides immediately on empty text")
  func hidesImmediatelyOnEmptyText() {
    let (host, spy) = makeHost()
    host.textView.setAutocompleteSuggestions([
      AutocompleteSuggestion(text: "users", type: .table, description: nil)
    ])
    host.textView.string = ""
    host.textView.updateAutocompleteSuggestions()
    #expect(host.textView.getAutocompleteSuggestions().isEmpty)
    #expect(host.textView.autocompleteTask == nil)
    #expect(spy.calls == 0)
  }

  @Test("hideAutocomplete cancels a pending computation")
  func hideCancelsPending() async {
    let saved = SQLTextView.autocompleteDebounce
    SQLTextView.autocompleteDebounce = Self.debounce
    defer { SQLTextView.autocompleteDebounce = saved }
    let (host, spy) = makeHost()

    host.textView.updateAutocompleteSuggestions()
    host.textView.hideAutocomplete()
    await pause(Self.negativeWaitMs)
    #expect(spy.calls == 0)
  }

  @Test("programmatic edit while a debounce is pending suppresses the computation")
  func programmaticEditSuppressesPending() async {
    let saved = SQLTextView.autocompleteDebounce
    SQLTextView.autocompleteDebounce = Self.debounce
    defer { SQLTextView.autocompleteDebounce = saved }
    let (host, spy) = makeHost()

    host.textView.updateAutocompleteSuggestions()
    host.textView.setProgrammaticEditFlag(true)
    await pause(Self.negativeWaitMs)
    host.textView.setProgrammaticEditFlag(false)
    #expect(spy.calls == 0)
    #expect(host.textView.getAutocompleteSuggestions().isEmpty)
  }

  @Test("accepting a suggestion while a debounce is pending suppresses the computation")
  func acceptingSuppressesPending() async {
    let saved = SQLTextView.autocompleteDebounce
    SQLTextView.autocompleteDebounce = Self.debounce
    defer { SQLTextView.autocompleteDebounce = saved }
    let (host, spy) = makeHost()

    host.textView.updateAutocompleteSuggestions()
    host.textView.setAcceptingSuggestionFlag(true)
    await pause(Self.negativeWaitMs)
    host.textView.setAcceptingSuggestionFlag(false)
    #expect(spy.calls == 0)
  }
}
