//
//  MongoAdminConfirmSheet.swift
//  Dblore
//
//  Confirmation of one MongoDB administration command (`MongoAdminActionModel`): the typed-name
//  step of a drop first, then the Safe Mode panel with the exact mongosh text that is sent. The
//  panel is only built once the name matches, so its Touch ID prompt cannot skip the typed name.
//  Then the running and failed states; the sheet closes once the command is done.
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
    case .drop: return "Drop Collection"
    case .renameCollection: return "Rename Collection"
    case .collMod: return "Modify Collection"
    }
  }

  /// Leaves without sending anything (no-op while the command runs)
  private func close() {
    guard model.state != .running else { return }
    model.cancel()
    dismiss()
  }
}
