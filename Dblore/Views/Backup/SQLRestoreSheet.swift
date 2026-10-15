import Foundation
import SwiftUI

/// Restore SQL Dump: an open panel (the file is read and checked off the main actor), what the
/// dump holds per kind and the notes for this engine, then the Safe Mode confirmation, then
/// the restore on the tab's connection with progress and Cancel.
struct SQLRestoreSheet: View {
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool
  @Binding var isPresented: Bool
  @Binding var isBusy: Bool

  @State private var model: DatabaseBackupModel

  /// Width of the right sidebar the sheet opens in
  static let panelWidth: CGFloat = 520

  init(
    viewModel: NotebookViewModel, databasePassword: String?, isConnected: Bool,
    isPresented: Binding<Bool>, isBusy: Binding<Bool>
  ) {
    self.databasePassword = databasePassword
    self.isConnected = isConnected
    _isPresented = isPresented
    _isBusy = isBusy
    _model = State(initialValue: DatabaseBackupModel(viewModel: viewModel))
  }

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: "Restore SQL Dump", titleIcon: "square.and.arrow.down", onClose: close)
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          fileSection
          if let plan = model.restorePlan {
            contentsSection(plan.summary)
            notesSection(plan.engine)
          }
          if let reason = model.restoreBlockedReason {
            BackupMessageBox(text: reason, isError: true)
          }
          progressSection
          if let error = model.errorMessage {
            BackupMessageBox(text: error, isError: true)
          } else if let result = model.resultMessage {
            BackupMessageBox(text: result, isError: false)
          }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: .infinity)
      if model.isConfirmingRestore, let plan = model.restorePlan {
        SafeModeConfirmationPanel(
          requiresPassword: model.confirmationRequiresPassword, confirmTitle: "Restore",
          biometricReason: "Authorize the SQL dump restore in Safe Mode",
          databasePassword: databasePassword, isConnected: isConnected,
          isPending: { [model, presented = $isPresented] in
            model.isConfirmingRestore && presented.wrappedValue
          },
          onCancel: { [model] in model.cancelRestoreConfirmation() },
          onConfirm: { [model] in await model.confirmRestore() }
        ) {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(
              "Restore \(Self.counted(plan.summary.statementCount, "statement")) from "
                + "\"\(model.restoreFileName ?? "")\": "
                + Self.kindsText(plan.summary)
                + (model.restoreConfirmation.isEmpty ? "." : ". Every statement but the rows:")
            )
            .font(.bodyText)
            .foregroundColor(.foreground)
            .fixedSize(horizontal: false, vertical: true)
            if !model.restoreConfirmation.isEmpty {
              SafeModeStatementList(statements: model.restoreConfirmation)
            }
          }
        }
      }
      GenericModalFooter {
        Spacer()
        Button(model.isBusy ? "Cancel" : "Close") {
          if model.isBusy {
            Task { await model.cancel() }
          } else {
            close()
          }
        }
        .buttonStyle(FilledSecondaryButtonStyle())
        Button(action: { Task { await model.restore() } }) {
          if model.activity == .restoring {
            HStack(spacing: Spacing.sm) {
              ProgressView().controlSize(.mini)
              Text("Restoring...")
            }
          } else {
            Text("Restore")
          }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(
          model.isBusy || model.restorePlan == nil || model.restoreBlockedReason != nil
            || model.isConfirmingRestore || model.restoreCompleted)
      }
    }
    .background(Color.cardBackground)
    .onChange(of: model.isBusy) { _, busy in isBusy = busy }
    // The panel can close while Safe Mode asks (a late Touch ID answer must not restore), or
    // the tab can close while the restore runs: it stops, and the panel is no longer busy
    .onDisappear {
      model.sheetDisappeared()
      isBusy = false
    }
  }

  // MARK: - Sections

  private var fileSection: some View {
    SettingsGroupCard(title: "File") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(spacing: Spacing.sm) {
          Text(verbatim: model.restoreFileName ?? "No file selected")
            .font(.bodyText)
            .foregroundColor(model.restoreFileName == nil ? .foregroundMuted : .foreground)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("Choose File...") { Task { await model.chooseRestoreFile() } }
            .buttonStyle(FilledSecondaryButtonStyle())
            .disabled(model.isBusy || model.isConfirmingRestore)
        }
        if model.activity == .reading {
          HStack(spacing: Spacing.sm) {
            ProgressView().controlSize(.small)
            Text("Reading and checking the file...")
              .font(.small)
              .foregroundColor(.foregroundMuted)
          }
        }
        if let size = model.restoreFileSize {
          Text(DataByteCount.text(Int64(size)))
            .font(.monoSmall)
            .foregroundColor(.foregroundMuted)
        }
        Text(
          "Reads Dblore SQL dumps of this engine up to 64 MiB (about 256 MiB of memory while it "
            + "is checked). Every statement is checked before anything runs: only the statements "
            + "a Dblore dump writes (tables, indexes, views, types, sequences and their rows) are "
            + "accepted, and any other statement refuses the whole file. Restoring still runs "
            + "the file's SQL on this connection: column defaults, checks, views and triggers "
            + "in it run as written, so restore only dumps you trust."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func contentsSection(_ summary: SQLRestoreSummary) -> some View {
    SettingsGroupCard(title: "Dump Contents") {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        row("Engine", summary.engine.rawValue)
        row("Statements", summary.statementCount.formatted())
        ForEach(SQLRestoreStatementKind.allCases, id: \.self) { kind in
          if summary.count(kind) > 0 {
            row(Self.kindLabel(kind), summary.count(kind).formatted())
          }
        }
        if !summary.serverVersionOptions.isEmpty {
          Text("Server-version options in CREATE TABLE:")
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .padding(.top, Spacing.xs)
          ForEach(Array(Set(summary.serverVersionOptions)).sorted(), id: \.self) { option in
            Text(verbatim: option)
              .font(.monoSmall)
              .foregroundColor(.foreground)
              .lineLimit(2)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
        }
      }
    }
  }

  private func notesSection(_ engine: DatabaseType) -> some View {
    SettingsGroupCard(title: "Before You Restore") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        switch engine {
        case .mysql:
          note(
            "MySQL commits each schema change at once, so the dump runs one statement at a "
              + "time and cannot be rolled back. Turn Protected mode off for this connection to "
              + "restore it, and commit or roll back any open transaction first.")
        case .postgresql:
          note(
            "The restore runs as one transaction. Under Protected mode it waits for Commit; a "
              + "Roll Back then undoes it, except sequence changes (setval), which stay.")
        default:
          note(
            "The restore runs as one transaction. Under Protected mode it waits for Commit.")
          note(
            "A Schema-only connection refuses SQLite restores: the dump starts with "
              + "PRAGMA defer_foreign_keys = ON, which counts as a schema statement.")
        }
        note("Restore into an empty database: existing tables with the same names make it fail.")
      }
    }
  }

  @ViewBuilder
  private var progressSection: some View {
    if model.activity == .restoring, let progress = model.restoreProgress {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        ProgressView(
          value: progress.statementCount == 0
            ? nil : Double(progress.statementsDone) / Double(progress.statementCount)
        )
        .accessibilityLabel("Restore progress")
        Text(
          "\(progress.statementsDone.formatted()) of \(progress.statementCount.formatted()) "
            + "statements"
        )
        .font(.monoSmall)
        .foregroundColor(.foregroundMuted)
      }
    }
  }

  // MARK: - Helpers

  private func row(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
        .font(.small)
        .foregroundColor(.foregroundMuted)
      Spacer()
      Text(verbatim: value)
        .font(.monoSmall)
        .foregroundColor(.foreground)
    }
  }

  private func note(_ text: String) -> some View {
    Label {
      Text(text)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "info.circle")
        .font(.small)
        .foregroundColor(.foregroundMuted)
    }
  }

  private static func kindLabel(_ kind: SQLRestoreStatementKind) -> String {
    switch kind {
    case .schema: "Schema statements"
    case .trigger: "Triggers"
    case .data: "Data statements"
    case .sequenceValue: "Sequence values"
    case .sessionSetting: "Session settings"
    }
  }

  private static func kindsText(_ summary: SQLRestoreSummary) -> String {
    SQLRestoreStatementKind.allCases.filter { summary.count($0) > 0 }.map {
      counted(summary.count($0), kindNoun($0))
    }.joined(separator: ", ")
  }

  /// Singular, for `counted` ("1 trigger", "2 triggers")
  private static func kindNoun(_ kind: SQLRestoreStatementKind) -> String {
    switch kind {
    case .schema: "schema statement"
    case .trigger: "trigger"
    case .data: "data statement"
    case .sequenceValue: "sequence value"
    case .sessionSetting: "session setting"
    }
  }

  private static func counted(_ count: Int, _ noun: String) -> String {
    "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
  }

  private func close() {
    guard !model.isBusy else { return }
    isPresented = false
  }
}
