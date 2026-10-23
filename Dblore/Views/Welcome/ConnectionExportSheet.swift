//
//  ConnectionExportSheet.swift
//  Dblore
//
//  Pick saved connections, and optionally an open workspace's favorites, to write to a Dblore
//  connections file. Opened from the Welcome screen's Connections tab.
//

import SwiftUI

struct ConnectionExportSheet: View {
  @Bindable var model: ConnectionExportModel
  @Binding var isPresented: Bool

  /// Width of the right sidebar the export opens in.
  static let panelWidth: CGFloat = 480

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(title: "Export Connections", onClose: close)

      VStack(alignment: .leading, spacing: Spacing.md) {
        Text(
          "Passwords, SSH credentials, keys and certificates are never exported. Dblore asks for passwords on first connect after import."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)

        if !model.favoritesSources.isEmpty {
          favoritesPicker
        }
        if let message = model.errorMessage {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.small)
            .foregroundColor(.warning)
        }
        connectionList
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      footer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.panelBackground)
  }

  private var favoritesPicker: some View {
    HStack(spacing: Spacing.sm) {
      Text("Favorites")
        .font(.labelText)
        .foregroundColor(.foregroundMuted)
      CapsulePickerMenu(
        title: model.favoritesSources.first { $0.id == model.favoritesSourceID }
          .map { "\($0.name) (\($0.count))" } ?? "Don't include"
      ) {
        Picker("Favorites", selection: $model.favoritesSourceID) {
          Text("Don't include").tag(UUID?.none)
          ForEach(model.favoritesSources) { source in
            Text(verbatim: "\(source.name) (\(source.count))").tag(UUID?.some(source.id))
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
      .accessibilityLabel("Favorites")
      .disabled(model.isExporting)
    }
  }

  private var connectionList: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        Text("Connections (\(model.rows.count))")
          .font(.labelText)
          .foregroundColor(.foregroundMuted)
        Spacer()
        if !model.rows.isEmpty {
          Button("Select All") { model.selectAll() }
            .buttonStyle(SecondaryButtonStyle())
          Button("Select None") { model.deselectAll() }
            .buttonStyle(SecondaryButtonStyle())
        }
      }

      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(model.rows) { row in
            ExportConnectionRow(row: row, onToggle: { model.toggle(row.id) })
            if row.id != model.rows.last?.id {
              Divider()
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay {
        if model.rows.isEmpty {
          Text("No saved connections to export.")
            .font(.small)
            .foregroundColor(.foregroundSubtle)
        }
      }
      .cardStyle()
      .disabled(model.isExporting)

      if model.skippedFileDatabases > 0 {
        Text(
          "\(model.skippedFileDatabases) file database\(model.skippedFileDatabases == 1 ? " is" : "s are") not exported: their files stay on this Mac."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var footer: some View {
    GenericModalFooter {
      Text("\(model.selectedCount) selected")
        .font(.small)
        .foregroundColor(.foregroundMuted)
      Spacer()
      Button("Cancel", action: close)
        .buttonStyle(FilledSecondaryButtonStyle())
        .keyboardShortcut(.cancelAction)
      Button("Export...", action: runExport)
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!model.canExport)
    }
  }

  private func close() {
    isPresented = false
  }

  private func runExport() {
    Task { @MainActor in
      guard let message = await model.export() else { return }
      close()
      WorkspaceWindowManager.shared.showToast(message, type: .success)
    }
  }
}

private struct ExportConnectionRow: View {
  let row: ConnectionExportModel.Row
  let onToggle: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Toggle("", isOn: Binding(get: { row.isSelected }, set: { _ in onToggle() }))
        .toggleStyle(.checkbox)
        .labelsHidden()

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        HStack(spacing: Spacing.xs) {
          Text(verbatim: row.name)
            .font(.bodyText)
            .foregroundColor(.foreground)
            .lineLimit(1)
          Text(verbatim: row.engine)
            .font(.smallest)
            .foregroundColor(.foregroundSubtle)
        }
        Text(verbatim: row.address)
          .font(.monoSmall)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }
}
