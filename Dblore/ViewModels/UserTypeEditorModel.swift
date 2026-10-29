// UserTypeEditorModel.swift
// The types editor sheet's state, for one PostgreSQL user type as the sidebar listed it, or a
// new one. Stages `[UserTypeChange]` (enum labels are added and renamed, never dropped; domain
// default, NOT NULL and CHECKs; composite attributes), previews exactly the DDL
// `PostgresUserTypeDDLBuilder` returns, asks Safe Mode through `SchemaChangeConfirmation` and
// applies the previewed strings. From PostgreSQL 12 (`server_version_num` 120000) everything is
// one gated schema change. Older or unknown servers refuse ADD VALUE inside a transaction block
// (25001): those statements run first, one by one, through the sequential gate (refused while a
// transaction is open or Protected mode applies), then the rest as one batch. The staged SQL
// never uses a label it adds (55P04 from 12 on): a rename of a new label edits its ADD VALUE,
// and a new label is placed next to a loaded label only. After an apply that is not pending the
// working type becomes the loaded one and `onApplied` reloads the catalog; a pending one reloads
// after Commit like any Protected mode change (`onApplied` still runs, so the host shows Commit).

import Foundation
import Observation

@MainActor
@Observable
final class UserTypeEditorModel: Identifiable {
  static let notPostgresMessage = "Types can only be edited on PostgreSQL connections"
  static let readOnlyMessage = "This connection is read-only"
  static let schemaOnlyMessage = "This connection blocks schema changes"
  static let pausedMessage = "Commit or roll back the pending changes to edit the type"
  static let appliedMessage = "Applied"
  static let pendingMessage = "Pending until you commit"
  static let insideTransactionMessage = "Applied inside your open transaction; commit to keep it"
  static let addValueOutsideTransactionMessage =
    "This server adds enum values outside a transaction: commit or roll back first"
  static let addValueUnderReviewMessage =
    "This server adds enum values outside a transaction: switch this connection's commit "
    + "style from Review to add values"

  let id = UUID()
  /// A new type's schema can change until it is created (the sheet's picker)
  var schema: String {
    didSet { editedName() }
  }
  /// Where a new type can go (the sheet's picker); empty when editing
  var schemaChoices: [String] = []
  /// `server_version_num`; nil when unknown (then ADD VALUE runs one by one, the safe way)
  let serverVersion: Int?
  /// The type as loaded; nil while a new type is not created yet
  private(set) var type: DatabaseUserType?
  /// A new type's name
  var newName = "" {
    didSet { editedName() }
  }
  let confirmation: SchemaChangeConfirmation
  private(set) var disabledReason: String?
  private(set) var changes: [UserTypeChange] = []
  private(set) var ddl = UserTypeDDL()
  /// Why the staged changes build no DDL (the builder's refusal)
  private(set) var previewError: String?
  /// Why a new type's draft cannot be created yet (a row half filled); set by the sheet
  var incompleteDraft: String?
  private(set) var isApplying = false
  private(set) var resultMessage: String?
  private(set) var applyError: String?
  /// The ADD VALUE step ran but the rest failed: the new labels are loaded now
  private(set) var applyPartiallyFailed = false

  /// Called once a change reached the server (pending: waits for Commit). The sheet host
  /// refreshes its transaction state and, when not pending, reloads the types through
  /// `startSchemaLoad()`.
  @ObservationIgnored var onApplied: (@MainActor (_ pending: Bool) async -> Void)?
  /// Toast for Apply results and new preview errors of staged edits (a new type's draft, fed on
  /// every keystroke, shows its preview error inline only). The host routes it; nothing by
  /// default.
  @ObservationIgnored var toastPresenter: @MainActor (String, ToastMessage.ToastType) -> Void = {
    _, _ in
  }
  @ObservationIgnored private let connectionEpoch: UInt64

  /// Edits `type`
  convenience init(
    type: DatabaseUserType, context: SchemaChangeContext, serverVersion: Int?,
    connectionEpoch: UInt64
  ) {
    self.init(
      schema: type.schema, type: type, context: context, serverVersion: serverVersion,
      connectionEpoch: connectionEpoch)
  }

  /// Creates a type in `schema`
  convenience init(
    newIn schema: String, context: SchemaChangeContext, serverVersion: Int?,
    connectionEpoch: UInt64
  ) {
    self.init(
      schema: schema, type: nil, context: context, serverVersion: serverVersion,
      connectionEpoch: connectionEpoch)
  }

  private init(
    schema: String, type: DatabaseUserType?, context: SchemaChangeContext, serverVersion: Int?,
    connectionEpoch: UInt64
  ) {
    self.schema = schema
    self.type = type
    self.serverVersion = serverVersion
    self.connectionEpoch = connectionEpoch
    confirmation = SchemaChangeConfirmation(context: context)
    disabledReason = Self.disabledReason(
      databaseType: context.databaseType, policy: context.policy)
  }

  /// Why `databaseType` under `policy` cannot change types, or nil
  static func disabledReason(databaseType: DatabaseType, policy: ProtectionPolicy) -> String? {
    guard databaseType == .postgresql else { return notPostgresMessage }
    switch policy.protectionLevel {
    case .readOnly: return readOnlyMessage
    case .schemaOnly: return schemaOnlyMessage
    case .none: return nil
    }
  }

  var isNew: Bool { type == nil }
  var name: String { type?.name ?? newName.trimmingCharacters(in: .whitespacesAndNewlines) }
  var previewStatements: [String] { ddl.all }

  var canApply: Bool {
    disabledReason == nil && !changes.isEmpty && previewError == nil && incompleteDraft == nil
      && !isApplying
  }

  /// Below PostgreSQL 12, or unknown: ADD VALUE runs one by one before the rest
  var addsValuesOneByOne: Bool { (serverVersion ?? 0) < 120_000 }

  /// What Apply sends, from the preview
  var plan: SchemaChangeConfirmation.Plan {
    addsValuesOneByOne
      ? .init(sequential: ddl.addValues, batch: ddl.others) : .init(batch: ddl.all)
  }

  /// The type as it will be once the staged changes ran; nil for a new type not defined yet
  var working: DatabaseUserType.Kind? {
    guard let loaded = type?.kind else { return changes.first.flatMap(Self.createdKind) }
    return Self.applying(changes, to: loaded)
  }

  // MARK: - New type

  /// Defines the new type (one create change)
  func define(_ create: UserTypeChange) {
    guard isNew, create.createsType else { return }
    stage { $0 = [create] }
  }

  // MARK: - Enum

  /// Adds `label`, at the end or next to a label the type has (by its shown name)
  func addLabel(_ label: String, position: UserTypeChange.LabelPosition? = nil) {
    let loadedPosition = position.map { position -> UserTypeChange.LabelPosition in
      switch position {
      case .before(let shown): .before(loadedLabel(shown) ?? shown)
      case .after(let shown): .after(loadedLabel(shown) ?? shown)
      }
    }
    stage { $0.append(.addValue(label: label, position: loadedPosition)) }
  }

  /// Renames the label shown as `shown`. A label added here is renamed in its ADD VALUE.
  func renameLabel(_ shown: String, to newLabel: String) {
    let loaded = loadedLabel(shown)
    stage { changes in
      if let added = changes.firstIndex(where: { Self.addedLabel($0) == shown }),
        case .addValue(_, let position) = changes[added]
      {
        changes[added] = .addValue(label: newLabel, position: position)
        return
      }
      guard let loaded else { return }
      changes.removeAll {
        if case .renameValue(loaded, _) = $0 { true } else { false }
      }
      if newLabel != loaded { changes.append(.renameValue(label: loaded, newLabel: newLabel)) }
    }
  }

  // MARK: - Domain

  /// Nil or blank drops the default
  func setDefault(_ expression: String?) {
    let trimmed = expression?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = trimmed?.isEmpty == false ? trimmed : nil
    guard case .domain(_, _, let loaded, _) = type?.kind else { return }
    stage { changes in
      changes.removeAll {
        switch $0 {
        case .setDefault, .dropDefault: true
        default: false
        }
      }
      guard value != loaded else { return }
      changes.append(value.map { .setDefault(expression: $0) } ?? .dropDefault)
    }
  }

  func setNotNull(_ notNull: Bool) {
    guard case .domain(_, let loaded, _, _) = type?.kind else { return }
    stage { changes in
      changes.removeAll {
        switch $0 {
        case .setNotNull, .dropNotNull: true
        default: false
        }
      }
      if notNull != loaded { changes.append(notNull ? .setNotNull : .dropNotNull) }
    }
  }

  func addCheck(_ check: UserTypeChange.Check) {
    stage { $0.append(.addCheck(check)) }
  }

  /// Drops the CHECK `name`; one added here is just removed
  func dropConstraint(named name: String) {
    stage { changes in
      if let added = changes.lastIndex(where: {
        if case .addCheck(let check) = $0 { check.name == name } else { false }
      }) {
        changes.remove(at: added)
      } else {
        changes.append(.dropConstraint(name: name))
      }
    }
  }

  // MARK: - Composite

  func addAttribute(_ attribute: UserTypeChange.Attribute) {
    stage { $0.append(.addAttribute(attribute)) }
  }

  /// Renames the attribute shown as `shown`; one added here is renamed in its ADD ATTRIBUTE
  func renameAttribute(_ shown: String, to newName: String) {
    let loaded = loadedAttribute(shown)
    stage { changes in
      if editAddedAttribute(shown, in: &changes, { $0.name = newName }) { return }
      guard let loaded else { return }
      changes.removeAll {
        if case .renameAttribute(loaded, _) = $0 { true } else { false }
      }
      if newName != loaded { changes.append(.renameAttribute(name: loaded, newName: newName)) }
    }
  }

  func setAttributeType(_ shown: String, to attributeType: String) {
    let loaded = loadedAttribute(shown)
    var loadedType: String?
    if case .composite(let attributes) = type?.kind {
      loadedType = attributes.first { $0.name == loaded }?.type
    }
    stage { changes in
      if editAddedAttribute(shown, in: &changes, { $0.type = attributeType }) { return }
      guard let loaded else { return }
      changes.removeAll {
        if case .alterAttributeType(loaded, _) = $0 { true } else { false }
      }
      if loadedType != attributeType {
        changes.append(.alterAttributeType(name: loaded, type: attributeType))
      }
    }
  }

  /// Drops the attribute shown as `shown`: one added here is removed, a loaded one loses its
  /// other staged edits
  func dropAttribute(_ shown: String) {
    let loaded = loadedAttribute(shown)
    stage { changes in
      if let added = changes.firstIndex(where: {
        if case .addAttribute(let attribute) = $0 { attribute.name == shown } else { false }
      }) {
        changes.remove(at: added)
        return
      }
      guard let loaded else { return }
      changes.removeAll {
        switch $0 {
        case .renameAttribute(loaded, _), .alterAttributeType(loaded, _): true
        default: false
        }
      }
      changes.append(.dropAttribute(name: loaded))
    }
  }

  // MARK: - Staged list

  func undoChange(at index: Int) {
    guard changes.indices.contains(index) else { return }
    stage { $0.remove(at: index) }
  }

  func discardChanges() {
    stage { $0 = [] }
  }

  // MARK: - Apply

  /// Asks Safe Mode first when the commit style confirms writes (the sheet then verifies the
  /// password / Touch ID and calls `confirmApply`); otherwise sends the preview.
  func apply() async {
    guard canApply else { return }
    let plan = plan
    if confirmation.ask(plan) { return }
    await send(plan)
  }

  /// Sends what Safe Mode showed, unless the preview changed meanwhile
  func confirmApply() async {
    guard let confirmed = confirmation.takeConfirmed(), confirmed == plan, canApply else { return }
    await send(confirmed)
  }

  func cancelConfirmation() {
    confirmation.cancel()
  }

  // MARK: - Private

  private func send(_ plan: SchemaChangeConfirmation.Plan) async {
    isApplying = true
    resultMessage = nil
    applyError = nil
    applyPartiallyFailed = false
    let applied = working
    do {
      let result = try await confirmation.send(plan, connectionEpoch: connectionEpoch)
      isApplying = false
      changes = []
      if result.pending {
        // Catalog reads are paused until Commit / Rollback: keep the loaded type
        resultMessage = Self.pendingMessage
        disabledReason = Self.pausedMessage
        rebuildPreview()
        toastPresenter(Self.pendingMessage, .warning)
        await onApplied?(true)
        return
      }
      if let applied {
        type = DatabaseUserType(schema: schema, name: name, kind: applied, oid: type?.oid)
      }
      let message =
        result.insideUserTransaction ? Self.insideTransactionMessage : Self.appliedMessage
      resultMessage = message
      rebuildPreview()
      toastPresenter(message, result.insideUserTransaction ? .warning : .success)
      await onApplied?(false)
    } catch {
      isApplying = false
      let message =
        switch error {
        // Refused before anything ran: an open transaction, or Protected mode (Review)
        case DatabaseError.sequentialBatchRefused(
          DatabaseConnectionManager.sequentialTransactionOpenRefusal):
          Self.addValueOutsideTransactionMessage
        case DatabaseError.sequentialBatchRefused(
          DatabaseConnectionManager.sequentialProtectedModeRefusal):
          Self.addValueUnderReviewMessage
        default:
          error.localizedDescription
        }
      applyError = message
      guard let committed = Self.committedAddCount(error, plan: plan), let loaded = type else {
        toastPresenter(message, .error)
        return
      }
      // The first new labels are committed: they become loaded, the rest stays staged
      toastPresenter(message, .warning)
      applyPartiallyFailed = true
      let added = Set(
        changes.indices.filter { Self.addedLabel(changes[$0]) != nil }.prefix(committed))
      type = DatabaseUserType(
        schema: loaded.schema, name: loaded.name,
        kind: Self.applying(added.sorted().map { changes[$0] }, to: loaded.kind), oid: loaded.oid)
      changes = changes.indices.filter { !added.contains($0) }.map { changes[$0] }
      rebuildPreview()
      await onApplied?(false)
    }
  }

  /// Editable, and no change on its way to the server
  private var canStage: Bool { disabledReason == nil && !isApplying }

  private func stage(_ edit: (inout [UserTypeChange]) -> Void) {
    guard canStage else { return }
    confirmation.cancel()
    let before = changes
    edit(&changes)
    // A new edit: "Applied" and an apply error no longer describe the sheet (the open
    // transaction warning and a partial failure, whose labels stay applied, stay)
    if changes != before {
      if resultMessage == Self.appliedMessage { resultMessage = nil }
      if !applyPartiallyFailed { applyError = nil }
    }
    rebuildPreview()
  }

  /// The name or schema changed: what Safe Mode showed no longer matches
  private func editedName() {
    confirmation.cancel()
    rebuildPreview()
  }

  private func rebuildPreview() {
    let previous = previewError
    previewError = nil
    ddl = UserTypeDDL()
    guard !changes.isEmpty else { return }
    do {
      ddl = try PostgresUserTypeDDLBuilder.build(
        changes, schema: schema, name: name, loaded: type?.kind)
    } catch {
      previewError = error.localizedDescription
    }
    // Only a new error of a staged edit: an unrelated edit that keeps the same one, and a new
    // type's draft (rebuilt while the user types), stay quiet
    if !isNew, let previewError, previewError != previous {
      toastPresenter(previewError, .error)
    }
  }

  /// The loaded label shown as `shown` (renamed or not); nil for a label added here
  private func loadedLabel(_ shown: String) -> String? {
    guard case .enum(let labels) = type?.kind else { return nil }
    for case .renameValue(let label, shown) in changes { return label }
    let renamedAway = changes.contains {
      if case .renameValue(shown, _) = $0 { true } else { false }
    }
    return labels.contains(shown) && !renamedAway ? shown : nil
  }

  /// The loaded attribute shown as `shown` (renamed or not); nil for one added here
  private func loadedAttribute(_ shown: String) -> String? {
    guard case .composite(let attributes) = type?.kind else { return nil }
    for case .renameAttribute(let name, shown) in changes { return name }
    let renamedAway = changes.contains {
      if case .renameAttribute(shown, _) = $0 { true } else { false }
    }
    return attributes.contains { $0.name == shown } && !renamedAway ? shown : nil
  }

  /// Edits the ADD ATTRIBUTE of `shown`; false when it is not added here
  private func editAddedAttribute(
    _ shown: String, in changes: inout [UserTypeChange],
    _ edit: (inout UserTypeChange.Attribute) -> Void
  ) -> Bool {
    guard
      let index = changes.firstIndex(where: {
        if case .addAttribute(let attribute) = $0 { attribute.name == shown } else { false }
      }), case .addAttribute(var attribute) = changes[index]
    else { return false }
    edit(&attribute)
    changes[index] = .addAttribute(attribute)
    return true
  }

  /// How many ADD VALUE statements of the sequential step stay committed after `error`; nil
  /// when none
  private static func committedAddCount(
    _ error: any Error, plan: SchemaChangeConfirmation.Plan
  ) -> Int? {
    if error is SchemaChangePartialFailure { return plan.sequential.count }
    if case DatabaseError.batchPartiallyApplied(let applied, _, _, _) = error, applied > 0 {
      return applied
    }
    return nil
  }

  private static func addedLabel(_ change: UserTypeChange) -> String? {
    if case .addValue(let label, _) = change { return label }
    return nil
  }

  private static func createdKind(_ change: UserTypeChange) -> DatabaseUserType.Kind? {
    switch change {
    case .createEnum(let labels):
      .enum(labels)
    case .createDomain(let domain):
      .domain(
        baseType: domain.baseType, notNull: domain.notNull,
        defaultExpression: domain.defaultExpression,
        constraints: domain.checks.map(constraint))
    case .createComposite(let attributes):
      .composite(attributes.map { .init(name: $0.name, type: $0.type) })
    default:
      nil
    }
  }

  private static func constraint(_ check: UserTypeChange.Check) -> DatabaseUserType.Constraint {
    .init(name: check.name, definition: "CHECK (\(check.expression))")
  }

  /// `kind` with `changes` applied in run order: ADD VALUE first, renames last
  static func applying(
    _ changes: [UserTypeChange], to kind: DatabaseUserType.Kind
  ) -> DatabaseUserType.Kind {
    switch kind {
    case .enum(var labels):
      for case .addValue(let label, let position) in changes {
        switch position {
        case .before(let anchor):
          labels.insert(label, at: labels.firstIndex(of: anchor) ?? labels.endIndex)
        case .after(let anchor):
          labels.insert(label, at: labels.firstIndex(of: anchor).map { $0 + 1 } ?? labels.endIndex)
        case nil:
          labels.append(label)
        }
      }
      for case .renameValue(let label, let newLabel) in changes {
        if let index = labels.firstIndex(of: label) { labels[index] = newLabel }
      }
      return .enum(labels)
    case .domain(let baseType, var notNull, var defaultExpression, var constraints):
      for change in changes {
        switch change {
        case .setDefault(let expression): defaultExpression = expression
        case .dropDefault: defaultExpression = nil
        case .setNotNull: notNull = true
        case .dropNotNull: notNull = false
        case .addCheck(let check): constraints.append(constraint(check))
        case .dropConstraint(let name): constraints.removeAll { $0.name == name }
        default: break
        }
      }
      return .domain(
        baseType: baseType, notNull: notNull, defaultExpression: defaultExpression,
        constraints: constraints)
    case .composite(var attributes):
      for case .dropAttribute(let name) in changes { attributes.removeAll { $0.name == name } }
      for case .addAttribute(let attribute) in changes {
        attributes.append(.init(name: attribute.name, type: attribute.type))
      }
      for case .alterAttributeType(let name, let newType) in changes {
        if let index = attributes.firstIndex(where: { $0.name == name }) {
          attributes[index] = .init(name: name, type: newType)
        }
      }
      for case .renameAttribute(let name, let newName) in changes {
        if let index = attributes.firstIndex(where: { $0.name == name }) {
          attributes[index] = .init(name: newName, type: attributes[index].type)
        }
      }
      return .composite(attributes)
    }
  }
}
