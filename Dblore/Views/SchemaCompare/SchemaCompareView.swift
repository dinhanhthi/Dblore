// SchemaCompareView.swift
// The Compare Schemas sheet: the source (this connection or a saved connection of the same
// engine, and its schema), the target schema of this connection, Compare with progress and
// Cancel, the differences grouped by table with a checkbox per table and per item (drops tagged
// destructive, unticked by default), manual items and warnings under their item, and the exact
// script Run sends (`SQLCodeWell`), with Copy Script and Save Script. Run asks about selected
// drops first, then Safe Mode inside the sheet, as the structure editor does. A source that
// cannot connect shows a fixed message, the driver's text under Details.

import AppKit
import SwiftUI

extension View {
  func schemaCompareSheet(workspaceManager: WorkspaceManager) -> some View {
    sheet(
      item: Binding(
        get: { workspaceManager.schemaCompare },
        set: { if $0 == nil { workspaceManager.closeSchemaCompare() } })
    ) { model in
      SchemaCompareView(
        model: model,
        databasePassword: workspaceManager.workspace.connectionConfig?.password,
        isConnected: workspaceManager.connectionState == .connected,
        isShown: { [weak workspaceManager, weak model] in
          model != nil && workspaceManager?.schemaCompare === model
        },
        onClose: { workspaceManager.closeSchemaCompare() })
    }
  }
}

private struct SchemaCompareView: View {
  @Bindable var model: SchemaCompareModel
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool
  /// False once the sheet was closed or replaced (a late Touch ID answer then sends nothing)
  let isShown: () -> Bool
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: "Compare Schemas", titleIcon: "arrow.left.arrow.right", titleIconColor: .accent,
        titleBadge: model.databaseType.rawValue, onClose: onClose
      ) {
        EmptyView()
      }
      pickers
        .padding(Spacing.md)
        .disabled(model.isComparing || model.isRunning)
      Divider()
      banners
      HStack(spacing: 0) {
        differences
          .frame(width: 440)
        Divider()
        scriptPreview
      }
      .frame(maxHeight: .infinity)
      if let statements = model.pendingDestructive {
        destructiveConfirmation(statements)
      }
      if let statements = model.pendingConfirmation {
        SafeModeConfirmationPanel(
          requiresPassword: model.confirmationRequiresPassword, confirmTitle: "Run",
          biometricReason: "Authorize running the schema script in Safe Mode",
          databasePassword: databasePassword, isConnected: isConnected,
          isPending: { [model] in model.pendingConfirmation != nil && isShown() },
          onCancel: { [model] in model.cancelConfirmation() },
          onConfirm: { [model] in await model.confirmRun() }
        ) {
          SafeModeStatementList(statements: statements)
        }
      }
      footer
    }
    .frame(width: 960, height: 700)
    .background(Color.cardBackground)
    .interactiveDismissDisabled(model.isRunning)
  }

  // MARK: - Source and target

  private var sourceConnectionTitle: String {
    guard case .saved(let id) = model.sourceConnection else { return "This connection" }
    return model.savedConnections.first { $0.id == id }?.name ?? "This connection"
  }

  private var pickers: some View {
    HStack(alignment: .bottom, spacing: Spacing.md) {
      labeled("Source") {
        CapsulePickerMenu(title: sourceConnectionTitle, width: 220) {
          Picker("Source", selection: $model.sourceConnection) {
            Text("This connection").tag(SchemaCompareModel.SourceConnection.current)
            if !model.savedConnections.isEmpty {
              Divider()
              ForEach(model.savedConnections) { saved in
                // A locked row asks before Compare reads it
                Group {
                  if saved.isLocked {
                    Label(saved.name, systemImage: "lock.fill")
                  } else {
                    Text(saved.name)
                  }
                }
                .tag(SchemaCompareModel.SourceConnection.saved(saved.id))
              }
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        }
        .accessibilityLabel("Source")
      }
      labeled("Source \(model.schemaLabel.lowercased())") {
        // A saved connection's schemas are not listed before it is opened; MySQL lists only the
        // connected database
        if model.sourceConnection == .current, model.databaseType != .mysql {
          CapsulePickerMenu(title: model.sourceSchema, width: 180) {
            Picker("Source \(model.schemaLabel)", selection: $model.sourceSchema) {
              ForEach(model.sourceSchemas, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
          }
          .accessibilityLabel("Source \(model.schemaLabel)")
        } else {
          TextField(model.schemaLabel, text: $model.sourceSchema)
            .textFieldStyle(.plain)
            .font(.structureField)
            .autocorrectionDisabled()
            .structureInputStyle()
            .frame(width: 180)
        }
      }
      Image(systemName: "arrow.right")
        .foregroundColor(.foregroundMuted)
        .padding(.bottom, Spacing.xs)
      labeled("Target \(model.schemaLabel.lowercased()) (this connection)") {
        CapsulePickerMenu(title: model.targetSchema, width: 180) {
          Picker("Target \(model.schemaLabel)", selection: $model.targetSchema) {
            ForEach(model.targetSchemas, id: \.self) { Text($0).tag($0) }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        }
        .accessibilityLabel("Target \(model.schemaLabel)")
        .disabled(model.targetSchemas.count < 2)
      }
      Spacer(minLength: Spacing.sm)
      if model.isComparing {
        Button("Cancel") { model.cancelCompare() }
          .buttonStyle(FilledSecondaryButtonStyle())
      } else {
        Button(model.hasResult ? "Compare Again" : "Compare") {
          Task { await model.compare() }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!model.canCompare)
      }
    }
  }

  // MARK: - Banners

  @ViewBuilder
  private var banners: some View {
    let shown =
      model.isComparing || model.compareError != nil || model.runError != nil
      || model.resultMessage != nil || model.runDisabledReason != nil
      || !model.diffWarnings.isEmpty || !model.sourceDiffersFromTarget
    if shown {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        if let progress = model.progress {
          progressRow(progress)
        }
        if !model.sourceDiffersFromTarget {
          StructureBanner(
            text: "The source and the target are the same schema. Pick another one.",
            systemImage: "info.circle", color: .foregroundMuted)
        }
        if let error = model.compareError {
          StructureBanner(text: error, systemImage: "exclamationmark.triangle", color: .destructive)
          if let detail = model.compareErrorDetail {
            DisclosureGroup("Details") {
              Text(detail)
                .font(.monoSmall)
                .foregroundColor(.foregroundMuted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.small)
          }
        }
        ForEach(model.diffWarnings, id: \.self) { warning in
          StructureBanner(text: warning, systemImage: "exclamationmark.triangle", color: .warning)
        }
        if let reason = model.runDisabledReason {
          StructureBanner(text: reason, systemImage: "lock", color: .warning)
        }
        if let error = model.runError {
          runFailure(error)
        }
        if let message = model.resultMessage {
          StructureBanner(
            text: "\(message). Compare again to check the schemas as they are now.",
            systemImage: "checkmark.circle", color: .success)
        }
      }
      .padding(Spacing.md)
      Divider()
    }
  }

  private func progressRow(_ progress: SchemaCompareModel.Progress) -> some View {
    let side = progress.side == .source ? "the source" : "the target"
    let text: String
    if let total = progress.total {
      text = "Reading \(side): \(progress.done.formatted()) of \(total.formatted()) tables…"
    } else {
      text = "Reading \(side)…"
    }
    return HStack(spacing: Spacing.sm) {
      if let total = progress.total, total > 0 {
        ProgressView(value: Double(progress.done), total: Double(total))
          .progressViewStyle(.linear)
          .frame(width: 160)
      } else {
        ProgressView().controlSize(.small)
      }
      Text(text)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .monospacedDigit()
    }
  }

  /// The failure, and for a run stopped part way, what ran and what did not
  private func runFailure(_ error: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      StructureBanner(text: error, systemImage: "exclamationmark.triangle", color: .destructive)
      if let report = model.runReport {
        Text(
          "Ran: \(report.applied.count). Failed: 1. Not run: \(report.notRun.count)."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        if let failed = report.failed {
          Text(failed)
            .font(.monoSmall)
            .foregroundColor(.foreground)
            .lineLimit(3)
            .textSelection(.enabled)
        }
      }
    }
  }

  // MARK: - Differences

  @ViewBuilder
  private var differences: some View {
    if !model.hasResult {
      placeholder(
        model.isComparing ? "Comparing…" : "Pick a source and a target, then Compare.")
    } else if model.items.isEmpty {
      placeholder("The schemas match.")
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Spacing.sm) {
          ForEach(model.tableGroups) { group in
            tableRow(group)
            ForEach(group.items) { item in
              itemRow(item)
            }
          }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .disabled(!model.canEditSelection)
    }
  }

  private func tableRow(_ group: SchemaCompareModel.TableGroup) -> some View {
    Toggle(
      isOn: Binding(
        get: { group.items.allSatisfy(\.isSelected) },
        set: { model.setTableSelected(group.table, $0) })
    ) {
      Label(group.table, systemImage: "tablecells")
        .font(.bodyText)
        .fontWeight(.medium)
        .foregroundColor(.foreground)
    }
    .toggleStyle(.checkbox)
    .padding(.top, Spacing.xs)
  }

  private func itemRow(_ item: SchemaDiffItem) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
      Toggle(
        "Include",
        isOn: Binding(get: { item.isSelected }, set: { model.setSelected(item.id, $0) })
      )
      .toggleStyle(.checkbox)
      .labelsHidden()
      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
          Text(item.description)
            .font(.small)
            .foregroundColor(.foreground)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          if model.isDestructive(item) {
            destructiveTag
          }
        }
        ForEach(Array(model.manualItems(for: item.id).enumerated()), id: \.offset) { _, manual in
          note("Not scripted, change it by hand: \(manual.reason)", color: .warning)
        }
        ForEach(Array(model.warnings(for: item.id).enumerated()), id: \.offset) { _, warning in
          note(warning, color: .warning)
        }
      }
    }
    .padding(.leading, Spacing.lg)
  }

  private var destructiveTag: some View {
    Text("destructive")
      .font(.smallest)
      .foregroundColor(.destructive)
      .padding(.horizontal, Spacing.xs)
      .background(Color.destructive.opacity(0.12), in: Capsule())
  }

  private func note(_ text: String, color: Color) -> some View {
    Label(text, systemImage: "exclamationmark.triangle")
      .font(.smallest)
      .foregroundColor(color)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func placeholder(_ text: String) -> some View {
    Text(text)
      .font(.bodyText)
      .foregroundColor(.foregroundMuted)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Script

  private var scriptPreview: some View {
    // The schema the script was built for, not the picker's (a changed picker clears the script)
    let schema = model.comparedTargetSchema ?? model.targetSchema
    return VStack(alignment: .leading, spacing: Spacing.sm) {
      Text(
        model.runsInPendingTransaction
          ? "Run sends exactly this SQL to \(schema); it is kept only after Commit"
          : "Run sends exactly this SQL to \(schema)"
      )
      .font(.small)
      .foregroundColor(.foregroundSubtle)
      SQLCodeWell(
        sql: model.scriptText,
        placeholder: model.hasResult ? "Nothing to run for the ticked items" : "No script yet",
        dialect: model.databaseType.dialect)
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  // MARK: - Confirmation and footer

  private func destructiveConfirmation(_ statements: [String]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Divider()
      Label(
        "The script drops \(statements.count == 1 ? "1 object" : "\(statements.count) objects"). "
          + "Their data cannot be recovered.",
        systemImage: "exclamationmark.triangle"
      )
      .font(.small)
      .foregroundColor(.destructive)
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          ForEach(Array(statements.enumerated()), id: \.offset) { _, sql in
            Text(sql)
              .font(.monoSmall)
              .foregroundColor(.foreground)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .frame(maxHeight: 120)
      HStack {
        Spacer()
        Button("Cancel") { model.cancelConfirmation() }
          .buttonStyle(FilledSecondaryButtonStyle())
        Button("Run with Drops") { Task { await model.confirmDestructive() } }
          .buttonStyle(DangerButtonStyle())
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.bottom, Spacing.md)
  }

  private var footer: some View {
    GenericModalFooter {
      Button("Copy Script") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.scriptText, forType: .string)
      }
      .buttonStyle(FilledSecondaryButtonStyle())
      .disabled(model.script.statements.isEmpty)
      Button("Save Script...") {
        DataExporter.saveFile(
          content: model.scriptText + "\n", defaultFilename: "schema_compare.sql",
          allowedFileTypes: ["sql"])
      }
      .buttonStyle(FilledSecondaryButtonStyle())
      .disabled(model.script.statements.isEmpty)
      Spacer()
      Button("Close", action: onClose)
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(model.isRunning)
        .keyboardShortcut(.cancelAction)
      Button(model.isRunning ? "Running..." : "Run...") {
        Task { await model.run() }
      }
      .buttonStyle(PrimaryButtonStyle())
      .disabled(!model.canRun)
    }
  }

  // MARK: - Pieces

  private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(title)
        .font(.small)
        .foregroundColor(.foregroundMuted)
      content()
    }
  }
}
