//
//  ConnectionInfoContent.swift
//  SQLNotebook
//

import SwiftUI

// MARK: - Connection Info Content

struct ConnectionInfoContent: View {
  @Bindable var viewModel: NotebookViewModel
  @State private var showDisableReadOnlyConfirmation = false

  private var config: ConnectionConfig? {
    viewModel.notebook.connectionConfig
  }

  var body: some View {
    if let config {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          // Protection level indicator (at top for visibility)
          if config.protectionLevel != .none {
            HStack(spacing: Spacing.xs) {
              Image(systemName: config.protectionLevel.iconName)
                .font(.caption)
                .foregroundColor(config.protectionLevel == .readOnly ? .warning : .secondary)

              Text(
                config.protectionLevel == .readOnly
                  ? "Read-only mode enabled" : "Schema changes blocked"
              )
              .font(.caption)
              .foregroundColor(config.protectionLevel == .readOnly ? .warning : .secondary)

              Spacer()

              Button(action: {
                showDisableReadOnlyConfirmation = true
              }) {
                Text("Change")
                  .font(.caption)
                  .foregroundColor(.accent)
              }
              .buttonStyle(.plain)
              .pointerStyle(.link)
            }
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(
                  config.protectionLevel == .readOnly
                    ? Color.warning.opacity(0.1) : Color.secondary.opacity(0.1))
            )
            // Lowering goes through the Safe Mode unlock (see ProtectionLevelDialogModifier)
            .protectionLevelDialog(
              isPresented: $showDisableReadOnlyConfirmation, viewModel: viewModel)
          }

          // Connection name (if provided)
          if !config.name.isEmpty {
            infoRow(label: "Connection Name", value: config.name)
          }

          infoRow(label: "Host", value: config.host)
          infoRow(label: "Port", value: String(config.port))
          infoRow(label: "Database", value: config.database)
          infoRow(label: "Username", value: config.username)
          infoRow(label: "SSL Mode", value: config.sslMode.displayName)
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
  @Previewable @State var viewModel = NotebookViewModel()

  ConnectionInfoContent(viewModel: viewModel)
    .frame(width: 350, height: 400)
    .background(Color.cardBackground)
    .preferredColorScheme(.dark)
}

#Preview("Connection - Connected") {
  @Previewable @State var viewModel: NotebookViewModel = {
    let vm = NotebookViewModel()
    vm.notebook.connectionConfig = ConnectionConfig(
      host: "db.example.com",
      port: 5432,
      database: "my_database",
      username: "admin_user",
      password: "secret123",
      sslMode: .require
    )
    return vm
  }()

  ConnectionInfoContent(viewModel: viewModel)
    .frame(width: 350, height: 400)
    .background(Color.cardBackground)
    .preferredColorScheme(.dark)
}
