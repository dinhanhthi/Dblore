import Foundation
import SwiftUI

/// Restore Backup (MongoDB) in the right side panel: an open panel (every line of the file is
/// checked off the main actor before anything is sent), what the backup holds and the database
/// it was read from when that is not the connection's, the collections and views that already
/// exist with Drop existing first, then the typed database name (when something is dropped) and
/// the Safe Mode panel in a sheet over the panel, then the restore with progress and Cancel.
/// The presenter refuses to close the panel while it works.
struct MongoRestoreSheet: View {
  let model: MongoBackupModel
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool
  @Binding var isPresented: Bool

  @State private var dropExisting = false

  private var isConfirming: Bool {
    if case .confirming = model.state { true } else { false }
  }

  private var isRestoring: Bool {
    if case .restoring = model.state { true } else { false }
  }

  private var canRestore: Bool {
    model.header != nil && !model.isBusy && !isConfirming && !model.restoreStarted
      && (model.collisions.isEmpty || dropExisting)
  }

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: "Restore Backup", titleIcon: "square.and.arrow.down", onClose: close)
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          fileSection
          if let header = model.header {
            contentsSection(header)
            if !model.collisions.isEmpty { collisionsSection }
          }
          progressSection
          messageSection
          if model.restoreStarted, !model.isBusy {
            Text("Choose the file again to restore it again.")
              .font(.small)
              .foregroundColor(.foregroundMuted)
          }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: .infinity)
      GenericModalFooter {
        Spacer()
        Button(cancels ? "Cancel" : "Close") {
          if cancels {
            model.cancel()
          } else {
            close()
          }
        }
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(model.choosingFile || model.cancelRequested)
        Button {
          let drop = dropExisting
          Task { await model.requestRestore(dropExisting: drop) }
        } label: {
          if isRestoring {
            HStack(spacing: Spacing.sm) {
              ProgressView().controlSize(.mini)
              Text("Restoring...")
            }
          } else {
            Text("Restore")
          }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!canRestore)
      }
    }
    .background(Color.cardBackground)
    // A new file starts without Drop existing first
    .onChange(of: model.restoreURL) { _, _ in dropExisting = false }
    .sheet(isPresented: MongoRestoreConfirmSheet.isPresented(model)) {
      MongoRestoreConfirmSheet(
        model: model, databasePassword: databasePassword, isConnected: isConnected)
    }
  }

  /// The footer button stops the check or the restore
  private var cancels: Bool {
    switch model.state {
    case .reading, .restoring: true
    case .idle, .backingUp, .confirming, .done, .failed, .cancelled: false
    }
  }

  // MARK: - Sections

  private var fileSection: some View {
    SettingsGroupCard(title: "File") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(spacing: Spacing.sm) {
          Text(verbatim: model.restoreURL?.lastPathComponent ?? "No file selected")
            .font(.bodyText)
            .foregroundColor(model.restoreURL == nil ? .foregroundMuted : .foreground)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(model.restoreURL?.path ?? "")
          Button("Choose File...") { Task { await model.chooseRestoreFile() } }
            .buttonStyle(FilledSecondaryButtonStyle())
            .disabled(model.isBusy || isConfirming)
        }
        if model.state == .reading {
          HStack(spacing: Spacing.sm) {
            ProgressView().controlSize(.small)
            Text("Reading and checking the file...")
              .font(.small)
              .foregroundColor(.foregroundMuted)
          }
        }
        Text(
          "Reads Dblore MongoDB backups (.ndjson). Every line is checked before anything is "
            + "sent. The backup restores into \(model.database): its collections are created "
            + "with their options, then their documents, indexes and validator, then the views. "
            + "A restore that stops is not rolled back."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func contentsSection(_ header: MongoBackupHeader) -> some View {
    SettingsGroupCard(title: "Backup Contents") {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        if let source = model.sourceDatabase {
          row("Backed up from", source)
        }
        row("Restores into", model.database)
        row(
          "Created",
          Date(timeIntervalSince1970: Double(header.createdAt) / 1000)
            .formatted(date: .abbreviated, time: .shortened))
        row("Collections", header.collections.count.formatted())
        row("Views", header.views.count.formatted())
        row("Documents", model.documentCount.formatted())
      }
    }
  }

  private var collisionsSection: some View {
    SettingsGroupCard(title: "Already in \(model.database)") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        ForEach(model.collisions, id: \.self) { name in
          Text(verbatim: name)
            .font(.monoMedium)
            .foregroundColor(.foreground)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        Toggle("Drop existing first", isOn: $dropExisting)
          .toggleStyle(.checkbox)
          .font(.bodyText)
          .disabled(model.isBusy || isConfirming || model.restoreStarted)
        Text(
          "Drops only the collections and views listed above, with their documents, before the "
            + "restore. You type the database name to confirm."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private var progressSection: some View {
    if case .restoring(let progress) = model.state {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        ProgressView(
          value: progress.documentsTotal == 0
            ? nil : Double(progress.documentsInserted) / Double(progress.documentsTotal)
        )
        .accessibilityLabel("Restore progress")
        Text(
          model.cancelRequested
            ? "Stopping before the next command..."
            : "\(progress.collectionsDone) of \(progress.collectionsTotal) collections, "
              + "\(progress.documentsInserted.formatted()) of "
              + "\(progress.documentsTotal.formatted()) documents"
        )
        .font(.monoSmall)
        .foregroundColor(.foregroundMuted)
      }
    }
  }

  @ViewBuilder
  private var messageSection: some View {
    switch model.state {
    case .done(let message): BackupMessageBox(text: message, isError: false)
    case .failed(let message): BackupMessageBox(text: message, isError: true)
    case .cancelled(let message): BackupMessageBox(text: message, isError: false)
    case .idle, .reading, .backingUp, .confirming, .restoring: EmptyView()
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
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private func close() {
    guard !model.isBusy else { return }
    isPresented = false
  }
}

/// The confirmation of a restore (`MongoBackupModel`): the typed database name first when
/// existing collections or views are dropped, then the Safe Mode panel with the summary. The
/// panel is only built once the name matches, so its Touch ID prompt cannot skip the typed name.
/// Presented while the model asks only: once confirmed the panel under it shows the progress.
struct MongoRestoreConfirmSheet: View {
  let model: MongoBackupModel
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool

  @Environment(\.dismiss) private var dismiss
  /// The name typed in the typed-name step; nil until that step is passed
  @State private var typedName: String?

  private static let width: CGFloat = 520
  private static let title = "Restore Backup"

  /// Presents the sheet while `model` asks. Closing it leaves the confirmation.
  static func isPresented(_ model: MongoBackupModel) -> Binding<Bool> {
    Binding(
      get: {
        if case .confirming = model.state { true } else { false }
      },
      set: { if !$0, case .confirming = model.state { model.cancel() } })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      if case .confirming(let pending) = model.state {
        summary(pending)
        if let name = pending.typedName, typedName == nil {
          TypedNameConfirmation(
            objectKind: "database", name: name, confirmTitle: "Drop and Restore",
            onCancel: close,
            onConfirm: { typed in
              if pending.needsSafeModePanel {
                typedName = typed
              } else {
                Task { await model.confirm(pending, typedName: typed) }
              }
            })
        } else {
          SafeModeConfirmationPanel(
            requiresPassword: pending.requiresPassword, confirmTitle: "Restore",
            biometricReason: "Authorize the MongoDB restore in Safe Mode",
            databasePassword: databasePassword, isConnected: isConnected,
            isPending: { [model] in model.isPending(pending) },
            onCancel: close,
            onConfirm: { [model, typedName] in
              await model.confirm(pending, typedName: typedName ?? "")
            }
          ) {
            Text(verbatim: Self.restoreLine(pending))
              .font(.bodyText)
              .foregroundColor(.foreground)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.top, Spacing.md)
        }
      }
    }
    .frame(width: Self.width)
    .background(Color.appBackground)
    .onChange(of: model.state) { _, _ in
      // A new confirmation starts at its typed-name step again
      typedName = nil
    }
    // A late Touch ID answer after the sheet closed must not send (the panel checks
    // `isPending`); a running restore is left alone
    .onDisappear {
      if case .confirming = model.state { model.cancel() }
    }
  }

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Text(Self.title)
        .font(.subheading)
        .foregroundColor(.foreground)
      Spacer()
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .keyboardShortcut(.cancelAction)
      .help("Close")
    }
    .modalBarPadding(vertical: Spacing.sm)
  }

  /// The file, the database written into (and the one backed up when it differs) and what is
  /// dropped first
  private func summary(_ pending: MongoBackupModel.RestoreConfirmation) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(verbatim: "From \(pending.fileName)")
        .font(.small)
        .foregroundColor(.foregroundMuted)
      if let source = pending.sourceDatabase {
        Text(verbatim: "Backed up from \(source); restores into \(pending.database)")
          .font(.small)
          .foregroundColor(.foreground)
      }
      if !pending.drops.isEmpty {
        Text(verbatim: "Drops first: \(pending.drops.joined(separator: ", "))")
          .font(.small)
          .foregroundColor(.destructive)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .textSelection(.enabled)
    .padding([.horizontal, .top], Spacing.md)
  }

  /// "Restores 3 collections, 1 view and 12,000 documents into shop."
  private static func restoreLine(_ pending: MongoBackupModel.RestoreConfirmation) -> String {
    "Restores \(counted(pending.collections, "collection")), "
      + "\(counted(pending.views, "view")) and \(counted(pending.documents, "document")) into "
      + "\(pending.database)."
  }

  private static func counted(_ count: Int, _ noun: String) -> String {
    "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
  }

  /// Leaves without sending anything
  private func close() {
    if case .confirming = model.state { model.cancel() }
    dismiss()
  }
}
