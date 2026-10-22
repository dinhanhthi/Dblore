//
//  ResultTableSettingsSection.swift
//  Dblore
//
//  Result table settings for both Notebook and Editor modes
//

import SwiftUI

struct ResultTableSettingsSection: View {
  @Bindable var appSettings: AppSettings
  let viewMode: ViewMode

  var body: some View {
    SettingsSection(title: "Result Table", icon: "tablecells.fill") {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        // Hide Column Types toggle
        SettingsToggle(
          title: "Hide Column Types",
          description:
            "When enabled, column types (e.g., VARCHAR, INTEGER) will be hidden from table headers, showing only column names.",
          isOn: $appSettings.hideColumnTypes
        )

        SettingsToggle(
          title: "Color Values by Type",
          description:
            "Show numbers, text, dates, booleans and JSON in their own soft colors. NULL keeps its faint style.",
          isOn: $appSettings.colorValuesByType
        )

        SettingsToggle(
          title: "Show Invisible Characters",
          description: InvisibleCharactersSetting.description,
          isOn: $appSettings.showsInvisibleCharacters
        )

        // Hide Run with Query Section toggle
        SettingsToggle(
          title: "Hide Run with Query Section",
          description:
            "When enabled, the 'Run with query' section (with query text and download button) will be hidden from result tables.",
          isOn: $appSettings.hideRunWithQuerySection
        )

        SettingsToggle(
          title: "Neutralize Copied Formulas",
          description:
            "Adds ' before copied text that starts with =, +, -, @ so spreadsheets don't run it.",
          isOn: $appSettings.neutralizesCopiedFormulas
        )

        CopyRowsFormatSetting(appSettings: appSettings)

        // Max Height (Notebook only)
        if viewMode == .notebook {
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
        }

        // One row cap for Notebook and Editor
        ResultRowCapSetting(appSettings: appSettings)

        SessionTimeoutSettings(appSettings: appSettings)
      }
    }
  }
}

/// Text of the "Show Invisible Characters" setting, shared by both settings views and search
enum InvisibleCharactersSetting {
  static let description =
    "Marks control characters, zero-width characters, special spaces and direction controls in result cells. Copy, export and search keep the original text."
}

/// "Copy rows as": the format Cmd+C copies selected result grid rows in
struct CopyRowsFormatSetting: View {
  @Bindable var appSettings: AppSettings

  static let description =
    "Format of the rows Cmd+C copies from a result table. Neutralize Copied Formulas applies to TSV and CSV."

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        Text("Copy rows as")
          .font(.bodyText)
          .foregroundColor(.foreground)

        Spacer()

        CapsuleDropdown(
          title: appSettings.copyRowsFormat.title,
          width: 160,
          accessibilityLabel: "Copy rows as",
          options: Array(CopyRowsFormat.allCases),
          optionTitle: \.title,
          isSelected: { $0 == appSettings.copyRowsFormat },
          onSelect: { appSettings.copyRowsFormat = $0 }
        )
      }

      Text(Self.description)
        .font(.bodyText)
        .foregroundColor(.foregroundSubtle)
    }
  }
}
