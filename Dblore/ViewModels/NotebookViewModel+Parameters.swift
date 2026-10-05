//
//  NotebookViewModel+Parameters.swift
//  Dblore
//
//  Named :name parameters: detection, binding, and the classification Safe Mode sees.
//  A nil cellId scopes values to the editor tab; a cell id scopes them to that cell.
//

import Foundation

extension NotebookViewModel {
  /// Distinct `:name` values in the editor query, first occurrence, case-sensitive.
  func detectedParameterNames() -> [String] {
    parameterNames(in: getEditorQueryText() ?? "")
  }

  /// Names in `script`, in first-occurrence order.
  func parameterNames(in script: String) -> [String] {
    SQLParameterRewriter.parameterNames(in: script, dialect: sqlDialect)
  }

  /// Stored `:name` values of the scope `cellId` selects: nil is the editor tab, a cell id
  /// is that cell's list. A gone cell has no values.
  func storedParameters(cellId: UUID?) -> [QueryParameter] {
    guard let cellId else { return editorParameters }
    return notebook.cells.first(where: { $0.id == cellId })?.parameters ?? []
  }

  /// `nil` when `script` has no `:name`, so the gate sends the text unchanged.
  func boundParameterValues(for script: String, cellId: UUID?) -> [String: SQLBindValue]? {
    let names = parameterNames(in: script)
    guard !names.isEmpty else { return nil }
    return storedParameters(cellId: cellId).bindValues(for: names).values
  }

  /// Protection and Safe Mode classification. No `:name` keeps today's `classify` result.
  /// With names, kind and flags come from the rewritten text and `text` stays the original
  /// slice, so the confirmation preview still shows `:name`.
  func classifiedStatements(for query: String) -> [ClassifiedStatement] {
    let classified = SQLStatementClassifier.classify(query, dialect: sqlDialect)
    guard !parameterNames(in: query).isEmpty else { return classified }
    return classified.compactMap { original in
      let rewritten = SQLParameterRewriter.rewrite(statement: original.text, dialect: sqlDialect)
        .text
      guard let again = SQLStatementClassifier.classifyStatement(rewritten, dialect: sqlDialect)
      else { return nil }
      return ClassifiedStatement(
        text: original.text, kind: again.kind, hasReturning: again.hasReturning,
        hasTopLevelReturning: again.hasTopLevelReturning, affectsAllRows: again.affectsAllRows,
        nonTransactional: again.nonTransactional, resetsSessionBrakes: again.resetsSessionBrakes,
        changesPrivileges: again.changesPrivileges, createsTable: again.createsTable)
    }
  }

  /// Stores the missing-parameter error and opens that scope's parameter UI: the cell's
  /// inline form, or the editor tab's sidebar. A notebook refusal with no cell (Explain
  /// without a selection) only toasts — the notebook tab has no sidebar Parameters button.
  /// Nil when every `:name` has a value, or the script has none. Callers must not send.
  @discardableResult
  func refuseMissingParameters(_ script: String, cellId: UUID?) -> String? {
    let names = parameterNames(in: script)
    guard !names.isEmpty else { return nil }
    let missing = storedParameters(cellId: cellId).bindValues(for: names).missing
    guard !missing.isEmpty else { return nil }
    let message = DatabaseError.missingParameters(missing).localizedDescription
    if let cellId, let index = notebook.cells.firstIndex(where: { $0.id == cellId }) {
      notebook.cells[index].result = .errorResult(message, sourceQuery: script)
      notebook.cells[index].statementResults = []
      notebook.cells[index].selectedStatementIndex = 0
      notebook.cells[index].totalExecutionTime = nil
      notebook.cells[index].isRunning = false
      onDocumentChanged?()
      openParameterFormCellIds.insert(cellId)
      return message
    }
    guard viewMode == .editor else {
      showToast(message, type: .error)
      return message
    }
    editorStatementResults = []
    selectedStatementIndex = 0
    totalExecutionTime = 0
    editorResult = .errorResult(message, sourceQuery: script)
    rightSidebarContent = .parameters
    isRightSidebarVisible = true
    return message
  }

  /// Stores `value` for `name` in the scope `cellId` selects (nil is the editor tab).
  /// The first stored name wins; writing the same value is a no-op. A cell edit marks the
  /// file dirty only when that cell saves its parameter values. Editor values are
  /// session-only, so an editor edit never does.
  func updateParameter(_ value: String?, for name: String, cellId: UUID? = nil) {
    guard let cellId else {
      editorParameters.store(value, for: name)
      return
    }
    guard let index = notebook.cells.firstIndex(where: { $0.id == cellId }),
      notebook.cells[index].parameters.store(value, for: name)
    else { return }
    if notebook.cells[index].savesParameterValues {
      onDocumentChanged?()
    }
  }

  /// Whether the cell's parameter values are written to the file. Toggling marks dirty.
  func setSavesParameterValues(_ saves: Bool, cellId: UUID) {
    guard let index = notebook.cells.firstIndex(where: { $0.id == cellId }) else { return }
    notebook.cells[index].savesParameterValues = saves
    onDocumentChanged?()
  }

  /// True when the cell stores an entry — text or NULL — for a `:name` its SQL uses.
  func hasStoredParameterValues(cellId: UUID) -> Bool {
    guard let cell = notebook.cells.first(where: { $0.id == cellId }) else { return false }
    let names = Set(parameterNames(in: cell.content))
    return cell.parameters.contains { names.contains($0.name) }
  }

  /// Opens or closes the cell's inline parameter form. Session only.
  func toggleParameterForm(cellId: UUID) {
    if openParameterFormCellIds.contains(cellId) {
      openParameterFormCellIds.remove(cellId)
    } else {
      openParameterFormCellIds.insert(cellId)
    }
  }

  /// Drops a stored editor parameter the query no longer uses. A used name stays.
  /// Editor values are session-only, so the file is never marked dirty.
  func removeUnusedParameter(named name: String) {
    guard !detectedParameterNames().contains(name) else { return }
    editorParameters.removeAll { $0.name == name }
  }
}

extension Array where Element == QueryParameter {
  /// Stores `value` for `name`; the first stored name wins. False when nothing changed.
  @discardableResult
  fileprivate mutating func store(_ value: String?, for name: String) -> Bool {
    if let index = firstIndex(where: { $0.name == name }) {
      guard self[index].value != value else { return false }
      self[index] = QueryParameter(name: name, value: value)
    } else {
      append(QueryParameter(name: name, value: value))
    }
    return true
  }
}
