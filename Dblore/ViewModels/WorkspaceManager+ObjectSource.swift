// WorkspaceManager+ObjectSource.swift
// Read-only routine and trigger source tabs: one tab per object (keyed by `ObjectSourceRef.key`),
// opened at once in a loading state while the definition is read off the main actor. The
// result is dropped if the tab closed (or was reloaded) in the meantime.

import Foundation

/// Read state of an object source tab, shown by the read-only editor
nonisolated enum ObjectSourceLoadState: Equatable, Sendable {
  /// Not an object source tab
  case idle
  case loading
  case loaded
  /// The engine has no source for this object; the editor shows a placeholder
  case unavailable
  /// The read failed. Plain text for display only.
  case failed(String)

  /// Short display text for a failed read. Server text stays local (shown, never sent).
  static func message(for error: Error) -> String {
    if case DatabaseError.metadataPausedDuringTransaction = error {
      return "Source is unavailable while a transaction is open"
    }
    return "Could not load the source: \(error.localizedDescription)"
  }
}

extension ObjectSourceRef {
  init(_ object: SchemaObjectRef) {
    switch object {
    case .function(let function):
      self.init(
        kind: .function, schema: function.schema, name: function.name,
        arguments: function.arguments, oid: function.oid)
    case .procedure(let procedure):
      self.init(
        kind: .procedure, schema: procedure.schema, name: procedure.name,
        arguments: procedure.arguments, oid: procedure.oid)
    case .trigger(let trigger):
      self.init(
        kind: .trigger, schema: trigger.schema, name: trigger.name, table: trigger.table,
        oid: trigger.oid)
    }
  }
}

nonisolated extension ObjectSourceRef.Kind {
  /// Label in the source banner
  var displayName: String {
    switch self {
    case .function: "Function"
    case .procedure: "Procedure"
    case .trigger: "Trigger"
    }
  }

  /// SF Symbol shared with the sidebar sections
  var iconName: String {
    switch self {
    case .function: "function"
    case .procedure: "gearshape.2"
    case .trigger: "bolt"
    }
  }
}

nonisolated extension ObjectSourceRef {
  /// "schema.title", or the bare title when the engine has no schema (SQLite)
  var qualifiedName: String {
    schema.isEmpty ? title : "\(schema).\(title)"
  }
}

nonisolated extension DatabaseTrigger {
  /// Sidebar subtitle: "on orders · BEFORE INSERT OR UPDATE", plus "disabled" when off
  var sidebarSubtitle: String {
    var parts = ["on \(table)"]
    let events = events.map(\.rawValue).joined(separator: " OR ")
    parts.append(events.isEmpty ? timing.rawValue : "\(timing.rawValue) \(events)")
    if !enabled { parts.append("disabled") }
    return parts.joined(separator: " · ")
  }
}

extension WorkspaceManager {
  static let objectSourceLoadingText = "-- Loading source…"

  /// The live schema object for a ref: by oid when it has one, else by schema and name (plus
  /// table for triggers, arguments for routines). Nil when the object is not in the schema.
  func schemaObjectRef(for ref: ObjectSourceRef) -> SchemaObjectRef? {
    switch ref.kind {
    case .function:
      let match =
        databaseFunctions.first { ref.oid != nil && $0.oid == ref.oid }
        ?? databaseFunctions.first {
          $0.schema == ref.schema && $0.name == ref.name
            && $0.arguments == (ref.arguments ?? "")
        }
      return match.map { .function($0) }
    case .procedure:
      let match =
        databaseProcedures.first { ref.oid != nil && $0.oid == ref.oid }
        ?? databaseProcedures.first {
          $0.schema == ref.schema && $0.name == ref.name
            && $0.arguments == (ref.arguments ?? "")
        }
      return match.map { .procedure($0) }
    case .trigger:
      let match =
        databaseTriggers.first { ref.oid != nil && $0.oid == ref.oid }
        ?? databaseTriggers.first {
          $0.schema == ref.schema && $0.name == ref.name && $0.table == (ref.table ?? "")
        }
      return match.map { .trigger($0) }
    }
  }

  /// Show an object's source: select its open tab, else open a read-only tab in the loading
  /// state and read the definition in the background. A failed open tab reads again.
  @discardableResult
  func openObjectSource(_ object: SchemaObjectRef) -> UUID {
    let ref = ObjectSourceRef(object)
    if let open = tabs.first(where: { $0.objectSource?.key == ref.key }) {
      selectTab(id: open.id)
      if case .failed = viewModels[open.id]?.objectSourceLoad {
        reloadObjectSource(tabId: open.id)
      }
      return open.id
    }
    let tab = TabItem(documentType: .sqlFile, title: ref.title, isDirty: false, objectSource: ref)
    _ = appendEditorTab(tab, content: Self.objectSourceLoadingText)
    selectTab(id: tab.id)
    startObjectSourceLoad(tabId: tab.id, object: object)
    return tab.id
  }

  /// Read the source of an object source tab again (retry after an error, or refresh). When
  /// the object is not in the loaded schema (disconnected, or dropped) the read fails with Retry.
  func reloadObjectSource(tabId: UUID) {
    guard let ref = tabs.first(where: { $0.id == tabId })?.objectSource,
      let viewModel = viewModels[tabId]
    else { return }
    guard let object = schemaObjectRef(for: ref) else {
      objectSourceLoads.removeValue(forKey: tabId)?.cancel()
      let message =
        "Object not found in the loaded schema — reconnect or refresh the schema, then retry"
      viewModel.editorContent = "-- \(message)"
      viewModel.objectSourceLoad = .failed(message)
      return
    }
    startObjectSourceLoad(tabId: tabId, object: object)
  }

  private func startObjectSourceLoad(tabId: UUID, object: SchemaObjectRef) {
    guard let viewModel = viewModels[tabId],
      let ref = tabs.first(where: { $0.id == tabId })?.objectSource
    else { return }
    objectSourceLoads.removeValue(forKey: tabId)?.cancel()
    viewModel.objectSourceLoad = .loading
    viewModel.editorContent = Self.objectSourceLoadingText

    objectSourceLoads[tabId] = Task { [weak self] in
      let result: Result<String?, Error>
      do {
        result = .success(try await self?.loadDefinition(of: object))
      } catch {
        result = .failure(error)
      }
      // Closed or reloaded meanwhile: a newer load (or none) owns the tab
      guard let self, !Task.isCancelled, self.viewModels[tabId] === viewModel else { return }
      self.objectSourceLoads[tabId] = nil
      self.applyObjectSource(result, ref: ref, to: viewModel)
    }
  }

  private func applyObjectSource(
    _ result: Result<String?, Error>, ref: ObjectSourceRef, to viewModel: NotebookViewModel
  ) {
    switch result {
    case .success(let source?):
      viewModel.editorContent = source
      viewModel.objectSourceLoad = .loaded
    case .success(nil):
      viewModel.editorContent = "-- Source not available for \(ref.kind.rawValue) \(ref.name)"
      viewModel.objectSourceLoad = .unavailable
    case .failure(let error):
      let message = ObjectSourceLoadState.message(for: error)
      let oneLine = message.replacingOccurrences(of: "\n", with: " ")
      viewModel.editorContent = "-- \(oneLine)"
      viewModel.objectSourceLoad = .failed(message)
    }
  }
}

extension WorkspaceManager {
  /// A new untitled SQL tab holding the loaded source of an object source tab, marked dirty so
  /// closing it asks to save. Nil until the source has loaded. The text is never run.
  @discardableResult
  func openEditableCopy(ofSourceTab tabId: UUID) -> UUID? {
    guard let source = viewModels[tabId], source.objectSourceLoad == .loaded else { return nil }
    let text = source.editorContent
    let id = newSQLFile()
    viewModels[id]?.editorContent = text
    markDirty(tabId: id)
    return id
  }
}
