// QueryInsightsAggregator.swift
// Query Insights: run statistics per statement fingerprint over a window of query history.

import Foundation

/// The runs of one fingerprint (or of one SQL text too long to fingerprint).
nonisolated struct QueryInsight: Sendable, Identifiable, Equatable {
  /// The fingerprint, or the SQL itself when `isFingerprinted` is false
  let text: String
  /// False for SQL over `QueryHistoryStore.maxSQLCharacters` (it was cut when recorded): it
  /// groups by its own text, as lexing it again for every row would be slow.
  let isFingerprinted: Bool
  let count: Int
  let averageMs: Double
  /// Nearest rank: the `ceil(0.95 * count)`th of the sorted durations
  let p95Ms: Int
  let maxMs: Int
  /// Failed runs over all runs. A cancelled run is not a failure.
  let errorRate: Double
  let lastRun: Date
  /// The newest run, for Open in Editor
  let latest: QueryHistoryEntry

  var id: String { text }
}

/// A connection with runs in the window, for the connection filter.
nonisolated struct QueryInsightsConnection: Sendable, Identifiable, Hashable {
  let key: String
  let label: String

  var id: String { key }
}

nonisolated struct QueryInsightsSummary: Sendable, Equatable {
  /// Most runs first
  var insights: [QueryInsight] = []
  /// By label
  var connections: [QueryInsightsConnection] = []
}

/// Groups history rows by `SQLFingerprint` with each row's connection dialect. Label rows
/// (dump, restore and transaction summaries) are not SQL that ran and are left out.
nonisolated enum QueryInsightsAggregator {
  /// Rows read for one window; the newest are kept
  static let maxRows = 50_000

  /// `aggregate` off the main actor: 50,000 rows must not hold up the UI
  @concurrent static func summary(of entries: [QueryHistoryEntry]) async -> QueryInsightsSummary {
    aggregate(entries)
  }

  static func aggregate(_ entries: [QueryHistoryEntry]) -> QueryInsightsSummary {
    var groups: [String: Group] = [:]
    var keys: [String: (key: String, isFingerprinted: Bool)] = [:]
    var connections: [String: String] = [:]
    for entry in entries where !entry.isLabel {
      connections[entry.connectionKey] = connections[entry.connectionKey] ?? entry.connectionLabel
      let cacheKey = entry.connectionKey + "\u{0}" + entry.sql
      let groupKey =
        keys[cacheKey]
        ?? {
          let key = Self.key(for: entry)
          keys[cacheKey] = key
          return key
        }()
      if groups[groupKey.key] == nil {
        groups[groupKey.key] = Group(isFingerprinted: groupKey.isFingerprinted, latest: entry)
      }
      groups[groupKey.key]?.add(entry)
    }
    let insights = groups.map { $0.value.insight(text: $0.key) }
      .sorted { ($0.count, $0.lastRun) > ($1.count, $1.lastRun) }
    let connectionList = connections.map { QueryInsightsConnection(key: $0.key, label: $0.value) }
      .sorted {
        let order = $0.label.localizedStandardCompare($1.label)
        return order == .orderedSame ? $0.key < $1.key : order == .orderedAscending
      }
    return QueryInsightsSummary(insights: insights, connections: connectionList)
  }

  private static func key(for entry: QueryHistoryEntry) -> (key: String, isFingerprinted: Bool) {
    guard entry.sql.count <= QueryHistoryStore.maxSQLCharacters else { return (entry.sql, false) }
    let dialect = QueryHistoryStore.dialect(for: entry.connectionKey)
    return (SQLFingerprint.fingerprint(entry.sql, dialect: dialect), true)
  }

  private struct Group {
    let isFingerprinted: Bool
    /// The group's first row until a newer one is added
    var latest: QueryHistoryEntry
    var durations: [Int] = []
    var errors = 0

    init(isFingerprinted: Bool, latest: QueryHistoryEntry) {
      self.isFingerprinted = isFingerprinted
      self.latest = latest
    }

    mutating func add(_ entry: QueryHistoryEntry) {
      durations.append(entry.durationMs)
      if entry.status == .error { errors += 1 }
      if entry.executedAt > latest.executedAt { latest = entry }
    }

    func insight(text: String) -> QueryInsight {
      let sorted = durations.sorted()
      // ceil(0.95 * count) in integers, so 0.95 being inexact in binary never moves the rank
      let rank = (95 * sorted.count + 99) / 100
      return QueryInsight(
        text: text, isFingerprinted: isFingerprinted, count: sorted.count,
        averageMs: Double(sorted.reduce(0, +)) / Double(sorted.count),
        p95Ms: sorted[max(rank, 1) - 1], maxMs: sorted[sorted.count - 1],
        errorRate: Double(errors) / Double(sorted.count), lastRun: latest.executedAt,
        latest: latest)
    }
  }
}
