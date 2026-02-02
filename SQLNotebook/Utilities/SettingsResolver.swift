//
//  SettingsResolver.swift
//  SQLNotebook
//

import Foundation
import SwiftUI

/// Setting keys for checking overrides
enum SettingKey: String, CaseIterable {
  case safeMode
  case connectionProtectionLevel
  case maxRowLimit
  case editorMaxRowLimit
  case syntaxHighlightingEnabled
  case wordWrapEnabled
  case isAutoCompleteEnabled
  case showLineNumbers
  case leftSidebarWidth
  case isLeftSidebarVisible
  case hideColumnTypes
  case maxResultHeight
  case includeResultsOnSave
  case hideRunWithQuerySection
  case editorSimpleMode
}

/// Resolves settings with priority: workspace > user > default
/// This class provides the effective value for each setting based on the hierarchy.
@MainActor
@Observable
class SettingsResolver {
  // MARK: - Dependencies

  private var workspaceSettings: WorkspaceSettings?
  private let userSettings: AppSettings

  // MARK: - Default Values

  private nonisolated enum Defaults {
    static let safeMode: SafeMode = .alertRead
    static let connectionProtectionLevel: ConnectionProtectionLevel = .none
    static let maxRowLimit: Int = 50
    static let editorMaxRowLimit: Int = 100
    static let syntaxHighlightingEnabled: Bool = true
    static let wordWrapEnabled: Bool = true
    static let isAutoCompleteEnabled: Bool = true
    static let showLineNumbers: Bool = true
    static let leftSidebarWidth: Double = 300.0
    static let isLeftSidebarVisible: Bool = false
    static let hideColumnTypes: Bool = false
    static let maxResultHeight: Double = 500.0
    static let includeResultsOnSave: Bool = true
    static let hideRunWithQuerySection: Bool = false
    static let editorSimpleMode: Bool = false
  }

  // MARK: - Initialization

  init(workspaceSettings: WorkspaceSettings? = nil, userSettings: AppSettings = .shared) {
    self.workspaceSettings = workspaceSettings
    self.userSettings = userSettings
  }

  /// Update workspace settings
  func updateWorkspaceSettings(_ settings: WorkspaceSettings?) {
    workspaceSettings = settings
  }

  // MARK: - Resolved Settings (workspace > user > default)

  var safeMode: SafeMode {
    workspaceSettings?.safeMode ?? userSettings.safeMode
  }

  var connectionProtectionLevel: ConnectionProtectionLevel {
    workspaceSettings?.connectionProtectionLevel ?? Defaults.connectionProtectionLevel
  }

  var maxRowLimit: Int {
    workspaceSettings?.maxRowLimit ?? userSettings.maxRowLimit
  }

  var editorMaxRowLimit: Int {
    workspaceSettings?.editorMaxRowLimit ?? userSettings.editorMaxRowLimit
  }

  var syntaxHighlightingEnabled: Bool {
    workspaceSettings?.syntaxHighlightingEnabled ?? userSettings.syntaxHighlightingEnabled
  }

  var wordWrapEnabled: Bool {
    workspaceSettings?.wordWrapEnabled ?? userSettings.wordWrapEnabled
  }

  var isAutoCompleteEnabled: Bool {
    workspaceSettings?.isAutoCompleteEnabled ?? userSettings.isAutoCompleteEnabled
  }

  var showLineNumbers: Bool {
    workspaceSettings?.showLineNumbers ?? userSettings.showLineNumbers
  }

  var leftSidebarWidth: CGFloat {
    CGFloat(workspaceSettings?.leftSidebarWidth ?? Double(userSettings.leftSidebarWidth))
  }

  var isLeftSidebarVisible: Bool {
    workspaceSettings?.isLeftSidebarVisible ?? userSettings.isLeftSidebarVisible
  }

  var hideColumnTypes: Bool {
    workspaceSettings?.hideColumnTypes ?? userSettings.hideColumnTypes
  }

  var maxResultHeight: CGFloat {
    CGFloat(workspaceSettings?.maxResultHeight ?? Double(userSettings.maxResultHeight))
  }

  var includeResultsOnSave: Bool {
    workspaceSettings?.includeResultsOnSave ?? userSettings.includeResultsOnSave
  }

  var hideRunWithQuerySection: Bool {
    workspaceSettings?.hideRunWithQuerySection ?? userSettings.hideRunWithQuerySection
  }

  var editorSimpleMode: Bool {
    workspaceSettings?.editorSimpleMode ?? userSettings.editorSimpleMode
  }

  // MARK: - Settings from UserSettings only (not overridable)

  var themePreference: ThemePreference {
    userSettings.themePreference
  }

  var accentColor: AccentColor {
    userSettings.accentColor
  }

  var bypassDestructiveQueryConfirmation: Bool {
    userSettings.bypassDestructiveQueryConfirmation
  }

  // MARK: - Override Checking

  /// Check if a setting is overridden in workspace
  func isOverriddenInWorkspace(_ key: SettingKey) -> Bool {
    guard let ws = workspaceSettings else { return false }
    switch key {
    case .safeMode: return ws.safeMode != nil
    case .connectionProtectionLevel: return ws.connectionProtectionLevel != nil
    case .maxRowLimit: return ws.maxRowLimit != nil
    case .editorMaxRowLimit: return ws.editorMaxRowLimit != nil
    case .syntaxHighlightingEnabled: return ws.syntaxHighlightingEnabled != nil
    case .wordWrapEnabled: return ws.wordWrapEnabled != nil
    case .isAutoCompleteEnabled: return ws.isAutoCompleteEnabled != nil
    case .showLineNumbers: return ws.showLineNumbers != nil
    case .leftSidebarWidth: return ws.leftSidebarWidth != nil
    case .isLeftSidebarVisible: return ws.isLeftSidebarVisible != nil
    case .hideColumnTypes: return ws.hideColumnTypes != nil
    case .maxResultHeight: return ws.maxResultHeight != nil
    case .includeResultsOnSave: return ws.includeResultsOnSave != nil
    case .hideRunWithQuerySection: return ws.hideRunWithQuerySection != nil
    case .editorSimpleMode: return ws.editorSimpleMode != nil
    }
  }

  /// Get default value for a setting
  func defaultValue(for key: SettingKey) -> Any {
    switch key {
    case .safeMode: return Defaults.safeMode
    case .connectionProtectionLevel: return Defaults.connectionProtectionLevel
    case .maxRowLimit: return Defaults.maxRowLimit
    case .editorMaxRowLimit: return Defaults.editorMaxRowLimit
    case .syntaxHighlightingEnabled: return Defaults.syntaxHighlightingEnabled
    case .wordWrapEnabled: return Defaults.wordWrapEnabled
    case .isAutoCompleteEnabled: return Defaults.isAutoCompleteEnabled
    case .showLineNumbers: return Defaults.showLineNumbers
    case .leftSidebarWidth: return Defaults.leftSidebarWidth
    case .isLeftSidebarVisible: return Defaults.isLeftSidebarVisible
    case .hideColumnTypes: return Defaults.hideColumnTypes
    case .maxResultHeight: return Defaults.maxResultHeight
    case .includeResultsOnSave: return Defaults.includeResultsOnSave
    case .hideRunWithQuerySection: return Defaults.hideRunWithQuerySection
    case .editorSimpleMode: return Defaults.editorSimpleMode
    }
  }
}
