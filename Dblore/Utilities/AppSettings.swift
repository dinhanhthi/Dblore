//
//  AppSettings.swift
//  Dblore
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

  /// Light/dark-only toggle: the opposite of the scheme currently on screen
  static func toggled(from displayed: ColorScheme) -> ThemePreference {
    displayed == .dark ? .light : .dark
  }
}

/// Type of tab created by default by the new tab action
enum NewTabType: String, CaseIterable {
  case notebook
  case sqlFile

  var title: String {
    switch self {
    case .notebook: return "Notebook"
    case .sqlFile: return "SQL File"
    }
  }
}

/// What Dblore opens when it starts
enum LaunchBehavior: String, CaseIterable {
  case welcome
  case restoreLastSession

  var title: String {
    switch self {
    case .welcome: return "Show Welcome screen"
    case .restoreLastSession: return "Restore last sessions"
    }
  }
}

/// Where the AI assistant panel opens
enum AIPanelMode: String, CaseIterable {
  case sidebar
  case bubble

  var title: String {
    switch self {
    case .sidebar: return "Right sidebar"
    case .bubble: return "Bubble"
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

/// Why Touch ID could not be enabled for Safe Mode
enum SafeModeBiometricError: LocalizedError, Equatable {
  /// Touch ID needs a Safe Mode password as its fallback
  case passwordRequired

  var errorDescription: String? {
    switch self {
    case .passwordRequired:
      return "Set a Safe Mode password before enabling Touch ID."
    }
  }
}

/// Accent color preference enum
enum AccentColor: String, CaseIterable {
  case blue = "Blue"
  case purple = "Purple"
  case green = "Green"
  case orange = "Orange"
  case pink = "Pink"
  case cyan = "Cyan"
  case gray = "Gray"

  /// Light mode hex color
  var lightHex: String {
    switch self {
    case .purple: return "9333ea"
    case .blue: return "2563eb"
    case .green: return "16a34a"
    case .orange: return "ea580c"
    case .pink: return "db2777"
    case .cyan: return "0891b2"
    case .gray: return "71717a"
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
    case .gray: return "71717a"
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
    case .gray: return "52525b"
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
    case .gray: return "52525b"
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
    case .gray: return "18181b"
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
    case .gray: return "fafafa"
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
    let name = "ace.thi.Dblore.tests"
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
    static let openWindowsAsTabs = "app.settings.openWindowsAsTabs"
    static let defaultNewTabType = "app.settings.defaultNewTabType"
    static let launchBehavior = "app.settings.launchBehavior"
    static let aiPanelOpenMode = "app.settings.aiPanelOpenMode"
    static let aiBubblePosition = "app.settings.aiBubblePosition"
    static let editorSideBySideDefault = "app.settings.editorSideBySideDefault"
    static let hideRunWithQuerySection = "app.settings.hideRunWithQuerySection"
    static let editorSimpleMode = "app.settings.editorSimpleMode"
    static let syntaxHighlightingEnabled = "app.settings.syntaxHighlightingEnabled"
    static let accentColor = "app.settings.accentColor"
    static let hideColumnTypes = "app.settings.hideColumnTypes"
    static let safeMode = "app.settings.safeMode"
    static let commitStyle = "app.settings.commitStyle"
    static let historyEnabled = "app.settings.historyEnabled"
    static let historyRetentionDays = "app.settings.historyRetentionDays"
    static let historyMaxEntries = "app.settings.historyMaxEntries"
    static let showExperimentalEngines = "app.settings.showExperimentalEngines"
    static let resultFontSize = "app.settings.resultFontSize"
    static let editorFontSize = "app.settings.editorFontSize"
  }

  /// Result cell text. Matches the previous grid face (`NSFont.smallSystemFontSize`, 11pt).
  static let defaultResultFontSize: CGFloat = NSFont.smallSystemFontSize
  /// SQL editor text. Default monospaced face.
  static let defaultEditorFontSize: CGFloat = 12
  /// Inclusive pt range for both font sliders.
  static let fontSizeRange: ClosedRange<Double> = 9...24

  /// Whole points inside `fontSizeRange`.
  static func clampFontSize(_ size: CGFloat) -> CGFloat {
    let rounded = size.rounded()
    return CGFloat(min(max(Double(rounded), fontSizeRange.lowerBound), fontSizeRange.upperBound))
  }

  /// Gutter digits sit one point under the editor face, and never below 9. At the default
  /// 12pt editor this is 11pt. At 13pt it stays 12pt, which is what the gutter used before
  /// the setting existed.
  static func editorGutterFontSize(for editorSize: CGFloat) -> CGFloat {
    max(9, editorSize - 1)
  }

  /// Row-number digits sit one point under the result face, and never below 9. At the default
  /// result size this stays 10pt.
  static func resultRowNumberFontSize(for resultSize: CGFloat) -> CGFloat {
    max(9, resultSize - 1)
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

  /// Global timeouts (seconds) for connections without their own override; read when a
  /// connection opens. Clamped to the `SessionBrakeLimits` ranges.
  var statementTimeout: Int = SessionBrakeLimits.defaultStatementTimeout {
    didSet {
      let clamped = SessionBrakeLimits.clampStatementTimeout(statementTimeout)
      if clamped != statementTimeout {
        statementTimeout = clamped
        return
      }
      defaults.set(statementTimeout, forKey: Self.statementTimeoutKey)
    }
  }

  var lockTimeout: Int = SessionBrakeLimits.defaultLockTimeout {
    didSet {
      let clamped = SessionBrakeLimits.clampLockTimeout(lockTimeout)
      if clamped != lockTimeout {
        lockTimeout = clamped
        return
      }
      defaults.set(lockTimeout, forKey: Self.lockTimeoutKey)
    }
  }

  var idleTimeout: Int = SessionBrakeLimits.defaultIdleTimeout {
    didSet {
      let clamped = SessionBrakeLimits.clampIdleTimeout(idleTimeout)
      if clamped != idleTimeout {
        idleTimeout = clamped
        return
      }
      defaults.set(idleTimeout, forKey: Self.idleTimeoutKey)
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

  /// Layout a newly opened .sql file starts with: editor left / result right (true) or
  /// editor top / result bottom (false)
  /// Default: false (top/bottom)
  var editorSideBySideDefault: Bool = false {
    didSet {
      defaults.set(editorSideBySideDefault, forKey: Keys.editorSideBySideDefault)
    }
  }

  /// Enable word wrap in Editor mode
  /// Default: true (enabled)
  var wordWrapEnabled: Bool = true {
    didSet {
      defaults.set(wordWrapEnabled, forKey: Keys.wordWrapEnabled)
    }
  }

  /// Open new windows as tabs of the current window (native macOS window tabs)
  /// Default: false
  var openWindowsAsTabs: Bool = false {
    didSet {
      defaults.set(openWindowsAsTabs, forKey: Keys.openWindowsAsTabs)
    }
  }

  /// Type of tab created by the new tab action
  /// Default: notebook
  var defaultNewTabType: NewTabType = .notebook {
    didSet {
      defaults.set(defaultNewTabType.rawValue, forKey: Keys.defaultNewTabType)
    }
  }

  /// What opens when Dblore starts. Welcome removes the saved launch snapshot.
  /// Default: welcome
  var launchBehavior: LaunchBehavior = .welcome {
    didSet {
      defaults.set(launchBehavior.rawValue, forKey: Keys.launchBehavior)
      if launchBehavior == .welcome {
        LaunchSessionStore(defaults: defaults).clear()
      }
    }
  }

  /// Where the AI assistant panel opens
  /// Default: sidebar
  var aiPanelOpenMode: AIPanelMode = .sidebar {
    didSet {
      defaults.set(aiPanelOpenMode.rawValue, forKey: Keys.aiPanelOpenMode)
    }
  }

  /// Horizontal position of the AI bubble along the bottom edge (0 = left, 1 = right)
  /// Default: 1, clamped to 0...1
  var aiBubblePosition: Double = 1.0 {
    didSet {
      let clampedValue = min(max(aiBubblePosition, 0), 1)
      if clampedValue != aiBubblePosition {
        aiBubblePosition = clampedValue
        return  // Avoid triggering didSet again
      }
      defaults.set(aiBubblePosition, forKey: Keys.aiBubblePosition)
    }
  }

  /// Monospaced size of SQL editors (Editor mode and notebook cells), in points.
  /// Default: 12
  var editorFontSize: CGFloat = defaultEditorFontSize {
    didSet {
      let clamped = Self.clampFontSize(editorFontSize)
      if clamped != editorFontSize {
        editorFontSize = clamped
        return
      }
      defaults.set(Double(editorFontSize), forKey: Keys.editorFontSize)
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

  /// Enable syntax highlighting in editors
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
  /// Default: blue
  var accentColor: AccentColor = .blue {
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

  /// Monospaced size of result-table cell text, in points.
  /// Default: `NSFont.smallSystemFontSize` (11pt), the size the grid used before this setting.
  var resultFontSize: CGFloat = defaultResultFontSize {
    didSet {
      let clamped = Self.clampFontSize(resultFontSize)
      if clamped != resultFontSize {
        resultFontSize = clamped
        return
      }
      defaults.set(Double(resultFontSize), forKey: Keys.resultFontSize)
    }
  }

  /// Safe Mode level for query protection
  /// Default: .alertRead (confirm modification queries)
  var safeMode: SafeMode = .alertRead {
    didSet {
      defaults.set(safeMode.rawValue, forKey: Keys.safeMode)
    }
  }

  /// True until `init` has loaded `commitStyle`. `@Observable` runs `didSet` for that
  /// assignment, so the observer must not persist until load has finished.
  @ObservationIgnored
  private var isLoadingCommitStyle = true

  /// How a connection confirms a write, unless that connection stores its own style.
  /// Load reads a known `app.settings.commitStyle` string, or migrates from Safe Mode
  /// (`CommitStyle.migrateGlobal`), and writes neither key. A later assignment writes the
  /// raw string and copies `legacyProjection.safeMode` into Safe Mode.
  /// Default: .review (neither key stored)
  var commitStyle: CommitStyle = .review {
    didSet {
      guard !isLoadingCommitStyle else { return }
      defaults.set(commitStyle.rawValue, forKey: Keys.commitStyle)
      safeMode = commitStyle.legacyProjection.safeMode
    }
  }

  /// Record executed statements in query history.
  /// Default: true
  var historyEnabled: Bool = true {
    didSet {
      defaults.set(historyEnabled, forKey: Keys.historyEnabled)
    }
  }

  /// Days of query history to keep. `0` keeps history forever.
  /// Allowed: 7, 30, 90, 365, and 0. Any other value becomes 90.
  /// Default: 90
  var historyRetentionDays: Int = AppSettings.defaultHistoryRetentionDays {
    didSet {
      let clampedValue = Self.clampHistoryRetentionDays(historyRetentionDays)
      if clampedValue != historyRetentionDays {
        historyRetentionDays = clampedValue
        return  // Avoid triggering didSet again
      }
      defaults.set(historyRetentionDays, forKey: Keys.historyRetentionDays)
      QueryHistoryPrune.schedule()
    }
  }

  /// Show database engines with `isAvailable == false` in the connection type picker.
  /// Default: false (the picker stays hidden while only PostgreSQL is available)
  var showExperimentalEngines: Bool = false {
    didSet {
      defaults.set(showExperimentalEngines, forKey: Keys.showExperimentalEngines)
    }
  }

  /// Maximum query-history rows, clamped to 1,000...500,000.
  /// Default: 50,000
  var historyMaxEntries: Int = AppSettings.defaultHistoryMaxEntries {
    didSet {
      let clampedValue = Self.clampHistoryMaxEntries(historyMaxEntries)
      if clampedValue != historyMaxEntries {
        historyMaxEntries = clampedValue
        return  // Avoid triggering didSet again
      }
      defaults.set(historyMaxEntries, forKey: Keys.historyMaxEntries)
      QueryHistoryPrune.schedule()
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

  /// Turns Touch ID on after a successful prompt; the password is kept as fallback.
  /// Throws `SafeModeBiometricError.passwordRequired` (no prompt) without a Safe Mode password,
  /// so Touch ID never becomes the only unlock. Existing Touch-ID-only setups keep working.
  func enableBiometricAuth() async throws {
    guard hasCustomPasswordSet else { throw SafeModeBiometricError.passwordRequired }
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

  /// Known `app.settings.commitStyle` raw value, otherwise `CommitStyle.migrateGlobal`.
  /// Reads only; the caller must not persist the result during load.
  private static func loadedCommitStyle(from defaults: UserDefaults) -> CommitStyle {
    if let raw = defaults.string(forKey: Keys.commitStyle),
      let style = CommitStyle(rawValue: raw)
    {
      return style
    }
    let keyPresent = defaults.object(forKey: Keys.safeMode) != nil
    let stored = keyPresent ? SafeMode(rawValue: defaults.integer(forKey: Keys.safeMode)) : nil
    return CommitStyle.migrateGlobal(stored: stored, keyPresent: keyPresent)
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

    if !SessionManager.isRunningAsTestHost {
      loadSessionBrakeDefaults(from: defaults)
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

    // Load default editor layout setting
    if defaults.object(forKey: Keys.editorSideBySideDefault) != nil {
      editorSideBySideDefault = defaults.bool(forKey: Keys.editorSideBySideDefault)
    }

    // Load word wrap enabled setting
    if defaults.object(forKey: Keys.wordWrapEnabled) != nil {
      wordWrapEnabled = defaults.bool(forKey: Keys.wordWrapEnabled)
    }

    if defaults.object(forKey: Keys.openWindowsAsTabs) != nil {
      openWindowsAsTabs = defaults.bool(forKey: Keys.openWindowsAsTabs)
    }

    if let raw = defaults.string(forKey: Keys.defaultNewTabType),
      let type = NewTabType(rawValue: raw)
    {
      defaultNewTabType = type
    }

    if let raw = defaults.string(forKey: Keys.launchBehavior),
      let behavior = LaunchBehavior(rawValue: raw)
    {
      launchBehavior = behavior
    }

    if let raw = defaults.string(forKey: Keys.aiPanelOpenMode),
      let mode = AIPanelMode(rawValue: raw)
    {
      aiPanelOpenMode = mode
    }

    if defaults.object(forKey: Keys.aiBubblePosition) != nil {
      aiBubblePosition = min(max(defaults.double(forKey: Keys.aiBubblePosition), 0), 1)
    }

    if defaults.object(forKey: Keys.editorFontSize) != nil {
      let stored = CGFloat(defaults.double(forKey: Keys.editorFontSize))
      let clamped = Self.clampFontSize(stored)
      if clamped != stored {
        defaults.set(Double(clamped), forKey: Keys.editorFontSize)
      }
      editorFontSize = clamped
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

    if defaults.object(forKey: Keys.resultFontSize) != nil {
      let stored = CGFloat(defaults.double(forKey: Keys.resultFontSize))
      let clamped = Self.clampFontSize(stored)
      if clamped != stored {
        defaults.set(Double(clamped), forKey: Keys.resultFontSize)
      }
      resultFontSize = clamped
    }

    if defaults.object(forKey: Keys.historyEnabled) != nil {
      historyEnabled = defaults.bool(forKey: Keys.historyEnabled)
    }

    if defaults.object(forKey: Keys.historyRetentionDays) != nil {
      let stored = defaults.integer(forKey: Keys.historyRetentionDays)
      let clamped = Self.clampHistoryRetentionDays(stored)
      if clamped != stored {
        defaults.set(clamped, forKey: Keys.historyRetentionDays)
      }
      historyRetentionDays = clamped
    }

    if defaults.object(forKey: Keys.showExperimentalEngines) != nil {
      showExperimentalEngines = defaults.bool(forKey: Keys.showExperimentalEngines)
    }

    if defaults.object(forKey: Keys.historyMaxEntries) != nil {
      let stored = defaults.integer(forKey: Keys.historyMaxEntries)
      let clamped = Self.clampHistoryMaxEntries(stored)
      if clamped != stored {
        defaults.set(clamped, forKey: Keys.historyMaxEntries)
      }
      historyMaxEntries = clamped
    }

    // Load Safe Mode setting
    let savedSafeMode = defaults.integer(forKey: Keys.safeMode)
    if defaults.object(forKey: Keys.safeMode) != nil,
      let mode = SafeMode(rawValue: savedSafeMode)
    {
      safeMode = mode
    }
    // The Safe Mode password lives in SafeModeAuthenticator (Keychain), never in UserDefaults

    // `@Observable` runs didSet here. The load flag keeps both keys unchanged.
    commitStyle = Self.loadedCommitStyle(from: defaults)
    isLoadingCommitStyle = false
  }

  // MARK: - Reset to Defaults

  /// Reset all settings to their default values
  func resetToDefaults() {
    maxResultHeight = 500.0
    includeResultsOnSave = true
    resultRowCap = Self.defaultResultRowCap
    statementTimeout = SessionBrakeLimits.defaultStatementTimeout
    lockTimeout = SessionBrakeLimits.defaultLockTimeout
    idleTimeout = SessionBrakeLimits.defaultIdleTimeout
    isLeftSidebarVisible = false
    leftSidebarWidth = 250.0
    themePreference = .dark
    bypassDestructiveQueryConfirmation = false
    isAutoCompleteEnabled = true
    showLineNumbers = true
    wordWrapEnabled = true
    openWindowsAsTabs = false
    defaultNewTabType = .notebook
    launchBehavior = .welcome
    // Same-value assignment may not run didSet, so remove the snapshot here too.
    LaunchSessionStore(defaults: defaults).clear()
    aiPanelOpenMode = .sidebar
    aiBubblePosition = 1.0
    editorFontSize = Self.defaultEditorFontSize
    editorSideBySideDefault = false
    hideRunWithQuerySection = false
    editorSimpleMode = false
    syntaxHighlightingEnabled = true
    accentColor = .blue
    hideColumnTypes = false
    resultFontSize = Self.defaultResultFontSize
    // Same-value assignment does not run didSet, so write the review projection first.
    defaults.set(CommitStyle.review.rawValue, forKey: Keys.commitStyle)
    safeMode = CommitStyle.review.legacyProjection.safeMode
    commitStyle = .review
    historyEnabled = true
    historyRetentionDays = Self.defaultHistoryRetentionDays
    historyMaxEntries = Self.defaultHistoryMaxEntries
    showExperimentalEngines = false
    // Leave no Safe Mode password material behind (incl. a not-yet-migrated legacy hash);
    // goes through the shared authenticator's store (in-memory under XCTest)
    clearSafeModePassword()
  }

  /// Clear the Safe Mode password (Keychain and legacy UserDefaults hash) and Touch ID
  func clearSafeModePassword() {
    safeModeAuth.removePassword()
  }
}
