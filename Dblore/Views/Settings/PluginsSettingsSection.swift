//
//  PluginsSettingsSection.swift
//  Dblore
//
//  Settings > Plugins: one card per catalog plugin to install, cancel and remove it.
//

import AppKit
import SwiftUI

struct PluginsSettingsSection: View {
  /// In catalog order; empty only when the bundled catalog is missing or invalid (logged by the
  /// registry).
  private let managers = PluginRegistry.shared.managers

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      if managers.isEmpty {
        Text(PluginManagerError.catalogUnavailable.localizedDescription)
          .font(.bodyText)
          .foregroundColor(.destructive)
      }
      ForEach(managers, id: \.entry.id) { manager in
        PluginRow(manager: manager)
      }
    }
  }
}

/// App-side text for a plugin id; the catalog carries none. Unknown ids show their id only.
private struct PluginDisplayInfo {
  let name: String
  var summary: String?
  var license: (title: String, url: URL)?
  var removeMessage: String

  static func forID(_ id: String) -> PluginDisplayInfo {
    switch id {
    case "duckdb":
      PluginDisplayInfo(
        name: "DuckDB",
        summary:
          "Query .duckdb files and Parquet/CSV with DuckDB. Downloaded on demand (~117 MB).",
        license: (
          "DuckDB is MIT licensed",
          URL(string: "https://github.com/duckdb/duckdb/blob/main/LICENSE")!
        ),
        removeMessage:
          "Deletes the downloaded DuckDB library. Install it again to use DuckDB connections.")
    default:
      PluginDisplayInfo(name: id, removeMessage: "Deletes the downloaded \(id) library.")
    }
  }
}

private struct PluginRow: View {
  let manager: PluginManager

  @State private var isConfirmingRemove = false

  private var info: PluginDisplayInfo { .forID(manager.entry.id) }

  var body: some View {
    SettingsGroupCard(title: info.name, accessory: { versionLabel }) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        if let summary = info.summary {
          Text(summary)
            .font(.bodyText)
            .foregroundColor(.foregroundSubtle)
        }

        controls

        if case .failed(let message) = manager.state {
          Text(message)
            .font(.bodyText)
            .foregroundColor(.destructive)
            .textSelection(.enabled)
        }

        if manager.requiresRestartToUnload {
          Text("\(info.name) stays loaded until you quit Dblore.")
            .font(.bodyText)
            .foregroundColor(.foregroundMuted)
        }

        if let license = info.license {
          Divider()

          Button(license.title) {
            NSWorkspace.shared.open(license.url)
          }
          .buttonStyle(.plain)
          .font(.small)
          .foregroundColor(.foregroundSubtle)
          .linkPointer()
        }
      }
    }
    .confirmationDialog(
      "Remove the \(info.name) plugin?",
      isPresented: $isConfirmingRemove,
      titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) {
        Task { await manager.remove() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(info.removeMessage)
    }
  }

  private var versionLabel: some View {
    Text("v\(manager.entry.version)")
      .font(.monoSmall)
      .foregroundColor(.foregroundMuted)
  }

  @ViewBuilder
  private var controls: some View {
    switch manager.state {
    case .checking:
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        Text("Checking…")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
    case .notInstalled:
      Button("Install") { install() }
        .buttonStyle(PrimaryButtonStyle())
        .controlSize(.regular)
        .disabled(manager.installedURL == nil)
        .linkPointer()
    case .downloading(let fraction):
      HStack(spacing: Spacing.md) {
        ProgressView(value: fraction)
        Text("\(Int((fraction * 100).rounded()))%")
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .monospacedDigit()
        Button("Cancel") { manager.cancel() }
          .buttonStyle(FilledSecondaryButtonStyle())
          .controlSize(.regular)
          .linkPointer()
      }
    case .verifying:
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        Text("Verifying…")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
    case .installed(let version, let size):
      HStack(spacing: Spacing.md) {
        Text(
          "Installed v\(version) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
        )
        .font(.bodyText)
        .foregroundColor(.success)
        Spacer(minLength: Spacing.sm)
        Button("Remove") { isConfirmingRemove = true }
          .buttonStyle(FilledSecondaryButtonStyle())
          .controlSize(.regular)
          .linkPointer()
      }
    case .failed:
      Button("Retry") { install() }
        .buttonStyle(PrimaryButtonStyle())
        .controlSize(.regular)
        .disabled(manager.installedURL == nil)
        .linkPointer()
    }
  }

  private func install() {
    Task { await manager.install() }
  }
}
