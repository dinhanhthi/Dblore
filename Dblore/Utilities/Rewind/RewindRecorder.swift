// RewindRecorder.swift
// Writes Data Rewind entries off the connection actor, one at a time in call order, and keeps
// which pending entries still wait for their transaction to end.

import Foundation

/// Store writes run on one serial queue, so the connection actor never waits on SQLite and a
/// lifecycle change always finds the entries recorded before it. A failed write is logged and
/// never reaches the edit. Pending entries are "open" per scope (one connection manager) until
/// `close(scope:as:)`; any other pending entry is unconfirmed (see `openEntryIDs`).
nonisolated final class RewindRecorder: @unchecked Sendable {
  /// The recorder of `RewindStore.shared`, nil when that store cannot be opened
  static let shared: RewindRecorder? = RewindStore.shared.map { RewindRecorder(store: $0) }

  let store: RewindStore
  private let queue = DispatchQueue(label: "ace.thi.dblore.rewind", qos: .utility)
  /// Pending entry ids by scope, waiting for COMMIT or ROLLBACK. Touched on `queue` only.
  private var open: [UUID: [Int64]] = [:]

  init(store: RewindStore) {
    self.store = store
  }

  /// Writes the entry. A pending entry with a `scope` stays open until that scope closes.
  func record(_ entry: RewindEntry, rows: [RewindRow], scope: UUID?) {
    queue.async { [self] in
      do {
        let id = try PerfSignpost.interval("rewind.record") {
          try store.record(entry, rows: rows)
        }
        if entry.state == .pending, let scope {
          open[scope, default: []].append(id)
        }
      } catch {
        Self.log("Data Rewind entry not recorded", error)
      }
    }
  }

  /// The transaction of `scope` ended: its open entries become `state` (committed or
  /// discarded). Nil leaves them pending, unconfirmed (the connection went during Commit).
  func close(scope: UUID, as state: RewindEntry.State?) {
    queue.async { [self] in
      guard let ids = open.removeValue(forKey: scope), let state else { return }
      do {
        try store.setState(state, ids: ids)
      } catch {
        Self.log("Data Rewind entries not marked \(state.rawValue)", error)
      }
    }
  }

  /// Pending entries whose transaction is still open in this run, after every write queued
  /// before. Any other pending entry is unconfirmed: recorded before a quit or crash, or its
  /// connection went during Commit; the rewind's conflict check decides.
  func openEntryIDs() async -> Set<Int64> {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        continuation.resume(returning: Set(open.values.joined()))
      }
    }
  }

  /// Returns once every write queued before is in the store (read the store after it).
  func flushed() async {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume() }
    }
  }

  private static func log(_ message: String, _ error: Error) {
    let text = "\(message): \(error.localizedDescription)"
    Task { await AppLogger.shared.error(text, category: "Rewind") }
  }
}
