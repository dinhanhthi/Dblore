//
//  GeneralSettingsSection.swift
//  Dblore
//
//  General settings: Startup, Windows, New tab, Notifications and Automatic updates
//

import AppKit
import SwiftUI

struct GeneralSettingsSection: View {
  @Bindable var appSettings: AppSettings
  @ObservedObject private var updater = UpdaterController.shared
  /// Asks for notification permission. Injected so tests and previews never prompt.
  var requestNotificationAuthorization: () async -> Bool = {
    await QueryCompletionNotifier().requestAuthorization()
  }
  @State private var notificationsDenied = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsGroupCard(title: "Startup") {
        launchBehaviorPicker
      }

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

      SettingsGroupCard(title: "Notifications") {
        longQueryNotifications
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

  /// Turning on asks for permission without blocking; a denial switches it back off.
  private var notifyLongQueriesBinding: Binding<Bool> {
    Binding(
      get: { appSettings.notifyLongQueries },
      set: { isOn in
        guard isOn else {
          appSettings.notifyLongQueries = false
          notificationsDenied = false
          return
        }
        notificationsDenied = false
        appSettings.notifyLongQueries = true  // Switch stays on while the system prompt is up
        Task {
          let granted = await appSettings.enableLongQueryNotifications(
            authorize: requestNotificationAuthorization)
          notificationsDenied = !granted
        }
      }
    )
  }

  private var longQueryNotifications: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      SettingsToggle(
        title: "Notify when a long query finishes",
        description:
          "Post a macOS notification with the tab name, duration and row count. Never the SQL or data.",
        warning: notificationsDenied
          ? "Notifications are turned off for Dblore in System Settings." : nil,
        isOn: notifyLongQueriesBinding
      )

      if notificationsDenied {
        Button("Open Notification Settings") {
          if let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
          {
            NSWorkspace.shared.open(url)
          }
        }
        .buttonStyle(.link)
        .font(.bodyText)
      }

      longQueryThresholdRow
        .disabled(!appSettings.notifyLongQueries)

      SettingsToggle(
        title: "Only when Dblore is in the background",
        description: "Skip the notification while Dblore is the active app.",
        isOn: $appSettings.notifyOnlyWhenInactive,
        isDisabled: !appSettings.notifyLongQueries
      )
    }
  }

  private var longQueryThresholdRow: some View {
    HStack {
      Text("Longer than (seconds)")
        .font(.bodyText)
        .foregroundColor(.foreground)

      Spacer()

      HStack(spacing: Spacing.sm) {
        TextField(
          "\(Int(AppSettings.defaultLongQueryThresholdSeconds))",
          value: $appSettings.longQueryThresholdSeconds,
          format: .number.grouping(.never)
        )
        .textFieldStyle(.plain)
        .numberInputCapsuleStyle()
        .frame(width: 60)
        .accessibilityLabel("Notification threshold in seconds")
        Stepper(
          "Notification threshold",
          value: $appSettings.longQueryThresholdSeconds,
          in: AppSettings.longQueryThresholdRange,
          step: 1
        )
        .compactStepperStyle()
      }
    }
  }

  private var launchBehaviorPicker: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("When Dblore starts")
        .font(.bodyText)
        .foregroundColor(.foregroundMuted)

      CapsuleDropdown(
        title: appSettings.launchBehavior.title,
        width: 200,
        accessibilityLabel: "When Dblore starts",
        options: Array(LaunchBehavior.allCases),
        optionTitle: \.title,
        isSelected: { $0 == appSettings.launchBehavior },
        onSelect: { appSettings.launchBehavior = $0 }
      )
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
