// DataDictionaryExportSheet.swift
// Export Data Dictionary: the format, then the structure reads with a bar and Cancel. The save
// panel opens once every table is read and the sheet has closed.

import SwiftUI

extension View {
  func dataDictionaryExportSheet(workspaceManager: WorkspaceManager) -> some View {
    sheet(
      item: Binding(
        get: { workspaceManager.dataDictionaryExport },
        set: { if $0 == nil { workspaceManager.dataDictionaryExport?.cancel() } })
    ) { model in
      DataDictionaryExportSheet(model: model)
    }
  }
}

private struct DataDictionaryExportSheet: View {
  @Bindable var model: DataDictionaryExportModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Export Data Dictionary")
        .font(.subheading)
        .foregroundColor(.foreground)
        .modalBarPadding(vertical: Spacing.sm)

      Divider()

      VStack(alignment: .leading, spacing: Spacing.sm) {
        if let completed = model.completed {
          ProgressView(value: Double(completed), total: Double(max(model.tables.count, 1)))
            .progressViewStyle(.linear)
          Text(progressText(completed))
            .font(.bodyText)
            .foregroundColor(.foregroundSubtle)
            .lineLimit(1)
            .monospacedDigit()
        } else {
          HStack(spacing: Spacing.sm) {
            Text("Format")
              .font(.bodyText)
              .foregroundColor(.foreground)
            Spacer(minLength: Spacing.sm)
            CapsulePickerMenu(title: model.format.title) {
              Picker("Format", selection: $model.format) {
                ForEach(DataDictionaryRenderer.Format.allCases) { format in
                  Text(format.title).tag(format)
                }
              }
              .pickerStyle(.inline)
              .labelsHidden()
            }
            .accessibilityLabel("Format")
          }
          Text(summary)
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)

      Divider()

      HStack {
        Spacer()
        Button(model.isCancelling ? "Cancelling…" : "Cancel") { model.cancel() }
          .buttonStyle(GhostButtonStyle())
          .disabled(model.isCancelling)
          .keyboardShortcut(.cancelAction)
        if !model.isLoading {
          Button("Export...") { model.start() }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.tables.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
      }
      .modalBarPadding()
    }
    .frame(width: 400)
    .background(Color.appBackground)
    .interactiveDismissDisabled()
  }

  private var summary: String {
    let count = model.tables.count
    guard count > 0 else { return "\(model.databaseName) has no tables to document." }
    let tables = count == 1 ? "1 table" : "\(count.formatted()) tables"
    return "Columns, indexes and foreign keys of \(tables) in \(model.databaseName)."
  }

  private func progressText(_ completed: Int) -> String {
    if model.isCancelling { return "Stopping after the reads in progress…" }
    return "Reading table structures (\(completed.formatted()) of "
      + "\(model.tables.count.formatted()))…"
  }
}
