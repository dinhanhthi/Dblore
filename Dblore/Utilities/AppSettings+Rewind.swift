//
//  AppSettings+Rewind.swift
//  Dblore
//
//  Data Rewind retention: allowed day choices and the prune that applies them.
//

import Foundation

extension AppSettings {
  /// Days of Data Rewind entries kept when none is stored
  nonisolated static let defaultRewindRetentionDays = 30

  /// Day choices offered for Data Rewind. No "forever": the entries hold row data.
  nonisolated static let rewindRetentionChoices = [7, 30, 90, 365]

  /// Anything outside `rewindRetentionChoices` becomes 30
  nonisolated static func clampRewindRetentionDays(_ value: Int) -> Int {
    rewindRetentionChoices.contains(value) ? value : defaultRewindRetentionDays
  }
}

/// Applies the Data Rewind retention at launch and after a change. Only an existing file is
/// opened, so this never creates the store file (Settings > Data does, through
/// `RewindStore.shared`).
enum RewindPrune {
  private static var generation = 0

  /// Reads the setting when the prune runs, so a burst of changes keeps the latest value.
  @MainActor
  static func schedule() {
    guard !SessionManager.isRunningAsTestHost else { return }
    generation += 1
    let token = generation
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(200))
      guard token == generation,
        FileManager.default.fileExists(atPath: RewindStore.defaultURL.path),
        let store = RewindStore.shared
      else { return }
      do {
        try await prune(store, retentionDays: AppSettings.shared.rewindRetentionDays)
        LocalDataNotifications.post(.dataRewind)
      } catch {
        await AppLogger.shared.error(
          "Data Rewind prune failed: \(error.localizedDescription)", category: "Rewind")
      }
    }
  }

  /// The store call blocks on SQLite, so it runs off the main actor.
  @concurrent private static func prune(_ store: RewindStore, retentionDays: Int) async throws {
    try store.prune(retentionDays: retentionDays)
  }
}
