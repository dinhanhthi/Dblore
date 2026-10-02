//
//  StagedChangesPreviewSheet.swift
//  Dblore
//
//  Read-only preview of staged data-viewer SQL. Copy puts the text on the pasteboard.
//  Nothing in this sheet is sent to the database.
//

import AppKit
import SwiftUI

struct StagedChangesPreviewSheet: View {
  @Bindable var viewModel: NotebookViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var copied = false

  /// Display SQL from `previewStagedSQL()`. Not executed.
  var sql: String { viewModel.previewStagedSQL() }

  private var dialect: SQLDialect {
    viewModel.dataViewer?.databaseType.dialect
      ?? viewModel.notebook.connectionConfig?.databaseType.dialect
      ?? .postgresql
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Preview SQL")
          .font(.subheading)
          .foregroundColor(.foreground)
        Spacer()
        Button(action: { dismiss() }) {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .help("Close")
      }
      .modalBarPadding(vertical: Spacing.sm)

      Divider()

      SQLCodeWell(
        sql: sql,
        placeholder: "No staged changes",
        dialect: dialect
      )
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()

      HStack {
        Text("Preview only. Commit applies the staged changes.")
          .font(.small)
          .foregroundColor(.foregroundSubtle)
        Spacer()
        Button(copied ? "Copied" : "Copy") { copy() }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(sql.isEmpty)
        Button("Done") { dismiss() }
          .buttonStyle(PrimaryButtonStyle())
      }
      .modalBarPadding()
    }
    .frame(width: 560, height: 360)
    .background(Color.appBackground)
  }

  private func copy() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(sql, forType: .string)
    copied = true
  }
}
