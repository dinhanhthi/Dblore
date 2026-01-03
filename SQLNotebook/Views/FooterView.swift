//
//  FooterView.swift
//  SQLNotebook
//

import SwiftUI

struct FooterView: View {
  @Bindable var viewModel: NotebookViewModel
  var lastSaved: Date?

  var body: some View {
    HStack(spacing: Spacing.lg) {
      //      Left side
      HStack(spacing: Spacing.sm) {
        // Connection status
        connectionStatusIcon
        Text(connectionStatusText)
          .font(.caption)
          .foregroundColor(.foregroundMuted)
      }

      Spacer()

      HStack(spacing: Spacing.sm) {
        // Last saved
        if let lastSaved {
          Text(lastSavedText(lastSaved))
            .font(.caption)
            .foregroundColor(.foregroundSubtle)

          Text("|")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)
        }

        // Notebook stats
        Text("\(viewModel.cellCount) cells, \(viewModel.executedCellCount) executed")
          .font(.caption)
          .foregroundColor(.foregroundSubtle)
      }
    }
    .padding(.horizontal, Spacing.lg)
    .frame(height: ComponentSize.footerHeight)
    .background(Color.cardBackground)
    .overlay(alignment: .top) {
      Divider()
    }
  }

  @ViewBuilder
  private var connectionStatusIcon: some View {
    switch viewModel.connectionState {
    case .disconnected:
      Circle()
        .fill(Color.foregroundSubtle)
        .frame(width: 8, height: 8)
    case .connecting:
      Circle()
        .fill(Color.warning)
        .frame(width: 8, height: 8)
    case .connected:
      Circle()
        .fill(Color.success)
        .frame(width: 8, height: 8)
    case .error:
      Circle()
        .fill(Color.destructive)
        .frame(width: 8, height: 8)
    }
  }

  private var connectionStatusText: String {
    switch viewModel.connectionState {
    case .disconnected:
      return "Not connected"
    case .connecting:
      return "Connecting..."
    case .connected:
      if let config = viewModel.notebook.connectionConfig {
        return "Connected: \(config.database)@\(config.host) (User: \(config.username))"
      }
      return "Connected"
    case .error(let message):
      return "Error: \(message)"
    }
  }

  private func lastSavedText(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)

    if interval < 60 {
      return "Saved just now"
    } else if interval < 3600 {
      let minutes = Int(interval / 60)
      return "Saved \(minutes) minute\(minutes == 1 ? "" : "s") ago"
    } else {
      let formatter = DateFormatter()
      formatter.timeStyle = .short
      return "Last saved: \(formatter.string(from: date))"
    }
  }

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
  }
}

#Preview {
  FooterView(
    viewModel: NotebookViewModel(),
    lastSaved: Date()
  )
  .preferredColorScheme(.dark)
}
