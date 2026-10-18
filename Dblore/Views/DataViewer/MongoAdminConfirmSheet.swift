//
//  MongoAdminConfirmSheet.swift
//  Dblore
//
//  Confirmation of one MongoDB administration command (`MongoAdminActionModel`): the typed-name
//  step of a drop first, then the Safe Mode panel with the exact mongosh text that is sent. The
//  panel is only built once the name matches, so its Touch ID prompt cannot skip the typed name.
//  Then the running and failed states; the sheet closes once the command is done.
//  `MongoBulkWriteConfirmSheet` does the same for a bulk update or delete, with its count line.
//

import SwiftUI

struct MongoAdminConfirmSheet: View {
  let model: MongoAdminActionModel
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool

  @Environment(\.dismiss) private var dismiss
  /// The name typed in the typed-name step; nil until that step is passed
  @State private var typedName: String?

  private static let width: CGFloat = 520

  /// Presents the sheet while `model` asks, runs what the sheet confirmed, or shows a failure;
  /// a command sent without asking runs without it. Closing it cancels.
  static func isPresented(_ model: MongoAdminActionModel) -> Binding<Bool> {
    Binding(
      get: {
        switch model.state {
        case .confirming, .failed: true
        case .running: model.runsConfirmed
        case .idle, .done: false
        }
      },
      set: { if !$0 { model.cancel() } })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
    }
    .frame(width: Self.width)
    .background(Color.appBackground)
    .interactiveDismissDisabled(model.state == .running)
    .onChange(of: model.state) { _, state in
      // A new confirmation starts at its typed-name step again
      typedName = nil
      if state == .done { close() }
    }
    // A late Touch ID answer after the sheet closed must not send, nor send a later
    // confirmation of the same model (the panel checks `isPending` for this confirmation)
    .onDisappear { model.cancel() }
  }

  // MARK: - Sections

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Text(title)
        .font(.subheading)
        .foregroundColor(.foreground)
      Spacer()
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .keyboardShortcut(.cancelAction)
      .disabled(model.state == .running)
      .help("Close")
    }
    .modalBarPadding(vertical: Spacing.sm)
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .confirming(let pending):
      if let database = pending.database {
        // A database command shows the database it creates or drops
        Text(pending.objectKind == "database" ? "Database \(database)" : "In database \(database)")
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .padding([.horizontal, .top], Spacing.md)
      }
      if let name = pending.typedName, typedName == nil {
        TypedNameConfirmation(
          objectKind: pending.objectKind, name: name, confirmTitle: title, onCancel: close,
          onConfirm: { typed in
            if pending.needsSafeModePanel {
              typedName = typed
            } else {
              Task { await model.confirm(pending, typedName: typed) }
            }
          })
      } else {
        SafeModeConfirmationPanel(
          requiresPassword: pending.requiresPassword, confirmTitle: title,
          biometricReason: "Authorize the MongoDB change in Safe Mode",
          databasePassword: databasePassword, isConnected: isConnected,
          isPending: { [model] in model.isPending(pending) },
          onCancel: close,
          onConfirm: { [model, typedName] in
            await model.confirm(pending, typedName: typedName ?? "")
          }
        ) {
          Text(verbatim: pending.text)
            .font(.mono)
            .foregroundColor(.foreground)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    case .running:
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        Text("Running...")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
      .frame(maxWidth: .infinity, minHeight: 80)
    case .failed(let message):
      VStack(alignment: .leading, spacing: Spacing.md) {
        Label {
          Text(message)
            .font(.bodyText)
            .foregroundColor(.foreground)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.destructive)
        }
        HStack {
          Spacer()
          Button("Close", action: close)
            .buttonStyle(FilledSecondaryButtonStyle())
        }
      }
      .padding(Spacing.md)
    case .idle, .done:
      EmptyView()
    }
  }

  // MARK: - Helpers

  /// The command's action, as the sheet title and the destructive button title
  private var title: String {
    guard case .confirming(let pending) = model.state else { return "MongoDB Command" }
    switch pending.command {
    case .createIndex: return "Create Index"
    case .dropIndex: return "Drop Index"
    case .setIndexHidden(_, _, let hidden): return hidden ? "Hide Index" : "Unhide Index"
    case .createCollection: return "Create Collection"
    case .createView: return "Create View"
    case .drop: return pending.objectKind == "view" ? "Drop View" : "Drop Collection"
    case .renameCollection: return "Rename Collection"
    case .collMod: return "Modify Collection"
    case .createDatabase: return "Create Database"
    case .dropDatabase: return "Drop Database"
    }
  }

  /// Leaves without sending anything (no-op while the command runs)
  private func close() {
    guard model.state != .running else { return }
    model.cancel()
    dismiss()
  }
}

/// Confirmation of a bulk update or delete (`MongoBulkWriteModel`): the count line ("Deletes
/// 12,345 documents") and the all-documents warning of an empty filter over every step; the
/// typed collection name first when asked, then the Safe Mode panel, or under Immediate an
/// inline Confirm step (a second step is always shown). The panel is only built once the name
/// matches, so its Touch ID prompt cannot skip the typed name. Presented while the model asks or
/// runs; a failure or the result shows in the form under it.
struct MongoBulkWriteConfirmSheet: View {
  let model: MongoBulkWriteModel
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool

  @Environment(\.dismiss) private var dismiss
  /// The name typed in the typed-name step; nil until that step is passed
  @State private var typedName: String?

  private static let width: CGFloat = 520

  /// Presents the sheet while `model` asks or runs what it confirmed. Closing it cancels.
  static func isPresented(_ model: MongoBulkWriteModel) -> Binding<Bool> {
    Binding(
      get: {
        switch model.state {
        case .confirming, .running: true
        case .idle, .previewing, .ready, .failed, .done: false
        }
      },
      set: { if !$0 { model.cancel() } })
  }

  /// "Deletes 12,345 documents", "Updates 1 document", "Deletes an unknown number of documents"
  static func countLine(mode: MongoBulkWriteModel.Mode, count: Int?) -> String {
    let verb = mode == .update ? "Updates" : "Deletes"
    guard let count else { return "\(verb) an unknown number of documents" }
    return "\(verb) \(count.formatted()) document\(count == 1 ? "" : "s")"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
    }
    .frame(width: Self.width)
    .background(Color.appBackground)
    .interactiveDismissDisabled(model.state == .running)
    .onChange(of: model.state) { _, _ in
      // A new confirmation starts at its typed-name step again
      typedName = nil
    }
    // A late Touch ID answer after the sheet closed must not send, nor send a later
    // confirmation (the panel checks `isPending` for this one). A failure or a result stays for
    // the form.
    .onDisappear {
      if case .confirming = model.state { model.cancel() }
    }
  }

  // MARK: - Sections

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Text(title)
        .font(.subheading)
        .foregroundColor(.foreground)
      Spacer()
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .keyboardShortcut(.cancelAction)
      .disabled(model.state == .running)
      .help("Close")
    }
    .modalBarPadding(vertical: Spacing.sm)
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .confirming(let pending):
      summary(pending)
      if let name = pending.typedName, typedName == nil {
        TypedNameConfirmation(
          objectKind: "collection", name: name, confirmTitle: title, onCancel: close,
          onConfirm: { typedName = $0 })
      } else if pending.needsSafeModePanel {
        SafeModeConfirmationPanel(
          requiresPassword: pending.requiresPassword, confirmTitle: title,
          biometricReason: "Authorize the MongoDB change in Safe Mode",
          databasePassword: databasePassword, isConnected: isConnected,
          isPending: { [model] in model.isPending(pending) },
          onCancel: close,
          onConfirm: { [model, typedName] in
            await model.confirm(pending, typedName: typedName ?? "")
          }
        ) {
          commandText(pending)
        }
      } else {
        inlineConfirm(pending)
      }
    case .running:
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        Text("Running...")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
      .frame(maxWidth: .infinity, minHeight: 80)
    case .idle, .previewing, .ready, .failed, .done:
      EmptyView()
    }
  }

  /// The count line, and the existing warning when the filter is empty
  private func summary(_ pending: MongoBulkWriteModel.Confirmation) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text(Self.countLine(mode: pending.mode, count: pending.count))
        .font(.bodyText)
        .foregroundColor(.foreground)
      if pending.affectsAllRows {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.destructive)
          Text(
            "WARNING: This command has an empty filter and will affect ALL documents in "
              + "\(model.collection)!"
          )
          .font(.bodyText)
          .foregroundColor(.destructive)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .background(Color.destructive.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      }
    }
    .padding([.horizontal, .top], Spacing.md)
  }

  /// Immediate commit style: no Safe Mode panel, so this step asks before anything is sent
  private func inlineConfirm(_ pending: MongoBulkWriteModel.Confirmation) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text(pending.question)
        .font(.subheading)
        .foregroundColor(.foreground)
      commandText(pending)
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
        .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))
      HStack(spacing: Spacing.md) {
        Spacer()
        Button("Cancel", action: close)
          .buttonStyle(FilledSecondaryButtonStyle())
        Button(title) {
          Task { [model, typedName] in await model.confirm(pending, typedName: typedName ?? "") }
        }
        .buttonStyle(DangerButtonStyle())
      }
    }
    .padding(Spacing.md)
  }

  private func commandText(_ pending: MongoBulkWriteModel.Confirmation) -> some View {
    Text(verbatim: pending.text)
      .font(.mono)
      .foregroundColor(.foreground)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: - Helpers

  /// The sheet title and the destructive button title
  private var title: String {
    // The form's mode while the command runs (it cannot change under the sheet)
    var mode = model.mode
    if case .confirming(let pending) = model.state { mode = pending.mode }
    return mode == .update ? "Update Documents" : "Delete Documents"
  }

  /// Leaves without sending anything (no-op while the command runs)
  private func close() {
    guard model.state != .running else { return }
    model.cancel()
    dismiss()
  }
}
