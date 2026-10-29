// UserTypeEditorView.swift
// The PostgreSQL types editor sheet (New Type... on the sidebar's Types header, Edit Type... on a
// type row). An enum's labels are added (at the end, or before / after a label the type already
// has) and renamed, never dropped; a domain's default, NOT NULL and CHECK constraints change; a
// composite type's attributes are added, dropped, renamed and retyped. A new type picks its kind,
// name and schema and is defined in one CREATE. Staged changes list with undo, the exact SQL
// Apply sends (`SQLCodeWell`) and the Safe Mode step inside the sheet, as in the structure
// editor. Disabled reasons, results and apply errors show inline; toasts show in the sheet's own
// overlay while it is open (the window's overlay hides them meanwhile).

import SwiftUI

extension View {
  /// Presents `workspaceManager.userTypeEditor`, one per window
  func userTypeEditorSheet(workspaceManager: WorkspaceManager) -> some View {
    sheet(
      item: Binding(
        get: { workspaceManager.userTypeEditor },
        set: { if $0 == nil { workspaceManager.closeUserTypeEditor() } })
    ) { model in
      UserTypeEditorView(
        model: model,
        databasePassword: workspaceManager.workspace.connectionConfig?.password,
        isConnected: workspaceManager.connectionState == .connected,
        isShown: { [weak workspaceManager, weak model] in
          model != nil && workspaceManager?.userTypeEditor === model
        },
        onClose: { workspaceManager.closeUserTypeEditor() })
    }
  }
}

private struct UserTypeEditorView: View {
  @Bindable var model: UserTypeEditorModel
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool
  /// False once the sheet was closed or replaced (a late Touch ID answer then sends nothing)
  let isShown: () -> Bool
  let onClose: () -> Void

  @State private var showsSpinner = false
  @State private var spinnerTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: model.isNew ? "New Type" : "\(model.schema).\(model.name)",
        titleIcon: ObjectSourceRef.Kind.userType.iconName, titleIconColor: .accent,
        titleBadge: model.working.map(Self.kindName), onClose: onClose)
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          banners
          Group {
            if model.isNew {
              NewUserTypeSection(model: model)
            } else {
              typeSection
              if !model.changes.isEmpty { stagedSection }
            }
          }
          .disabled(model.isApplying || model.disabledReason != nil)
          previewSection
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: .infinity)
      .overlay { ToastOverlay().environment(\.hidesToastOverlay, false) }
      if let statements = model.confirmation.pendingConfirmation {
        SafeModeConfirmationPanel(
          requiresPassword: model.confirmation.requiresPassword,
          confirmTitle: model.isNew ? "Create Type" : "Apply Changes",
          biometricReason: "Authorize the type change in Safe Mode",
          databasePassword: databasePassword, isConnected: isConnected,
          isPending: { [model] in model.confirmation.pendingConfirmation != nil && isShown() },
          onCancel: { [model] in model.cancelConfirmation() },
          onConfirm: { [model] in await model.confirmApply() }
        ) {
          SafeModeStatementList(statements: statements)
        }
      }
      footer
    }
    .frame(width: 780, height: 640)
    .background(Color.cardBackground)
    .interactiveDismissDisabled(model.isApplying)
    // The button says Applying at once; the spinner fades in only after 150 ms
    .onChange(of: model.isApplying) { _, applying in
      spinnerTask?.cancel()
      showsSpinner = false
      guard applying else { return }
      spinnerTask = Task {
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, model.isApplying else { return }
        showsSpinner = true
      }
    }
  }

  static func kindName(_ kind: DatabaseUserType.Kind) -> String {
    switch kind {
    case .enum: "enum"
    case .domain: "domain"
    case .composite: "composite"
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private var banners: some View {
    if let reason = model.disabledReason {
      StructureBanner(text: reason, systemImage: "lock", color: .warning)
    }
    if let error = model.applyError {
      StructureBanner(
        text: error, systemImage: "exclamationmark.triangle",
        color: model.applyPartiallyFailed ? .warning : .destructive)
    } else if let result = model.resultMessage {
      StructureBanner(
        text: result, systemImage: "checkmark.circle",
        color: result == UserTypeEditorModel.appliedMessage ? .success : .warning)
    }
  }

  @ViewBuilder
  private var typeSection: some View {
    switch model.working {
    case .enum(let labels):
      EnumLabelsSection(model: model, labels: labels)
    case .domain(let baseType, let notNull, let defaultExpression, let constraints):
      DomainSection(
        model: model, baseType: baseType, notNull: notNull, defaultExpression: defaultExpression,
        constraints: constraints)
    case .composite(let attributes):
      CompositeAttributesSection(model: model, attributes: attributes)
    case nil:
      EmptyView()
    }
  }

  private var stagedSection: some View {
    SettingsGroupCard(title: "Staged Changes", background: .cardBackground, contentPadding: 0) {
      Text("\(model.changes.count)")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    } content: {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(model.changes.enumerated()), id: \.offset) { index, change in
          HStack(spacing: Spacing.sm) {
            Text(Self.summary(change))
              .font(.structureField)
              .foregroundColor(.structureCellForeground)
              .lineLimit(1)
              .truncationMode(.middle)
              .frame(maxWidth: .infinity, alignment: .leading)
            Button {
              model.undoChange(at: index)
            } label: {
              Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(GhostButtonStyle(iconOnly: true))
            .help("Undo this change")
          }
          .structureTableRow(isFirst: index == 0)
        }
      }
    }
  }

  private var previewSection: some View {
    SettingsGroupCard(title: "SQL Preview") {
      Text(previewNote)
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    } content: {
      // A builder error leaves no statements: it takes the placeholder's place in the well
      SQLCodeWell(
        sql: model.previewStatements.map { $0 + ";" }.joined(separator: "\n"),
        placeholder: model.previewError == nil ? "No changes" : nil, dialect: .postgresql
      )
      .overlay(alignment: .topLeading) {
        if let error = model.previewError {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.small)
            .foregroundColor(.destructive)
            .textSelection(.enabled)
            .padding(Spacing.md)
        }
      }
      .frame(height: 140)
    }
  }

  /// Below PostgreSQL 12 new labels run first, one by one, and stay even if the rest fails
  private var previewNote: String {
    model.addsValuesOneByOne && !model.plan.sequential.isEmpty
      ? "Apply sends exactly this SQL; new labels go first, one by one, outside a transaction"
      : "Apply sends exactly this SQL"
  }

  private var footer: some View {
    GenericModalFooter {
      if !model.changes.isEmpty, !model.isNew {
        Text(model.changes.count == 1 ? "1 change" : "\(model.changes.count) changes")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
      Spacer()
      ProgressView()
        .controlSize(.small)
        .opacity(showsSpinner ? 1 : 0)
        .animation(.easeIn(duration: 0.15), value: showsSpinner)
        .accessibilityHidden(!showsSpinner)
      if !model.isNew {
        Button("Discard") { model.discardChanges() }
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(model.changes.isEmpty || model.isApplying || model.disabledReason != nil)
      }
      Button("Close", action: onClose)
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(model.isApplying)
        .keyboardShortcut(.cancelAction)
      Button(applyTitle) {
        Task { await model.apply() }
      }
      .buttonStyle(PrimaryButtonStyle())
      .disabled(!model.canApply || model.confirmation.pendingConfirmation != nil)
      .help(applyHelp)
    }
  }

  private var applyTitle: String {
    if model.isApplying { return model.isNew ? "Creating..." : "Applying..." }
    return model.isNew ? "Create" : "Apply"
  }

  /// Why Apply is disabled, or what it does
  private var applyHelp: String {
    if let reason = model.disabledReason { return reason }
    if let error = model.previewError { return error }
    if let incomplete = model.incompleteDraft { return incomplete }
    if model.changes.isEmpty { return model.isNew ? "Define the type first" : "No changes" }
    return model.isNew ? "Create the type" : "Apply the staged changes"
  }

  /// One line of the staged list
  static func summary(_ change: UserTypeChange) -> String {
    switch change {
    case .addValue(let label, let position):
      switch position {
      case .before(let anchor): "Add label '\(label)' before '\(anchor)'"
      case .after(let anchor): "Add label '\(label)' after '\(anchor)'"
      case nil: "Add label '\(label)' at the end"
      }
    case .renameValue(let label, let newLabel): "Rename label '\(label)' to '\(newLabel)'"
    case .setDefault(let expression): "Set default \(expression)"
    case .dropDefault: "Drop default"
    case .setNotNull: "Set NOT NULL"
    case .dropNotNull: "Drop NOT NULL"
    case .addCheck(let check):
      check.name.isEmpty
        ? "Add CHECK \(check.expression)" : "Add CHECK \(check.name): \(check.expression)"
    case .dropConstraint(let name): "Drop constraint \(name)"
    case .addAttribute(let attribute): "Add attribute \(attribute.name) \(attribute.type)"
    case .dropAttribute(let name): "Drop attribute \(name)"
    case .renameAttribute(let name, let newName): "Rename attribute \(name) to \(newName)"
    case .alterAttributeType(let name, let type): "Change attribute \(name) to \(type)"
    case .createEnum: "Create enum"
    case .createDomain: "Create domain"
    case .createComposite: "Create composite type"
    }
  }
}

// MARK: - Shared pieces

private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
  VStack(alignment: .leading, spacing: Spacing.xs) {
    Text(title)
      .font(.small)
      .foregroundColor(.foregroundMuted)
    content()
  }
}

private func draftField(_ placeholder: String, text: Binding<String>) -> some View {
  TextField(placeholder, text: text)
    .textFieldStyle(.plain)
    .font(.structureField)
    .autocorrectionDisabled()
    .structureInputStyle()
}

private func isBlank(_ text: String) -> Bool {
  text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func removeButton(_ help: String, action: @escaping () -> Void) -> some View {
  Button(action: action) {
    Image(systemName: "minus.circle")
  }
  .buttonStyle(GhostButtonStyle(iconOnly: true))
  .help(help)
}

private enum Width {
  static let name: CGFloat = 200
  static let type: CGFloat = 220
  static let marker: CGFloat = 6
  static let action: CGFloat = 28
}

// MARK: - Enum

/// The working labels in sort order: each renamed in place (a new one in its ADD VALUE), and an
/// add form whose position offers only labels the type already has (or the end)
private struct EnumLabelsSection: View {
  let model: UserTypeEditorModel
  let labels: [String]

  /// Where the next label goes; `LabelPosition` by shown name
  private enum Anchor: Hashable {
    case end
    case before(String)
    case after(String)
  }

  @State private var newLabel = ""
  @State private var anchor = Anchor.end

  var body: some View {
    SettingsGroupCard(title: "Labels", background: .cardBackground, contentPadding: 0) {
      Text("\(labels.count)")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    } content: {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(labels.enumerated()), id: \.offset) { position, label in
          HStack(spacing: Spacing.sm) {
            StructureStateMarker(state: state(of: label))
              .frame(width: Width.marker)
            StructureCommitField(value: label, isEdited: state(of: label) != .unchanged) {
              model.renameLabel(label, to: $0)
            }
          }
          .structureTableRow(isFirst: position == 0)
        }
        addForm.structureTableFooter()
      }
    }
    // A label the anchor named was renamed or undone: back to the end
    .onChange(of: loadedShownLabels) { _, shown in
      switch anchor {
      case .before(let label), .after(let label):
        if !shown.contains(label) { anchor = .end }
      case .end: break
      }
    }
  }

  private var addForm: some View {
    HStack(spacing: Spacing.sm) {
      draftField("New label", text: $newLabel)
        .frame(width: Width.name)
        .onSubmit(add)
      CapsulePickerMenu(title: title(anchor), width: 200) {
        Picker("Position", selection: $anchor) {
          Text(title(.end)).tag(Anchor.end)
          ForEach(loadedShownLabels, id: \.self) { label in
            Divider()
            Text(title(.before(label))).tag(Anchor.before(label))
            Text(title(.after(label))).tag(Anchor.after(label))
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
      .accessibilityLabel("Position")
      .help("A new label goes at the end or next to a label the type already has")
      Spacer()
      Button("Add Label", action: add)
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(newLabel.isEmpty)
    }
  }

  /// The labels the type has, by the name shown (after a staged rename)
  private var loadedShownLabels: [String] {
    guard case .enum(let loaded) = model.type?.kind else { return [] }
    return loaded.map { label in
      for case .renameValue(label, let newLabel) in model.changes { return newLabel }
      return label
    }
  }

  private func state(of label: String) -> StructureEditorModel.StagedState {
    for change in model.changes {
      switch change {
      case .addValue(label, _): return .added
      case .renameValue(_, label): return .edited
      default: continue
      }
    }
    return .unchanged
  }

  private func title(_ anchor: Anchor) -> String {
    switch anchor {
    case .end: "At the end"
    case .before(let label): "Before \(label)"
    case .after(let label): "After \(label)"
    }
  }

  private func add() {
    guard !newLabel.isEmpty else { return }
    let position: UserTypeChange.LabelPosition? =
      switch anchor {
      case .end: nil
      case .before(let label): .before(label)
      case .after(let label): .after(label)
      }
    model.addLabel(newLabel, position: position)
    newLabel = ""
  }
}

// MARK: - Domain

/// The base type (fixed), NOT NULL, the default and the CHECK constraints with an add form
private struct DomainSection: View {
  let model: UserTypeEditorModel
  let baseType: String
  let notNull: Bool
  let defaultExpression: String?
  let constraints: [DatabaseUserType.Constraint]

  @State private var checkName = ""
  @State private var checkExpression = ""

  var body: some View {
    SettingsGroupCard(title: "Domain") {
      HStack(alignment: .top, spacing: Spacing.md) {
        labeled("Base type") {
          Text(baseType)
            .font(.structureField)
            .foregroundColor(.structureCellForeground)
            .textSelection(.enabled)
            .frame(height: ButtonMetrics.regularHeight)
        }
        .frame(width: 160, alignment: .leading)
        labeled("Not null") {
          Toggle(
            "Not null", isOn: Binding(get: { notNull }, set: { model.setNotNull($0) })
          )
          .toggleStyle(.checkbox)
          .labelsHidden()
          .frame(height: ButtonMetrics.regularHeight)
        }
        labeled("Default") {
          StructureCommitField(
            value: defaultExpression ?? "", placeholder: "None",
            isEdited: defaultExpression != loadedDefault
          ) { model.setDefault($0) }
          .help("A SQL expression; empty drops the default")
        }
      }
    }
    SettingsGroupCard(
      title: "Check Constraints", background: .cardBackground, contentPadding: 0
    ) {
      Text("\(constraints.count)")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    } content: {
      VStack(alignment: .leading, spacing: 0) {
        if constraints.isEmpty {
          Text("No CHECK constraints")
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .structureTableRow(isFirst: true)
        }
        ForEach(Array(constraints.enumerated()), id: \.offset) { position, constraint in
          HStack(spacing: Spacing.sm) {
            StructureStateMarker(state: addedIndex(at: position) != nil ? .added : .unchanged)
              .frame(width: Width.marker)
            Text(constraint.name.isEmpty ? "Unnamed" : constraint.name)
              .font(.structureField)
              .foregroundColor(
                constraint.name.isEmpty ? .foregroundMuted : .structureCellForeground
              )
              .lineLimit(1)
              .frame(width: Width.name, alignment: .leading)
            Text(constraint.definition)
              .font(.structureField)
              .foregroundColor(.structureCellForeground)
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
              .help(constraint.definition)
              .frame(maxWidth: .infinity, alignment: .leading)
            removeAction(constraint, at: position)
              .frame(width: Width.action)
          }
          .structureTableRow(isFirst: position == 0)
        }
        addForm.structureTableFooter()
      }
    }
  }

  private var addForm: some View {
    HStack(spacing: Spacing.sm) {
      draftField("Name (optional)", text: $checkName)
        .frame(width: Width.name)
      draftField("Expression, e.g. VALUE > 0", text: $checkExpression)
        .onSubmit(add)
      Button("Add Check", action: add)
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(isBlank(checkExpression))
    }
  }

  /// Drops a loaded constraint or removes one added here. An unnamed one applied from this sheet
  /// has a server-assigned name the sheet does not know until it is reopened: no drop.
  @ViewBuilder
  private func removeAction(
    _ constraint: DatabaseUserType.Constraint, at position: Int
  ) -> some View {
    if !constraint.name.isEmpty {
      removeButton("Drop the constraint") { model.dropConstraint(named: constraint.name) }
    } else if let added = addedIndex(at: position) {
      removeButton("Remove the constraint") { model.undoChange(at: added) }
    } else {
      Color.clear.frame(height: 0)
    }
  }

  private var loadedDefault: String? {
    guard case .domain(_, _, let loaded, _) = model.type?.kind else { return nil }
    return loaded
  }

  /// The staged ADD shown at `position`: added constraints follow the loaded ones in their
  /// order, so an unnamed one is told apart from an applied one with the same definition
  private func addedIndex(at position: Int) -> Int? {
    let adds = model.changes.indices.filter {
      if case .addCheck = model.changes[$0] { true } else { false }
    }
    let offset = position - (constraints.count - adds.count)
    return adds.indices.contains(offset) ? adds[offset] : nil
  }

  /// A blank name leaves the name to the server
  private func add() {
    guard !isBlank(checkExpression) else { return }
    model.addCheck(
      .init(
        name: checkName.trimmingCharacters(in: .whitespacesAndNewlines),
        expression: checkExpression))
    checkName = ""
    checkExpression = ""
  }
}

// MARK: - Composite

/// The working attributes in column order, each renamed, retyped or dropped in place, and an
/// add form
private struct CompositeAttributesSection: View {
  let model: UserTypeEditorModel
  let attributes: [DatabaseUserType.Attribute]

  @State private var newName = ""
  @State private var newType = ""

  var body: some View {
    SettingsGroupCard(title: "Attributes", background: .cardBackground, contentPadding: 0) {
      Text("\(attributes.count)")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    } content: {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: Spacing.sm) {
          Color.clear.frame(width: Width.marker, height: 0)
          Text("Name").frame(width: Width.name, alignment: .leading)
          Text("Type").frame(maxWidth: .infinity, alignment: .leading)
            .structureColumnDivider()
          Color.clear.frame(width: Width.action, height: 0)
        }
        .structureTableHeader()
        ForEach(Array(attributes.enumerated()), id: \.offset) { position, attribute in
          row(attribute)
            .structureTableRow(isFirst: position == 0)
        }
        addForm.structureTableFooter()
      }
    }
  }

  private func row(_ attribute: DatabaseUserType.Attribute) -> some View {
    let state = state(of: attribute)
    return HStack(spacing: Spacing.sm) {
      StructureStateMarker(state: state)
        .frame(width: Width.marker)
      StructureCommitField(value: attribute.name, isEdited: state != .unchanged) {
        model.renameAttribute(attribute.name, to: $0)
      }
      .frame(width: Width.name)
      StructureCommitField(value: attribute.type, isEdited: state != .unchanged) {
        model.setAttributeType(attribute.name, to: $0)
      }
      removeButton("Drop the attribute") { model.dropAttribute(attribute.name) }
        .frame(width: Width.action)
    }
  }

  private var addForm: some View {
    HStack(spacing: Spacing.sm) {
      Color.clear.frame(width: Width.marker, height: 0)
      draftField("Name", text: $newName)
        .frame(width: Width.name)
      draftField("Type, e.g. integer", text: $newType)
        .onSubmit(add)
      Button("Add Attribute", action: add)
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(isBlank(newName) || newType.isEmpty)
    }
  }

  private func state(
    of attribute: DatabaseUserType.Attribute
  ) -> StructureEditorModel.StagedState {
    let isAdded = model.changes.contains {
      if case .addAttribute(let added) = $0 { added.name == attribute.name } else { false }
    }
    if isAdded { return .added }
    guard case .composite(let loaded) = model.type?.kind, !loaded.contains(attribute) else {
      return .unchanged
    }
    return .edited
  }

  private func add() {
    guard !isBlank(newName), !newType.isEmpty else { return }
    model.addAttribute(
      .init(name: newName.trimmingCharacters(in: .whitespacesAndNewlines), type: newType))
    newName = ""
    newType = ""
  }
}

// MARK: - New type

/// Kind, name and schema of a new type, and its definition: a draft kept here that defines the
/// model's one CREATE on every edit (nothing staged while it is empty)
private struct NewUserTypeSection: View {
  @Bindable var model: UserTypeEditorModel

  @State private var draft = UserTypeDraft()

  var body: some View {
    SettingsGroupCard(title: "Type") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        CapsuleTabPicker(selection: $draft.kind, tabs: UserTypeDraft.Kind.allCases, height: 28) {
          kind in
          CapsuleTabLabel(text: kind.rawValue, isSelected: draft.kind == kind)
        }
        .fitsContent()
        HStack(alignment: .top, spacing: Spacing.md) {
          if model.schemaChoices.count > 1 {
            labeled("Schema") {
              CapsulePickerMenu(title: model.schema, width: 180) {
                Picker("Schema", selection: $model.schema) {
                  ForEach(model.schemaChoices, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
              }
              .accessibilityLabel("Schema")
            }
          }
          labeled("Name") {
            draftField("e.g. mood", text: $model.newName)
              .frame(width: 240)
          }
          Spacer()
        }
      }
    }
    definition
      .onChange(of: draft, initial: true) { _, draft in define(draft) }
  }

  @ViewBuilder
  private var definition: some View {
    switch draft.kind {
    case .enumType:
      rowsCard(
        title: "Labels", rows: $draft.labels, firstPlaceholder: "Label", secondPlaceholder: nil,
        addTitle: "Add Label", emptyText: nil, note: nil)
    case .domain:
      SettingsGroupCard(title: "Domain") {
        HStack(alignment: .top, spacing: Spacing.md) {
          labeled("Base type") {
            draftField("e.g. integer", text: $draft.baseType)
              .frame(width: 180)
          }
          labeled("Not null") {
            Toggle("Not null", isOn: $draft.notNull)
              .toggleStyle(.checkbox)
              .labelsHidden()
              .frame(height: ButtonMetrics.regularHeight)
          }
          labeled("Default") {
            draftField("None", text: $draft.defaultExpression)
          }
        }
      }
      rowsCard(
        title: "Check Constraints", rows: $draft.checks, firstPlaceholder: "Name (optional)",
        secondPlaceholder: "Expression, e.g. VALUE > 0", addTitle: "Add Check",
        emptyText: "No CHECK constraints", note: draft.incompleteNote)
    case .composite:
      rowsCard(
        title: "Attributes", rows: $draft.attributes, firstPlaceholder: "Name",
        secondPlaceholder: "Type, e.g. integer", addTitle: "Add Attribute", emptyText: nil,
        note: draft.incompleteNote)
    }
  }

  private func rowsCard(
    title: String, rows: Binding<[UserTypeDraft.Row]>, firstPlaceholder: String,
    secondPlaceholder: String?,
    addTitle: String, emptyText: String?, note: String?
  ) -> some View {
    SettingsGroupCard(title: title, background: .cardBackground, contentPadding: 0) {
      Text("\(rows.wrappedValue.count)")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    } content: {
      VStack(alignment: .leading, spacing: 0) {
        if let emptyText, rows.wrappedValue.isEmpty {
          Text(emptyText)
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .structureTableRow(isFirst: true)
        }
        ForEach(Array(rows.enumerated()), id: \.element.id) { position, $row in
          HStack(spacing: Spacing.sm) {
            draftField(firstPlaceholder, text: $row.first)
              .frame(width: secondPlaceholder == nil ? nil : Width.name)
            if let secondPlaceholder {
              draftField(secondPlaceholder, text: $row.second)
            }
            removeButton("Remove") { rows.wrappedValue.removeAll { $0.id == row.id } }
              .frame(width: Width.action)
          }
          .structureTableRow(isFirst: position == 0)
        }
        HStack(spacing: Spacing.md) {
          Button(addTitle) { rows.wrappedValue.append(UserTypeDraft.Row()) }
            .buttonStyle(FilledSecondaryButtonStyle())
          // A half-filled row blocks Create (the same text is its disabled reason)
          if let note {
            Text(note)
              .font(.small)
              .foregroundColor(.warning)
          }
          Spacer()
        }
        .structureTableFooter()
      }
    }
  }

  /// The draft's CREATE (nothing staged while the draft is empty); a half-filled row blocks
  /// Create, its note the reason. A builder error shows in the preview.
  private func define(_ draft: UserTypeDraft) {
    model.incompleteDraft = draft.incompleteNote
    if let create = draft.create {
      model.define(create)
    } else {
      model.discardChanges()
    }
  }
}
