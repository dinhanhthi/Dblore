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
  case security
  case results

  static let userInfoKey = "settingsSection"
}

/// A single option another screen can ask Settings to highlight briefly.
enum SettingsOption: String {
  case inlineEditAutoCommit

  static let userInfoKey = "settingsHighlight"
}

// MARK: - Settings Modal

/// Main settings modal for workspace level
/// Shows settings in a tabbed modal, one section per tab
struct SettingsModal: View {
  @Binding var isPresented: Bool
  let viewMode: ViewMode?
  var viewModel: NotebookViewModel?
  let section: SettingsPage?
  let highlight: SettingsOption?
  let openToken: UUID

  @Bindable var appSettings = AppSettings.shared
  @State private var isExportingLogs = false
  @State private var selectedTab: SettingsTab
  @State private var highlightedOption: SettingsOption?

  init(
    isPresented: Binding<Bool>,
    viewMode: ViewMode?,
    viewModel: NotebookViewModel? = nil,
    section: SettingsPage? = nil,
    highlight: SettingsOption? = nil,
    openToken: UUID = UUID()
  ) {
    _isPresented = isPresented
    self.viewMode = viewMode
    self.viewModel = viewModel
    self.section = section
    self.highlight = highlight
    self.openToken = openToken
    _selectedTab = State(initialValue: SettingsTab.tab(for: section))
  }

  /// Tabs shown in the settings tab row (rawValue = label)
  private enum SettingsTab: String, CaseIterable {
    case general = "General"
    case appearance = "Appearance"
    case editor = "Editor"
    case ai = "AI"
    case results = "Results"
    case save = "Save"
    case data = "Data"
    case security = "Security"
    case developer = "Developer"
    case shortcuts = "Shortcuts"

    /// SF Symbol shown next to the label in the navigation sidebar
    var icon: String {
      switch self {
      case .general: return "gearshape"
      case .appearance: return "paintbrush"
      case .editor: return "text.cursor"
      case .ai: return "sparkles"
      case .results: return "tablecells"
      case .save: return "square.and.arrow.down"
      case .data: return "externaldrive"
      case .security: return "lock.shield"
      case .developer: return "wrench.and.screwdriver"
      case .shortcuts: return "keyboard"
      }
    }

    fileprivate static func tab(for section: SettingsPage?) -> SettingsTab {
      switch section {
      case .ai: .ai
      case .data: .data
      case .security: .security
      case .results: .results
      case nil: .general
      }
    }
  }

  /// Effective view mode - defaults to notebook if no active tab
  private var effectiveViewMode: ViewMode {
    viewMode ?? .notebook
  }

  var body: some View {
    GenericModal(
      title: "Settings - \(selectedTab.rawValue)",
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
    // Highlight the requested option for a moment, then fade it out
    .task(id: openToken) {
      withAnimation(.easeIn(duration: 0.2)) { highlightedOption = highlight }
      guard highlight != nil else { return }
      try? await Task.sleep(for: .seconds(2.5))
      withAnimation(.easeOut(duration: 0.6)) { highlightedOption = nil }
    }
  }

  /// Section view for the selected tab
  @ViewBuilder
  private var selectedSection: some View {
    switch selectedTab {
    case .general:
      GeneralSettingsSection(appSettings: appSettings)
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
        viewMode: effectiveViewMode,
        highlightedOption: highlightedOption
      )
    case .save:
      // Save Options (Notebook Mode Only)
      SettingsModalSaveOptionsSection(appSettings: appSettings)
    case .data:
      DataSettingsSection()
    case .security:
      if let viewModel {
        SecuritySettingsSection(appSettings: appSettings, viewModel: viewModel)
      } else {
        Text("Open a tab to change protection and security for this connection.")
          .font(.bodyText)
          .foregroundColor(.foregroundSubtle)
      }
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
      SettingsGroupCard(title: "Text") {
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
      }

      SettingsGroupCard(title: "Editing") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          SettingsToggle(
            title: "Enable Syntax Highlighting",
            description:
              "Colorize SQL keywords, functions, strings, and comments. Disable to improve performance with large files.",
            isOn: $appSettings.syntaxHighlightingEnabled
          )
          Divider()
          SettingsToggle(
            title: "Enable Autocomplete",
            description:
              "When enabled, SQL keywords, table names, and column names will be suggested as you type.",
            isOn: $appSettings.isAutoCompleteEnabled
          )
          Divider()
          SettingsToggle(
            title: "Show Line Numbers",
            description:
              "Display line numbers in the gutter. Helps with navigation and debugging queries. (Editor only)",
            isOn: $appSettings.showLineNumbers
          )
          Divider()
          SettingsToggle(
            title: "Word Wrap",
            description:
              "Wrap long lines to fit the editor width. Use Option+Z to toggle quickly.",
            isOn: $appSettings.wordWrapEnabled
          )
          Divider()
          SettingsToggle(
            title: "Side-by-Side Layout",
            description:
              "Open new .sql files with the editor on the left and results on the right instead of stacked. Toggle per file with the layout button in the header. (Editor only)",
            isOn: $appSettings.editorSideBySideDefault
          )
          Divider()
          SettingsToggle(
            title: "Simple Mode",
            description:
              "When enabled, Run executes the selection or the current line. Otherwise, Run executes the selection or the entire file. (Editor only)",
            isOn: $appSettings.editorSimpleMode
          )
        }
      }
    }
  }
}

// MARK: - Result Table Settings Section

struct SettingsModalResultTableSection: View {
  @Bindable var appSettings: AppSettings
  let viewMode: ViewMode
  var highlightedOption: SettingsOption?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsGroupCard(title: "Text") {
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
      }

      SettingsGroupCard(title: "Table") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          SettingsToggle(
            title: "Hide Column Types",
            description:
              "When enabled, column types (e.g., VARCHAR, INTEGER) will be hidden from table headers, showing only column names.",
            isOn: $appSettings.hideColumnTypes
          )
          Divider()
          SettingsToggle(
            title: "Hide Run with Query Section",
            description:
              "When enabled, the 'Run with query' section (with query text and download button) will be hidden from result tables.",
            isOn: $appSettings.hideRunWithQuerySection
          )
          Divider()
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
          Divider()
          ResultRowCapSetting(appSettings: appSettings)
        }
      }

      SettingsGroupCard(title: "Editing") {
        SettingsToggle(
          title: "Commit Inline Edits Immediately",
          description:
            "When enabled, a cell edited in the result table is saved as soon as you press Enter. Otherwise, the edit waits in the pending transaction bar for Commit or Rollback.",
          isOn: $appSettings.inlineEditAutoCommit
        )
        .padding(Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: CornerRadius.lg)
            .fill(Color.accent.opacity(highlightedOption == .inlineEditAutoCommit ? 0.15 : 0))
        )
        .padding(-Spacing.sm)
      }
    }
  }
}

// MARK: - Save Options Section

struct SettingsModalSaveOptionsSection: View {
  @Bindable var appSettings: AppSettings

  var body: some View {
    SettingsGroupCard(title: "Notebook") {
      SettingsToggle(
        title: "Include Results When Saving",
        description:
          "When enabled, query results are saved with the notebook. Disable to reduce file size. (Notebook only)",
        isOn: $appSettings.includeResultsOnSave
      )
    }
  }
}

// MARK: - Developer Settings Section

struct SettingsModalDeveloperSection: View {
  @Binding var isExportingLogs: Bool
  @Bindable private var appSettings = AppSettings.shared

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsGroupCard(title: "Connection form") {
        SettingsToggle(
          title: "Show experimental engines",
          description:
            "Include database engines that are not ready for general use in the connection form.",
          isOn: $appSettings.showExperimentalEngines
        )
      }

      SettingsGroupCard(title: "Logs") {
        VStack(alignment: .leading, spacing: Spacing.md) {
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
    VStack(alignment: .leading, spacing: Spacing.lg) {
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

  private func shortcutCard(
    _ title: String, _ rows: [(action: String, shortcut: String)]
  )
    -> some View
  {
    SettingsGroupCard(title: title) {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          ShortcutRow(action: row.action, shortcut: row.shortcut)
        }
      }
    }
  }

  private var appShortcuts: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      shortcutCard(
        "Files",
        [
          ("New Tab (Notebook or SQL File, see General)", "Cmd+T"),
          ("New SQL File", "Cmd+Shift+J"),
          ("Open", "Cmd+O"),
          ("Save", "Cmd+S"),
          ("Save As", "Cmd+Shift+S"),
        ]
      )
      shortcutCard(
        "Workspace",
        [
          ("New Workspace", "Cmd+Ctrl+N"),
          ("Open Workspace", "Cmd+Option+O"),
          ("Save Workspace", "Cmd+Option+S"),
          ("Save Workspace As", "Cmd+Option+Shift+S"),
          ("Close Workspace", "Cmd+Option+W"),
        ]
      )
      shortcutCard(
        "Tabs",
        [
          ("Close Tab", "Cmd+W"),
          ("Reopen Closed Tab", "Cmd+Shift+T"),
          ("Next Tab", "Cmd+Shift+]"),
          ("Previous Tab", "Cmd+Shift+["),
          ("Go to Tab 1-9", "Cmd+1 ... Cmd+9"),
        ]
      )
      shortcutCard(
        "View",
        [
          ("Settings", "Cmd+,"),
          ("Toggle Left Sidebar", "Cmd+B"),
          ("Toggle Right Sidebar", "Cmd+Shift+B"),
          ("Toggle AI Assistant", "Cmd+L"),
        ]
      )
      shortcutCard(
        "AI",
        [
          ("Send Message", "Return"),
          ("New Line in Message", "Shift+Return"),
        ]
      )
    }
  }

  private var editorShortcuts: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      shortcutCard(
        "Editor",
        [
          ("Run Query", "Cmd+R / Cmd+Enter"),
          ("Toggle Comment", "Cmd+/"),
          ("Toggle Word Wrap", "Option+Z"),
          ("Find", "Cmd+F"),
          ("Find Next", "Cmd+G"),
          ("Find Previous", "Cmd+Shift+G"),
          ("Close Search", "Esc"),
          ("Accept Autocomplete", "Tab / Enter"),
          ("Dismiss Autocomplete", "Esc"),
        ]
      )
      shortcutCard(
        "Notebook Cells",
        [
          ("Add New Cell", "Cmd+Option+N"),
          ("Run Cell", "Ctrl+Enter"),
          ("Run Cell and Select Next", "Shift+Enter"),
          ("Run Cell and Insert Below", "Option+Enter"),
          ("Run All Cells", "Cmd+Shift+Enter"),
          ("Delete Cell", "Cmd+Delete"),
          ("Duplicate Cell", "Cmd+D"),
          ("Undo / Redo Cell Change", "Cmd+Z / Cmd+Shift+Z outside the editor"),
          ("Previous / Next Cell", "Up / Down at first / last line"),
        ]
      )
      shortcutCard(
        "View",
        [
          ("Settings", "Cmd+,")
        ]
      )
    }
  }
}

// MARK: - View Extension for Settings Modal

extension View {
  /// Shows a settings modal with zoom animation from center
  func settingsModal(
    isPresented: Binding<Bool>,
    viewMode: ViewMode?,
    viewModel: NotebookViewModel? = nil,
    section: SettingsPage? = nil,
    highlight: SettingsOption? = nil,
    openToken: UUID = UUID()
  ) -> some View {
    modalOverlay(isPresented: isPresented) {
      SettingsModal(
        isPresented: isPresented,
        viewMode: viewMode,
        viewModel: viewModel,
        section: section,
        highlight: highlight,
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
    highlight: SettingsOption? = nil,
    openToken: UUID = UUID()
  ) -> some View {
    self.settingsModal(
      isPresented: Binding(
        get: { workspaceManager.isSettingsModalVisible },
        set: { workspaceManager.isSettingsModalVisible = $0 }
      ),
      viewMode: workspaceManager.activeViewModel?.viewMode,
      viewModel: workspaceManager.activeViewModel,
      section: section,
      highlight: highlight,
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
