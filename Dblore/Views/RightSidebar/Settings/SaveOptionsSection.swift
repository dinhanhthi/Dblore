//
//  SaveOptionsSection.swift
//  Dblore
//
//  Save options settings (Notebook mode only)
//

import SwiftUI

struct SaveOptionsSection: View {
  @Bindable var appSettings: AppSettings

  var body: some View {
    SettingsSection(title: "Save Options", icon: "square.and.arrow.down.fill") {
      SettingsToggle(
        title: "Include Results When Saving",
        description:
          "When enabled, query results are saved with the notebook. Disable to reduce file size.",
        isOn: $appSettings.includeResultsOnSave
      )
    }
  }
}
