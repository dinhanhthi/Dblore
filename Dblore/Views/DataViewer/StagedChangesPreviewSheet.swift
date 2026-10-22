//
//  StagedChangesPreviewSheet.swift
//  Dblore
//
//  Read-only preview of staged data-viewer SQL, or for MongoDB the mongosh commands exactly as
//  Commit sends them. Copy puts the text on the pasteboard. The staged SQL is not sent from
//  this sheet; with staged deletes, "Also affected" counts related rows through the read-only
//  gate on a separate read-only connection (`stagedDeleteImpact`), stopped when the sheet
//  closes. A blocker disables Commit and shows Commit Anyway (the server decides); rows that
//  only may block show as a warning.
//

import AppKit
import SwiftUI

struct StagedChangesPreviewSheet: View {
  @Bindable var viewModel: NotebookViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var copied = false
  /// Nil while counting, or when nothing existing is staged for deletion
  @State private var impact: CascadeImpactSummary?

  /// Display SQL from `previewStagedSQL()` (MongoDB: the commands as sent). Not executed.
  var sql: String { viewModel.previewStagedSQL() }

  private var dialect: SQLDialect {
    viewModel.dataViewer?.databaseType.dialect
      ?? viewModel.notebook.connectionConfig?.databaseType.dialect
      ?? .postgresql
  }

  /// Existing rows staged for deletion (SQL engines; MongoDB has no foreign keys)
  private var hasStagedDeletes: Bool {
    !viewModel.isMongoDataViewer && (viewModel.stagedChangeCounts?.deletes ?? 0) > 0
  }

  /// Counting related rows (from the first frame: `.task` starts after it)
  private var checking: Bool { hasStagedDeletes && impact == nil }

  /// Counting finished with a blocker that has rows: only Commit Anyway commits
  private var blocked: Bool { impact?.blocksCommit == true }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(viewModel.isMongoDataViewer ? "Preview Commands" : "Preview SQL")
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

      if hasStagedDeletes {
        Divider()
        alsoAffectedSection
      }

      Divider()

      HStack {
        Text(
          blocked
            ? DataViewerControls.commitAnywayNote
            : "Preview only. Commit applies the staged changes."
        )
        .font(.small)
        .foregroundColor(blocked ? .destructive : .foregroundSubtle)
        .fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button(copied ? "Copied" : "Copy") { copy() }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(sql.isEmpty)
        Button("Done") { dismiss() }
          .buttonStyle(SecondaryButtonStyle())
        if blocked {
          Button("Commit Anyway") { commit(ignoringBlockers: true) }
            .buttonStyle(DangerButtonStyle())
            .disabled(sql.isEmpty || !viewModel.stagingEnabled)
        }
        Button("Commit") { commit() }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(sql.isEmpty || !viewModel.stagingEnabled || checking || blocked)
      }
      .modalBarPadding()
    }
    .frame(width: 560, height: hasStagedDeletes ? 480 : 360)
    .background(Color.appBackground)
    .task {
      guard hasStagedDeletes else { return }
      // Nil: no live table to check (the page is reloading)
      impact = await viewModel.stagedDeleteImpact() ?? .notComputed("The table is not loaded.")
    }
  }

  /// What the staged deletes also change through foreign keys
  private var alsoAffectedSection: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Also affected")
        .font(.labelText)
        .foregroundColor(.foreground)
      if checking {
        HStack(spacing: Spacing.sm) {
          ProgressView().controlSize(.small)
          Text("Checking related rows…")
            .font(.small)
            .foregroundColor(.foregroundSubtle)
        }
      } else if let impact {
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(impact.blockers) { blocker in
              Label(blocker.text, systemImage: "exclamationmark.triangle.fill")
                .font(.small)
                .foregroundColor(.destructive)
            }
            ForEach(impact.affected) { affected in
              if affected.effect == .mayBlock {
                Label(affected.text, systemImage: "exclamationmark.triangle")
                  .font(.small)
                  .foregroundColor(.warning)
              } else {
                Text(affected.text)
                  .font(.small)
                  .foregroundColor(.foregroundMuted)
              }
            }
            if impact.blockers.isEmpty, impact.affected.isEmpty, impact.note == nil {
              Text("No related rows.")
                .font(.small)
                .foregroundColor(.foregroundSubtle)
            }
            if let note = impact.note {
              Text(note)
                .font(.small)
                .foregroundColor(.foregroundSubtle)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
        }
        .frame(maxHeight: 96)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
  }

  /// Commit counts again (rows may have changed since): `commitStaged` asks about a blocker,
  /// except after Commit Anyway here
  private func commit(ignoringBlockers: Bool = false) {
    dismiss()
    Task { await viewModel.commitStaged(ignoringBlockers: ignoringBlockers) }
  }

  private func copy() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(sql, forType: .string)
    copied = true
  }
}
