//
//  NotebookViewModel+DataViewer.swift
//  Dblore
//
//  Data viewer tab: loads one page of a table/view through the editor run (same gate, cancel
//  and inline edit path) plus a one-off exact COUNT(*) for the page count.
//

import Foundation

extension NotebookViewModel {
  /// Load the current page (and the row count while unknown). A request made while a run is in
  /// flight is dropped by the guard, so the page is loaded again when the state changed meanwhile.
  func loadDataViewerPage() async {
    while let state = dataViewer, let connectionManager, !isEditorQueryRunning {
      let key = state.loadKey
      // maxRows = pageSize never truncates a LIMIT pageSize page (no cap notice)
      await executeEditorQuery(
        state.pageSQL, maxRows: max(state.pageSize, SessionBrakeLimits.rowCapRange.lowerBound))

      if dataViewer?.totalRows == nil {
        // Busy during the count too: Cancel stops it, paging meanwhile is coalesced by the loop
        isEditorQueryRunning = true
        defer { isEditorQueryRunning = false }
        // Errors keep the total unknown (Next stays enabled), no toast
        let result = try? await connectionManager.execute(
          userSQL: state.countSQL, policy: protectionPolicy, maxRows: 1, caller: id)
        if let result { storeDataViewerTotal(DataViewerState.total(from: result), for: state) }
      }

      guard let current = dataViewer, current.loadKey != key else { return }
    }
  }

  /// Write a count back only while the tab still shows the relation and filter it was counted
  /// for; otherwise the total stays unknown and the load loop recounts.
  func storeDataViewerTotal(_ total: Int?, for state: DataViewerState) {
    guard let current = dataViewer, current.schema == state.schema, current.name == state.name,
      current.filter == state.filter
    else { return }
    dataViewer?.totalRows = total
  }

  /// Go to `page`, clamped to 1...pageCount (no upper bound while the total is unknown)
  func goToPage(_ page: Int) async {
    guard let state = dataViewer else { return }
    let upper = state.pageCount ?? max(page, 1)
    dataViewer?.page = min(max(page, 1), upper)
    await loadDataViewerPage()
  }

  /// Change the rows per page and go back to page 1
  func setPageSize(_ size: Int) async {
    guard dataViewer != nil else { return }
    dataViewer?.pageSize = size
    dataViewer?.page = 1
    await loadDataViewerPage()
  }

  /// Reload the current page and recount the rows
  func refreshDataViewer() async {
    guard dataViewer != nil else { return }
    dataViewer?.totalRows = nil
    await loadDataViewerPage()
  }

  func setColumnHidden(_ name: String, _ hidden: Bool) {
    if hidden {
      dataViewer?.hiddenColumns.insert(name)
    } else {
      dataViewer?.hiddenColumns.remove(name)
    }
  }

  func showAllColumns() {
    dataViewer?.hiddenColumns.removeAll()
  }
}

// MARK: - Filter

extension NotebookViewModel {
  /// Prepare the filter form: the draft restarts from the applied filter when the viewer shows
  /// another table, keeps at least one row, and the saved filters are read again
  func prepareFilterDraft() {
    guard let state = dataViewer else { return }
    let relation = "\(state.schema).\(state.name)"
    if filterDraftRelation != relation {
      filterDraftRelation = relation
      filterDraft = state.filter
    }
    if filterDraft.isEmpty {
      filterDraft = TableFilter(conditions: [FilterCondition()])
    }
    refreshSavedFilters()
  }

  /// Apply the draft: back to page 1 with the count recomputed
  func applyFilter() async {
    guard let state = dataViewer else { return }
    let blank = filterDraft.whereClause(dialect: state.databaseType.dialect) == nil
    dataViewer?.filter = blank ? TableFilter(conditions: []) : filterDraft
    dataViewer?.page = 1
    dataViewer?.totalRows = nil
    await loadDataViewerPage()
  }

  /// Remove the applied filter and reset the form to one empty row
  func clearFilter() async {
    guard dataViewer != nil else { return }
    filterDraft = TableFilter(conditions: [FilterCondition()])
    dataViewer?.filter = TableFilter(conditions: [])
    dataViewer?.page = 1
    dataViewer?.totalRows = nil
    await loadDataViewerPage()
  }

  /// Column names of the viewed table or view, else those of the loaded result
  var filterColumns: [String] {
    guard let state = dataViewer else { return [] }
    if let table = databaseTables.first(where: {
      $0.schema == state.schema && $0.name == state.name
    }) {
      return table.columns.map(\.name)
    }
    if let view = databaseViews.first(where: { $0.schema == state.schema && $0.name == state.name })
    {
      return view.columns.map(\.name)
    }
    return editorResult?.columns.map(\.name) ?? []
  }

  private var savedFilterKey: String? {
    guard let state = dataViewer, let config = notebook.connectionConfig else { return nil }
    return SavedFilterStore.key(for: config, schema: state.schema, name: state.name)
  }

  func refreshSavedFilters() {
    savedFilters = savedFilterKey.map { savedFilterStore.list(for: $0) } ?? []
  }

  /// Save the draft under the trimmed `name`, replacing a saved filter of that name.
  /// Returns false (nothing saved) for a blank name.
  @discardableResult
  func saveCurrentFilter(named name: String) -> Bool {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let key = savedFilterKey else { return false }
    savedFilterStore.save(filterDraft, named: name, for: key)
    refreshSavedFilters()
    return true
  }

  /// Fill the draft with a saved filter (not applied until Apply)
  func loadSavedFilter(_ saved: SavedFilter) {
    filterDraft = saved.filter
    if filterDraft.isEmpty {
      filterDraft = TableFilter(conditions: [FilterCondition()])
    }
  }

  func deleteSavedFilter(_ saved: SavedFilter) {
    guard let key = savedFilterKey else { return }
    savedFilterStore.delete(id: saved.id, for: key)
    refreshSavedFilters()
  }
}
