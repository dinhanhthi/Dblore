//
//  SettingsContent.swift
//  SQLNotebook
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsContent: View {
  @Bindable var viewModel: NotebookViewModel
  @Bindable var appSettings = AppSettings.shared
  @State private var showRemoveResultsConfirmation = false
  @State private var isExportingLogs = false
  @State private var showDisableReadOnlyConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      // Mode Selection - Moved to File menu (File > Switch to Notebook/Editor)
      // Use keyboard shortcuts: Cmd+Shift+1 (Notebook) / Cmd+Shift+2 (Editor)

      // Appearance Settings
      settingsSection(title: "Appearance", icon: "paintbrush.fill") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          // Theme Picker
          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.md) {
              ForEach(ThemePreference.allCases, id: \.self) { theme in
                Button(action: {
                  appSettings.themePreference = theme
                }) {
                  HStack(spacing: Spacing.xs) {
                    Image(
                      systemName: appSettings.themePreference == theme ? "circle.fill" : "circle"
                    )
                    .font(.system(size: 12))
                    .foregroundColor(
                      appSettings.themePreference == theme ? .accent : .foregroundMuted)

                    Text(theme.rawValue)
                      .font(.bodyText)
                      .foregroundColor(
                        appSettings.themePreference == theme ? .foreground : .foregroundMuted)
                  }
                  .padding(.vertical, Spacing.sm)
                }
                .buttonStyle(.plain)
              }
            }

            Text("Choose between Light, Dark, or System theme. System follows macOS appearance.")
              .font(.small)
              .foregroundColor(.foregroundSubtle)
          }
        }
      }

      Divider()

      // Editor Settings
      settingsSection(title: "Editor", icon: "text.cursor") {
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
              "When enabled, SQL keywords, table names, and column names will be suggested as you type. Works in both Notebook and Editor modes.",
            isOn: $appSettings.isAutoCompleteEnabled
          )

          // Show Line Numbers toggle (Editor mode only)
          if viewModel.viewMode == .editor {
            SettingsToggle(
              title: "Show Line Numbers",
              description:
                "Display line numbers in the gutter. Helps with navigation and debugging queries.",
              isOn: $appSettings.showLineNumbers
            )
          }

          // Word Wrap toggle (both modes)
          SettingsToggle(
            title: "Word Wrap",
            description: "Wrap long lines to fit the editor width. Use Option+Z to toggle quickly.",
            isOn: $appSettings.wordWrapEnabled
          )

          // Simple Mode toggle (Editor mode only)
          if viewModel.viewMode == .editor {
            SettingsToggle(
              title: "Simple Mode",
              description:
                "When enabled, Run executes the selection or the current line. Otherwise, Run executes the selection or the entire file.",
              isOn: $appSettings.editorSimpleMode
            )
          }
        }
      }

      Divider()

      // Result Table Settings (Notebook Mode Only)
      if viewModel.viewMode == .notebook {
        settingsSection(title: "Result Table", icon: "tablecells.fill") {
          VStack(alignment: .leading, spacing: Spacing.lg) {
            // Hide Run with Query Section toggle
            SettingsToggle(
              title: "Hide Run with Query Section",
              description:
                "When enabled, the 'Run with query' section (with query text and download button) will be hidden from result tables.",
              isOn: $appSettings.hideRunWithQuerySection
            )

            // Max Height
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
                "Adjust the maximum height of result tables. Values between 200-1000 points."
            )

            // Max Row Limit
            SettingsSlider(
              title: "Max Rows",
              valueText: "\(appSettings.maxRowLimit) rows",
              value: Binding(
                get: { Double(appSettings.maxRowLimit) },
                set: { appSettings.maxRowLimit = Int($0) }
              ),
              range: 50...100,
              step: 5,
              description: "Maximum rows to fetch from database. Values between 50-100 rows."
            )
          }
        }

        Divider()
      }

      // Result Table Settings (Editor Mode Only)
      if viewModel.viewMode == .editor {
        settingsSection(title: "Result Table", icon: "tablecells.fill") {
          VStack(alignment: .leading, spacing: Spacing.lg) {
            // Hide Run with Query Section toggle
            SettingsToggle(
              title: "Hide Run with Query Section",
              description:
                "When enabled, the 'Run with query' section (with query text and download button) will be hidden from result tables.",
              isOn: $appSettings.hideRunWithQuerySection
            )

            // Max Row Limit
            SettingsSlider(
              title: "Max Rows",
              valueText: "\(appSettings.editorMaxRowLimit) rows",
              value: Binding(
                get: { Double(appSettings.editorMaxRowLimit) },
                set: { appSettings.editorMaxRowLimit = Int($0) }
              ),
              range: 100...200,
              step: 10,
              description: "Maximum rows to fetch from database. Values between 100-200 rows."
            )
          }
        }

        Divider()
      }

      // Save Settings (Notebook Mode Only)
      if viewModel.viewMode == .notebook {
        settingsSection(title: "Save Options", icon: "square.and.arrow.down.fill") {
          SettingsToggle(
            title: "Include Results When Saving",
            description:
              "When enabled, query results are saved with the notebook. Disable to reduce file size.",
            isOn: $appSettings.includeResultsOnSave
          )
        }

        Divider()
      }

      // Security Settings
      settingsSection(title: "Security", icon: "lock.shield.fill") {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          SettingsToggle(
            title: "Bypass Destructive Query Confirmation",
            isOn: $appSettings.bypassDestructiveQueryConfirmation,
            isDisabled: viewModel.editingConnectionConfig.readOnly
          ) {
            SettingsToggleDescriptionWithAction(
              description:
                "When enabled, UPDATE, DELETE, and INSERT queries will execute immediately without confirmation. Not recommended for production databases.",
              warning: viewModel.editingConnectionConfig.readOnly
                ? "This option is disabled because connection is in read-only mode."
                : nil,
              actionTitle: viewModel.editingConnectionConfig.readOnly
                ? "Disable Read-only Mode"
                : nil,
              onAction: {
                showDisableReadOnlyConfirmation = true
              }
            )
          }

          // Connection History Size Setting
          SettingsSlider(
            title: "Connection History Size",
            valueText: "\(appSettings.maxConnectionHistorySize) connections",
            value: Binding(
              get: { Double(appSettings.maxConnectionHistorySize) },
              set: { appSettings.maxConnectionHistorySize = Int($0) }
            ),
            range: 0...5,
            step: 1
          ) {
            Text(
              appSettings.maxConnectionHistorySize == 0
                ? "Connection history is disabled. Passwords will not be saved."
                : "Store up to \(appSettings.maxConnectionHistorySize) recent connection(s). Passwords are securely stored in Keychain."
            )
            .font(.small)
            .foregroundColor(.foregroundSubtle)
          }
        }
      }
      .confirmationDialog(
        "Disable Read-only Mode?",
        isPresented: $showDisableReadOnlyConfirmation,
        titleVisibility: .visible
      ) {
        Button("Disable Read-only Mode", role: .destructive) {
          Task {
            await viewModel.disableReadOnlyMode()
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Are you sure you want to disable read-only mode? This will allow data modification queries (INSERT, UPDATE, DELETE, etc.) to execute."
        )
      }

      Divider()

      // File Optimization Settings (Notebook Mode Only)
      if viewModel.viewMode == .notebook {
        settingsSection(title: "File Optimization", icon: "gauge.with.dots.needle.bottom.50percent")
        {
          VStack(alignment: .leading, spacing: Spacing.md) {
            // Current file size display
            HStack {
              VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Current File Size")
                  .font(.subheading)
                  .foregroundColor(.foreground)

                Text(viewModel.formattedFileSize)
                  .font(.mono)
                  .foregroundColor(
                    viewModel.isFileSizeLarge
                      ? .destructive
                      : (viewModel.isFileSizeWarning ? .warning : .accent)
                  )
              }

              Spacer()

              if viewModel.isFileSizeLarge {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundColor(.destructive)
              } else if viewModel.isFileSizeWarning {
                Image(systemName: "exclamationmark.circle.fill")
                  .foregroundColor(.warning)
              }
            }
            .padding(Spacing.md)
            .background(Color.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))

            if viewModel.isFileSizeLarge || viewModel.isFileSizeWarning {
              Text(
                viewModel.isFileSizeLarge
                  ? "File size exceeds \(FileOptimizationService.formatFileSize(FileOptimizationService.largeSizeThreshold)) limit. Consider removing old results or creating a new notebook."
                  : "File size is approaching the recommended limit (\(FileOptimizationService.formatFileSize(FileOptimizationService.warningSizeThreshold)))."
              )
              .font(.small)
              .foregroundColor(viewModel.isFileSizeLarge ? .destructive : .warning)
            }

            // Manual cleanup button
            Button(action: {
              showRemoveResultsConfirmation = true
            }) {
              HStack {
                Image(systemName: "trash")
                Text("Remove All Results Now")
              }
              .font(.bodyText)
              .foregroundColor(.destructive)
              .frame(maxWidth: .infinity)
              .padding(.vertical, Spacing.sm)
              .background(Color.destructive.opacity(0.3))
              .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
            }
            .buttonStyle(.plain)
            .confirmationDialog(
              "Remove All Results?",
              isPresented: $showRemoveResultsConfirmation,
              titleVisibility: .visible
            ) {
              Button("Remove All Results", role: .destructive) {
                viewModel.clearAllOutputs()
              }
              Button("Cancel", role: .cancel) {}
            } message: {
              Text(
                "This will permanently remove all query results from the notebook. You'll need to re-run queries to see results again. This action cannot be undone."
              )
            }

            Text(
              "Removing results will significantly reduce file size but you'll need to re-run queries."
            )
            .font(.small)
            .foregroundColor(.foregroundSubtle)
          }
        }

        Divider()
      }

      // Developer Logs
      settingsSection(title: "Developer", icon: "hammer.fill") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          // Export logs button
          Button(action: {
            exportLogs()
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

          Text(
            "Export diagnostic logs to share with developers for troubleshooting. Logs include app activity and error messages."
          )
          .font(.small)
          .foregroundColor(.foregroundSubtle)
        }
      }

      Divider()

      // Keyboard Shortcuts (different shortcuts for each mode)
      settingsSection(title: "Keyboard Shortcuts", icon: "command") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          Text("Custom keyboard shortcuts will be available in a future update.")
            .font(.small)
            .foregroundColor(.foregroundSubtle)

          if viewModel.viewMode == .notebook {
            notebookKeyboardShortcutsList
          } else {
            editorKeyboardShortcutsList
          }
        }
      }
    }
    .padding(Spacing.md)
    .fileExporter(
      isPresented: $isExportingLogs,
      document: LogDocument(),
      contentType: .plainText,
      defaultFilename: "sqlnotebook-logs-\(formattedDate).txt"
    ) { result in
      // Export completed, no action needed
    }
  }

  private var formattedDate: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    return formatter.string(from: Date())
  }

  private func exportLogs() {
    isExportingLogs = true
  }

  @ViewBuilder
  private func settingsSection<Content: View>(
    title: String,
    icon: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: icon)
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(.foreground)

        Text(title)
          .font(.heading)
          .foregroundColor(.foreground)
      }

      content()
    }
  }

  private var notebookKeyboardShortcutsList: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      shortcutRow(action: "New Notebook", shortcut: "Cmd+Shift+N")
      shortcutRow(action: "New SQL File", shortcut: "Cmd+Shift+J")
      shortcutRow(action: "Save As", shortcut: "Cmd+Shift+S")
      shortcutRow(action: "Add New Cell", shortcut: "Cmd+Option+N")
      shortcutRow(action: "Run Cell", shortcut: "Ctrl+Enter")
      shortcutRow(action: "Run Cell and Select Next", shortcut: "Shift+Enter")
      shortcutRow(action: "Run Cell and Insert Below", shortcut: "Option+Enter")
      shortcutRow(action: "Run All Cells", shortcut: "Cmd+Shift+Enter")
      shortcutRow(action: "Toggle Comment", shortcut: "Cmd+/")
      shortcutRow(action: "Toggle Word Wrap", shortcut: "Option+Z")
      shortcutRow(action: "Delete Cell", shortcut: "Cmd+Delete")
      shortcutRow(action: "Duplicate Cell", shortcut: "Cmd+D")
      shortcutRow(action: "Toggle Left Sidebar", shortcut: "Cmd+B")
      shortcutRow(action: "Toggle Right Sidebar", shortcut: "Cmd+,")
    }
  }

  private var editorKeyboardShortcutsList: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      shortcutRow(action: "New Notebook", shortcut: "Cmd+Shift+N")
      shortcutRow(action: "New SQL File", shortcut: "Cmd+Shift+J")
      shortcutRow(action: "Save As", shortcut: "Cmd+Shift+S")
      shortcutRow(action: "Run Query", shortcut: "Cmd+R / Cmd+Enter")
      shortcutRow(action: "Toggle Comment", shortcut: "Cmd+/")
      shortcutRow(action: "Toggle Word Wrap", shortcut: "Option+Z")
      shortcutRow(action: "Find", shortcut: "Cmd+F")
      shortcutRow(action: "Find Next", shortcut: "Cmd+G")
      shortcutRow(action: "Find Previous", shortcut: "Cmd+Shift+G")
      shortcutRow(action: "Toggle Left Sidebar", shortcut: "Cmd+B")
      shortcutRow(action: "Toggle Right Sidebar", shortcut: "Cmd+,")
    }
  }

  private func shortcutRow(action: String, shortcut: String) -> some View {
    HStack {
      Text(action)
        .font(.bodyText)
        .foregroundColor(.foregroundMuted)

      Spacer()

      Text(shortcut)
        .font(.monoSmall)
        .foregroundColor(.foregroundSubtle)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
    }
  }
}

// MARK: - Settings Toggle Component

/// A reusable toggle component for settings with title and description
private struct SettingsToggle<DescriptionContent: View>: View {
  let title: String
  @Binding var isOn: Bool
  var isDisabled: Bool = false
  @ViewBuilder let descriptionContent: () -> DescriptionContent

  // Checkbox width + spacing to align description with label text
  private let checkboxIndent: CGFloat = 20

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Toggle(title, isOn: $isOn)
        .font(.bodyText)
        .foregroundColor(.foreground)
        .tint(.accent)
        .disabled(isDisabled)

      descriptionContent()
        .padding(.leading, checkboxIndent)
    }
  }
}

extension SettingsToggle where DescriptionContent == Text {
  /// Convenience initializer for simple text description
  init(
    title: String,
    description: String,
    isOn: Binding<Bool>,
    isDisabled: Bool = false
  ) {
    self.title = title
    self._isOn = isOn
    self.isDisabled = isDisabled
    self.descriptionContent = {
      Text(description)
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    }
  }
}

extension SettingsToggle where DescriptionContent == SettingsToggleDescription {
  /// Convenience initializer for description with optional warning
  init(
    title: String,
    description: String,
    warning: String?,
    isOn: Binding<Bool>,
    isDisabled: Bool = false
  ) {
    self.title = title
    self._isOn = isOn
    self.isDisabled = isDisabled
    self.descriptionContent = {
      SettingsToggleDescription(description: description, warning: warning)
    }
  }
}

/// Helper view for toggle description with optional warning
struct SettingsToggleDescription: View {
  let description: String
  let warning: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(description)
        .font(.small)
        .foregroundColor(.foregroundSubtle)

      if let warning = warning {
        HStack(alignment: .top, spacing: Spacing.xs) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.small)
          Text(warning)
        }
        .font(.small)
        .foregroundColor(.warning)
      }
    }
  }
}

/// Helper view for toggle description with optional warning and action button
struct SettingsToggleDescriptionWithAction: View {
  let description: String
  let warning: String?
  let actionTitle: String?
  let onAction: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text(description)
        .font(.small)
        .foregroundColor(.foregroundSubtle)

      if let warning = warning {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          HStack(alignment: .top, spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.small)
            Text(warning)
          }
          .font(.small)
          .foregroundColor(.warning)

          if let actionTitle = actionTitle, let onAction = onAction {
            Button(action: onAction) {
              Text(actionTitle)
                .font(.small)
                .foregroundColor(.white)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(Color.warning)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }
}

// MARK: - Settings Slider Component

/// A reusable slider component for settings with title, value display, and description
private struct SettingsSlider<DescriptionContent: View>: View {
  let title: String
  let valueText: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  @ViewBuilder let descriptionContent: () -> DescriptionContent

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        Text(title)
          .font(.subheading)
          .foregroundColor(.foreground)

        Spacer()

        Text(valueText)
          .font(.monoSmall)
          .foregroundColor(.foregroundMuted)
      }

      Slider(value: $value, in: range, step: step)
        .tint(.accent)

      descriptionContent()
    }
  }
}

extension SettingsSlider where DescriptionContent == Text {
  /// Convenience initializer for simple text description
  init(
    title: String,
    valueText: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    description: String
  ) {
    self.title = title
    self.valueText = valueText
    self._value = value
    self.range = range
    self.step = step
    self.descriptionContent = {
      Text(description)
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    }
  }
}

// MARK: - Log Document for Export

struct LogDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.plainText] }

  init() {}

  init(configuration: ReadConfiguration) throws {}

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    // Get logs from file (synchronous operation)
    let logContent = AppLogger.shared.getAllLogsText()
    let data = logContent.data(using: .utf8) ?? Data()
    return FileWrapper(regularFileWithContents: data)
  }
}

#Preview("Settings") {
  let viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .settings

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
