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

/// Safe Mode levels for query protection (similar to TablePlus)
/// Higher levels provide more protection against accidental data modification
enum SafeMode: Int, Codable, CaseIterable, Sendable {
  /// No confirmations - execute all queries immediately
  case silent = 0
  /// Confirm non-SELECT queries (UPDATE/DELETE/INSERT/DROP/etc.) with a dialog
  case alertRead = 1
  /// Confirm ALL queries including SELECT with a dialog
  case alertAll = 2
  /// Require password for non-SELECT queries
  case safeRead = 3
  /// Require password for ALL queries
  case safeAll = 4

  var displayName: String {
    switch self {
    case .silent: return "Silent"
    case .alertRead: return "Alert (Read)"
    case .alertAll: return "Alert (All)"
    case .safeRead: return "Safe (Read)"
    case .safeAll: return "Safe (All)"
    }
  }

  var description: String {
    switch self {
    case .silent:
      return "No confirmations. All queries execute immediately."
    case .alertRead:
      return "Confirm data modification queries (UPDATE, DELETE, INSERT, DROP, etc.)"
    case .alertAll:
      return "Confirm all queries including SELECT"
    case .safeRead:
      return "Require password for data modification queries"
    case .safeAll:
      return "Require password for all queries"
    }
  }

  /// Short description for display in settings list
  var shortDescription: String {
    switch self {
    case .silent:
      return "Execute all queries without confirmation"
    case .alertRead:
      return "Confirm UPDATE, DELETE, INSERT, DROP"
    case .alertAll:
      return "Confirm all queries including SELECT"
    case .safeRead:
      return "Password required for modifications"
    case .safeAll:
      return "Password required for all queries"
    }
  }

  /// Short text for badge display in header (e.g., "Read" or "All")
  var badgeText: String {
    switch self {
    case .silent:
      return ""
    case .alertRead, .safeRead:
      return "Read"
    case .alertAll, .safeAll:
      return "All"
    }
  }

  /// Returns true if this mode requires confirmation for SELECT queries
  var requiresConfirmationForSelect: Bool {
    self == .alertAll || self == .safeAll
  }

  /// Returns true if this mode requires confirmation for modification queries
  var requiresConfirmationForModification: Bool {
    self != .silent
  }

  /// Returns true if this mode requires password entry (not just confirmation)
  var requiresPassword: Bool {
    self == .safeRead || self == .safeAll
  }
}

/// Accent color preference enum
enum AccentColor: String, CaseIterable {
  case purple = "Purple"
  case blue = "Blue"
  case green = "Green"
  case orange = "Orange"
  case pink = "Pink"
  case cyan = "Cyan"

  /// Light mode hex color
  var lightHex: String {
    switch self {
    case .purple: return "9333ea"
    case .blue: return "2563eb"
    case .green: return "16a34a"
    case .orange: return "ea580c"
    case .pink: return "db2777"
    case .cyan: return "0891b2"
    }
  }

  /// Dark mode hex color
  var darkHex: String {
    switch self {
    case .purple: return "a855f7"
    case .blue: return "3b82f6"
    case .green: return "22c55e"
    case .orange: return "f97316"
    case .pink: return "ec4899"
    case .cyan: return "06b6d4"
    }
  }

  /// Muted light mode hex color
  var mutedLightHex: String {
    switch self {
    case .purple: return "7e22ce"
    case .blue: return "1d4ed8"
    case .green: return "15803d"
    case .orange: return "c2410c"
    case .pink: return "be185d"
    case .cyan: return "0e7490"
    }
  }

  /// Muted dark mode hex color
  var mutedDarkHex: String {
    switch self {
    case .purple: return "7c3aed"
    case .blue: return "2563eb"
    case .green: return "16a34a"
    case .orange: return "ea580c"
    case .pink: return "db2777"
    case .cyan: return "0891b2"
    }
  }

  /// Syntax keyword light mode hex color (slightly lighter for readability)
  var syntaxLightHex: String {
    switch self {
    case .purple: return "9333ea"
    case .blue: return "2563eb"
    case .green: return "16a34a"
    case .orange: return "ea580c"
    case .pink: return "db2777"
    case .cyan: return "0891b2"
    }
  }

  /// Syntax keyword dark mode hex color (slightly lighter for readability)
  var syntaxDarkHex: String {
    switch self {
    case .purple: return "c084fc"
    case .blue: return "93c5fd"
    case .green: return "86efac"
    case .orange: return "fdba74"
    case .pink: return "f9a8d4"
    case .cyan: return "67e8f9"
    }
  }
}

/// Global app settings using UserDefaults
/// These settings apply to the entire app, not per-notebook
@MainActor
@Observable
class AppSettings {
  /// Shared singleton instance
  static let shared = AppSettings(defaults: sharedDefaults)

  /// Store of `shared`: `.standard` in the app; under XCTest an isolated suite, cleared at
  /// creation, so tests never touch the user's real settings (UserDefaults is thread-safe)
  nonisolated(unsafe) static let sharedDefaults: UserDefaults = {
    guard SessionManager.isRunningAsTestHost else { return .standard }
    let name = "ace.thi.SQLNotebook.tests"
    let suite = UserDefaults(suiteName: name) ?? UserDefaults()
    suite.removePersistentDomain(forName: name)
    return suite
  }()

  /// Backing store of every setting
  private let defaults: UserDefaults

  // MARK: - UserDefaults Keys

  private nonisolated enum Keys {
    static let maxResultHeight = "app.settings.maxResultHeight"
    static let includeResultsOnSave = "app.settings.includeResultsOnSave"
    static let isLeftSidebarVisible = "app.settings.isLeftSidebarVisible"
    static let leftSidebarWidth = "app.settings.leftSidebarWidth"
    static let themePreference = "app.settings.themePreference"
    static let bypassDestructiveQueryConfirmation =
      "app.settings.bypassDestructiveQueryConfirmation"
    static let isAutoCompleteEnabled = "app.settings.isAutoCompleteEnabled"
    static let showLineNumbers = "app.settings.showLineNumbers"
    static let wordWrapEnabled = "app.settings.wordWrapEnabled"
    static let hideRunWithQuerySection = "app.settings.hideRunWithQuerySection"
    static let editorSimpleMode = "app.settings.editorSimpleMode"
    static let syntaxHighlightingEnabled = "app.settings.syntaxHighlightingEnabled"
    static let accentColor = "app.settings.accentColor"
    static let hideColumnTypes = "app.settings.hideColumnTypes"
    static let safeMode = "app.settings.safeMode"
  }

  // MARK: - Settings Properties

  /// Maximum height for result table view (in points)
  var maxResultHeight: CGFloat = 500.0 {
    didSet {
      defaults.set(Double(maxResultHeight), forKey: Keys.maxResultHeight)
    }
  }

  /// Whether to include results when saving the notebook
  var includeResultsOnSave: Bool = true {
    didSet {
      defaults.set(includeResultsOnSave, forKey: Keys.includeResultsOnSave)
    }
  }

  /// Rows read per statement in Notebook and Editor mode (a connection's `rowCapOverride`
  /// wins, see `SettingsResolver.effectiveRowCap`). Clamped to `SessionBrakeLimits.rowCapRange`.
  var resultRowCap: Int = AppSettings.defaultResultRowCap {
    didSet {
      let clampedValue = Self.clampResultRowCap(resultRowCap)
      if clampedValue != resultRowCap {
        resultRowCap = clampedValue
        return  // Avoid triggering didSet again
      }
      defaults.set(resultRowCap, forKey: Self.resultRowCapKey)
    }
  }

  /// Whether the left sidebar (database schema) is visible
  var isLeftSidebarVisible: Bool = false {
    didSet {
      defaults.set(isLeftSidebarVisible, forKey: Keys.isLeftSidebarVisible)
    }
  }

  /// Width of the left sidebar (database schema) in points
  /// Default: 300, Min: 250, Max: 40% of window width
  var leftSidebarWidth: CGFloat = 300.0 {
    didSet {
      // Clamp between 250 and reasonable max (will be further clamped by view based on window width)
      let clampedValue = max(leftSidebarWidth, 250)
      if clampedValue != leftSidebarWidth {
        leftSidebarWidth = clampedValue
        return  // Avoid triggering didSet again
      }
      defaults.set(Double(leftSidebarWidth), forKey: Keys.leftSidebarWidth)
    }
  }

  /// Theme preference (system, light, or dark)
  var themePreference: ThemePreference = .dark {
    didSet {
      defaults.set(themePreference.rawValue, forKey: Keys.themePreference)
    }
  }

  /// Bypass the Run All confirmation dialog for cells that may modify the database
  /// (DML, DDL, DO/CALL/COPY and other utility or unrecognized statements).
  /// Cells that change the session brakes (`SET statement_timeout`, `RESET ALL`, ...) or
  /// role/privileges are ALWAYS confirmed, even when this is on.
  /// Default: false (show confirmation)
  var bypassDestructiveQueryConfirmation: Bool = false {
    didSet {
      defaults.set(
        bypassDestructiveQueryConfirmation, forKey: Keys.bypassDestructiveQueryConfirmation)
    }
  }

  /// Enable autocomplete in query editor
  /// Default: true (enabled)
  var isAutoCompleteEnabled: Bool = true {
    didSet {
      defaults.set(isAutoCompleteEnabled, forKey: Keys.isAutoCompleteEnabled)
    }
  }

  /// Show line numbers in Editor mode
  /// Default: true (shown)
  var showLineNumbers: Bool = true {
    didSet {
      defaults.set(showLineNumbers, forKey: Keys.showLineNumbers)
    }
  }

  /// Enable word wrap in Editor mode
  /// Default: true (enabled)
  var wordWrapEnabled: Bool = true {
    didSet {
      defaults.set(wordWrapEnabled, forKey: Keys.wordWrapEnabled)
    }
  }

  /// Hide "Run with query" section in Notebook mode result tables
  /// Default: false (shown)
  var hideRunWithQuerySection: Bool = false {
    didSet {
      defaults.set(hideRunWithQuerySection, forKey: Keys.hideRunWithQuerySection)
    }
  }

  /// Editor Simple Mode - controls Run behavior when no selection
  /// When OFF: Run executes the entire file (default)
  /// When ON: Run executes only the query at cursor position
  /// Default: false (off - traditional behavior)
  var editorSimpleMode: Bool = false {
    didSet {
      defaults.set(editorSimpleMode, forKey: Keys.editorSimpleMode)
    }
  }

  /// Enable syntax highlighting in SQL editors
  /// When disabled, SQL code is displayed as plain text (faster for large files)
  /// Default: true (enabled)
  var syntaxHighlightingEnabled: Bool = true {
    didSet {
      defaults.set(syntaxHighlightingEnabled, forKey: Keys.syntaxHighlightingEnabled)
      // Notify editors to re-apply highlighting
      NotificationCenter.default.post(name: .syntaxHighlightingChanged, object: nil)
    }
  }

  /// Accent color preference for the app UI
  /// Default: purple
  var accentColor: AccentColor = .purple {
    didSet {
      defaults.set(accentColor.rawValue, forKey: Keys.accentColor)
      // Notify views to update colors
      NotificationCenter.default.post(name: .accentColorChanged, object: nil)
    }
  }

  /// Hide column types in result table headers
  /// When enabled, only column names are shown (not the type like VARCHAR, INTEGER, etc.)
  /// Default: false (show column types)
  var hideColumnTypes: Bool = false {
    didSet {
      defaults.set(hideColumnTypes, forKey: Keys.hideColumnTypes)
    }
  }

  /// Safe Mode level for query protection
  /// Default: .alertRead (confirm modification queries)
  var safeMode: SafeMode = .alertRead {
    didSet {
      defaults.set(safeMode.rawValue, forKey: Keys.safeMode)
    }
  }

  // MARK: - Safe Mode Unlock (forwarded to SafeModeAuthenticator: Keychain + Touch ID)

  private var safeModeAuth: SafeModeAuthenticator { .shared }

  /// Safe Mode has an unlock configured (password or Touch ID)
  var isSafeModePasswordSet: Bool { safeModeAuth.isProtected }

  /// Safe Mode has a password (Touch ID may also be on)
  var hasCustomPasswordSet: Bool { safeModeAuth.hasPassword }

  /// Touch ID is enabled for Safe Mode (the password stays the fallback)
  var isBiometricEnabled: Bool { safeModeAuth.isBiometricEnabled }

  /// Touch ID is enrolled and usable right now (never prompts)
  var canUseTouchID: Bool { safeModeAuth.canUseBiometrics }

  /// True if `password` is the Safe Mode password (false when none is set)
  func verifySafeModePassword(_ password: String) -> Bool {
    safeModeAuth.verify(password: password)
  }

  /// Sets the Safe Mode password and switches the unlock to password (Touch ID off).
  /// False (nothing changed) if the password could not be stored.
  @discardableResult
  func setSafeModePassword(_ password: String) -> Bool {
    guard safeModeAuth.setPassword(password) else { return false }
    safeModeAuth.disableBiometrics()
    return true
  }

  /// Turns Touch ID on after a successful prompt; the password is kept as fallback
  func enableBiometricAuth() async throws {
    guard
      await safeModeAuth.enableBiometrics(
        reason: "Enable Touch ID for Safe Mode query authorization")
    else {
      throw NSError(
        domain: "SafeMode", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Touch ID is not available or was not confirmed."])
    }
  }

  /// Touch ID prompt; false means "use the password"
  func verifyBiometric() async throws -> Bool {
    await safeModeAuth.authenticate(reason: "Authorize query execution in Safe Mode")
  }

  // MARK: - Thread-safe accessors for non-MainActor contexts

  /// Get includeResultsOnSave directly from UserDefaults (thread-safe)
  nonisolated static func getIncludeResultsOnSave() -> Bool {
    // Check if key exists, otherwise use default
    if sharedDefaults.object(forKey: Keys.includeResultsOnSave) != nil {
      return sharedDefaults.bool(forKey: Keys.includeResultsOnSave)
    }
    return true  // default value
  }

  // MARK: - Initialization

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // Load from UserDefaults or use defaults
    let savedHeight = defaults.double(forKey: Keys.maxResultHeight)
    if savedHeight > 0 {
      maxResultHeight = CGFloat(savedHeight)
    }

    // Check if key exists, otherwise use default
    if defaults.object(forKey: Keys.includeResultsOnSave) != nil {
      includeResultsOnSave = defaults.bool(forKey: Keys.includeResultsOnSave)
    }

    // Also migrates the legacy per-mode row limit keys (once); skipped under XCTest
    if !SessionManager.isRunningAsTestHost, let savedRowCap = Self.loadResultRowCap(from: defaults)
    {
      resultRowCap = savedRowCap
    }

    // Load left sidebar visibility state
    if defaults.object(forKey: Keys.isLeftSidebarVisible) != nil {
      isLeftSidebarVisible = defaults.bool(forKey: Keys.isLeftSidebarVisible)
    }

    // Load left sidebar width
    let savedSidebarWidth = defaults.double(forKey: Keys.leftSidebarWidth)
    if savedSidebarWidth > 0 {
      leftSidebarWidth = max(CGFloat(savedSidebarWidth), 200)
    }

    // Load theme preference
    if let themeString = defaults.string(forKey: Keys.themePreference),
      let theme = ThemePreference(rawValue: themeString)
    {
      themePreference = theme
    }

    // Load bypass destructive query confirmation setting
    if defaults.object(forKey: Keys.bypassDestructiveQueryConfirmation) != nil {
      bypassDestructiveQueryConfirmation = defaults.bool(
        forKey: Keys.bypassDestructiveQueryConfirmation)
    }

    // Load autocomplete enabled setting
    if defaults.object(forKey: Keys.isAutoCompleteEnabled) != nil {
      isAutoCompleteEnabled = defaults.bool(forKey: Keys.isAutoCompleteEnabled)
    }

    // Load show line numbers setting
    if defaults.object(forKey: Keys.showLineNumbers) != nil {
      showLineNumbers = defaults.bool(forKey: Keys.showLineNumbers)
    }

    // Load word wrap enabled setting
    if defaults.object(forKey: Keys.wordWrapEnabled) != nil {
      wordWrapEnabled = defaults.bool(forKey: Keys.wordWrapEnabled)
    }

    // Load hide run with query section setting
    if defaults.object(forKey: Keys.hideRunWithQuerySection) != nil {
      hideRunWithQuerySection = defaults.bool(forKey: Keys.hideRunWithQuerySection)
    }

    // Load editor simple mode setting
    if defaults.object(forKey: Keys.editorSimpleMode) != nil {
      editorSimpleMode = defaults.bool(forKey: Keys.editorSimpleMode)
    }

    // Load syntax highlighting enabled setting
    if defaults.object(forKey: Keys.syntaxHighlightingEnabled) != nil {
      syntaxHighlightingEnabled = defaults.bool(forKey: Keys.syntaxHighlightingEnabled)
    }

    // Load accent color preference
    if let accentString = defaults.string(forKey: Keys.accentColor),
      let accent = AccentColor(rawValue: accentString)
    {
      accentColor = accent
    }

    // Load hide column types setting
    if defaults.object(forKey: Keys.hideColumnTypes) != nil {
      hideColumnTypes = defaults.bool(forKey: Keys.hideColumnTypes)
    }

    // Load Safe Mode setting
    let savedSafeMode = defaults.integer(forKey: Keys.safeMode)
    if defaults.object(forKey: Keys.safeMode) != nil,
      let mode = SafeMode(rawValue: savedSafeMode)
    {
      safeMode = mode
    }
    // The Safe Mode password lives in SafeModeAuthenticator (Keychain), never in UserDefaults
  }

  // MARK: - Reset to Defaults

  /// Reset all settings to their default values
  func resetToDefaults() {
    maxResultHeight = 500.0
    includeResultsOnSave = true
    resultRowCap = Self.defaultResultRowCap
    isLeftSidebarVisible = false
    leftSidebarWidth = 250.0
    themePreference = .dark
    bypassDestructiveQueryConfirmation = false
    isAutoCompleteEnabled = true
    showLineNumbers = true
    wordWrapEnabled = true
    hideRunWithQuerySection = false
    editorSimpleMode = false
    syntaxHighlightingEnabled = true
    accentColor = .purple
    hideColumnTypes = false
    safeMode = .alertRead
    // Leave no Safe Mode password material behind (incl. a not-yet-migrated legacy hash);
    // goes through the shared authenticator's store (in-memory under XCTest)
    clearSafeModePassword()
  }

  /// Clear the Safe Mode password (Keychain and legacy UserDefaults hash) and Touch ID
  func clearSafeModePassword() {
    safeModeAuth.removePassword()
  }
}
