// QueryInsightsAggregatorTests.swift
// Query Insights statistics per fingerprint over a fixed set of history rows.

import Foundation
import Testing

@testable import Dblore

@Suite("Query insights aggregator")
struct QueryInsightsAggregatorTests {
  @Test("Count, average, p95, max, error rate and last run per fingerprint")
  func statisticsOnFixedSet() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    // 20 runs of one statement shape, 1 to 20 ms; runs 5, 10, 15 and 20 failed, 3 was cancelled
    var entries = (1...20).map { run in
      Self.entry(
        sql: "SELECT * FROM t WHERE id = \(run)", at: start.addingTimeInterval(Double(run)),
        durationMs: run,
        status: run % 5 == 0 ? .error : run == 3 ? .cancelled : .success)
    }
    entries.append(Self.entry(sql: "DELETE FROM t", at: start, durationMs: 100))
    // A label row is not SQL that ran, so it is not a query
    entries.append(
      Self.entry(sql: "COMMIT (2 statements)", at: start, durationMs: 9, source: .editor))

    let insights = QueryInsightsAggregator.aggregate(entries).insights
    #expect(insights.count == 2)
    let select = try #require(insights.first { $0.text == "SELECT * FROM t WHERE id = ?" })
    #expect(select.count == 20)
    #expect(select.averageMs == 10.5)
    // Nearest rank: ceil(0.95 * 20) = 19th of the sorted durations
    #expect(select.p95Ms == 19)
    #expect(select.maxMs == 20)
    #expect(select.errorRate == 0.2)
    #expect(select.lastRun == start.addingTimeInterval(20))
    #expect(select.latest.sql == "SELECT * FROM t WHERE id = 20")
    #expect(select.isFingerprinted)

    let delete = try #require(insights.first { $0.text == "DELETE FROM t" })
    #expect(delete.count == 1)
    #expect(delete.p95Ms == 100)
    #expect(delete.errorRate == 0)
  }

  @Test("SQL over 100,000 characters groups by its own text and is flagged")
  func longSQLIsNotFingerprinted() throws {
    let long = "SELECT '" + String(repeating: "x", count: 100_001) + "'"
    let insights = QueryInsightsAggregator.aggregate([
      Self.entry(sql: long, at: Date(), durationMs: 5),
      Self.entry(sql: long + " ", at: Date(), durationMs: 5),
    ]).insights
    #expect(insights.count == 2)
    #expect(insights.allSatisfy { !$0.isFingerprinted })
    #expect(Set(insights.map(\.text)) == [long, long + " "])
  }

  private static func entry(
    sql: String, at executedAt: Date, durationMs: Int,
    status: QueryHistoryEntry.Status = .success, source: QueryHistoryEntry.Source = .cell
  ) -> QueryHistoryEntry {
    QueryHistoryEntry(
      id: 0, sql: sql, executedAt: executedAt, durationMs: durationMs, rowCount: nil,
      status: status, errorMessage: status == .error ? "failed" : nil,
      connectionKey: "PostgreSQL|localhost|5432|app|user", connectionLabel: "localhost/app",
      workspaceID: nil, workspaceName: nil, source: source)
  }
}
