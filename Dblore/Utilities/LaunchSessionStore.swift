//
//  LaunchSessionStore.swift
//  Dblore
//

import Foundation

/// Reads and writes the launch snapshot. Passwords are never stored.
struct LaunchSessionStore {
  static let key = "ace.thi.dblore.launchSession"

  private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  /// Encodes `session` after clearing every embedded connection password.
  func save(_ session: LaunchSession) {
    let stored = session.clearingPasswords()
    guard let data = try? JSONEncoder().encode(stored) else { return }
    defaults.set(data, forKey: Self.key)
  }

  /// Removes the saved snapshot.
  func clear() {
    defaults.removeObject(forKey: Self.key)
  }

  /// The saved snapshot, or nil when the key is missing or the data is corrupt.
  func load() -> LaunchSession? {
    guard let data = defaults.data(forKey: Self.key) else { return nil }
    return try? JSONDecoder().decode(LaunchSession.self, from: data)
  }
}
