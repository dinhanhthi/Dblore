//
//  SettingsModal.swift
//  Dblore
//
//  Settings modal at workspace level - accessible via Cmd+,
//

import SwiftUI
import UniformTypeIdentifiers

/// A settings tab that another screen can request when it opens Settings.
enum SettingsPage: String {
  case ai
  case data

  static let userInfoKey = "settingsSection"
}

// MARK: - Settings Modal

/// Main settings modal for workspace level
/// Shows settings in a tabbed modal, one section per tab
struct SettingsModal: View {
  @Binding var isPresented: Bool
  let viewMode: ViewMode?
  let section: SettingsPage?
  let openToken: UUID

  @Bindable var appSettings = AppSettings.shared
  @State private var isExportingLogs = false
  @State private var selectedTab: SettingsTab

  init(
    isPresented: Binding<Bool>,
    viewMode: ViewMode?,
    section: SettingsPage? = nil,
    openToken: UUID = UUID()
  ) {
    _isPresented = isPresented
    self.viewMode = viewMode
    self.section = section
    self.openToken = openToken
    _selectedTab = State(initialValue: SettingsTab.tab(for: section))
  }

  /// Tabs shown in the settings tab row (rawValue = label)
  private enum SettingsTab: String, CaseIterable {
    case appearance = "Appearance"
    case editor = "Editor"
    case ai = "AI"
    case results = "Results"
    case save = "Save"
    case data = "Data"
    case developer = "Developer"
    case shortcuts = "Shortcuts"
    case updates = "Updates"

    /// SF Symbol shown next to the label in the navigation sidebar
    var icon: String {
      switch self {
      case .appearance: return "paintbrush"
      case .editor: return "text.cursor"
      case .ai: return "sparkles"
      case .results: return "tablecells"
      case .save: return "square.and.arrow.down"
      case .data: return "externaldrive"
      case .updates: return "arrow.triangle.2.circlepath"
      case .developer: return "wrench.and.screwdriver"
      case .shortcuts: return "keyboard"
      }
    }

    fileprivate static func tab(for section: SettingsPage?) -> SettingsTab {
      switch section {
      case .ai: .ai
      case .data: .data
      case nil: .appearance
      }
    }
  }

  /// Effective view mode - defaults to notebook if no active tab
  private var effectiveViewMode: ViewMode {
    viewMode ?? .notebook
  }

  var body: some View {
    GenericModal(
      title: "Settings",
      titleIcon: "gear",
      width: 720,
      height: 600,
      isPresented: $isPresented
    ) {
      HStack(spacing: 0) {
        // Navigation sidebar (fixed, does not scroll)
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          ForEach(SettingsTab.allCases, id: \.self) { tab in
            SettingsNavRow(
              title: tab.rawValue,
              icon: tab.icon,
              isSelected: selectedTab == tab,
              action: { selectedTab = tab }
            )
          }
          Spacer(minLength: 0)
        }
        .padding(Spacing.sm)
        .frame(width: 180)
        .frame(maxHeight: .infinity)
        .background(Color.cardHeaderBackground)

        Divider()

        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.lg) {
            Text(selectedTab.rawValue)
              .font(.heading)
              .foregroundColor(.foreground)

            selectedSection
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .fileExporter(
      isPresented: $isExportingLogs,
      document: LogDocument(),
      contentType: .plainText,
      defaultFilename: "dblore-logs-\(formattedDate).txt"
    ) { _ in
      // Export completed, no action needed
    }
    .onChange(of: openToken) { _, _ in
      guard let section else { return }
      selectedTab = SettingsTab.tab(for: section)
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
    case .ai:
      AISettingsSection()
    case .results:
      SettingsModalResultTableSection(
        appSettings: appSettings,
        viewMode: effectiveViewMode
      )
    case .save:
      // Save Options (Notebook Mode Only)
      SettingsModalSaveOptionsSection(appSettings: appSettings)
    case .data:
      DataSettingsSection()
    case .updates:
      SettingsModalUpdatesSection()
    case .developer:
      SettingsModalDeveloperSection(isExportingLogs: $isExportingLogs)
    case .shortcuts:
      SettingsModalKeyboardShortcutsSection()
    }
  }

  private var formattedDate: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    return formatter.string(from: Date())
  }
}

// MARK: - Settings Navigation Row

/// One row of the settings sidebar: icon + label, capsule fill when selected or hovered
private struct SettingsNavRow: View {
  let title: String
  let icon: String
  let isSelected: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: icon)
          .font(.labelText)
          .frame(width: 16)

        Text(title)
          .font(.bodyText)

        Spacer(minLength: 0)
      }
      .foregroundColor(isSelected ? .foreground : .foregroundMuted)
      .padding(.horizontal, Spacing.sm)
      .frame(height: 28)
      .background {
        Capsule()
          .fill(
            isSelected
              ? Color.accent.opacity(0.15)
              // cellBackgroundHover matches cardHeaderBackground, so the capsule disappears.
              : (isHovered ? Color.foreground.opacity(0.12) : Color.clear))
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .linkPointer()
    .onHover { isHovered = $0 }
  }
}

// MARK: - Editor Settings Section

struct SettingsModalEditorSection: View {
  @Bindable var appSettings: AppSettings
  let viewMode: ViewMode

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsSlider(
        title: "Font Size",
        valueText: "\(Int(appSettings.editorFontSize)) pt",
        value: Binding(
          get: { Double(appSettings.editorFontSize) },
          set: { appSettings.editorFontSize = CGFloat($0) }
        ),
        range: AppSettings.fontSizeRange,
        step: 1,
        description: "Size of the text in the SQL editor, including notebook cells."
      )

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

      SettingsToggle(
        title: "Side-by-Side Layout",
        description:
          "Open new .sql files with the editor on the left and results on the right instead of stacked. Toggle per file with the layout button in the header. (Editor only)",
        isOn: $appSettings.editorSideBySideDefault
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
      SettingsSlider(
        title: "Font Size",
        valueText: "\(Int(appSettings.resultFontSize)) pt",
        value: Binding(
          get: { Double(appSettings.resultFontSize) },
          set: { appSettings.resultFontSize = CGFloat($0) }
        ),
        range: AppSettings.fontSizeRange,
        step: 1,
        description: "Size of the text in result tables. Column headers stay the same."
      )

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

// MARK: - Updates Section

struct SettingsModalUpdatesSection: View {
  @ObservedObject private var updater = UpdaterController.shared

  var body: some View {
    SettingsToggle(
      title: "Automatically Check for Updates",
      description:
        "Check for new versions of Dblore in the background and offer to install them. You can always check now from the Dblore menu.",
      isOn: $updater.automaticallyChecksForUpdates
    )
  }
}

// MARK: - Developer Settings Section

struct SettingsModalDeveloperSection: View {
  @Binding var isExportingLogs: Bool
  @Bindable private var appSettings = AppSettings.shared

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      SettingsToggle(
        title: "Show experimental engines",
        description:
          "Include database engines that are not ready for general use in the connection form.",
        isOn: $appSettings.showExperimentalEngines
      )

      Button(action: {
        isExportingLogs = true
      }) {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "square.and.arrow.up")
          Text("Export Application Logs")
        }
      }
      .buttonStyle(FilledSecondaryButtonStyle())
      .linkPointer()

      Text(
        "Export diagnostic logs to share with developers for troubleshooting. Logs include app activity and error messages."
      )
      .font(.bodyText)
      .foregroundColor(.foregroundSubtle)
    }
  }
}

// MARK: - Keyboard Shortcuts Section

struct SettingsModalKeyboardShortcutsSection: View {
  /// Sub-tabs at the top of the page (rawValue = label)
  private enum ShortcutsTab: String, CaseIterable {
    case app = "App"
    case editor = "Editor"
  }

  @State private var selectedTab: ShortcutsTab = .app

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      CapsuleTabPicker(selection: $selectedTab, tabs: ShortcutsTab.allCases, height: 28)
        .frame(width: 200)

      Text("Custom keyboard shortcuts will be available in a future update.")
        .font(.bodyText)
        .foregroundColor(.foregroundSubtle)

      switch selectedTab {
      case .app:
        appShortcuts
      case .editor:
        editorShortcuts
      }
    }
  }

  private func groupTitle(_ title: String) -> some View {
    Text(title)
      .font(.bodyText)
      .fontWeight(.medium)
      .foregroundColor(.foreground)
  }

  private var appShortcuts: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      groupTitle("Files")
      ShortcutRow(action: "New Notebook", shortcut: "Cmd+Shift+N")
      ShortcutRow(action: "New SQL File", shortcut: "Cmd+Shift+J")
      ShortcutRow(action: "Open", shortcut: "Cmd+O")
      ShortcutRow(action: "Save", shortcut: "Cmd+S")
      ShortcutRow(action: "Save As", shortcut: "Cmd+Shift+S")

      Divider().padding(.vertical, Spacing.xs)

      groupTitle("Workspace")
      ShortcutRow(action: "New Workspace", shortcut: "Cmd+Ctrl+N")
      ShortcutRow(action: "Open Workspace", shortcut: "Cmd+Option+O")
      ShortcutRow(action: "Save Workspace", shortcut: "Cmd+Option+S")
      ShortcutRow(action: "Save Workspace As", shortcut: "Cmd+Option+Shift+S")
      ShortcutRow(action: "Close Workspace", shortcut: "Cmd+Option+W")

      Divider().padding(.vertical, Spacing.xs)

      groupTitle("Tabs")
      ShortcutRow(action: "Close Tab", shortcut: "Cmd+W")
      ShortcutRow(action: "Reopen Closed Tab", shortcut: "Cmd+Shift+T")
      ShortcutRow(action: "Next Tab", shortcut: "Cmd+Shift+]")
      ShortcutRow(action: "Previous Tab", shortcut: "Cmd+Shift+[")
      ShortcutRow(action: "Go to Tab 1-9", shortcut: "Cmd+1 ... Cmd+9")

      Divider().padding(.vertical, Spacing.xs)

      groupTitle("View")
      ShortcutRow(action: "Toggle Left Sidebar", shortcut: "Cmd+B")
      ShortcutRow(action: "Toggle Right Sidebar", shortcut: "Cmd+Shift+B")
      ShortcutRow(action: "Toggle AI Assistant", shortcut: "Cmd+L")

      Divider().padding(.vertical, Spacing.xs)

      groupTitle("AI")
      ShortcutRow(action: "Send Message", shortcut: "Return")
      ShortcutRow(action: "New Line in Message", shortcut: "Shift+Return")
    }
  }

  private var editorShortcuts: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      groupTitle("Editor")
      ShortcutRow(action: "Run Query", shortcut: "Cmd+R / Cmd+Enter")
      ShortcutRow(action: "Toggle Comment", shortcut: "Cmd+/")
      ShortcutRow(action: "Toggle Word Wrap", shortcut: "Option+Z")
      ShortcutRow(action: "Find", shortcut: "Cmd+F")
      ShortcutRow(action: "Find Next", shortcut: "Cmd+G")
      ShortcutRow(action: "Find Previous", shortcut: "Cmd+Shift+G")
      ShortcutRow(action: "Close Search", shortcut: "Esc")
      ShortcutRow(action: "Accept Autocomplete", shortcut: "Tab / Enter")
      ShortcutRow(action: "Dismiss Autocomplete", shortcut: "Esc")

      Divider().padding(.vertical, Spacing.xs)

      groupTitle("Notebook Cells")
      ShortcutRow(action: "Add New Cell", shortcut: "Cmd+Option+N")
      ShortcutRow(action: "Run Cell", shortcut: "Ctrl+Enter")
      ShortcutRow(action: "Run Cell and Select Next", shortcut: "Shift+Enter")
      ShortcutRow(action: "Run Cell and Insert Below", shortcut: "Option+Enter")
      ShortcutRow(action: "Run All Cells", shortcut: "Cmd+Shift+Enter")
      ShortcutRow(action: "Delete Cell", shortcut: "Cmd+Delete")
      ShortcutRow(action: "Duplicate Cell", shortcut: "Cmd+D")
      ShortcutRow(
        action: "Undo / Redo Cell Change", shortcut: "Cmd+Z / Cmd+Shift+Z outside the editor")
      ShortcutRow(action: "Previous / Next Cell", shortcut: "Up / Down at first / last line")
    }
  }
}

// MARK: - View Extension for Settings Modal

extension View {
  /// Shows a settings modal with zoom animation from center
  func settingsModal(
    isPresented: Binding<Bool>,
    viewMode: ViewMode?,
    section: SettingsPage? = nil,
    openToken: UUID = UUID()
  ) -> some View {
    modalOverlay(isPresented: isPresented) {
      SettingsModal(
        isPresented: isPresented,
        viewMode: viewMode,
        section: section,
        openToken: openToken
      )
    }
  }
}

// MARK: - WorkspaceManager Settings Modal Extension

extension View {
  /// Shows a settings modal bound to a WorkspaceManager
  func settingsModal(
    workspaceManager: WorkspaceManager,
    section: SettingsPage? = nil,
    openToken: UUID = UUID()
  ) -> some View {
    self.settingsModal(
      isPresented: Binding(
        get: { workspaceManager.isSettingsModalVisible },
        set: { workspaceManager.isSettingsModalVisible = $0 }
      ),
      viewMode: workspaceManager.activeViewModel?.viewMode,
      section: section,
      openToken: openToken
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
