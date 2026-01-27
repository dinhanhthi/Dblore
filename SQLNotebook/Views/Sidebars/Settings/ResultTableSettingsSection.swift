//
//  ResultTableSettingsSection.swift
//  SQLNotebook
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

        // Hide Run with Query Section toggle
        SettingsToggle(
          title: "Hide Run with Query Section",
          description:
            "When enabled, the 'Run with query' section (with query text and download button) will be hidden from result tables.",
          isOn: $appSettings.hideRunWithQuerySection
        )

        // Mode-specific settings
        if viewMode == .notebook {
          notebookSpecificSettings
        } else {
          editorSpecificSettings
        }
      }
    }
  }

  private var notebookSpecificSettings: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
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

  private var editorSpecificSettings: some View {
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
