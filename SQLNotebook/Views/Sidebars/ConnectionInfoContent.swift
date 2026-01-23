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
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          // Connection name (if provided)
          if !config.name.isEmpty {
            infoRow(label: "Connection Name", value: config.name)
          }
          
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
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    } else {
      VStack(spacing: Spacing.sm) {
        Image(systemName: "cable.connector.slash")
          .font(.system(size: 32))
          .foregroundColor(.foregroundMuted)

        Text("No connection configured")
          .font(.caption)
          .foregroundColor(.foregroundMuted)
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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

#Preview("Connection - Not Configured") {
  let viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .connectionDetails

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Connection - Connected") {
  let viewModel = NotebookViewModel()
  viewModel.notebook.connectionConfig = ConnectionConfig(
    host: "db.example.com",
    port: 5432,
    database: "my_database",
    username: "admin_user",
    password: "secret123",
    sslMode: .require
  )
  viewModel.rightSidebarContent = .connectionDetails

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
