//
//  FooterView.swift
//  Dblore
//

import AppKit
import SwiftUI

/// Helper view to display window dimensions
struct WindowDimensionsView: View {
  @State private var windowSize: CGSize = .zero

  var body: some View {
    Text("| \(Int(windowSize.width))×\(Int(windowSize.height))pt")
      .font(.small)
      .foregroundColor(.foregroundSubtle.opacity(0.7))
      .monospacedDigit()
      .onAppear {
        updateWindowSize()
      }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in
        updateWindowSize()
      }
  }

  private func updateWindowSize() {
    if let window = NSApp.keyWindow {
      windowSize = window.frame.size
    }
  }
}

/// Window-level footer. `viewModel` is the active tab's (nil on the welcome view and the schema
/// visualizer: only the version and the connection status are shown then).
struct FooterView: View {
  var viewModel: NotebookViewModel?
  var connectionState: ConnectionState
  var connectionConfig: ConnectionConfig?
  var body: some View {
    bar(viewModel: viewModel)
  }

  private func bar(viewModel: NotebookViewModel?) -> some View {
    HStack(spacing: Spacing.lg) {
      // Left side - always visible
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
        connectionStatusLabel

        if let viewModel, connectionState.isConnected {
          ConnectionSafetyMenus(viewModel: viewModel)
        }

        // Window dimensions (for debugging)
        // WindowDimensionsView()
      }

      Spacer()

      if let viewModel {
        documentStats(viewModel: viewModel)
      }
    }
    .padding(.trailing, Spacing.lg)
    .frame(height: ComponentSize.footerHeight)
    .background(Color.cardBackground)
    .overlay(alignment: .top) {
      Divider()
    }
  }

  private func documentStats(viewModel: NotebookViewModel) -> some View {
    HStack(spacing: Spacing.sm) {
      // Last saved
      if let lastSaved = viewModel.lastSaved {
        Text(lastSavedText(lastSaved))
          .font(.small)
          .foregroundColor(.foregroundSubtle)

        Text("|")
          .font(.small)
          .foregroundColor(.foregroundSubtle)
      }

      // Notebook stats (only in notebook mode)
      if viewModel.viewMode == .notebook {
        Text("\(viewModel.cellCount) cells, \(viewModel.executedCellCount) executed")
          .font(.small)
          .foregroundColor(.foregroundSubtle)

        Text("|")
          .font(.small)
          .foregroundColor(.foregroundSubtle)
      }

      // File size indicator (always visible)
      HStack(spacing: 4) {
        Image(systemName: fileSizeIcon(viewModel))
          .font(.small)
          .foregroundColor(fileSizeColor(viewModel))

        Text(viewModel.formattedFileSize)
          .font(.small)
          .foregroundColor(fileSizeColor(viewModel))
      }
      .help(fileSizeTooltip(viewModel))
    }
  }

  @ViewBuilder
  private var connectionStatusIcon: some View {
    switch connectionState {
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

  /// Short connection state. A saved name or a server error stays out of this
  /// label so a line break cannot stretch the footer, the details row, or the
  /// welcome screen.
  static func connectionStatusText(for state: ConnectionState, config _: ConnectionConfig?)
    -> String
  {
    switch state {
    case .disconnected:
      return "Not connected"
    case .connecting:
      return "Connecting..."
    case .connected:
      return "Connected"
    case .error:
      return "Connection failed"
    }
  }

  /// Server text for a failed connection. Hover-only; the status label stays short.
  static func connectionFailureDetail(for state: ConnectionState) -> String? {
    guard case .error(let message) = state else { return nil }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  @ViewBuilder
  private var connectionStatusLabel: some View {
    let label = Text(Self.connectionStatusText(for: connectionState, config: connectionConfig))
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .truncationMode(.tail)
    if let detail = Self.connectionFailureDetail(for: connectionState) {
      label.help(detail)
    } else {
      label
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
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
  }

  // MARK: - File Size Helpers

  private func fileSizeIcon(_ viewModel: NotebookViewModel) -> String {
    if viewModel.isFileSizeLarge {
      return "exclamationmark.triangle.fill"
    } else if viewModel.isFileSizeWarning {
      return "exclamationmark.circle.fill"
    } else {
      return "doc.text"
    }
  }

  private func fileSizeColor(_ viewModel: NotebookViewModel) -> Color {
    if viewModel.isFileSizeLarge {
      return .destructive
    } else if viewModel.isFileSizeWarning {
      return .warning
    } else {
      return .foregroundSubtle
    }
  }

  private func fileSizeTooltip(_ viewModel: NotebookViewModel) -> String {
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
    connectionState: .connected,
    connectionConfig: ConnectionConfig(name: "My Database")
  )
  .preferredColorScheme(.dark)
}
