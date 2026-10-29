// CopyObjectsSheet.swift
// The Copy Objects sheet: the source tables as a filterable checklist (read and filtered off the
// main actor, rows built as they scroll into view; Select All and Select None act on the filtered
// list once it matches the filter text), the target saved connection, the preview (the plan's
// warnings and the DDL Copy runs, editable, with Reset), then Copy with progress, Cancel and a
// summary. Picking a target or ticking a table shows at once; the plan loads behind a placeholder
// of the same shape (its spinner after 150 ms). A refused edit shows the refused statement and
// why. The target's Safe Mode step shows inside the sheet before anything is sent. The sheet stays
// open while a copy runs.

import SwiftUI

extension View {
  /// The sheet, and its File menu item's action (published here rather than in the container's
  /// body, whose chain is at the type checker's limit)
  func copyObjectsSheet(workspaceManager: WorkspaceManager) -> some View {
    let menuAction: (() -> Void)? =
      workspaceManager.canCopyObjects
      ? { [workspaceManager] in workspaceManager.openCopyObjects() } : nil
    return sheet(
      item: Binding(
        get: { workspaceManager.copyObjects },
        set: { if $0 == nil { workspaceManager.closeCopyObjects() } })
    ) { model in
      CopyObjectsSheet(
        model: model,
        isShown: { [weak workspaceManager, weak model] in
          model != nil && workspaceManager?.copyObjects === model
        },
        onClose: { workspaceManager.closeCopyObjects() })
    }
    .bridgedFocusedSceneValue(\.openCopyObjectsAction, menuAction)
  }
}

struct CopyObjectsSheet: View {
  @Bindable var model: CopyObjectsModel
  /// False once the sheet was closed or replaced (a late Touch ID answer then sends nothing)
  let isShown: () -> Bool
  let onClose: () -> Void

  @State private var filter = ""
  /// The last filter result (read off the main actor) and the text it was computed for
  @State private var filtered: (text: String, tables: [CopyObjectsModel.TableRef])?
  @State private var showsSQL = false
  @State private var textViewRef: SQLTextView?
  @State private var isDDLEmpty = false

  private static let editorHeight: CGFloat = 240

  /// What a filter result is computed for: a keystroke or the table list landing runs it again
  private struct FilterKey: Equatable {
    let text: String
    let isLoadingTables: Bool
  }

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: "Copy Objects", titleIcon: "square.on.square", titleIconColor: .accent,
        titleBadge: model.sourceName, onClose: onClose)
      HStack(spacing: 0) {
        tablesColumn
          .frame(width: 320)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.lg) {
            targetSection
            previewSection
            runSection
          }
          .padding(Spacing.md)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(maxHeight: .infinity)
      if let statements = model.pendingConfirmation {
        SafeModeConfirmationPanel(
          requiresPassword: model.confirmationRequiresPassword, confirmTitle: "Copy",
          biometricReason: "Authorize copying the tables in Safe Mode",
          databasePassword: model.targetPassword, isConnected: model.isTargetConnected,
          isPending: { [model] in model.pendingConfirmation != nil && isShown() },
          onCancel: { [model] in model.cancelConfirmation() },
          onConfirm: { [model] in await model.confirmCopy() }
        ) {
          SafeModeStatementList(statements: statements)
        }
      }
      footer
    }
    .frame(width: 920, height: 680)
    .background(Color.cardBackground)
    .interactiveDismissDisabled(model.isRunning)
  }

  // MARK: - Tables

  private var filterText: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// The tables matching the filter (schema-qualified name, case-insensitive): the last result
  /// until the one for the current text lands
  private var filteredTables: [CopyObjectsModel.TableRef] {
    filterText.isEmpty ? model.tables : filtered?.tables ?? model.tables
  }

  /// The list shows the current filter's result (Select All and Select None act on it)
  private var isFilterCurrent: Bool {
    filterText.isEmpty || filtered?.text == filterText
  }

  private var tablesColumn: some View {
    let tables = filteredTables
    return VStack(alignment: .leading, spacing: Spacing.sm) {
      if model.isLoadingTables {
        ImportLoadingRow(text: "Reading the tables…")
      } else {
        Text("\(model.selectedTables.count) of \(model.tables.count) tables ticked")
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .monospacedDigit()
      }
      TextField("Filter tables", text: $filter)
        .textFieldStyle(.plain)
        .font(.structureField)
        .autocorrectionDisabled()
        .structureInputStyle()
      HStack(spacing: Spacing.xs) {
        Button("Select All") { model.setSelected(tables, true) }
          .buttonStyle(GhostButtonStyle())
        Button("Select None") { model.setSelected(tables, false) }
          .buttonStyle(GhostButtonStyle())
      }
      .disabled(tables.isEmpty || !isFilterCurrent)
      Divider()
      if model.isLoadingTables {
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if tables.isEmpty {
        Text(model.tables.isEmpty ? "This connection has no tables." : "No table matches.")
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          // Rows are built as they scroll into view, never one per table up front
          LazyVStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(tables, id: \.self) { table in
              tableRow(table)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .padding(Spacing.md)
    .disabled(model.isRunning)
    // Off the main actor; a newer keystroke cancels the run (its result is dropped)
    .task(id: FilterKey(text: filterText, isLoadingTables: model.isLoadingTables)) {
      let text = filterText
      guard !text.isEmpty, !model.isLoadingTables else { return }
      guard
        let tables = await CopyObjectsModel.filtered(
          model.tables, text: text, showsSchema: model.showsSchema),
        !Task.isCancelled
      else { return }
      filtered = (text, tables)
    }
  }

  private func tableRow(_ table: CopyObjectsModel.TableRef) -> some View {
    Toggle(
      isOn: Binding(
        get: { model.selectedTables.contains(table) },
        set: { model.setSelected([table], $0) })
    ) {
      Text(verbatim: label(table))
        .font(.monoMedium)
        .foregroundColor(.foreground)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .toggleStyle(.checkbox)
  }

  private func label(_ table: CopyObjectsModel.TableRef) -> String {
    CopyObjectsModel.label(table, showsSchema: model.showsSchema)
  }

  // MARK: - Target

  private var selectedTarget: CopyObjectsModel.SavedTarget? {
    model.targets.first { $0.id == model.targetID }
  }

  private func targetTitle(_ target: CopyObjectsModel.SavedTarget) -> String {
    "\(target.name) (\(target.databaseType.displayName)\(target.isLocked ? ", locked" : ""))"
  }

  private var targetSection: some View {
    SettingsGroupCard(title: "Target") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        if model.targets.isEmpty {
          note(
            "No saved PostgreSQL, MySQL / MariaDB or SQLite connection to copy into. Save one "
              + "in the connection form first.")
        } else {
          CapsuleDropdown(
            title: selectedTarget.map(targetTitle) ?? "Choose a saved connection", width: 360,
            accessibilityLabel: "Target", options: model.targets, optionTitle: targetTitle,
            isSelected: { $0.id == model.targetID },
            onSelect: { model.selectTarget($0.id) }
          )
          .disabled(model.isRunning)
        }
        note(
          "Creates each ticked table in the target's default schema, then copies its rows, "
            + "indexes and foreign keys. Views, triggers and other objects are not copied.")
        if let error = model.targetError {
          StructureBanner(text: error, systemImage: "lock", color: .warning)
        }
        if let text = model.mysqlNote {
          StructureBanner(text: text, systemImage: "info.circle", color: .foregroundMuted)
        }
        if let text = model.protectedModeNote {
          StructureBanner(text: text, systemImage: "lock.shield", color: .foregroundMuted)
        }
      }
    }
  }

  // MARK: - Preview

  private var dialect: SQLDialect {
    model.plan?.target.dialect ?? selectedTarget?.databaseType.dialect ?? .postgresql
  }

  private var previewSection: some View {
    SettingsGroupCard(title: "Preview") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        previewSummary
        if !model.warnings.isEmpty {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
              Label(warning, systemImage: "exclamationmark.triangle")
                .font(.small)
                .foregroundColor(.warning)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        if showsSQL {
          ddlEditor
        }
      }
    }
  }

  /// One row in every state, so the card keeps its shape while the plan loads
  @ViewBuilder
  private var previewSummary: some View {
    if model.isLoadingPlan {
      ImportLoadingRow(text: "Reading the tables and the target…")
    } else if let error = model.planError {
      StructureBanner(text: error, systemImage: "exclamationmark.triangle", color: .destructive)
    } else if let plan = model.plan {
      note(
        "\(plan.tables.count == 1 ? "1 table" : "\(plan.tables.count) tables") to create in "
          + "\(plan.targetSchema).")
    } else if model.targetID == nil {
      note("Pick a target connection.")
    } else if model.targetError != nil {
      note("Pick another target connection.")
    } else if model.selectedTables.isEmpty {
      note("Tick at least one table.")
    } else {
      note("Nothing to copy.")
    }
  }

  /// The DDL Copy runs, editable; an empty well of the same size while the plan loads
  private var ddlEditor: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.sm) {
        Text("Copy runs this SQL on the target, and copies the rows after the CREATE TABLEs")
          .font(.small)
          .foregroundColor(.foregroundSubtle)
        Spacer(minLength: Spacing.sm)
        if model.isDDLEdited {
          Button("Reset") { model.resetDDL() }
            .buttonStyle(GhostButtonStyle())
            .disabled(model.isRunning)
        }
      }
      Group {
        if model.plan != nil {
          HighlightedTextEditor(
            text: $model.editedDDL, textViewRef: $textViewRef, isEmpty: $isDDLEmpty,
            maxHeight: Self.editorHeight, dialect: dialect, isEditable: !model.isRunning)
        } else {
          Color.clear
            .frame(height: Self.editorHeight)
        }
      }
      .padding(Spacing.xs)
      .background(Color.inputBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
      if let refusal = model.refusal {
        StructureBanner(
          text: refusal.reason, systemImage: "exclamationmark.triangle", color: .destructive)
        if let statement = refusal.statement {
          SQLCodeWell(sql: statement, dialect: dialect)
            .frame(height: 120)
        }
      }
    }
  }

  // MARK: - Run

  @ViewBuilder
  private var runSection: some View {
    // A refusal shows under the editor; with the editor hidden, here
    if !showsSQL, let refusal = model.refusal {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        StructureBanner(
          text: refusal.reason, systemImage: "exclamationmark.triangle", color: .destructive)
        if let statement = refusal.statement {
          SQLCodeWell(sql: statement, dialect: dialect)
            .frame(height: 120)
        }
      }
    }
    if let progress = model.progress {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        ProgressView(
          value: progress.total == 0 ? nil : Double(progress.done) / Double(progress.total)
        )
        .accessibilityLabel("Copy progress")
        Text(
          progress.total == 0
            ? "Creating the tables…"
            : "\(progress.done.formatted()) of \(progress.total.formatted()) row batches copied"
        )
        .font(.monoSmall)
        .foregroundColor(.foregroundMuted)
      }
    }
    if let error = model.runError {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        StructureBanner(text: error, systemImage: "exclamationmark.triangle", color: .destructive)
        if !model.leftoverTables.isEmpty {
          note("Drop those tables on the target by hand before you copy again.")
        }
      }
    }
    if let result = model.result {
      StructureBanner(
        text: "Copied \(result.tables == 1 ? "1 table" : "\(result.tables) tables") and "
          + "\(result.rows == 1 ? "1 row" : "\(result.rows.formatted()) rows").",
        systemImage: "checkmark.circle", color: .success)
    }
  }

  // MARK: - Footer

  private var footer: some View {
    GenericModalFooter {
      Button(showsSQL ? "Hide SQL" : "Preview SQL") { showsSQL.toggle() }
        .buttonStyle(SecondaryButtonStyle())
      Spacer()
      if model.isRunning {
        Button("Cancel") { model.cancel() }
          .buttonStyle(FilledSecondaryButtonStyle())
      } else {
        Button("Close", action: onClose)
          .buttonStyle(FilledSecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
      }
      Button {
        Task { await model.copy() }
      } label: {
        if model.isRunning {
          HStack(spacing: Spacing.sm) {
            ProgressView().controlSize(.mini)
            Text("Copying...")
          }
        } else {
          Text("Copy")
        }
      }
      .buttonStyle(PrimaryButtonStyle())
      .disabled(!model.canCopy)
    }
  }

  // MARK: - Pieces

  private func note(_ text: String) -> some View {
    Text(text)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .fixedSize(horizontal: false, vertical: true)
  }
}
