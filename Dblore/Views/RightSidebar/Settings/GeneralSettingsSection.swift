//
//  GeneralSettingsSection.swift
//  Dblore
//
//  General settings: Windows, New tab and Automatic updates
//

import SwiftUI

struct GeneralSettingsSection: View {
  @Bindable var appSettings: AppSettings
  @ObservedObject private var updater = UpdaterController.shared

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsGroupCard(title: "Windows") {
        SettingsToggle(
          title: "Open new windows as tabs",
          description:
            "New workspace windows open as tabs of the current window. Window > Merge All Windows works either way; macOS may also use tabs in full screen or when System Settings prefers tabs.",
          isOn: $appSettings.openWindowsAsTabs
        )
      }

      SettingsGroupCard(title: "New tab") {
        newTabPicker
      }

      SettingsGroupCard(title: "Automatic updates") {
        SettingsToggle(
          title: "Automatically Check for Updates",
          description:
            "Check for new versions of Dblore in the background and offer to install them. You can always check now from the Dblore menu.",
          isOn: $updater.automaticallyChecksForUpdates
        )
      }
    }
  }

  private var newTabPicker: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Default file for new tab (Cmd+T)")
        .font(.bodyText)
        .foregroundColor(.foregroundMuted)

      CapsuleDropdown(
        title: appSettings.defaultNewTabType.title,
        width: 200,
        accessibilityLabel: "Default file for new tab",
        options: Array(NewTabType.allCases),
        optionTitle: \.title,
        isSelected: { $0 == appSettings.defaultNewTabType },
        onSelect: { appSettings.defaultNewTabType = $0 }
      )
    }
  }
}
