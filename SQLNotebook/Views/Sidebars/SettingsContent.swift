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
  @State private var scrollToSafeMode: Bool = false

  var body: some View {
    ScrollViewReader { proxy in
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

            Divider()
              .padding(.vertical, Spacing.xs)

            // Accent Color Picker
            VStack(alignment: .leading, spacing: Spacing.xs) {
              HStack(spacing: Spacing.md) {
                ForEach(AccentColor.allCases, id: \.self) { color in
                  Button(action: {
                    appSettings.accentColor = color
                  }) {
                    Circle()
                      .fill(Color(hex: color.darkHex))
                      .frame(width: 20, height: 20)
                      .overlay(
                        Circle()
                          .stroke(
                            appSettings.accentColor == color
                              ? Color.foreground : Color.clear,
                            lineWidth: 2
                          )
                          .frame(width: 26, height: 26)
                      )
                      .padding(Spacing.xs)
                  }
                  .buttonStyle(.plain)
                  .help(color.rawValue)
                }
              }

              Text("Choose the main color for buttons, links, and syntax highlighting.")
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
              description:
                "Wrap long lines to fit the editor width. Use Option+Z to toggle quickly.",
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
            // Safe Mode Picker
            SafeModePicker(appSettings: appSettings, viewModel: viewModel)
              .id("safeModeSection")

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

            // Read-only Mode Warning
            if viewModel.editingConnectionConfig.readOnly {
              HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: "lock.fill")
                  .foregroundColor(.warning)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                  Text("Read-Only Mode Active")
                    .font(.subheading)
                    .foregroundColor(.warning)
                  Text("Modification queries are blocked regardless of Safe Mode level.")
                    .font(.small)
                    .foregroundColor(.foregroundSubtle)
                  Button(action: {
                    showDisableReadOnlyConfirmation = true
                  }) {
                    Text("Disable Read-only Mode")
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
              .padding(Spacing.md)
              .background(Color.warning.opacity(0.1))
              .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
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
          settingsSection(
            title: "File Optimization", icon: "gauge.with.dots.needle.bottom.50percent"
          ) {
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
      .onReceive(NotificationCenter.default.publisher(for: .scrollToSafeModeSettings)) { _ in
        withAnimation(.easeInOut(duration: 0.4)) {
          // Use custom anchor with slight offset from top (0.15 = 15% from top)
          proxy.scrollTo("safeModeSection", anchor: UnitPoint(x: 0.5, y: 0.15))
        }
      }
    }
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

// MARK: - Safe Mode Picker Component

/// Dialog mode for password setup sheet
private enum PasswordDialogMode {
  case password
  case biometric
}

/// Action that requires authentication
private enum ProtectedAction {
  case changeSafeMode(SafeMode)
  case removeProtection
  case switchToPassword  // Switch from Touch ID to password
  case switchToBiometric  // Switch from password to Touch ID
}

/// A picker component for Safe Mode levels with password management
private struct SafeModePicker: View {
  @Bindable var appSettings: AppSettings
  let viewModel: NotebookViewModel  // For accessing database password
  @State private var showPasswordSetup: Bool = false
  @State private var currentPassword: String = ""  // For verifying current password when changing
  @State private var newPassword: String = ""
  @State private var confirmPassword: String = ""
  @State private var passwordError: String?
  @State private var dialogMode: PasswordDialogMode = .password
  @State private var activeDialogMode: PasswordDialogMode = .password  // Captured when sheet opens
  @State private var refreshTrigger: UUID = UUID()  // Force UI refresh
  @State private var isChangingPassword: Bool = false  // Track if we're changing existing password
  @State private var useDbPasswordForChange: Bool = false  // Forgot password mode for change password

  // Authentication for protected actions
  @State private var showAuthSheet: Bool = false
  @State private var pendingAction: ProtectedAction?
  @State private var authPassword: String = ""
  @State private var authError: String?
  @State private var isAuthenticating: Bool = false
  @State private var useDbPasswordForAuth: Bool = false  // Forgot password mode for auth

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Safe Mode Picker Label
      Text("Safe Mode")
        .font(.subheading)
        .foregroundColor(.foreground)

      // Mode Selection with descriptions
      VStack(alignment: .leading, spacing: 0) {
        ForEach(SafeMode.allCases, id: \.self) { mode in
          safeModeOption(mode)
        }
      }
    }
    .id(refreshTrigger)  // Force refresh when trigger changes
    .sheet(isPresented: $showPasswordSetup) {
      passwordSetupSheet
        .onAppear {
          // Capture the dialog mode when sheet opens - this prevents mode switching during editing
          activeDialogMode = dialogMode
        }
    }
    .sheet(isPresented: $showAuthSheet) {
      authenticationSheet
        .onAppear {
          authPassword = ""
          authError = nil
          isAuthenticating = false
        }
    }
  }

  @ViewBuilder
  private func safeModeOption(_ mode: SafeMode) -> some View {
    let isSelected = appSettings.safeMode == mode

    VStack(alignment: .leading, spacing: 0) {
      // Mode selection button
      Button(action: {
        // Check if current mode is protected and user is trying to change it
        if appSettings.safeMode.requiresPassword && appSettings.isSafeModePasswordSet
          && mode != appSettings.safeMode
        {
          // Require authentication before changing mode
          pendingAction = .changeSafeMode(mode)
          showAuthSheet = true
        } else {
          withAnimation(.snappy(duration: 0.2)) {
            appSettings.safeMode = mode
          }
        }
      }) {
        HStack(alignment: .top, spacing: Spacing.sm) {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundColor(isSelected ? .accent : .foregroundMuted)
            .font(.system(size: 16))

          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.xs) {
              Text(mode.displayName)
                .font(.bodyText)
                .foregroundColor(isSelected ? .foreground : .foregroundMuted)

              if mode.requiresPassword {
                Image(systemName: "lock.fill")
                  .font(.system(size: 10))
                  .foregroundColor(.foregroundSubtle)
              }
            }

            // Short description for each mode
            Text(mode.shortDescription)
              .font(.small)
              .foregroundColor(.foregroundSubtle)
          }

          Spacer()
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Password panel - shown indented under selected Safe mode options
      if isSelected && mode.requiresPassword {
        passwordManagementPanel
          .padding(.leading, Spacing.lg + Spacing.sm)
          .padding(.bottom, Spacing.sm)
      }
    }
  }

  private var passwordManagementPanel: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // Status header
      HStack(spacing: Spacing.xs) {
        Image(systemName: appSettings.isSafeModePasswordSet ? "lock.fill" : "lock.open.fill")
          .font(.system(size: 12))
          .foregroundColor(appSettings.isSafeModePasswordSet ? .accent : .warning)
        Text(appSettings.isSafeModePasswordSet ? "Password Protected" : "No Password Set")
          .font(.small)
          .fontWeight(.medium)
          .foregroundColor(appSettings.isSafeModePasswordSet ? .foreground : .warning)
      }

      if !appSettings.isSafeModePasswordSet {
        Text("Set a password or use Touch ID to enable protection.")
          .font(.small)
          .foregroundColor(.foregroundSubtle)
      }

      // Action buttons
      HStack(spacing: Spacing.md) {
        // Set Password button
        // - If Touch ID is enabled: require Touch ID auth first, then show password setup
        // - If password is enabled: show password setup directly (to change)
        // - If nothing is set: show password setup directly
        Button(action: {
          if appSettings.isBiometricEnabled {
            // Touch ID is enabled - require auth first before switching to password
            pendingAction = .switchToPassword
            showAuthSheet = true
          } else {
            // No protection or password mode - show password setup directly
            dialogMode = .password
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
            passwordError = nil
            // Track if we're changing an existing password
            isChangingPassword = appSettings.hasCustomPasswordSet
            showPasswordSetup = true
          }
        }) {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "key.fill")
              .font(.system(size: 10))
            // Show "Change" if custom password is set (not biometric), otherwise "Set Password"
            Text(appSettings.hasCustomPasswordSet ? "Change" : "Set Password")
          }
          .font(.small)
          .foregroundColor(.accent)
        }
        .buttonStyle(.plain)

        // Touch ID button
        // - If password is enabled: require password auth first, then enable Touch ID
        // - If Touch ID is already enabled: do nothing (already active)
        // - If nothing is set: show Touch ID setup directly
        if !appSettings.isBiometricEnabled {
          Button(action: {
            if appSettings.isSafeModePasswordSet && !appSettings.isBiometricEnabled {
              // Password is enabled - require auth first before switching to Touch ID
              pendingAction = .switchToBiometric
              showAuthSheet = true
            } else {
              // No protection - show Touch ID setup directly
              dialogMode = .biometric
              newPassword = ""
              confirmPassword = ""
              passwordError = nil
              showPasswordSetup = true
            }
          }) {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "touchid")
                .font(.system(size: 10))
              Text("Use Touch ID")
            }
            .font(.small)
            .foregroundColor(.accent)
          }
          .buttonStyle(.plain)
        }

        // Remove button (only if protection is set)
        if appSettings.isSafeModePasswordSet {
          Button(action: {
            // Require authentication before removing protection
            pendingAction = .removeProtection
            showAuthSheet = true
          }) {
            Text("Remove")
              .font(.small)
              .foregroundColor(.destructive)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(Spacing.sm)
    .background(Color.inputBackground.opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
  }

  private var passwordSetupSheet: some View {
    VStack(spacing: Spacing.lg) {
      // Use activeDialogMode which is captured when sheet opens
      // This prevents the view from switching while user is interacting
      switch activeDialogMode {
      case .biometric:
        // Touch ID / Biometric setup
        biometricSetupContent
      case .password:
        // Password setup
        passwordSetupContent
      }
    }
    .padding(Spacing.xl)
    .frame(width: 350)
    .background(Color.appBackground)
  }

  private var passwordSetupContent: some View {
    VStack(spacing: Spacing.lg) {
      Text(isChangingPassword ? "Change Safe Mode Password" : "Set Safe Mode Password")
        .font(.heading)
        .foregroundColor(.foreground)

      VStack(alignment: .leading, spacing: Spacing.md) {
        // Current password field - only shown when changing existing password
        if isChangingPassword {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
              Text(
                useDbPasswordForChange ? "Database Password" : "Current Password"
              )
              .font(.bodyText)
              .foregroundColor(.foreground)

              Spacer()

              // Forgot password option - only show when connected
              if viewModel.connectionState == .connected {
                Button(action: {
                  useDbPasswordForChange.toggle()
                  currentPassword = ""
                  passwordError = nil
                }) {
                  Text(useDbPasswordForChange ? "Use Safe Mode Password" : "Forgot Password?")
                    .font(.small)
                    .foregroundColor(.accent)
                }
                .buttonStyle(.plain)
              }
            }
            SecureField(
              useDbPasswordForChange ? "Enter database password" : "Enter current password",
              text: $currentPassword
            )
            .textFieldStyle(.roundedBorder)

            if useDbPasswordForChange {
              Text("Using database connection password to verify your identity.")
                .font(.small)
                .foregroundColor(.foregroundSubtle)
            }
          }
        }

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("New Password")
            .font(.bodyText)
            .foregroundColor(.foreground)
          SecureField("Enter password", text: $newPassword)
            .textFieldStyle(.roundedBorder)
        }

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Confirm Password")
            .font(.bodyText)
            .foregroundColor(.foreground)
          SecureField("Confirm password", text: $confirmPassword)
            .textFieldStyle(.roundedBorder)
        }

        if let error = passwordError {
          Text(error)
            .font(.small)
            .foregroundColor(.destructive)
        }
      }

      HStack(spacing: Spacing.md) {
        Button("Cancel") {
          showPasswordSetup = false
          useDbPasswordForChange = false
        }
        .buttonStyle(.plain)
        .foregroundColor(.foregroundMuted)

        Button("Save Password") {
          savePassword()
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          newPassword.isEmpty || confirmPassword.isEmpty
            || (isChangingPassword && currentPassword.isEmpty))
      }
    }
  }

  private var biometricSetupContent: some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "touchid")
        .font(.system(size: 48))
        .foregroundColor(.accent)

      Text("Enable Touch ID")
        .font(.heading)
        .foregroundColor(.foreground)

      Text("Use Touch ID or your macOS password to authorize queries in Safe Mode.")
        .font(.bodyText)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)

      if let error = passwordError {
        Text(error)
          .font(.small)
          .foregroundColor(.destructive)
      }

      HStack(spacing: Spacing.md) {
        Button("Cancel") {
          showPasswordSetup = false
        }
        .buttonStyle(.plain)
        .foregroundColor(.foregroundMuted)

        Button("Enable Touch ID") {
          enableBiometric()
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }

  private func savePassword() {
    // Verify current password if changing existing password
    if isChangingPassword {
      if useDbPasswordForChange {
        // Verify using database password
        guard currentPassword == viewModel.editingConnectionConfig.password else {
          passwordError = "Incorrect database password"
          return
        }
      } else {
        // Verify using Safe Mode password
        guard appSettings.verifySafeModePassword(currentPassword) else {
          passwordError = "Current password is incorrect"
          return
        }
      }
    }

    guard !newPassword.isEmpty else {
      passwordError = "Password cannot be empty"
      return
    }

    guard newPassword == confirmPassword else {
      passwordError = "Passwords do not match"
      return
    }

    guard newPassword.count >= 4 else {
      passwordError = "Password must be at least 4 characters"
      return
    }

    appSettings.safeModePassword = newPassword
    showPasswordSetup = false
    isChangingPassword = false
    useDbPasswordForChange = false
    // Force UI refresh to show updated password status
    refreshTrigger = UUID()
  }

  private func enableBiometric() {
    Task {
      do {
        try await appSettings.enableBiometricAuth()
        await MainActor.run {
          showPasswordSetup = false
          // Force UI refresh to show updated password status
          refreshTrigger = UUID()
        }
      } catch {
        await MainActor.run {
          // Check if user cancelled authentication
          // LAError codes: userCancel = -2, systemCancel = -4, appCancel = -9
          let nsError = error as NSError
          let isCancelled =
            nsError.code == -2 || nsError.code == -4 || nsError.code == -9
            || nsError.localizedDescription.lowercased().contains("cancel")

          if isCancelled {
            // User cancelled - show message prompting to try again (don't close dialog)
            passwordError = "Authentication cancelled. Tap 'Enable Touch ID' to try again."
            return
          }
          // Show other errors
          passwordError = error.localizedDescription
        }
      }
    }
  }

  // MARK: - Authentication Sheet for Protected Actions

  private var authenticationSheet: some View {
    VStack(spacing: Spacing.lg) {
      // Header with action-specific message
      HStack {
        Image(systemName: "lock.shield.fill")
          .font(.title)
          .foregroundColor(.accent)
        Text(authenticationTitle)
          .font(.heading)
          .foregroundColor(.foreground)
      }

      // Authentication options
      if appSettings.isBiometricEnabled && !useDbPasswordForAuth {
        // Touch ID / Biometric option
        VStack(spacing: Spacing.md) {
          Button(action: {
            authenticateForAction()
          }) {
            HStack(spacing: Spacing.sm) {
              if isAuthenticating {
                ProgressView()
                  .scaleEffect(0.8)
              } else {
                Image(systemName: "touchid")
                  .font(.title)
              }
              Text(isAuthenticating ? "Authenticating..." : "Use Touch ID")
                .font(.bodyText)
            }
            .foregroundColor(.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
            .background(Color.accent.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
          }
          .buttonStyle(.plain)
          .disabled(isAuthenticating)

          // Forgot password option for biometric - switch to database password
          if viewModel.connectionState == .connected {
            Button(action: {
              useDbPasswordForAuth = true
              authError = nil
            }) {
              Text("Use Database Password Instead")
                .font(.small)
                .foregroundColor(.accent)
            }
            .buttonStyle(.plain)
          }

          if let error = authError {
            Text(error)
              .font(.small)
              .foregroundColor(.destructive)
          }
        }
      } else {
        // Password entry (Safe Mode password or database password)
        VStack(alignment: .leading, spacing: Spacing.sm) {
          HStack {
            Text(
              useDbPasswordForAuth
                ? "Enter database password:" : "Enter Safe Mode password:"
            )
            .font(.bodyText)
            .foregroundColor(.foreground)

            Spacer()

            // Forgot password option - only show when connected and not already using db password
            if viewModel.connectionState == .connected && !appSettings.isBiometricEnabled {
              Button(action: {
                useDbPasswordForAuth.toggle()
                authPassword = ""
                authError = nil
              }) {
                Text(useDbPasswordForAuth ? "Use Safe Mode Password" : "Forgot Password?")
                  .font(.small)
                  .foregroundColor(.accent)
              }
              .buttonStyle(.plain)
            }
          }

          SecureField("Password", text: $authPassword)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              verifyPasswordForAction()
            }

          if useDbPasswordForAuth {
            Text("Using database connection password to verify your identity.")
              .font(.small)
              .foregroundColor(.foregroundSubtle)
          }

          if let error = authError {
            Text(error)
              .font(.small)
              .foregroundColor(.destructive)
          }
        }
      }

      // Buttons
      HStack(spacing: Spacing.md) {
        Button("Cancel") {
          showAuthSheet = false
          pendingAction = nil
          authPassword = ""
          authError = nil
          useDbPasswordForAuth = false
        }
        .buttonStyle(.plain)
        .foregroundColor(.foregroundMuted)

        // Show Confirm button when not using biometric OR using database password fallback
        if !appSettings.isBiometricEnabled || useDbPasswordForAuth {
          Button("Confirm") {
            verifyPasswordForAction()
          }
          .buttonStyle(.borderedProminent)
          .tint(.destructive)
          .disabled(authPassword.isEmpty)
        }
      }
    }
    .padding(Spacing.xl)
    .frame(width: 400)
    .background(Color.appBackground)
  }

  private var authenticationTitle: String {
    switch pendingAction {
    case .changeSafeMode:
      return "Change Safe Mode"
    case .removeProtection:
      return "Remove Protection"
    case .switchToPassword:
      return "Switch to Password"
    case .switchToBiometric:
      return "Switch to Touch ID"
    case .none:
      return "Authentication Required"
    }
  }

  private func verifyPasswordForAction() {
    if useDbPasswordForAuth {
      // Verify using database password
      guard authPassword == viewModel.editingConnectionConfig.password else {
        authError = "Incorrect database password"
        return
      }
    } else {
      // Verify using Safe Mode password
      guard appSettings.verifySafeModePassword(authPassword) else {
        authError = "Incorrect password"
        return
      }
    }

    executeProtectedAction()
  }

  private func authenticateForAction() {
    isAuthenticating = true
    authError = nil

    Task {
      do {
        let success = try await appSettings.verifyBiometric()
        await MainActor.run {
          isAuthenticating = false
          if success {
            executeProtectedAction()
          } else {
            authError = "Authentication failed"
          }
        }
      } catch {
        await MainActor.run {
          isAuthenticating = false
          // Check if user cancelled
          let nsError = error as NSError
          let isCancelled =
            nsError.code == -2 || nsError.code == -4 || nsError.code == -9
            || nsError.localizedDescription.lowercased().contains("cancel")

          if isCancelled {
            authError = "Authentication cancelled. Try again."
          } else {
            authError = error.localizedDescription
          }
        }
      }
    }
  }

  private func executeProtectedAction() {
    guard let action = pendingAction else { return }

    // Common cleanup for all actions
    let cleanup = {
      showAuthSheet = false
      pendingAction = nil
      authPassword = ""
      authError = nil
      useDbPasswordForAuth = false
    }

    switch action {
    case .changeSafeMode(let newMode):
      withAnimation(.snappy(duration: 0.2)) {
        appSettings.safeMode = newMode
      }
      cleanup()

    case .removeProtection:
      appSettings.clearSafeModePassword()
      refreshTrigger = UUID()
      cleanup()

    case .switchToPassword:
      cleanup()
      // Open password setup
      dialogMode = .password
      currentPassword = ""
      newPassword = ""
      confirmPassword = ""
      passwordError = nil
      isChangingPassword = false  // Switching from Touch ID, not changing password
      useDbPasswordForChange = false
      showPasswordSetup = true

    case .switchToBiometric:
      cleanup()
      // Open biometric setup
      dialogMode = .biometric
      newPassword = ""
      confirmPassword = ""
      passwordError = nil
      showPasswordSetup = true
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
