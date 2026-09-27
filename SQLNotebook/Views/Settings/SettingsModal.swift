//
//  SettingsModal.swift
//  SQLNotebook
//
//  Settings modal at workspace level - accessible via Cmd+,
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings Modal

/// Main settings modal for workspace level
/// Shows settings in a tabbed modal, one section per tab
struct SettingsModal: View {
  @Binding var isPresented: Bool
  let viewMode: ViewMode?

  @Bindable var appSettings = AppSettings.shared
  @State private var isExportingLogs = false
  @State private var selectedTab: SettingsTab = .appearance

  /// Tabs shown in the settings tab row (rawValue = label)
  private enum SettingsTab: String, CaseIterable {
    case appearance = "Appearance"
    case editor = "Editor"
    case results = "Results"
    case save = "Save"
    case developer = "Developer"
    case shortcuts = "Shortcuts"
  }

  /// Effective view mode - defaults to notebook if no active tab
  private var effectiveViewMode: ViewMode {
    viewMode ?? .notebook
  }

  var body: some View {
    GenericModal(
      title: "Settings",
      titleIcon: "gear",
      width: 640,
      height: 600,
      isPresented: $isPresented
    ) {
      VStack(spacing: 0) {
        // Tab row (fixed, does not scroll)
        CapsuleTabPicker(
          selection: $selectedTab,
          tabs: SettingsTab.allCases,
          height: 28
        )
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.md)

        ScrollView {
          selectedSection
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.xl)
        }
      }
    }
    .fileExporter(
      isPresented: $isExportingLogs,
      document: LogDocument(),
      contentType: .plainText,
      defaultFilename: "sqlnotebook-logs-\(formattedDate).txt"
    ) { _ in
      // Export completed, no action needed
    }
  }

  /// Section view for the selected tab
  @ViewBuilder
  private var selectedSection: some View {
    switch selectedTab {
    case .appearance:
      AppearanceSettingsSection(appSettings: appSettings)
    case .editor:
      SettingsModalEditorSection(
        appSettings: appSettings,
        viewMode: effectiveViewMode
      )
    case .results:
      SettingsModalResultTableSection(
        appSettings: appSettings,
        viewMode: effectiveViewMode
      )
    case .save:
      // Save Options (Notebook Mode Only)
      SettingsModalSaveOptionsSection(appSettings: appSettings)
    case .developer:
      SettingsModalDeveloperSection(isExportingLogs: $isExportingLogs)
    case .shortcuts:
      SettingsModalKeyboardShortcutsSection(viewMode: effectiveViewMode)
    }
  }

  private var formattedDate: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    return formatter.string(from: Date())
  }
}

// MARK: - Editor Settings Section

struct SettingsModalEditorSection: View {
  @Bindable var appSettings: AppSettings
  let viewMode: ViewMode

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsToggle(
        title: "Enable Syntax Highlighting",
        description:
          "Colorize SQL keywords, functions, strings, and comments. Disable to improve performance with large files.",
        isOn: $appSettings.syntaxHighlightingEnabled
      )

      SettingsToggle(
        title: "Enable Autocomplete",
        description:
          "When enabled, SQL keywords, table names, and column names will be suggested as you type.",
        isOn: $appSettings.isAutoCompleteEnabled
      )

      // Show Line Numbers toggle (Editor mode only)
      SettingsToggle(
        title: "Show Line Numbers",
        description:
          "Display line numbers in the gutter. Helps with navigation and debugging queries. (Editor only)",
        isOn: $appSettings.showLineNumbers
      )

      // Word Wrap toggle (both modes)
      SettingsToggle(
        title: "Word Wrap",
        description:
          "Wrap long lines to fit the editor width. Use Option+Z to toggle quickly.",
        isOn: $appSettings.wordWrapEnabled
      )

      // Simple Mode toggle (Editor mode only)
      SettingsToggle(
        title: "Simple Mode",
        description:
          "When enabled, Run executes the selection or the current line. Otherwise, Run executes the selection or the entire file. (Editor only)",
        isOn: $appSettings.editorSimpleMode
      )
    }
  }
}

// MARK: - Result Table Settings Section

struct SettingsModalResultTableSection: View {
  @Bindable var appSettings: AppSettings
  let viewMode: ViewMode

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      // Hide Column Types toggle
      SettingsToggle(
        title: "Hide Column Types",
        description:
          "When enabled, column types (e.g., VARCHAR, INTEGER) will be hidden from table headers, showing only column names.",
        isOn: $appSettings.hideColumnTypes
      )

      // Hide Run with Query Section toggle
      SettingsToggle(
        title: "Hide Run with Query Section",
        description:
          "When enabled, the 'Run with query' section (with query text and download button) will be hidden from result tables.",
        isOn: $appSettings.hideRunWithQuerySection
      )

      SettingsToggle(
        title: "Commit Inline Edits Immediately",
        description:
          "When enabled, a cell edited in the result table is saved as soon as you press Enter. Otherwise, the edit waits in the pending transaction bar for Commit or Rollback.",
        isOn: $appSettings.inlineEditAutoCommit
      )

      // Max Height (Notebook only)
      SettingsSlider(
        title: "Max Height",
        valueText: "\(Int(appSettings.maxResultHeight)) pt",
        value: Binding(
          get: { Double(appSettings.maxResultHeight) },
          set: { appSettings.maxResultHeight = CGFloat($0) }
        ),
        range: 200...1000,
        step: 50,
        description:
          "Adjust the maximum height of result tables. Values between 200-1000 points. (Notebook only)"
      )

      // One row cap for Notebook and Editor
      ResultRowCapSetting(appSettings: appSettings)
    }
  }
}

// MARK: - Save Options Section

struct SettingsModalSaveOptionsSection: View {
  @Bindable var appSettings: AppSettings

  var body: some View {
    SettingsToggle(
      title: "Include Results When Saving",
      description:
        "When enabled, query results are saved with the notebook. Disable to reduce file size. (Notebook only)",
      isOn: $appSettings.includeResultsOnSave
    )
  }
}

// MARK: - Developer Settings Section

struct SettingsModalDeveloperSection: View {
  @Binding var isExportingLogs: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Export logs button
      Button(action: {
        isExportingLogs = true
      }) {
        HStack {
          Image(systemName: "square.and.arrow.up")
          Text("Export Application Logs")
        }
        .font(.bodyText)
        .foregroundColor(.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
        .background(Color.accent.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
      }
      .buttonStyle(.plain)
      .pointerStyle(.link)

      Text(
        "Export diagnostic logs to share with developers for troubleshooting. Logs include app activity and error messages."
      )
      .font(.small)
      .foregroundColor(.foregroundSubtle)
    }
  }
}

// MARK: - Keyboard Shortcuts Section

struct SettingsModalKeyboardShortcutsSection: View {
  let viewMode: ViewMode

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Custom keyboard shortcuts will be available in a future update.")
        .font(.small)
        .foregroundColor(.foregroundSubtle)

      // General shortcuts (both modes)
      generalShortcutsList

      Divider()
        .padding(.vertical, Spacing.xs)

      // Mode-specific shortcuts
      Text(viewMode == .notebook ? "Notebook Shortcuts" : "Editor Shortcuts")
        .font(.small)
        .fontWeight(.medium)
        .foregroundColor(.foregroundMuted)

      if viewMode == .notebook {
        notebookShortcutsList
      } else {
        editorShortcutsList
      }
    }
  }

  private var generalShortcutsList: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ShortcutRow(action: "New Notebook", shortcut: "Cmd+Shift+N")
      ShortcutRow(action: "New SQL File", shortcut: "Cmd+Shift+J")
      ShortcutRow(action: "Save As", shortcut: "Cmd+Shift+S")
      ShortcutRow(action: "Toggle Comment", shortcut: "Cmd+/")
      ShortcutRow(action: "Toggle Word Wrap", shortcut: "Option+Z")
      ShortcutRow(action: "Toggle Left Sidebar", shortcut: "Cmd+B")
      ShortcutRow(action: "Toggle Right Sidebar", shortcut: "Cmd+Shift+B")
    }
  }

  private var notebookShortcutsList: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ShortcutRow(action: "Add New Cell", shortcut: "Cmd+Option+N")
      ShortcutRow(action: "Run Cell", shortcut: "Ctrl+Enter")
      ShortcutRow(action: "Run Cell and Select Next", shortcut: "Shift+Enter")
      ShortcutRow(action: "Run Cell and Insert Below", shortcut: "Option+Enter")
      ShortcutRow(action: "Run All Cells", shortcut: "Cmd+Shift+Enter")
      ShortcutRow(action: "Delete Cell", shortcut: "Cmd+Delete")
      ShortcutRow(action: "Duplicate Cell", shortcut: "Cmd+D")
    }
  }

  private var editorShortcutsList: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ShortcutRow(action: "Run Query", shortcut: "Cmd+R / Cmd+Enter")
      ShortcutRow(action: "Find", shortcut: "Cmd+F")
      ShortcutRow(action: "Find Next", shortcut: "Cmd+G")
      ShortcutRow(action: "Find Previous", shortcut: "Cmd+Shift+G")
    }
  }
}

// MARK: - View Extension for Settings Modal

extension View {
  /// Shows a settings modal with zoom animation from center
  func settingsModal(
    isPresented: Binding<Bool>,
    viewMode: ViewMode?
  ) -> some View {
    modalOverlay(isPresented: isPresented) {
      SettingsModal(
        isPresented: isPresented,
        viewMode: viewMode
      )
    }
  }
}

// MARK: - WorkspaceManager Settings Modal Extension

extension View {
  /// Shows a settings modal bound to a WorkspaceManager
  func settingsModal(workspaceManager: WorkspaceManager) -> some View {
    self.settingsModal(
      isPresented: Binding(
        get: { workspaceManager.isSettingsModalVisible },
        set: { workspaceManager.isSettingsModalVisible = $0 }
      ),
      viewMode: workspaceManager.activeViewModel?.viewMode
    )
  }
}

// MARK: - Preview

#Preview("Settings Modal") {
  @Previewable @State var isPresented = true

  Color.appBackground
    .frame(width: 800, height: 700)
    .settingsModal(isPresented: $isPresented, viewMode: .notebook)
}

#Preview("Settings Modal - Editor Mode") {
  @Previewable @State var isPresented = true

  Color.appBackground
    .frame(width: 800, height: 700)
    .settingsModal(isPresented: $isPresented, viewMode: .editor)
}
