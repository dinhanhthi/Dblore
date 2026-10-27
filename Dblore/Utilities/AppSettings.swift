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

/// Whether the app animates. System follows macOS Reduce motion.
enum AnimationPreference: String, CaseIterable {
  case system = "System"
  case on = "On"
  case off = "Off"

  /// True when motion should be dropped, given macOS Reduce motion
  func reducesMotion(system systemReduceMotion: Bool) -> Bool {
    switch self {
    case .system: return systemReduceMotion
    case .on: return false
    case .off: return true
    }
  }
}

/// Type of tab created by default by the new tab action
enum NewTabType: String, CaseIterable {
  case notebook
  case sqlFile
  case markdownFile

  var title: String {
    switch self {
    case .notebook: return "Notebook"
    case .sqlFile: return "SQL File"
    case .markdownFile: return "Markdown File"
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

/// What Cmd+C puts on the clipboard for the selected result grid rows
enum CopyRowsFormat: String, CaseIterable {
  case tsv
  case tsvWithHeaders
  case csv
  case csvWithHeaders
  case json
  case markdown

  var title: String {
    switch self {
    case .tsv: return "TSV"
    case .tsvWithHeaders: return "TSV with headers"
    case .csv: return "CSV"
    case .csvWithHeaders: return "CSV with headers"
    case .json: return "JSON"
    case .markdown: return "Markdown"
    }
  }
}

/// How long the Mac stays without input before Dblore covers its unlocked items again
enum LockIdleTimeout: Int, CaseIterable {
  case minutes5 = 5
  case minutes15 = 15
  case minutes30 = 30
  case minutes60 = 60
  case never = 0

  var title: String {
    self == .never ? "Never" : "\(rawValue) minutes"
  }

  /// Nil for Never
  var seconds: TimeInterval? {
    self == .never ? nil : TimeInterval(rawValue * 60)
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

/// Indent of one nesting level when Format SQL runs
enum FormatterIndent: String, CaseIterable {
  case twoSpaces
  case fourSpaces
  case tab

  var title: String {
    switch self {
    case .twoSpaces: return "2 spaces"
    case .fourSpaces: return "4 spaces"
    case .tab: return "Tab"
    }
  }

  var indent: SQLFormatter.Options.Indent {
    switch self {
    case .twoSpaces: return .spaces(2)
    case .fourSpaces: return .spaces(4)
    case .tab: return .tab
    }
  }
}

/// Safe Mode levels for query protection
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

/// What MCP's execute_write may change on an allowlisted connection. Ordered: a wider scope
/// allows everything a narrower one does.
nonisolated enum MCPWriteScope: String, CaseIterable, Sendable, Comparable {
  case read
  /// INSERT, UPDATE, DELETE, MERGE (MongoDB inserts, updates, deletes)
  case data
  /// Data changes plus schema changes (CREATE, ALTER, DROP; MongoDB collections and indexes)
  case schema

  var title: String {
    switch self {
    case .read: "Read"
    case .data: "Read + data changes"
    case .schema: "Read + data + schema changes"
    }
  }

  private var rank: Int {
    switch self {
    case .read: 0
    case .data: 1
    case .schema: 2
    }
  }

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
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
nonisolated enum AccentColor: String, CaseIterable, Sendable {
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
    case .green: return "15803d"
    case .orange: return "c2410c"
    case .pink: return "db2777"
    case .cyan: return "0e7490"
    case .gray: return "71717a"
    }
  }

  /// Dark mode hex color
  var darkHex: String {
    switch self {
    case .purple: return "c084fc"
    case .blue: return "60a5fa"
    case .green: return "22c55e"
    case .orange: return "f97316"
    case .pink: return "f472b6"
    case .cyan: return "06b6d4"
    case .gray: return "a1a1aa"
    }
  }

  /// Muted light mode hex color
  var mutedLightHex: String {
    switch self {
    case .purple: return "7e22ce"
    case .blue: return "1d4ed8"
    case .green: return "166534"
    case .orange: return "9a3412"
    case .pink: return "be185d"
    case .cyan: return "155e75"
    case .gray: return "52525b"
    }
  }

  /// Muted dark mode hex color (pressed state, darker than `darkHex`)
  var mutedDarkHex: String {
    switch self {
    case .purple: return "a855f7"
    case .blue: return "3b82f6"
    case .green: return "16a34a"
    case .orange: return "ea580c"
    case .pink: return "ec4899"
    case .cyan: return "0891b2"
    case .gray: return "8e8e96"
    }
  }

  /// Syntax keyword light mode hex color (slightly lighter for readability)
  var syntaxLightHex: String {
    switch self {
    case .purple: return "9333ea"
    case .blue: return "2563eb"
    case .green: return "15803d"
    case .orange: return "c2410c"
    case .pink: return "db2777"
    case .cyan: return "0e7490"
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
    static let confirmBeforeQuit = "app.settings.confirmBeforeQuit"
    static let lockIdleTimeout = "app.settings.lockIdleTimeout"
    static let aiPanelOpenMode = "app.settings.aiPanelOpenMode"
    static let aiBubblePosition = "app.settings.aiBubblePosition"
    static let aiSidebarWidth = "app.settings.aiSidebarWidth"
    static let aiBubbleCardWidth = "app.settings.aiBubbleCardWidth"
    static let aiBubbleCardHeight = "app.settings.aiBubbleCardHeight"
    static let editorSideBySideDefault = "app.settings.editorSideBySideDefault"
    static let hideRunWithQuerySection = "app.settings.hideRunWithQuerySection"
    static let editorSimpleMode = "app.settings.editorSimpleMode"
    static let syntaxHighlightingEnabled = "app.settings.syntaxHighlightingEnabled"
    static let accentColor = "app.settings.accentColor"
    static let animationPreference = "app.settings.animationPreference"
    static let hideColumnTypes = "app.settings.hideColumnTypes"
    static let safeMode = "app.settings.safeMode"
    static let commitStyle = "app.settings.commitStyle"
    static let historyEnabled = "app.settings.historyEnabled"
    static let historyRetentionDays = "app.settings.historyRetentionDays"
    static let historyMaxEntries = "app.settings.historyMaxEntries"
    static let rewindEnabled = "app.settings.rewindEnabled"
    static let rewindRetentionDays = "app.settings.rewindRetentionDays"
    static let showExperimentalEngines = "app.settings.showExperimentalEngines"
    static let resultFontSize = "app.settings.resultFontSize"
    static let colorValuesByType = "app.settings.colorValuesByType"
    static let neutralizesCopiedFormulas = "app.settings.neutralizesCopiedFormulas"
    static let copyRowsFormat = "app.settings.copyRowsFormat"
    static let showsInvisibleCharacters = "app.settings.showsInvisibleCharacters"
    static let editorFontSize = "app.settings.editorFontSize"
    static let notifyLongQueries = "app.settings.notifyLongQueries"
    static let longQueryThresholdSeconds = "app.settings.longQueryThresholdSeconds"
    static let notifyOnlyWhenInactive = "app.settings.notifyOnlyWhenInactive"
    static let mcpEnabled = "app.settings.mcpEnabled"
    static let mcpPort = "app.settings.mcpPort"
    static let mcpAllowedConnectionIDs = "app.settings.mcpAllowedConnectionIDs"
    static let mcpRowCap = "app.settings.mcpRowCap"
    static let mcpWriteToolsEnabled = "app.settings.mcpWriteToolsEnabled"
    static let mcpWriteScopes = "app.settings.mcpWriteScopes"
    static let mongoPreviewDocumentCount = "app.settings.mongoPreviewDocumentCount"
    static let formatterIndent = "app.settings.formatterIndent"
    static let formatterKeywordCase = "app.settings.formatterKeywordCase"
    static let formatterFunctionCase = "app.settings.formatterFunctionCase"
    static let formatterCommaPosition = "app.settings.formatterCommaPosition"
    static let formatterLineWidth = "app.settings.formatterLineWidth"
  }

  /// Seconds a query must run before it notifies, when none is stored.
  static let defaultLongQueryThresholdSeconds: Double = 10
  /// Inclusive seconds range for the long-query threshold.
  static let longQueryThresholdRange: ClosedRange<Double> = 1...3600

  /// Clamp to `longQueryThresholdRange`; a non-finite value becomes the default.
  static func clampLongQueryThreshold(_ seconds: Double) -> Double {
    guard seconds.isFinite else { return defaultLongQueryThresholdSeconds }
    return min(max(seconds, longQueryThresholdRange.lowerBound), longQueryThresholdRange.upperBound)
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

  /// View > Zoom In (1) or Zoom Out (-1): one whole point per step, inside `fontSizeRange`
  static func steppedFontSize(_ size: CGFloat, by steps: Int) -> CGFloat {
    clampFontSize(size + CGFloat(steps))
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

  /// Ask before quitting when Quit comes from the keyboard (Cmd+Q)
  /// Default: false
  var confirmBeforeQuit: Bool = false {
    didSet {
      defaults.set(confirmBeforeQuit, forKey: Keys.confirmBeforeQuit)
    }
  }

  /// Idle time after which Dblore relocks its locked items (`RelockMonitor`)
  /// Default: 15 minutes
  var lockIdleTimeout: LockIdleTimeout = .minutes15 {
    didSet {
      defaults.set(lockIdleTimeout.rawValue, forKey: Keys.lockIdleTimeout)
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

  /// Width of the AI assistant sidebar in points
  /// Default: 320, Min: 320, Max: 35% of window width (clamped by the view)
  var aiSidebarWidth: CGFloat = ComponentSize.sidebarWidth {
    didSet {
      let clampedValue = max(aiSidebarWidth, ComponentSize.sidebarWidth)
      if clampedValue != aiSidebarWidth {
        aiSidebarWidth = clampedValue
        return  // Avoid triggering didSet again
      }
      defaults.set(Double(aiSidebarWidth), forKey: Keys.aiSidebarWidth)
    }
  }

  /// Width of the AI bubble card in points; nil = default. Min clamped here, the max
  /// depends on the window and is clamped by `AIBubbleLayout`.
  var aiBubbleCardWidth: Double? {
    didSet {
      if let width = aiBubbleCardWidth, width < Double(AIBubbleLayout.minCardWidth) {
        aiBubbleCardWidth = Double(AIBubbleLayout.minCardWidth)
        return  // Avoid triggering didSet again
      }
      Self.setOptional(aiBubbleCardWidth, forKey: Keys.aiBubbleCardWidth, in: defaults)
    }
  }

  /// Height of the AI bubble card in points; nil = default (follows the window height).
  /// Min clamped here, the max depends on the window and is clamped by `AIBubbleLayout`.
  var aiBubbleCardHeight: Double? {
    didSet {
      if let height = aiBubbleCardHeight, height < Double(AIBubbleLayout.minCardHeight) {
        aiBubbleCardHeight = Double(AIBubbleLayout.minCardHeight)
        return  // Avoid triggering didSet again
      }
      Self.setOptional(aiBubbleCardHeight, forKey: Keys.aiBubbleCardHeight, in: defaults)
    }
  }

  /// Stores `value`, or removes the key when nil
  private static func setOptional(_ value: Double?, forKey key: String, in defaults: UserDefaults) {
    if let value {
      defaults.set(value, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
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

  /// Animations on, off, or following macOS Reduce motion
  /// Default: system
  var animationPreference: AnimationPreference = .system {
    didSet {
      defaults.set(animationPreference.rawValue, forKey: Keys.animationPreference)
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

  /// Color result-table values by type (numbers, text, dates, booleans, JSON)
  /// Default: true
  var colorValuesByType: Bool = true {
    didSet {
      defaults.set(colorValuesByType, forKey: Keys.colorValuesByType)
    }
  }

  /// Prefix copied text cells that start with =, +, -, @ (TSV copies) so spreadsheets
  /// don't run them as formulas
  /// Default: true
  var neutralizesCopiedFormulas: Bool = true {
    didSet {
      defaults.set(neutralizesCopiedFormulas, forKey: Keys.neutralizesCopiedFormulas)
    }
  }

  /// Format of the result grid rows Cmd+C copies
  /// Default: .tsv (no header row)
  var copyRowsFormat: CopyRowsFormat = .tsv {
    didSet {
      defaults.set(copyRowsFormat.rawValue, forKey: Keys.copyRowsFormat)
    }
  }

  /// Show control, zero-width and special space characters in result grid cells as marks.
  /// Display only: copy, export and search read the raw value.
  /// Default: true
  var showsInvisibleCharacters: Bool = true {
    didSet {
      defaults.set(showsInvisibleCharacters, forKey: Keys.showsInvisibleCharacters)
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

  /// Record Data Rewind entries for data viewer edits.
  /// Default: true
  var rewindEnabled: Bool = true {
    didSet {
      defaults.set(rewindEnabled, forKey: Keys.rewindEnabled)
    }
  }

  /// Days of Data Rewind entries to keep. Allowed: 7, 30, 90, 365. Any other value becomes 30.
  /// Default: 30
  var rewindRetentionDays: Int = AppSettings.defaultRewindRetentionDays {
    didSet {
      let clampedValue = Self.clampRewindRetentionDays(rewindRetentionDays)
      if clampedValue != rewindRetentionDays {
        rewindRetentionDays = clampedValue
        return  // Avoid triggering didSet again
      }
      defaults.set(rewindRetentionDays, forKey: Keys.rewindRetentionDays)
      RewindPrune.schedule()
    }
  }

  /// Show database engines with `isAvailable == false` in the connection type picker.
  /// Default: false (the picker stays hidden while only PostgreSQL is available)
  var showExperimentalEngines: Bool = false {
    didSet {
      defaults.set(showExperimentalEngines, forKey: Keys.showExperimentalEngines)
    }
  }

  /// Post a notification when a query runs longer than `longQueryThresholdSeconds`.
  /// Default: false (turning it on asks for notification permission)
  var notifyLongQueries: Bool = false {
    didSet {
      defaults.set(notifyLongQueries, forKey: Keys.notifyLongQueries)
    }
  }

  /// Seconds a query must run before it notifies, clamped to 1...3600.
  /// Default: 10
  var longQueryThresholdSeconds: Double = AppSettings.defaultLongQueryThresholdSeconds {
    didSet {
      let clampedValue = Self.clampLongQueryThreshold(longQueryThresholdSeconds)
      if clampedValue != longQueryThresholdSeconds {
        longQueryThresholdSeconds = clampedValue
        return  // Avoid triggering didSet again
      }
      defaults.set(longQueryThresholdSeconds, forKey: Keys.longQueryThresholdSeconds)
    }
  }

  /// Notify only while Dblore is not the active app.
  /// Default: true
  var notifyOnlyWhenInactive: Bool = true {
    didSet {
      defaults.set(notifyOnlyWhenInactive, forKey: Keys.notifyOnlyWhenInactive)
    }
  }

  /// Snapshot of the long-query notification settings, taken when a run finishes.
  var queryNotificationSettings: QueryNotificationSettings {
    QueryNotificationSettings(
      enabled: notifyLongQueries, thresholdSeconds: longQueryThresholdSeconds,
      onlyWhenInactive: notifyOnlyWhenInactive)
  }

  /// Turns long-query notifications on, then asks for permission. When permission is denied
  /// the setting goes back to off. Returns whether permission was granted.
  @discardableResult
  func enableLongQueryNotifications(authorize: () async -> Bool) async -> Bool {
    notifyLongQueries = true
    let granted = await authorize()
    if !granted { notifyLongQueries = false }
    return granted
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

  // MARK: - MCP Server

  /// Default MCP port, the same across launches
  static let defaultMCPPort = 41730
  /// Ports the MCP server may bind (no privileged ports)
  static let mcpPortRange: ClosedRange<Int> = 1024...65535
  /// Default and allowed MCP run_query row caps
  static let defaultMCPRowCap = MCPToolService.defaultMaxRows
  static let mcpRowCapRange: ClosedRange<Int> = 1...MCPToolService.maxRowsLimit

  /// Run the MCP server on 127.0.0.1 (`MCPServerController`).
  /// Default: false
  var mcpEnabled: Bool = false {
    didSet {
      defaults.set(mcpEnabled, forKey: Keys.mcpEnabled)
    }
  }

  /// MCP server port, clamped to `mcpPortRange`.
  /// Default: 41730
  var mcpPort: Int = AppSettings.defaultMCPPort {
    didSet {
      let clampedValue = min(
        max(mcpPort, Self.mcpPortRange.lowerBound), Self.mcpPortRange.upperBound)
      if clampedValue != mcpPort {
        mcpPort = clampedValue
        return  // Avoid triggering didSet again
      }
      defaults.set(mcpPort, forKey: Keys.mcpPort)
    }
  }

  /// Ids (`ConnectionHistoryEntry.id`) of the saved connections MCP may use.
  /// Default: none
  var mcpAllowedConnectionIDs: Set<UUID> = [] {
    didSet {
      defaults.set(
        mcpAllowedConnectionIDs.map(\.uuidString).sorted(), forKey: Keys.mcpAllowedConnectionIDs)
    }
  }

  /// Default rows of an MCP run_query without max_rows, clamped to `mcpRowCapRange`.
  /// Default: 200
  var mcpRowCap: Int = AppSettings.defaultMCPRowCap {
    didSet {
      let clampedValue = min(
        max(mcpRowCap, Self.mcpRowCapRange.lowerBound), Self.mcpRowCapRange.upperBound)
      if clampedValue != mcpRowCap {
        mcpRowCap = clampedValue
        return  // Avoid triggering didSet again
      }
      defaults.set(mcpRowCap, forKey: Keys.mcpRowCap)
    }
  }

  /// Offer MCP's execute_write tool (each call still needs a write scope and an approval).
  /// Default: false
  var mcpWriteToolsEnabled: Bool = false {
    didSet {
      defaults.set(mcpWriteToolsEnabled, forKey: Keys.mcpWriteToolsEnabled)
    }
  }

  /// Write scopes of allowlisted connections, by id. A missing id is `.read`.
  /// Default: none (every connection Read)
  var mcpWriteScopes: [UUID: MCPWriteScope] = [:] {
    didSet {
      defaults.set(
        Dictionary(
          uniqueKeysWithValues: mcpWriteScopes.filter { $0.value != .read }
            .map { ($0.key.uuidString, $0.value.rawValue) }),
        forKey: Keys.mcpWriteScopes)
    }
  }

  /// The stored scopes; an unknown id or value is dropped (Read), so nothing widens.
  static func decodeMCPWriteScopes(_ stored: Any?) -> [UUID: MCPWriteScope] {
    guard let stored = stored as? [String: String] else { return [:] }
    var scopes: [UUID: MCPWriteScope] = [:]
    for (key, value) in stored {
      guard let id = UUID(uuidString: key), let scope = MCPWriteScope(rawValue: value),
        scope != .read
      else { continue }
      scopes[id] = scope
    }
    return scopes
  }

  // MARK: - MongoDB

  /// Choices and default of the documents an aggregation stage preview shows
  static let mongoPreviewDocumentCounts = [10, 20, 50, 100]
  static let defaultMongoPreviewDocumentCount = 20

  /// Documents an aggregation stage preview shows, one of `mongoPreviewDocumentCounts`
  /// (any other value goes back to the default).
  /// Default: 20
  var mongoPreviewDocumentCount: Int = AppSettings.defaultMongoPreviewDocumentCount {
    didSet {
      guard Self.mongoPreviewDocumentCounts.contains(mongoPreviewDocumentCount) else {
        mongoPreviewDocumentCount = Self.defaultMongoPreviewDocumentCount
        return  // Avoid triggering didSet again
      }
      defaults.set(mongoPreviewDocumentCount, forKey: Keys.mongoPreviewDocumentCount)
    }
  }

  // MARK: - SQL Formatter

  /// Line width choices of Format SQL; 0 turns wrapping off
  static let formatterLineWidths = [0, 80, 100, 120]

  /// Indent of one nesting level. Default: 2 spaces
  var formatterIndent: FormatterIndent = .twoSpaces {
    didSet {
      defaults.set(formatterIndent.rawValue, forKey: Keys.formatterIndent)
    }
  }

  /// Case of SQL keywords. Default: upper
  var formatterKeywordCase: SQLFormatter.Options.WordCase = .upper {
    didSet {
      defaults.set(formatterKeywordCase.rawValue, forKey: Keys.formatterKeywordCase)
    }
  }

  /// Case of function names. Default: preserve
  var formatterFunctionCase: SQLFormatter.Options.WordCase = .preserve {
    didSet {
      defaults.set(formatterFunctionCase.rawValue, forKey: Keys.formatterFunctionCase)
    }
  }

  /// Comma at the end of a line or at the start of the next. Default: trailing
  var formatterCommaPosition: SQLFormatter.Options.CommaPosition = .trailing {
    didSet {
      defaults.set(formatterCommaPosition.rawValue, forKey: Keys.formatterCommaPosition)
    }
  }

  /// Lines wider than this wrap, one of `formatterLineWidths` (any other value goes back to 0).
  /// Default: 0 (off)
  var formatterLineWidth: Int = 0 {
    didSet {
      guard Self.formatterLineWidths.contains(formatterLineWidth) else {
        formatterLineWidth = 0
        return  // Avoid triggering didSet again
      }
      defaults.set(formatterLineWidth, forKey: Keys.formatterLineWidth)
    }
  }

  /// The options Format SQL uses. The defaults give `SQLFormatter.Options.default`.
  var formatterOptions: SQLFormatter.Options {
    var options = SQLFormatter.Options()
    options.indent = formatterIndent.indent
    options.keywordCase = formatterKeywordCase
    options.functionCase = formatterFunctionCase
    options.commaPosition = formatterCommaPosition
    options.maxLineWidth = formatterLineWidth
    return options
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

    if defaults.object(forKey: Keys.confirmBeforeQuit) != nil {
      confirmBeforeQuit = defaults.bool(forKey: Keys.confirmBeforeQuit)
    }

    if defaults.object(forKey: Keys.lockIdleTimeout) != nil,
      let timeout = LockIdleTimeout(rawValue: defaults.integer(forKey: Keys.lockIdleTimeout))
    {
      lockIdleTimeout = timeout
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

    let savedAISidebarWidth = defaults.double(forKey: Keys.aiSidebarWidth)
    if savedAISidebarWidth > 0 {
      aiSidebarWidth = max(CGFloat(savedAISidebarWidth), ComponentSize.sidebarWidth)
    }
    if defaults.object(forKey: Keys.aiBubbleCardWidth) != nil {
      aiBubbleCardWidth = defaults.double(forKey: Keys.aiBubbleCardWidth)
    }
    if defaults.object(forKey: Keys.aiBubbleCardHeight) != nil {
      aiBubbleCardHeight = defaults.double(forKey: Keys.aiBubbleCardHeight)
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

    // Load animation preference
    if let animationString = defaults.string(forKey: Keys.animationPreference),
      let animation = AnimationPreference(rawValue: animationString)
    {
      animationPreference = animation
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

    if defaults.object(forKey: Keys.colorValuesByType) != nil {
      colorValuesByType = defaults.bool(forKey: Keys.colorValuesByType)
    }

    if defaults.object(forKey: Keys.neutralizesCopiedFormulas) != nil {
      neutralizesCopiedFormulas = defaults.bool(forKey: Keys.neutralizesCopiedFormulas)
    }

    if let raw = defaults.string(forKey: Keys.copyRowsFormat),
      let format = CopyRowsFormat(rawValue: raw)
    {
      copyRowsFormat = format
    }

    if defaults.object(forKey: Keys.showsInvisibleCharacters) != nil {
      showsInvisibleCharacters = defaults.bool(forKey: Keys.showsInvisibleCharacters)
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

    if defaults.object(forKey: Keys.rewindEnabled) != nil {
      rewindEnabled = defaults.bool(forKey: Keys.rewindEnabled)
    }

    if defaults.object(forKey: Keys.rewindRetentionDays) != nil {
      let stored = defaults.integer(forKey: Keys.rewindRetentionDays)
      let clamped = Self.clampRewindRetentionDays(stored)
      if clamped != stored {
        defaults.set(clamped, forKey: Keys.rewindRetentionDays)
      }
      rewindRetentionDays = clamped
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

    if defaults.object(forKey: Keys.notifyLongQueries) != nil {
      notifyLongQueries = defaults.bool(forKey: Keys.notifyLongQueries)
    }

    if defaults.object(forKey: Keys.longQueryThresholdSeconds) != nil {
      let stored = defaults.double(forKey: Keys.longQueryThresholdSeconds)
      let clamped = Self.clampLongQueryThreshold(stored)
      if clamped != stored {
        defaults.set(clamped, forKey: Keys.longQueryThresholdSeconds)
      }
      longQueryThresholdSeconds = clamped
    }

    if defaults.object(forKey: Keys.notifyOnlyWhenInactive) != nil {
      notifyOnlyWhenInactive = defaults.bool(forKey: Keys.notifyOnlyWhenInactive)
    }

    if defaults.object(forKey: Keys.mcpEnabled) != nil {
      mcpEnabled = defaults.bool(forKey: Keys.mcpEnabled)
    }

    if defaults.object(forKey: Keys.mcpPort) != nil {
      mcpPort = defaults.integer(forKey: Keys.mcpPort)
    }

    if let ids = defaults.stringArray(forKey: Keys.mcpAllowedConnectionIDs) {
      mcpAllowedConnectionIDs = Set(ids.compactMap(UUID.init(uuidString:)))
    }

    if defaults.object(forKey: Keys.mcpRowCap) != nil {
      mcpRowCap = defaults.integer(forKey: Keys.mcpRowCap)
    }

    if defaults.object(forKey: Keys.mcpWriteToolsEnabled) != nil {
      mcpWriteToolsEnabled = defaults.bool(forKey: Keys.mcpWriteToolsEnabled)
    }

    mcpWriteScopes = Self.decodeMCPWriteScopes(defaults.object(forKey: Keys.mcpWriteScopes))

    if defaults.object(forKey: Keys.mongoPreviewDocumentCount) != nil {
      // didSet does not run in init: an unknown stored value goes back to the default here
      let count = defaults.integer(forKey: Keys.mongoPreviewDocumentCount)
      mongoPreviewDocumentCount =
        Self.mongoPreviewDocumentCounts.contains(count)
        ? count : Self.defaultMongoPreviewDocumentCount
    }

    if let raw = defaults.string(forKey: Keys.formatterIndent),
      let indent = FormatterIndent(rawValue: raw)
    {
      formatterIndent = indent
    }
    if let raw = defaults.string(forKey: Keys.formatterKeywordCase),
      let wordCase = SQLFormatter.Options.WordCase(rawValue: raw)
    {
      formatterKeywordCase = wordCase
    }
    if let raw = defaults.string(forKey: Keys.formatterFunctionCase),
      let wordCase = SQLFormatter.Options.WordCase(rawValue: raw)
    {
      formatterFunctionCase = wordCase
    }
    if let raw = defaults.string(forKey: Keys.formatterCommaPosition),
      let position = SQLFormatter.Options.CommaPosition(rawValue: raw)
    {
      formatterCommaPosition = position
    }
    if defaults.object(forKey: Keys.formatterLineWidth) != nil {
      // An unknown stored value goes back to off
      let width = defaults.integer(forKey: Keys.formatterLineWidth)
      formatterLineWidth = Self.formatterLineWidths.contains(width) ? width : 0
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
    confirmBeforeQuit = false
    lockIdleTimeout = .minutes15
    defaultNewTabType = .notebook
    launchBehavior = .welcome
    // Same-value assignment may not run didSet, so remove the snapshot here too.
    LaunchSessionStore(defaults: defaults).clear()
    aiPanelOpenMode = .sidebar
    aiBubblePosition = 1.0
    aiSidebarWidth = ComponentSize.sidebarWidth
    aiBubbleCardWidth = nil
    aiBubbleCardHeight = nil
    editorFontSize = Self.defaultEditorFontSize
    editorSideBySideDefault = false
    hideRunWithQuerySection = false
    editorSimpleMode = false
    syntaxHighlightingEnabled = true
    accentColor = .blue
    animationPreference = .system
    hideColumnTypes = false
    resultFontSize = Self.defaultResultFontSize
    colorValuesByType = true
    neutralizesCopiedFormulas = true
    copyRowsFormat = .tsv
    showsInvisibleCharacters = true
    // Same-value assignment does not run didSet, so write the review projection first.
    defaults.set(CommitStyle.review.rawValue, forKey: Keys.commitStyle)
    safeMode = CommitStyle.review.legacyProjection.safeMode
    commitStyle = .review
    historyEnabled = true
    historyRetentionDays = Self.defaultHistoryRetentionDays
    historyMaxEntries = Self.defaultHistoryMaxEntries
    rewindEnabled = true
    rewindRetentionDays = Self.defaultRewindRetentionDays
    showExperimentalEngines = false
    notifyLongQueries = false
    longQueryThresholdSeconds = Self.defaultLongQueryThresholdSeconds
    notifyOnlyWhenInactive = true
    mcpEnabled = false
    mcpPort = Self.defaultMCPPort
    mcpAllowedConnectionIDs = []
    mcpRowCap = Self.defaultMCPRowCap
    mcpWriteToolsEnabled = false
    mcpWriteScopes = [:]
    mongoPreviewDocumentCount = Self.defaultMongoPreviewDocumentCount
    formatterIndent = .twoSpaces
    formatterKeywordCase = .upper
    formatterFunctionCase = .preserve
    formatterCommaPosition = .trailing
    formatterLineWidth = 0
    // Leave no Safe Mode password material behind (incl. a not-yet-migrated legacy hash);
    // goes through the shared authenticator's store (in-memory under XCTest)
    clearSafeModePassword()
  }

  /// Clear the Safe Mode password (Keychain and legacy UserDefaults hash) and Touch ID
  func clearSafeModePassword() {
    safeModeAuth.removePassword()
  }
}
