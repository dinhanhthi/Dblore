//
//  NotebookViewModel+Pinning.swift
//  Dblore
//
//  Pin a result and compare later runs against it. A cell pin is part of the document
//  (saved with results); the editor pin and every compare toggle are session only.
//

import Foundation

/// Pinned result against the current one: plans when both sides are EXPLAIN JSON, else rows
nonisolated enum CellComparison: Sendable, Equatable {
  case rows(ResultDiff)
  case plan(ExplainPlanDiff)
}

/// What a comparison describes: the pin and the current result (and its statement)
nonisolated struct CompareSubject: Hashable, Sendable {
  let pinnedAt: Date?
  let timestamp: Date?
  let statement: Int
}

/// A comparison with the subject it was computed for
nonisolated struct SubjectComparison: Sendable, Equatable {
  let subject: CompareSubject
  let comparison: CellComparison
}

extension NotebookViewModel {
  // MARK: - Cells

  /// Pin the cell's current result. False when the cell has no successful result.
  @discardableResult
  func pinResult(cellID: UUID) -> Bool {
    guard let index = notebook.cells.firstIndex(where: { $0.id == cellID }),
      let pin = Self.pin(
        notebook.cells[index].result,
        query: notebook.cells[index].result?.sourceQuery ?? notebook.cells[index].content)
    else { return false }
    notebook.cells[index].pinnedResult = pin
    onDocumentChanged?()
    refreshComparison(cellID: cellID)
    return true
  }

  func unpinResult(cellID: UUID) {
    guard let index = notebook.cells.firstIndex(where: { $0.id == cellID }),
      notebook.cells[index].pinnedResult != nil
    else { return }
    notebook.cells[index].pinnedResult = nil
    onDocumentChanged?()
    refreshComparison(cellID: cellID)
  }

  func isComparing(cellID: UUID) -> Bool {
    comparingCellIds.contains(cellID)
  }

  /// Allowed without a pin; the comparison stays nil until one exists
  func toggleCompare(cellID: UUID) {
    if comparingCellIds.remove(cellID) == nil {
      comparingCellIds.insert(cellID)
    }
    refreshComparison(cellID: cellID)
  }

  /// Pinned vs current result of the cell, nil without a pin or a successful result
  func comparison(for cellID: UUID) async -> CellComparison? {
    guard let cell = notebook.cells.first(where: { $0.id == cellID }) else { return nil }
    return await Self.compare(pin: cell.pinnedResult, current: cell.result)
  }

  /// The cell's comparison when it describes the shown pin and result, else nil ("Comparing…")
  func displayedComparison(cellID: UUID) -> CellComparison? {
    guard let stored = cellComparisons[cellID],
      let cell = notebook.cells.first(where: { $0.id == cellID }),
      stored.subject == Self.subject(of: cell)
    else { return nil }
    return stored.comparison
  }

  /// Recompute `cellComparisons[cellID]` off the main actor. The view calls this when the
  /// cell's result changes (e.g. `.task(id: result?.timestamp)`). The state is read now, so
  /// a refresh started later always wins.
  @discardableResult
  func refreshComparison(cellID: UUID) -> Task<Void, Never> {
    let generation = (comparisonGenerations[cellID] ?? 0) + 1
    comparisonGenerations[cellID] = generation
    let cell = notebook.cells.first(where: { $0.id == cellID })
    guard comparingCellIds.contains(cellID), let cell, cell.pinnedResult != nil else {
      cellComparisons[cellID] = nil
      return Task {}
    }
    let subject = Self.subject(of: cell)
    // Drop a diff of another result now; keep a matching one (no flicker on re-appear)
    if cellComparisons[cellID]?.subject != subject {
      cellComparisons[cellID] = nil
    }
    let pin = cell.pinnedResult
    let current = cell.result
    return Task { [weak self] in
      let comparison = await Self.compare(pin: pin, current: current)
      guard let self, self.comparisonGenerations[cellID] == generation else { return }
      self.cellComparisons[cellID] = comparison.map {
        SubjectComparison(subject: subject, comparison: $0)
      }
    }
  }

  /// Drop the session compare state of a deleted cell
  func forgetComparison(cellID: UUID) {
    comparingCellIds.remove(cellID)
    cellComparisons[cellID] = nil
    comparisonGenerations[cellID] = nil
  }

  // MARK: - Editor

  /// Pin the editor result (session only, the document is not changed)
  @discardableResult
  func pinEditorResult() -> Bool {
    guard let pin = Self.pin(editorResult, query: editorResult?.sourceQuery ?? editorContent)
    else { return false }
    editorPinnedResult = pin
    refreshEditorComparison()
    return true
  }

  func unpinEditorResult() {
    editorPinnedResult = nil
    refreshEditorComparison()
  }

  func toggleEditorCompare() {
    isEditorComparing.toggle()
    refreshEditorComparison()
  }

  /// The editor comparison when it describes the shown pin and result, else nil
  var displayedEditorComparison: CellComparison? {
    guard let stored = editorComparison, stored.subject == editorSubject else { return nil }
    return stored.comparison
  }

  /// Recompute `editorComparison` off the main actor; called after each editor run
  @discardableResult
  func refreshEditorComparison() -> Task<Void, Never> {
    editorComparisonGeneration += 1
    let generation = editorComparisonGeneration
    guard isEditorComparing, let pin = editorPinnedResult else {
      editorComparison = nil
      return Task {}
    }
    let subject = editorSubject
    if editorComparison?.subject != subject {
      editorComparison = nil
    }
    let current = editorResult
    return Task { [weak self] in
      let comparison = await Self.compare(pin: pin, current: current)
      guard let self, self.editorComparisonGeneration == generation else { return }
      self.editorComparison = comparison.map {
        SubjectComparison(subject: subject, comparison: $0)
      }
    }
  }

  // MARK: - Helpers

  private static func subject(of cell: NotebookCell) -> CompareSubject {
    CompareSubject(
      pinnedAt: cell.pinnedResult?.pinnedAt, timestamp: cell.result?.timestamp,
      statement: cell.selectedStatementIndex)
  }

  private var editorSubject: CompareSubject {
    CompareSubject(
      pinnedAt: editorPinnedResult?.pinnedAt, timestamp: editorResult?.timestamp,
      statement: selectedStatementIndex)
  }

  private static func pin(_ result: CellResult?, query: String) -> PinnedResult? {
    guard let result, result.error == nil else { return nil }
    return PinnedResult(result: result, pinnedAt: Date(), sourceQuery: query)
  }

  private static func compare(
    pin: PinnedResult?, current: CellResult?
  ) async
    -> CellComparison?
  {
    guard let pin, let current, current.error == nil else { return nil }
    let planDiff = await Task.detached(priority: .userInitiated) { () -> ExplainPlanDiff? in
      guard let baseline = ExplainResultPlan.parse(pin.result),
        let currentPlan = ExplainResultPlan.parse(current)
      else { return nil }
      return PerfSignpost.interval("plan.compare") {
        ExplainPlanComparison.compare(baseline: baseline.root, current: currentPlan.root)
      }
    }.value
    if let planDiff { return .plan(planDiff) }
    return .rows(
      await ResultComparison.compareInBackground(baseline: pin.result, current: current))
  }
}
