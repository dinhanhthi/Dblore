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
