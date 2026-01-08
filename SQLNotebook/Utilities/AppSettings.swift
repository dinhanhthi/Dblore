//
//  AppSettings.swift
//  SQLNotebook
//

import Foundation
import SwiftUI

/// Theme preference enum
enum ThemePreference: String, CaseIterable {
  case system = "System"
  case light = "Light"
  case dark = "Dark"

  var colorScheme: ColorScheme? {
    switch self {
    case .system:
      return nil
    case .light:
      return .light
    case .dark:
      return .dark
    }
  }
}

/// Global app settings using UserDefaults
/// These settings apply to the entire app, not per-notebook
@MainActor
@Observable
class AppSettings {
  /// Shared singleton instance
  static let shared = AppSettings()

  // MARK: - UserDefaults Keys

  private nonisolated enum Keys {
    static let maxResultHeight = "app.settings.maxResultHeight"
    static let includeResultsOnSave = "app.settings.includeResultsOnSave"
    static let maxRowLimit = "app.settings.maxRowLimit"
    static let isLeftSidebarVisible = "app.settings.isLeftSidebarVisible"
    static let themePreference = "app.settings.themePreference"
    static let bypassDestructiveQueryConfirmation = "app.settings.bypassDestructiveQueryConfirmation"
  }

  // MARK: - Settings Properties

  /// Maximum height for result table view (in points)
  var maxResultHeight: CGFloat = 500.0 {
    didSet {
      UserDefaults.standard.set(Double(maxResultHeight), forKey: Keys.maxResultHeight)
    }
  }

  /// Whether to include results when saving the notebook
  var includeResultsOnSave: Bool = true {
    didSet {
      UserDefaults.standard.set(includeResultsOnSave, forKey: Keys.includeResultsOnSave)
    }
  }

  /// Maximum number of rows to fetch from database (default 50, max 200)
  var maxRowLimit: Int = 50 {
    didSet {
      // Clamp between 1 and 200
      let clampedValue = min(max(maxRowLimit, 1), 200)
      if clampedValue != maxRowLimit {
        maxRowLimit = clampedValue
        return  // Avoid triggering didSet again
      }
      UserDefaults.standard.set(maxRowLimit, forKey: Keys.maxRowLimit)
    }
  }

  /// Whether the left sidebar (database schema) is visible
  var isLeftSidebarVisible: Bool = false {
    didSet {
      UserDefaults.standard.set(isLeftSidebarVisible, forKey: Keys.isLeftSidebarVisible)
    }
  }

  /// Theme preference (system, light, or dark)
  var themePreference: ThemePreference = .dark {
    didSet {
      UserDefaults.standard.set(themePreference.rawValue, forKey: Keys.themePreference)
    }
  }

  /// Bypass confirmation dialog for destructive queries (UPDATE/DELETE/INSERT)
  /// Default: false (show confirmation)
  var bypassDestructiveQueryConfirmation: Bool = false {
    didSet {
      UserDefaults.standard.set(
        bypassDestructiveQueryConfirmation, forKey: Keys.bypassDestructiveQueryConfirmation)
    }
  }

  // MARK: - Thread-safe accessors for non-MainActor contexts

  /// Get includeResultsOnSave directly from UserDefaults (thread-safe)
  nonisolated static func getIncludeResultsOnSave() -> Bool {
    // Check if key exists, otherwise use default
    if UserDefaults.standard.object(forKey: Keys.includeResultsOnSave) != nil {
      return UserDefaults.standard.bool(forKey: Keys.includeResultsOnSave)
    }
    return true  // default value
  }

  // MARK: - Initialization

  private init() {
    // Load from UserDefaults or use defaults
    let savedHeight = UserDefaults.standard.double(forKey: Keys.maxResultHeight)
    if savedHeight > 0 {
      maxResultHeight = CGFloat(savedHeight)
    }

    // Check if key exists, otherwise use default
    if UserDefaults.standard.object(forKey: Keys.includeResultsOnSave) != nil {
      includeResultsOnSave = UserDefaults.standard.bool(forKey: Keys.includeResultsOnSave)
    }

    let savedLimit = UserDefaults.standard.integer(forKey: Keys.maxRowLimit)
    if savedLimit > 0 {
      // Clamp between 1 and 200
      maxRowLimit = min(max(savedLimit, 1), 200)
    }

    // Load left sidebar visibility state
    if UserDefaults.standard.object(forKey: Keys.isLeftSidebarVisible) != nil {
      isLeftSidebarVisible = UserDefaults.standard.bool(forKey: Keys.isLeftSidebarVisible)
    }

    // Load theme preference
    if let themeString = UserDefaults.standard.string(forKey: Keys.themePreference),
      let theme = ThemePreference(rawValue: themeString)
    {
      themePreference = theme
    }

    // Load bypass destructive query confirmation setting
    if UserDefaults.standard.object(forKey: Keys.bypassDestructiveQueryConfirmation) != nil {
      bypassDestructiveQueryConfirmation = UserDefaults.standard.bool(
        forKey: Keys.bypassDestructiveQueryConfirmation)
    }
  }

  // MARK: - Reset to Defaults

  /// Reset all settings to their default values
  func resetToDefaults() {
    maxResultHeight = 500.0
    includeResultsOnSave = true
    maxRowLimit = 50
    isLeftSidebarVisible = false
    themePreference = .dark
    bypassDestructiveQueryConfirmation = false
  }
}
