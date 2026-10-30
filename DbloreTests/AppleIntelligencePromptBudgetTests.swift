// AppleIntelligencePromptBudgetTests.swift
// Unit tests for fitting a request into Apple Intelligence's context

import Foundation
import Testing

@testable import Dblore

@Suite("Apple Intelligence Prompt Budget Tests")
struct AppleIntelligencePromptBudgetTests {

  private typealias Budget = AppleIntelligencePromptBudget

  private static func tables(_ count: Int) -> [DatabaseTable] {
    (0..<count).map { index in
      DatabaseTable(
        schema: "public", name: "table_\(index)",
        columns: ["id", "name", "created_at", "owner_id"].map {
          DatabaseColumn(name: $0, type: "text")
        })
    }
  }

  private static func history(_ count: Int, chars: Int) -> [AIChatMessage] {
    (0..<count).map { index in
      AIChatMessage(
        role: index.isMultiple(of: 2) ? .user : .assistant,
        text: "message \(index) " + String(repeating: "x", count: chars))
    }
  }

  private static func fit(
    contextSize: Int, reserve: Int, tables: [DatabaseTable], history: [AIChatMessage],
    system: @escaping @Sendable (String) -> String = {
      AIPrompts.system(databaseName: "app", schema: $0, compact: true)
    },
    count: @escaping @Sendable (String) -> Int = { Budget.estimatedTokens($0) }
  ) async throws -> Budget.Fitted {
    try await Budget.fit(
      contextSize: contextSize, reserve: reserve, history: history, system: system,
      renderSchema: { Budget.renderSchema(tables: tables, foreignKeys: [], chars: $0) },
      tokenCount: { count($0) })
  }

  /// Tokens the fitted request takes, counted as the budget counted them
  private static func tokens(_ fitted: Budget.Fitted, count: (String) -> Int) -> Int {
    fitted.messages.reduce(count(fitted.system) + Budget.messageOverhead) {
      $0 + count($1.text) + Budget.messageOverhead
    }
  }

  /// The estimate, and a denser tokenizer (2 characters per token) the first schema render
  /// overshoots, so the schema is rendered again smaller
  private static let counters: [@Sendable (String) -> Int] = [
    { Budget.estimatedTokens($0) }, { ($0.count + 1) / 2 },
  ]

  @Test(
    "The assembled prompt plus the reserve never exceeds the context",
    arguments: [4_096, 8_192], [Budget.chatReserve, Budget.inlineReserve])
  func neverExceedsContext(contextSize: Int, reserve: Int) async throws {
    for count in Self.counters {
      for (tableCount, messageCount) in [(5, 1), (300, 1), (300, 20), (3_000, 20)] {
        let fitted = try await Self.fit(
          contextSize: contextSize, reserve: reserve, tables: Self.tables(tableCount),
          history: Self.history(messageCount, chars: 600), count: count)
        #expect(Self.tokens(fitted, count: count) + reserve <= contextSize)
        #expect(!fitted.schema.isEmpty)
        #expect(fitted.system.contains("public.table_0("))
      }
    }
  }

  @Test("A schema too large for any budget is cut, never sent whole")
  func largeSchemaIsCut() async throws {
    let tables = Self.tables(2_000)
    let fitted = try await Self.fit(
      contextSize: 8_192, reserve: Budget.chatReserve, tables: tables,
      history: Self.history(1, chars: 50))
    #expect(fitted.schema.contains("more tables"))
    #expect(fitted.schema.contains("public.table_0("))
    #expect(!fitted.schema.contains("public.\(tables[tables.count - 1].name)("))
  }

  @Test("The prompt keeps the whole schema render: no cut mid-table, the more-tables line kept")
  func schemaNeverCutByPrompt() async throws {
    let tables = Self.tables(2_000)
    #expect(
      AISchemaContext.render(tables: tables, foreignKeys: [], budgetChars: Budget.maxSchemaChars)
        .count <= AIPrompts.maxInputChars)
    let systems: [@Sendable (String) -> String] = [
      { AIPrompts.system(databaseName: "app", schema: $0, compact: true) },
      {
        AIPrompts.mongoAssistSystem(
          .filter, databaseName: "app", collection: "table_0", schema: $0, current: "")
      },
    ]
    for system in systems {
      let fitted = try await Self.fit(
        contextSize: 8_192, reserve: Budget.chatReserve, tables: tables,
        history: Self.history(1, chars: 50), system: system)
      #expect(!fitted.system.contains("-- [truncated]"))
      #expect(fitted.schema.hasSuffix("more tables"))
      #expect(fitted.system.contains(fitted.schema))
      // Every line before the note is a whole table
      #expect(fitted.schema.split(separator: "\n").dropLast().allSatisfy { $0.hasSuffix(")") })
    }
  }

  @Test("History is trimmed oldest first and starts with a user message")
  func historyTrimmedOldestFirst() async throws {
    let history = Self.history(21, chars: 900)
    let fitted = try await Self.fit(
      contextSize: 4_096, reserve: Budget.chatReserve, tables: Self.tables(5), history: history)
    #expect(fitted.messages.count < history.count)
    #expect(fitted.messages.last == history.last)
    #expect(fitted.messages == Array(history.suffix(fitted.messages.count)))
    #expect(fitted.messages.first?.role == .user)
  }

  @Test("A system prompt or newest message past the context is refused")
  func tooLongIsRefused() async {
    let longSystem = String(repeating: "rule ", count: 4_000)
    await #expect(throws: Budget.BudgetError.tooLong) {
      _ = try await Self.fit(
        contextSize: 4_096, reserve: Budget.chatReserve, tables: Self.tables(5),
        history: Self.history(1, chars: 10), system: { longSystem + $0 })
    }
    await #expect(throws: Budget.BudgetError.tooLong) {
      _ = try await Self.fit(
        contextSize: 4_096, reserve: Budget.chatReserve, tables: Self.tables(5),
        history: Self.history(1, chars: 20_000))
    }
  }
}
