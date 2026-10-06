//
//  AppearanceSettingsSection.swift
//  Dblore
//
//  Appearance settings: Theme and Accent Color
//

import SwiftUI

struct AppearanceSettingsSection: View {
  @Bindable var appSettings: AppSettings

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsGroupCard(title: "Theme") {
        themePicker
      }
      SettingsGroupCard(title: "Accent color") {
        accentColorPicker
      }
    }
  }

  private var themePicker: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      CapsuleTabPicker(
        selection: $appSettings.themePreference,
        tabs: Array(ThemePreference.allCases),
        height: 28
      )
      .fitsContent()
      .accessibilityLabel("Theme")

      Text("Choose between Light, Dark, or System theme. System follows macOS appearance.")
        .font(.bodyText)
        .foregroundColor(.foregroundSubtle)
    }
  }

  private var accentColorPicker: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      CapsuleTabPicker(
        selection: $appSettings.accentColor,
        tabs: Array(AccentColor.allCases),
        height: 28
      ) { color in
        Circle()
          .fill(Color(hex: color.darkHex))
          .frame(width: 16, height: 16)
          .help(color.rawValue)
          .accessibilityLabel(color.rawValue)
      }
      .fitsContent(selectedFill: Color.foreground.opacity(0.18), tabPadding: 4)
      .accessibilityLabel("Accent color")

      Text("Choose the main color for buttons, links, and syntax highlighting.")
        .font(.bodyText)
        .foregroundColor(.foregroundSubtle)
    }
  }
}
