//
//  WorkspaceSettings.swift
//  SQLNotebook
//

import Foundation

/// Workspace-level settings that override user settings.
/// Only non-nil values override user settings; nil values inherit from user settings.
struct WorkspaceSettings: Codable, Equatable, Sendable {
  // MARK: - Query Settings

  /// Safe Mode level override
  var safeMode: SafeMode?

  /// Connection protection level override
  var connectionProtectionLevel: ConnectionProtectionLevel?

  // MARK: - Editor Settings

  /// Enable syntax highlighting
  var syntaxHighlightingEnabled: Bool?

  /// Enable word wrap in editor mode
  var wordWrapEnabled: Bool?

  /// Enable autocomplete
  var isAutoCompleteEnabled: Bool?

  /// Show line numbers
  var showLineNumbers: Bool?

  // MARK: - UI Settings

  /// Left sidebar width
  var leftSidebarWidth: Double?

  /// Left sidebar visibility
  var isLeftSidebarVisible: Bool?

  /// Hide column types in result headers
  var hideColumnTypes: Bool?

  /// Maximum result table height
  var maxResultHeight: Double?

  /// Include results when saving
  var includeResultsOnSave: Bool?

  /// Hide "Run with query" section
  var hideRunWithQuerySection: Bool?

  /// Editor simple mode
  var editorSimpleMode: Bool?

  // MARK: - Initialization

  init(
    safeMode: SafeMode? = nil,
    connectionProtectionLevel: ConnectionProtectionLevel? = nil,
    syntaxHighlightingEnabled: Bool? = nil,
    wordWrapEnabled: Bool? = nil,
    isAutoCompleteEnabled: Bool? = nil,
    showLineNumbers: Bool? = nil,
    leftSidebarWidth: Double? = nil,
    isLeftSidebarVisible: Bool? = nil,
    hideColumnTypes: Bool? = nil,
    maxResultHeight: Double? = nil,
    includeResultsOnSave: Bool? = nil,
    hideRunWithQuerySection: Bool? = nil,
    editorSimpleMode: Bool? = nil
  ) {
    self.safeMode = safeMode
    self.connectionProtectionLevel = connectionProtectionLevel
    self.syntaxHighlightingEnabled = syntaxHighlightingEnabled
    self.wordWrapEnabled = wordWrapEnabled
    self.isAutoCompleteEnabled = isAutoCompleteEnabled
    self.showLineNumbers = showLineNumbers
    self.leftSidebarWidth = leftSidebarWidth
    self.isLeftSidebarVisible = isLeftSidebarVisible
    self.hideColumnTypes = hideColumnTypes
    self.maxResultHeight = maxResultHeight
    self.includeResultsOnSave = includeResultsOnSave
    self.hideRunWithQuerySection = hideRunWithQuerySection
    self.editorSimpleMode = editorSimpleMode
  }

  /// Returns true if any setting is overridden
  var hasOverrides: Bool {
    safeMode != nil
      || connectionProtectionLevel != nil
      || syntaxHighlightingEnabled != nil
      || wordWrapEnabled != nil
      || isAutoCompleteEnabled != nil
      || showLineNumbers != nil
      || leftSidebarWidth != nil
      || isLeftSidebarVisible != nil
      || hideColumnTypes != nil
      || maxResultHeight != nil
      || includeResultsOnSave != nil
      || hideRunWithQuerySection != nil
      || editorSimpleMode != nil
  }

  /// Returns an empty settings instance (no overrides)
  static let empty = WorkspaceSettings()
}
