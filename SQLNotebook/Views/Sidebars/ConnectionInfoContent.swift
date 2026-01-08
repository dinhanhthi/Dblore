//
//  ConnectionInfoContent.swift
//  SQLNotebook
//

import SwiftUI

// MARK: - Connection Info Content

struct ConnectionInfoContent: View {
  let config: ConnectionConfig?

  var body: some View {
    if let config {
      VStack(alignment: .leading, spacing: Spacing.md) {
        infoRow(label: "Host", value: config.host)
        infoRow(label: "Port", value: String(config.port))
        infoRow(label: "Database", value: config.database)
        infoRow(label: "Username", value: config.username)
        infoRow(label: "SSL Mode", value: config.sslMode.displayName)

        // Read-only mode indicator
        if config.readOnly {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "lock.fill")
              .font(.caption)
              .foregroundColor(.warning)

            Text("Read-only mode enabled")
              .font(.caption)
              .foregroundColor(.warning)
          }
          .padding(Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: CornerRadius.md)
              .fill(Color.warning.opacity(0.1))
          )
        }
      }
    } else {
      Text("No connection configured")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
    }
  }

  private func infoRow(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.caption)
        .foregroundColor(.foregroundSubtle)

      Text(value)
        .font(.mono)
        .foregroundColor(.foreground)
    }
  }
}
