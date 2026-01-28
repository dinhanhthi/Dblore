//
//  DeveloperSettingsSection.swift
//  SQLNotebook
//
//  Developer settings: Export logs
//

import SwiftUI

struct DeveloperSettingsSection: View {
  @Binding var isExportingLogs: Bool

  var body: some View {
    SettingsSection(title: "Developer", icon: "hammer.fill") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        // Export logs button
        Button(action: {
          isExportingLogs = true
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
  }
}
