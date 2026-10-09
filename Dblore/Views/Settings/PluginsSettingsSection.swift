//
//  PluginsSettingsSection.swift
//  Dblore
//
//  Settings > Plugins: install, cancel and remove the optional DuckDB plugin.
//

import AppKit
import SwiftUI

struct PluginsSettingsSection: View {
  private let manager = DuckDBPluginManager.shared

  @State private var isConfirmingRemove = false

  private static let licenseURL = URL(
    string: "https://github.com/duckdb/duckdb/blob/main/LICENSE")!

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsGroupCard(title: "DuckDB", accessory: { versionLabel }) {
        VStack(alignment: .leading, spacing: Spacing.md) {
          Text(
            "Query .duckdb files and Parquet/CSV with DuckDB. Downloaded on demand (~117 MB)."
          )
          .font(.bodyText)
          .foregroundColor(.foregroundSubtle)

          controls

          if case .failed(let message) = manager.state {
            Text(message)
              .font(.bodyText)
              .foregroundColor(.destructive)
              .textSelection(.enabled)
          }

          if manager.requiresRestartToUnload {
            Text("DuckDB stays loaded until you quit Dblore.")
              .font(.bodyText)
              .foregroundColor(.foregroundMuted)
          }

          Button("DuckDB is MIT licensed") {
            NSWorkspace.shared.open(Self.licenseURL)
          }
          .buttonStyle(.link)
          .font(.bodyText)
        }
      }
    }
    .confirmationDialog(
      "Remove the DuckDB plugin?",
      isPresented: $isConfirmingRemove,
      titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) {
        Task { await manager.remove() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Deletes the downloaded DuckDB library. Install it again to use DuckDB connections.")
    }
  }

  @ViewBuilder
  private var versionLabel: some View {
    if let version = manager.catalog?.version {
      Text("v\(version)")
        .font(.monoSmall)
        .foregroundColor(.foregroundMuted)
    }
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
        .disabled(manager.catalog == nil)
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
        .disabled(manager.catalog == nil)
        .linkPointer()
    }
  }

  private func install() {
    Task { await manager.install() }
  }
}
