//
//  AppSettings.swift
//  SQLNotebook
//

import CommonCrypto
import Foundation
import LocalAuthentication
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
  static let shared = AppSettings()

  // MARK: - UserDefaults Keys

  private nonisolated enum Keys {
    static let maxResultHeight = "app.settings.maxResultHeight"
    static let includeResultsOnSave = "app.settings.includeResultsOnSave"
    static let maxRowLimit = "app.settings.maxRowLimit"
    static let editorMaxRowLimit = "app.settings.editorMaxRowLimit"
    static let isLeftSidebarVisible = "app.settings.isLeftSidebarVisible"
    static let leftSidebarWidth = "app.settings.leftSidebarWidth"
    static let themePreference = "app.settings.themePreference"
    static let bypassDestructiveQueryConfirmation =
      "app.settings.bypassDestructiveQueryConfirmation"
    static let isAutoCompleteEnabled = "app.settings.isAutoCompleteEnabled"
    static let showLineNumbers = "app.settings.showLineNumbers"
    static let maxConnectionHistorySize = "app.settings.maxConnectionHistorySize"
    static let wordWrapEnabled = "app.settings.wordWrapEnabled"
    static let hideRunWithQuerySection = "app.settings.hideRunWithQuerySection"
    static let editorSimpleMode = "app.settings.editorSimpleMode"
    static let syntaxHighlightingEnabled = "app.settings.syntaxHighlightingEnabled"
    static let accentColor = "app.settings.accentColor"
    static let hideColumnTypes = "app.settings.hideColumnTypes"
    static let safeMode = "app.settings.safeMode"
    static let safeModePassword = "app.settings.safeModePassword"
    static let safeModeBiometricEnabled = "app.settings.safeModeBiometricEnabled"
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

  /// Maximum number of rows to fetch from database in Notebook mode (default 50, range 50-100)
  var maxRowLimit: Int = 50 {
    didSet {
      // Clamp between 50 and 100
      let clampedValue = min(max(maxRowLimit, 50), 100)
      if clampedValue != maxRowLimit {
        maxRowLimit = clampedValue
        return  // Avoid triggering didSet again
      }
      UserDefaults.standard.set(maxRowLimit, forKey: Keys.maxRowLimit)
    }
  }

  /// Maximum number of rows to fetch from database in Editor mode (default 100, range 100-200)
  var editorMaxRowLimit: Int = 100 {
    didSet {
      // Clamp between 100 and 200
      let clampedValue = min(max(editorMaxRowLimit, 100), 200)
      if clampedValue != editorMaxRowLimit {
        editorMaxRowLimit = clampedValue
        return  // Avoid triggering didSet again
      }
      UserDefaults.standard.set(editorMaxRowLimit, forKey: Keys.editorMaxRowLimit)
    }
  }

  /// Whether the left sidebar (database schema) is visible
  var isLeftSidebarVisible: Bool = false {
    didSet {
      UserDefaults.standard.set(isLeftSidebarVisible, forKey: Keys.isLeftSidebarVisible)
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
      UserDefaults.standard.set(Double(leftSidebarWidth), forKey: Keys.leftSidebarWidth)
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

  /// Enable autocomplete in query editor
  /// Default: true (enabled)
  var isAutoCompleteEnabled: Bool = true {
    didSet {
      UserDefaults.standard.set(isAutoCompleteEnabled, forKey: Keys.isAutoCompleteEnabled)
    }
  }

  /// Show line numbers in Editor mode
  /// Default: true (shown)
  var showLineNumbers: Bool = true {
    didSet {
      UserDefaults.standard.set(showLineNumbers, forKey: Keys.showLineNumbers)
    }
  }

  /// Maximum number of connection history entries to store (0-5)
  /// 0 = disabled (no history saved), 5 = maximum
  /// Default: 5
  var maxConnectionHistorySize: Int = 5 {
    didSet {
      // Clamp value between 0 and 5
      let clampedValue = min(max(maxConnectionHistorySize, 0), 5)
      if clampedValue != maxConnectionHistorySize {
        maxConnectionHistorySize = clampedValue
        return  // Avoid triggering didSet again
      }
      UserDefaults.standard.set(maxConnectionHistorySize, forKey: Keys.maxConnectionHistorySize)

      // If size decreased, trim history immediately
      Task {
        await MainActor.run {
          SessionManager.trimHistoryToSize(clampedValue)
        }
      }
    }
  }

  /// Enable word wrap in Editor mode
  /// Default: true (enabled)
  var wordWrapEnabled: Bool = true {
    didSet {
      UserDefaults.standard.set(wordWrapEnabled, forKey: Keys.wordWrapEnabled)
    }
  }

  /// Hide "Run with query" section in Notebook mode result tables
  /// Default: false (shown)
  var hideRunWithQuerySection: Bool = false {
    didSet {
      UserDefaults.standard.set(hideRunWithQuerySection, forKey: Keys.hideRunWithQuerySection)
    }
  }

  /// Editor Simple Mode - controls Run behavior when no selection
  /// When OFF: Run executes the entire file (default)
  /// When ON: Run executes only the query at cursor position
  /// Default: false (off - traditional behavior)
  var editorSimpleMode: Bool = false {
    didSet {
      UserDefaults.standard.set(editorSimpleMode, forKey: Keys.editorSimpleMode)
    }
  }

  /// Enable syntax highlighting in SQL editors
  /// When disabled, SQL code is displayed as plain text (faster for large files)
  /// Default: true (enabled)
  var syntaxHighlightingEnabled: Bool = true {
    didSet {
      UserDefaults.standard.set(syntaxHighlightingEnabled, forKey: Keys.syntaxHighlightingEnabled)
      // Notify editors to re-apply highlighting
      NotificationCenter.default.post(name: .syntaxHighlightingChanged, object: nil)
    }
  }

  /// Accent color preference for the app UI
  /// Default: purple
  var accentColor: AccentColor = .purple {
    didSet {
      UserDefaults.standard.set(accentColor.rawValue, forKey: Keys.accentColor)
      // Notify views to update colors
      NotificationCenter.default.post(name: .accentColorChanged, object: nil)
    }
  }

  /// Hide column types in result table headers
  /// When enabled, only column names are shown (not the type like VARCHAR, INTEGER, etc.)
  /// Default: false (show column types)
  var hideColumnTypes: Bool = false {
    didSet {
      UserDefaults.standard.set(hideColumnTypes, forKey: Keys.hideColumnTypes)
    }
  }

  /// Safe Mode level for query protection
  /// Default: .alertRead (confirm modification queries)
  var safeMode: SafeMode = .alertRead {
    didSet {
      UserDefaults.standard.set(safeMode.rawValue, forKey: Keys.safeMode)
    }
  }

  /// Password for Safe Mode (used in safeRead and safeAll levels)
  /// Stored in UserDefaults as simple hash (not production-secure, but sufficient for local app)
  /// Default: empty string (no password set)
  var safeModePassword: String = "" {
    didSet {
      // Store hashed password (SHA256)
      let hashedPassword = safeModePassword.isEmpty ? "" : hashPassword(safeModePassword)
      UserDefaults.standard.set(hashedPassword, forKey: Keys.safeModePassword)
    }
  }

  /// Check if Safe Mode password is set (password or biometric)
  var isSafeModePasswordSet: Bool {
    let hasPassword =
      !(UserDefaults.standard.string(forKey: Keys.safeModePassword) ?? "").isEmpty
    let hasBiometric = UserDefaults.standard.bool(forKey: Keys.safeModeBiometricEnabled)
    return hasPassword || hasBiometric
  }

  /// Check if Safe Mode has a custom password set (not biometric)
  var hasCustomPasswordSet: Bool {
    !(UserDefaults.standard.string(forKey: Keys.safeModePassword) ?? "").isEmpty
  }

  /// Verify Safe Mode password
  /// Returns true if password matches stored hash
  func verifySafeModePassword(_ password: String) -> Bool {
    let storedHash = UserDefaults.standard.string(forKey: Keys.safeModePassword) ?? ""
    if storedHash.isEmpty {
      return true  // No password set, allow access
    }
    return hashPassword(password) == storedHash
  }

  /// Hash password using SHA256
  private func hashPassword(_ password: String) -> String {
    guard let data = password.data(using: .utf8) else { return "" }
    let hash = data.withUnsafeBytes { bytes -> [UInt8] in
      var hash = [UInt8](repeating: 0, count: 32)
      CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
      return hash
    }
    return hash.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Biometric Authentication

  /// Observable property for biometric enabled state
  /// This property triggers SwiftUI refresh when biometric state changes
  private(set) var biometricEnabledState: Bool = false

  /// Check if biometric authentication is enabled for Safe Mode
  var isBiometricEnabled: Bool {
    biometricEnabledState
  }

  /// Check if Safe Mode has any protection (password or biometric)
  var isSafeModeProtected: Bool {
    isSafeModePasswordSet || isBiometricEnabled
  }

  /// Enable biometric/system authentication for Safe Mode
  /// Uses deviceOwnerAuthentication which supports Touch ID, Face ID, or macOS password
  func enableBiometricAuth() async throws {
    let context = LAContext()
    var error: NSError?

    // Check if device owner authentication is available (Touch ID, Face ID, or password)
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      throw error
        ?? NSError(
          domain: "SafeMode", code: -1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "System authentication is not available. Please set up Touch ID or a system password."
          ])
    }

    // Authenticate using Touch ID, Face ID, or macOS password
    let success = try await context.evaluatePolicy(
      .deviceOwnerAuthentication,
      localizedReason: "Enable system authentication for Safe Mode query authorization")

    if success {
      await MainActor.run {
        // Clear any existing password and enable biometric/system auth
        UserDefaults.standard.removeObject(forKey: Keys.safeModePassword)
        UserDefaults.standard.set(true, forKey: Keys.safeModeBiometricEnabled)
        // Update observable property to trigger UI refresh
        biometricEnabledState = true
      }
    }
  }

  /// Verify using biometric authentication
  func verifyBiometric() async throws -> Bool {
    let context = LAContext()

    // Use biometrics or device passcode as fallback
    return try await context.evaluatePolicy(
      .deviceOwnerAuthentication,
      localizedReason: "Authorize query execution in Safe Mode")
  }

  /// Disable biometric authentication
  func disableBiometricAuth() {
    UserDefaults.standard.set(false, forKey: Keys.safeModeBiometricEnabled)
    // Update observable property to trigger UI refresh
    biometricEnabledState = false
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
      // Clamp between 50 and 100
      maxRowLimit = min(max(savedLimit, 50), 100)
    }

    let savedEditorLimit = UserDefaults.standard.integer(forKey: Keys.editorMaxRowLimit)
    if savedEditorLimit > 0 {
      // Clamp between 100 and 200
      editorMaxRowLimit = min(max(savedEditorLimit, 100), 200)
    }

    // Load left sidebar visibility state
    if UserDefaults.standard.object(forKey: Keys.isLeftSidebarVisible) != nil {
      isLeftSidebarVisible = UserDefaults.standard.bool(forKey: Keys.isLeftSidebarVisible)
    }

    // Load left sidebar width
    let savedSidebarWidth = UserDefaults.standard.double(forKey: Keys.leftSidebarWidth)
    if savedSidebarWidth > 0 {
      leftSidebarWidth = max(CGFloat(savedSidebarWidth), 200)
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

    // Load autocomplete enabled setting
    if UserDefaults.standard.object(forKey: Keys.isAutoCompleteEnabled) != nil {
      isAutoCompleteEnabled = UserDefaults.standard.bool(forKey: Keys.isAutoCompleteEnabled)
    }

    // Load show line numbers setting
    if UserDefaults.standard.object(forKey: Keys.showLineNumbers) != nil {
      showLineNumbers = UserDefaults.standard.bool(forKey: Keys.showLineNumbers)
    }

    // Load connection history size setting
    let savedHistorySize = UserDefaults.standard.integer(forKey: Keys.maxConnectionHistorySize)
    if UserDefaults.standard.object(forKey: Keys.maxConnectionHistorySize) != nil {
      maxConnectionHistorySize = min(max(savedHistorySize, 0), 5)
    } else {
      // Default to 5 if not set
      maxConnectionHistorySize = 5
    }

    // Load word wrap enabled setting
    if UserDefaults.standard.object(forKey: Keys.wordWrapEnabled) != nil {
      wordWrapEnabled = UserDefaults.standard.bool(forKey: Keys.wordWrapEnabled)
    }

    // Load hide run with query section setting
    if UserDefaults.standard.object(forKey: Keys.hideRunWithQuerySection) != nil {
      hideRunWithQuerySection = UserDefaults.standard.bool(forKey: Keys.hideRunWithQuerySection)
    }

    // Load editor simple mode setting
    if UserDefaults.standard.object(forKey: Keys.editorSimpleMode) != nil {
      editorSimpleMode = UserDefaults.standard.bool(forKey: Keys.editorSimpleMode)
    }

    // Load syntax highlighting enabled setting
    if UserDefaults.standard.object(forKey: Keys.syntaxHighlightingEnabled) != nil {
      syntaxHighlightingEnabled = UserDefaults.standard.bool(forKey: Keys.syntaxHighlightingEnabled)
    }

    // Load accent color preference
    if let accentString = UserDefaults.standard.string(forKey: Keys.accentColor),
      let accent = AccentColor(rawValue: accentString)
    {
      accentColor = accent
    }

    // Load hide column types setting
    if UserDefaults.standard.object(forKey: Keys.hideColumnTypes) != nil {
      hideColumnTypes = UserDefaults.standard.bool(forKey: Keys.hideColumnTypes)
    }

    // Load Safe Mode setting
    let savedSafeMode = UserDefaults.standard.integer(forKey: Keys.safeMode)
    if UserDefaults.standard.object(forKey: Keys.safeMode) != nil,
      let mode = SafeMode(rawValue: savedSafeMode)
    {
      safeMode = mode
    }
    // Note: safeModePassword is not loaded directly - it's stored as hash
    // and only verified via verifySafeModePassword()

    // Load biometric enabled state
    biometricEnabledState = UserDefaults.standard.bool(forKey: Keys.safeModeBiometricEnabled)
  }

  // MARK: - Reset to Defaults

  /// Reset all settings to their default values
  func resetToDefaults() {
    maxResultHeight = 500.0
    includeResultsOnSave = true
    maxRowLimit = 50
    editorMaxRowLimit = 100
    isLeftSidebarVisible = false
    leftSidebarWidth = 250.0
    themePreference = .dark
    bypassDestructiveQueryConfirmation = false
    isAutoCompleteEnabled = true
    showLineNumbers = true
    maxConnectionHistorySize = 5
    wordWrapEnabled = true
    hideRunWithQuerySection = false
    editorSimpleMode = false
    syntaxHighlightingEnabled = true
    accentColor = .purple
    hideColumnTypes = false
    safeMode = .alertRead
    // Note: Don't reset safeModePassword on general reset for security
  }

  /// Clear Safe Mode password and biometric (separate from general reset)
  func clearSafeModePassword() {
    UserDefaults.standard.removeObject(forKey: Keys.safeModePassword)
    UserDefaults.standard.set(false, forKey: Keys.safeModeBiometricEnabled)
    // Update observable property to trigger UI refresh
    biometricEnabledState = false
  }
}
