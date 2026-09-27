//
//  AppearanceSettingsSection.swift
//  SQLNotebook
//
//  Appearance settings: Theme and Accent Color
//

import SwiftUI

struct AppearanceSettingsSection: View {
  @Bindable var appSettings: AppSettings

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Theme Picker
      themePicker

      Divider()
        .padding(.vertical, Spacing.xs)

      // Accent Color Picker
      accentColorPicker
    }
  }

  private var themePicker: some View {
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
          .pointerStyle(.link)
        }
      }

      Text("Choose between Light, Dark, or System theme. System follows macOS appearance.")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    }
  }

  private var accentColorPicker: some View {
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
          .pointerStyle(.link)
          .help(color.rawValue)
        }
      }

      Text("Choose the main color for buttons, links, and syntax highlighting.")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    }
  }
}
