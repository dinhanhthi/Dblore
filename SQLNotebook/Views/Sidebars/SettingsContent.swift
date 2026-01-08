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

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      // Appearance Settings
      settingsSection(title: "Appearance", icon: "paintbrush.fill") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          // Theme Picker
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Theme")
              .font(.subheading)
              .foregroundColor(.foreground)

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
              .font(.caption)
              .foregroundColor(.foregroundSubtle)
          }
        }
      }

      Divider()

      // Result Table Settings
      settingsSection(title: "Result Table", icon: "tablecells.fill") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          // Max Height
          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
              Text("Max Height")
                .font(.subheading)
                .foregroundColor(.foreground)

              Spacer()

              Text("\(Int(appSettings.maxResultHeight)) pt")
                .font(.monoSmall)
                .foregroundColor(.foregroundMuted)
            }

            Slider(
              value: $appSettings.maxResultHeight,
              in: 200...1000,
              step: 50
            )
            .tint(.accent)

            Text("Adjust the maximum height of result tables. Values between 200-1000 points.")
              .font(.caption)
              .foregroundColor(.foregroundSubtle)
          }

          // Max Row Limit
          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
              Text("Max Rows")
                .font(.subheading)
                .foregroundColor(.foreground)

              Spacer()

              Text("\(appSettings.maxRowLimit) rows")
                .font(.monoSmall)
                .foregroundColor(.foregroundMuted)
            }

            Slider(
              value: Binding(
                get: { Double(appSettings.maxRowLimit) },
                set: { newValue in
                  appSettings.maxRowLimit = Int(newValue)
                }
              ),
              in: 10...200,
              step: 10
            )
            .tint(.accent)

            Text("Maximum rows to fetch from database. Values between 10-200 rows.")
              .font(.caption)
              .foregroundColor(.foregroundSubtle)
          }
        }
      }

      Divider()

      // Save Settings
      settingsSection(title: "Save Options", icon: "square.and.arrow.down.fill") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          Toggle(
            "Include Results When Saving",
            isOn: $appSettings.includeResultsOnSave
          )
          .font(.bodyText)
          .foregroundColor(.foreground)
          .tint(.accent)

          Text(
            "When enabled, query results are saved with the notebook. Disable to reduce file size."
          )
          .font(.caption)
          .foregroundColor(.foregroundSubtle)
        }
      }

      Divider()

      // Security Settings
      settingsSection(title: "Security", icon: "lock.shield.fill") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          Toggle(
            "Bypass Destructive Query Confirmation",
            isOn: $appSettings.bypassDestructiveQueryConfirmation
          )
          .font(.bodyText)
          .foregroundColor(.foreground)
          .tint(.accent)

          Text(
            "When enabled, UPDATE, DELETE, and INSERT queries will execute immediately without confirmation. Not recommended for production databases."
          )
          .font(.caption)
          .foregroundColor(.foregroundSubtle)
        }
      }

      Divider()

      // File Optimization Settings
      settingsSection(title: "File Optimization", icon: "gauge.with.dots.needle.bottom.50percent") {
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
            .font(.caption)
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
          .font(.caption)
          .foregroundColor(.foregroundSubtle)
        }
      }

      Divider()

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
          .font(.caption)
          .foregroundColor(.foregroundSubtle)
        }
      }

      Divider()

      // Keyboard Shortcuts (placeholder for future expansion)
      settingsSection(title: "Keyboard Shortcuts", icon: "command") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          Text("Custom keyboard shortcuts will be available in a future update.")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)

          // Placeholder for future keyboard shortcut customization UI
          keyboardShortcutsList
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

  private var keyboardShortcutsList: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      shortcutRow(action: "Run Cell", shortcut: "Ctrl+Enter")
      shortcutRow(action: "Run Cell and Select Next", shortcut: "Shift+Enter")
      shortcutRow(action: "Run Cell and Insert Below", shortcut: "Option+Enter")
      shortcutRow(action: "Run All Cells", shortcut: "Cmd+Shift+Enter")
      shortcutRow(action: "Delete Cell", shortcut: "Cmd+Delete")
      shortcutRow(action: "Duplicate Cell", shortcut: "Cmd+D")
      shortcutRow(action: "Toggle Left Sidebar", shortcut: "Cmd+B")
      shortcutRow(action: "Toggle Right Sidebar", shortcut: "Cmd+Shift+R")
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

#Preview {
  SettingsContent(viewModel: NotebookViewModel())
    .frame(width: 450)
    .background(Color.cardBackground)
    .preferredColorScheme(.dark)
}
