//
//  SettingsContent.swift
//  SQLNotebook
//

import SwiftUI

struct SettingsContent: View {
  @Bindable var viewModel: NotebookViewModel
  @Bindable var appSettings = AppSettings.shared

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      // Appearance Settings
      settingsSection(title: "Appearance") {
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
                    Image(systemName: appSettings.themePreference == theme ? "circle.fill" : "circle")
                      .font(.system(size: 12))
                      .foregroundColor(appSettings.themePreference == theme ? .accentColor : .foregroundMuted)

                    Text(theme.rawValue)
                      .font(.bodyText)
                      .foregroundColor(appSettings.themePreference == theme ? .foreground : .foregroundMuted)
                  }
                  // .padding(.horizontal, Spacing.md)
                  .padding(.vertical, Spacing.sm)
                  // .background(
                  //   appSettings.themePreference == theme
                  //     ? Color.accentColor.opacity(0.1)
                  //     : Color.clear
                  // )
                  // .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
                  // .overlay(
                  //   RoundedRectangle(cornerRadius: CornerRadius.sm)
                  //     .stroke(
                  //       appSettings.themePreference == theme
                  //         ? Color.accentColor.opacity(0.3)
                  //         : Color.border,
                  //       lineWidth: 1
                  //     )
                  // )
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
      settingsSection(title: "Result Table") {
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

            Text("Maximum rows to fetch from database. Values between 10-200 rows.")
              .font(.caption)
              .foregroundColor(.foregroundSubtle)
          }
        }
      }

      Divider()

      // Save Settings
      settingsSection(title: "Save Options") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          Toggle(
            "Include Results When Saving",
            isOn: $appSettings.includeResultsOnSave
          )
          .font(.bodyText)
          .foregroundColor(.foreground)

          Text("When enabled, query results are saved with the notebook. Disable to reduce file size.")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)
        }
      }
      
      Divider()
      
      // Keyboard Shortcuts (placeholder for future expansion)
      settingsSection(title: "Keyboard Shortcuts") {
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
  }
  
  @ViewBuilder
  private func settingsSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text(title)
        .font(.heading)
        .foregroundColor(.foreground)

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

#Preview {
  SettingsContent(viewModel: NotebookViewModel())
    .frame(width: 400)
    .background(Color.cardBackground)
    .preferredColorScheme(.dark)
}

