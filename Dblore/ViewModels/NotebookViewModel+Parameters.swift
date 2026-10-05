//
//  NotebookViewModel+Parameters.swift
//  Dblore
//
//  Named :name parameters: detection, binding, and the classification Safe Mode sees.
//

import Foundation

extension NotebookViewModel {
  /// Distinct `:name` values in the visible script, first occurrence, case-sensitive.
  /// Editor mode uses the editor query. Notebook mode walks SQL cells in order.
  func detectedParameterNames() -> [String] {
    var names: [String] = []
    var seen: Set<String> = []
    let scripts: [String]
    if viewMode == .editor {
      scripts = [getEditorQueryText() ?? ""]
    } else {
      scripts = notebook.cells.filter { $0.cellType == .sql }.map(\.content)
    }
    for script in scripts {
      for name in parameterNames(in: script) where seen.insert(name).inserted {
        names.append(name)
      }
    }
    return names
  }

  /// Names in `script`, in first-occurrence order.
  func parameterNames(in script: String) -> [String] {
    SQLParameterRewriter.parameterNames(in: script, dialect: sqlDialect)
  }

  /// `nil` when `script` has no `:name`, so the gate sends the text unchanged.
  func boundParameterValues(for script: String) -> [String: SQLBindValue]? {
    let names = parameterNames(in: script)
    guard !names.isEmpty else { return nil }
    return notebook.parameters.bindValues(for: names).values
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

  /// Stores the missing-parameter error, opens the Parameters sidebar, and returns the message.
  /// Nil when every `:name` has a value, or the script has none. Callers must not send.
  @discardableResult
  func refuseMissingParameters(_ script: String, cellId: UUID?) -> String? {
    let names = parameterNames(in: script)
    guard !names.isEmpty else { return nil }
    let missing = notebook.parameters.bindValues(for: names).missing
    guard !missing.isEmpty else { return nil }
    let message = DatabaseError.missingParameters(missing).localizedDescription
    if let cellId, let index = notebook.cells.firstIndex(where: { $0.id == cellId }) {
      notebook.cells[index].result = .errorResult(message, sourceQuery: script)
      notebook.cells[index].statementResults = []
      notebook.cells[index].selectedStatementIndex = 0
      notebook.cells[index].totalExecutionTime = nil
      notebook.cells[index].isRunning = false
      onDocumentChanged?()
    } else {
      editorStatementResults = []
      selectedStatementIndex = 0
      totalExecutionTime = 0
      editorResult = .errorResult(message, sourceQuery: script)
    }
    rightSidebarContent = .parameters
    isRightSidebarVisible = true
    return message
  }

  /// Stores `value` for `name`. The first stored name wins.
  /// A `.script` tab keeps the value in memory only: Save writes the SQL text, so this edit
  /// does not mark the file dirty.
  func updateParameter(_ value: String?, for name: String) {
    var parameters = notebook.parameters
    if let index = parameters.firstIndex(where: { $0.name == name }) {
      guard parameters[index].value != value else { return }
      parameters[index] = QueryParameter(name: name, value: value)
    } else {
      parameters.append(QueryParameter(name: name, value: value))
    }
    notebook.parameters = parameters
    guard notebook.documentType != .script else { return }
    onDocumentChanged?()
  }

  /// Drops a stored parameter the visible SQL no longer uses. A used name stays.
  /// A `.script` tab does not mark the file dirty.
  func removeUnusedParameter(named name: String) {
    guard !detectedParameterNames().contains(name),
      notebook.parameters.contains(where: { $0.name == name })
    else { return }
    notebook.parameters.removeAll { $0.name == name }
    guard notebook.documentType != .script else { return }
    onDocumentChanged?()
  }
}
