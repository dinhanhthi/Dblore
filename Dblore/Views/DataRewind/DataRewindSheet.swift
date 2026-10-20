// DataRewindSheet.swift
// Data Rewind in the right side panel: the recorded data viewer edits of this connection with
// their state, the exact inverse SQL of the ones picked, consent for rows that cannot be undone,
// then the Safe Mode confirmation and one atomic rewind (`DataRewindModel`).

import SwiftUI

/// The Data Rewind panel of `workspaceManager.dataRewind` (it cannot close while the rewind
/// runs), and the View menu's action: nil unless edits are recorded on this connection, else
/// through the active tab or a new SQL file.
struct DataRewindPanel: ViewModifier {
  let workspaceManager: WorkspaceManager

  private var isPresented: Binding<Bool> {
    Binding(
      get: { workspaceManager.dataRewind != nil },
      set: {
        guard !$0, workspaceManager.dataRewind?.model.activity != .rewinding else { return }
        workspaceManager.dataRewind = nil
      })
  }

  private var openAction: (() -> Void)? {
    guard workspaceManager.canOpenDataRewind else { return nil }
    return { [workspaceManager] in workspaceManager.openDataRewind() }
  }

  func body(content: Content) -> some View {
    content
      .focusedSceneValue(\.openDataRewindAction, openAction)
      .sidePanelOverlay(isPresented: isPresented, width: DataRewindSheet.panelWidth) {
        if let request = workspaceManager.dataRewind {
          DataRewindSheet(
            model: request.model,
            databasePassword: workspaceManager.workspace.connectionConfig?.password,
            isConnected: workspaceManager.connectionState == .connected,
            isPresented: isPresented
          )
          .id(ObjectIdentifier(request.model))
        }
      }
  }
}

struct DataRewindSheet: View {
  @Bindable var model: DataRewindModel
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool
  @Binding var isPresented: Bool

  /// Width of the right sidebar the sheet opens in (the inverse SQL needs room)
  static let panelWidth: CGFloat = 640

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: "Data Rewind", titleIcon: "clock.arrow.circlepath", onClose: close)
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          Text(
            "Undo data viewer edits on this connection. Pick edits to see the exact SQL that "
              + "puts their rows back. It runs as one batch: if any row changed since the edit, "
              + "nothing is rewound."
          )
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .fixedSize(horizontal: false, vertical: true)
          entriesSection
          if model.activity == .planning {
            HStack(spacing: Spacing.sm) {
              ProgressView().controlSize(.small)
              Text("Reading the rows and the table...")
                .font(.small)
                .foregroundColor(.foregroundMuted)
            }
          }
          if let plan = model.plan {
            previewSection(plan)
          }
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
      if model.isConfirming, let plan = model.plan {
        SafeModeConfirmationPanel(
          requiresPassword: model.confirmationRequiresPassword, confirmTitle: "Rewind",
          biometricReason: "Authorize the Data Rewind in Safe Mode",
          databasePassword: databasePassword, isConnected: isConnected,
          isPending: { [model, presented = $isPresented] in
            model.isConfirming && presented.wrappedValue
          },
          onCancel: { [model] in model.cancelConfirmation() },
          onConfirm: { [model] in await model.confirmRewind() }
        ) {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Rewind \(Self.counted(plan.entryIDs.count, "edit")) with these statements:")
              .font(.bodyText)
              .foregroundColor(.foreground)
            SafeModeStatementList(statements: model.confirmation)
          }
        }
      }
      GenericModalFooter {
        Spacer()
        Button("Close", action: close)
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(model.activity == .rewinding)
        Button(action: { Task { await model.rewind() } }) {
          if model.activity == .rewinding {
            HStack(spacing: Spacing.sm) {
              ProgressView().controlSize(.mini)
              Text("Rewinding...")
            }
          } else {
            Text("Rewind")
          }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!model.canRewind)
      }
    }
    .background(Color.cardBackground)
    .task { await model.load() }
    // A late Touch ID answer after the panel closed must not rewind
    .onDisappear { model.sheetDisappeared() }
  }

  // MARK: - Sections

  private var entriesSection: some View {
    SettingsGroupCard(title: "Edits") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        if model.activity == .loading && model.items.isEmpty {
          ProgressView().controlSize(.small)
        } else if model.items.isEmpty {
          Text("No data viewer edits were recorded on this connection.")
            .font(.small)
            .foregroundColor(.foregroundMuted)
        }
        LazyVStack(alignment: .leading, spacing: Spacing.sm) {
          ForEach(model.items) { item in
            entryRow(item)
          }
        }
      }
    }
  }

  private func entryRow(_ item: DataRewindModel.Item) -> some View {
    let entry = item.entry
    let isOn = Binding(
      get: { model.selection.contains(item.id) },
      set: { _ in Task { await model.toggle(item.id) } })
    return HStack(alignment: .top, spacing: Spacing.sm) {
      Toggle("", isOn: isOn)
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(!item.status.isSelectable || model.isBusy || model.isConfirming)
        .accessibilityLabel("Rewind the edit of \(entry.table)")
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(verbatim: entry.table)
          .font(.bodyText)
          .foregroundColor(item.status.isSelectable ? .foreground : .foregroundMuted)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(
          "\(entry.created.formatted(date: .abbreviated, time: .standard)) · "
            + "\(Self.counted(entry.statementCount, "row")) · "
            + (entry.editKind == .staged ? "Staged" : "Inline")
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        if entry.notCaptured {
          note("Some rows were not captured")
        }
        if let reason = entry.notRewindableReason {
          note("Some rows cannot be undone: \(reason)")
        }
      }
      Spacer(minLength: Spacing.sm)
      Text(item.status.label)
        .font(.caption2)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .padding(.horizontal, Spacing.xs)
        .background(Capsule().fill(Color.inputBackground))
        .overlay(HairlineBorder(shape: Capsule()))
    }
  }

  private func previewSection(_ plan: RewindInverse) -> some View {
    SettingsGroupCard(title: "Inverse SQL") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        if plan.statements.isEmpty {
          Text("Nothing to undo: the picked edits changed no value that can be put back.")
            .font(.small)
            .foregroundColor(.foregroundMuted)
        } else {
          SQLCodeWell(sql: plan.preview, dialect: model.dialect)
            .frame(height: 220)
        }
        if !plan.skipped.isEmpty {
          Text("Left out (no row image or key was recorded):")
            .font(.small)
            .foregroundColor(.foreground)
          ForEach(plan.skipped.indices, id: \.self) { index in
            let skipped = plan.skipped[index]
            Text(
              verbatim: "\(skipped.origin.operation.rawValue) of \(skipped.origin.table)"
                + (skipped.origin.key.isEmpty ? "" : " \(skipped.origin.key)")
                + " (\(skipped.reason))"
            )
            .font(.monoSmall)
            .foregroundColor(.foregroundMuted)
            .lineLimit(1)
            .truncationMode(.middle)
          }
          Toggle("Rewind without these rows", isOn: $model.skipConsent)
            .toggleStyle(.checkbox)
            .font(.small)
            .disabled(model.isBusy || model.isConfirming)
        }
      }
    }
  }

  // MARK: - Helpers

  private func note(_ text: String) -> some View {
    Label {
      Text(text)
        .font(.small)
        .foregroundColor(.foregroundMuted)
    } icon: {
      Image(systemName: "info.circle")
        .font(.small)
        .foregroundColor(.foregroundMuted)
    }
  }

  private static func counted(_ count: Int, _ noun: String) -> String {
    "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
  }

  private func close() {
    guard model.activity != .rewinding else { return }
    isPresented = false
  }
}
