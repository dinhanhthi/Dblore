//
//  FooterView.swift
//  SQLNotebook
//

import SwiftUI

struct FooterView: View {
  @Bindable var viewModel: NotebookViewModel
  var lastSaved: Date?
  var isEditorMode: Bool = false

  var body: some View {
    HStack(spacing: Spacing.lg) {
      //      Left side
      HStack(spacing: Spacing.sm) {
        // App version
        Text("v\(appVersion)")
          .font(.small)
          .foregroundColor(.foregroundSubtle)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.xs + 2)
          .background(Color.cardHeaderBackground)

        // Connection status
        connectionStatusIcon
        Text(connectionStatusText)
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }

      Spacer()

      HStack(spacing: Spacing.sm) {
        // Last saved
        if let lastSaved {
          Text(lastSavedText(lastSaved))
            .font(.small)
            .foregroundColor(.foregroundSubtle)

          Text("|")
            .font(.small)
            .foregroundColor(.foregroundSubtle)
        }

        // Notebook stats (only in notebook mode)
        if !isEditorMode {
          Text("\(viewModel.cellCount) cells, \(viewModel.executedCellCount) executed")
            .font(.small)
            .foregroundColor(.foregroundSubtle)

          Text("|")
            .font(.small)
            .foregroundColor(.foregroundSubtle)
        }

        // File size indicator
        HStack(spacing: 4) {
          Image(systemName: fileSizeIcon)
            .font(.small)
            .foregroundColor(fileSizeColor)

          Text(viewModel.formattedFileSize)
            .font(.small)
            .foregroundColor(fileSizeColor)
        }
        .help(fileSizeTooltip)
      }
    }
    .padding(.trailing, Spacing.lg)
    .padding(.leading, 0)
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

  // MARK: - File Size Helpers

  private var fileSizeIcon: String {
    if viewModel.isFileSizeLarge {
      return "exclamationmark.triangle.fill"
    } else if viewModel.isFileSizeWarning {
      return "exclamationmark.circle.fill"
    } else {
      return "doc.text"
    }
  }

  private var fileSizeColor: Color {
    if viewModel.isFileSizeLarge {
      return .destructive
    } else if viewModel.isFileSizeWarning {
      return .warning
    } else {
      return .foregroundSubtle
    }
  }

  private var fileSizeTooltip: String {
    if viewModel.isFileSizeLarge {
      return
        "File size is very large (> \(FileOptimizationService.formatFileSize(FileOptimizationService.largeSizeThreshold))). Consider creating a new notebook or removing old results."
    } else if viewModel.isFileSizeWarning {
      return
        "File size is approaching the recommended limit (> \(FileOptimizationService.formatFileSize(FileOptimizationService.warningSizeThreshold)))"
    } else {
      return "Current file size"
    }
  }
}

#Preview {
  FooterView(
    viewModel: NotebookViewModel(),
    lastSaved: Date()
  )
  .preferredColorScheme(.dark)
}
