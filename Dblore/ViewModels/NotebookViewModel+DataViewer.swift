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
      guard let query = dataViewerQuery(state) else { return }
      // maxRows >= pageSize never truncates a LIMIT pageSize page (no cap notice); MongoDB's
      // `limit(min(limit, maxRows + 1))` rewrite keeps limit(pageSize)
      await executeEditorQuery(
        query.page, maxRows: max(state.pageSize, SessionBrakeLimits.rowCapRange.lowerBound),
        source: .internal)

      if dataViewer?.totalRows == nil {
        // Busy during the count too: Cancel stops it, paging meanwhile is coalesced by the loop
        isEditorQueryRunning = true
        defer { isEditorQueryRunning = false }
        // Errors keep the total unknown (Next stays enabled), no toast
        let started = Date()
        let result = try? await connectionManager.execute(
          userSQL: query.count, policy: protectionPolicy, maxRows: 1, caller: id)
        scheduleHistory(
          [
            QueryHistoryOutcome(
              sql: query.count, duration: Date().timeIntervalSince(started),
              rowCount: result?.rowCount, status: result == nil ? .error : .success,
              errorMessage: nil)
          ], source: .internal)
        if let result { storeDataViewerTotal(DataViewerState.total(from: result), for: state) }
      }

      guard let current = dataViewer, current.loadKey != key else { return }
    }
  }

  /// True for a data viewer on a MongoDB connection: pages are mongosh commands and the
  /// document filter bar replaces the SQL filter form.
  var isMongoDataViewer: Bool {
    guard let state = dataViewer else { return false }
    return state.databaseType == .mongodb || sqlDialect == .mongodb
  }

  /// Collection screen of a MongoDB data viewer, nil for any other tab. A plain read, safe from
  /// a view body: the model is created by `syncMongoCollectionModel()` when `dataViewer` changes.
  var mongoCollection: MongoCollectionModel? {
    isMongoDataViewer ? mongoCollectionModel : nil
  }

  /// Cmd+F and the header search button: a MongoDB collection searches its Documents section only
  var isSearchAvailable: Bool {
    (mongoCollection?.section ?? .documents) == .documents
  }

  /// Called on every `dataViewer` change: keep the model while the viewer shows the same
  /// collection (its section and indexes stay), else cancel its read and start a new one.
  func syncMongoCollectionModel() {
    guard isMongoDataViewer, let state = dataViewer, let connectionManager else {
      if mongoCollectionModel != nil {
        mongoCollectionModel?.cancel()
        mongoCollectionModel = nil
      }
      return
    }
    let database = state.schema.isEmpty ? nil : state.schema
    if let model = mongoCollectionModel, model.database == database,
      model.collection == state.name
    {
      return
    }
    mongoCollectionModel?.cancel()
    mongoCollectionModel = MongoCollectionModel(
      database: database, collection: state.name, connectionManager: connectionManager)
  }

  /// Page and count text of `state`: the rendered `find` and `countDocuments` for MongoDB (the
  /// SQL paging and WHERE helpers never run there), else the SQL. Nil, with the error shown, when
  /// the applied document filter does not parse.
  private func dataViewerQuery(_ state: DataViewerState) -> (page: String, count: String)? {
    guard isMongoDataViewer else { return (state.pageSQL, state.countSQL) }
    do {
      let commands = try state.mongoQueries()
      return (commands.page.render(), commands.count.render())
    } catch {
      editorResult = CellResult.errorResult(
        error.localizedDescription, sourceQuery: state.documentFilter)
      return nil
    }
  }

  /// Write a count back only while the tab still shows the relation and filter it was counted
  /// for; otherwise the total stays unknown and the load loop recounts.
  func storeDataViewerTotal(_ total: Int?, for state: DataViewerState) {
    guard let current = dataViewer, current.schema == state.schema, current.name == state.name,
      current.filter == state.filter, current.documentFilter == state.documentFilter
    else { return }
    dataViewer?.totalRows = total
  }

  /// Go to `page`, clamped to 1...pageCount (no upper bound while the total is unknown).
  /// Staged changes must be committed or discarded first. Cancel leaves the page.
  func goToPage(_ page: Int) async {
    guard dataViewer != nil else { return }
    guard await confirmLeaveStagedChanges() else { return }
    guard let state = dataViewer else { return }
    let upper = state.pageCount ?? max(page, 1)
    dataViewer?.page = min(max(page, 1), upper)
    await loadDataViewerPage()
  }

  /// Change the rows per page and go back to page 1. Staged changes must be resolved first.
  func setPageSize(_ size: Int) async {
    guard dataViewer != nil else { return }
    guard await confirmLeaveStagedChanges() else { return }
    guard dataViewer != nil else { return }
    dataViewer?.pageSize = size
    dataViewer?.page = 1
    await loadDataViewerPage()
  }

  /// Reload the current page and recount the rows. Staged changes must be resolved first.
  func refreshDataViewer() async {
    guard dataViewer != nil else { return }
    guard await confirmLeaveStagedChanges() else { return }
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

  /// Apply the draft: back to page 1 with the count recomputed.
  /// Staged changes must be resolved first.
  func applyFilter() async {
    guard dataViewer != nil else { return }
    guard await confirmLeaveStagedChanges() else { return }
    await applyFilterDraft()
  }

  /// Apply `filter` (a foreign-key jump). The draft becomes `filter` only once staged changes
  /// are resolved: Cancel, or a prompt already open, keeps the user's draft.
  func applyFilter(_ filter: TableFilter) async {
    guard dataViewer != nil else { return }
    guard await confirmLeaveStagedChanges() else { return }
    filterDraft = filter
    await applyFilterDraft()
  }

  /// MongoDB has no SQL filter (the document filter bar replaces it): nothing is applied.
  private func applyFilterDraft() async {
    guard let state = dataViewer, !isMongoDataViewer else { return }
    let blank = filterDraft.whereClause(dialect: state.databaseType.dialect) == nil
    dataViewer?.filter = blank ? TableFilter(conditions: []) : filterDraft
    dataViewer?.page = 1
    dataViewer?.totalRows = nil
    await loadDataViewerPage()
  }

  /// Remove the applied filter and reset the form to one empty row.
  /// Staged changes must be resolved first.
  func clearFilter() async {
    guard dataViewer != nil else { return }
    guard await confirmLeaveStagedChanges() else { return }
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

// MARK: - MongoDB filter and sort

extension NotebookViewModel {
  /// Apply the document filter `text`: back to page 1 with the count recomputed. Returns the
  /// parse error (nothing applied, no prompt) for text that is not a document.
  /// Staged changes must be resolved first.
  func applyDocumentFilter(_ text: String) async -> DataViewerState.DocumentFilterError? {
    guard dataViewer != nil else { return nil }
    let value: MongoValue?
    switch DataViewerState.documentFilterValue(text) {
    case .success(let document): value = document
    case .failure(let error): return error
    }
    guard await confirmLeaveStagedChanges() else { return nil }
    guard dataViewer != nil else { return nil }
    // Blank text and `{}` are both no filter
    dataViewer?.documentFilter =
      value == nil ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines)
    dataViewer?.page = 1
    dataViewer?.totalRows = nil
    await loadDataViewerPage()
    return nil
  }

  /// Remove the document filter. Staged changes must be resolved first.
  func clearDocumentFilter() async {
    _ = await applyDocumentFilter("")
  }

  /// Sort by `field` (nil: the default `{_id: 1}`) on the server and go back to page 1.
  /// Staged changes must be resolved first.
  func setDocumentSort(_ field: String?, ascending: Bool) async {
    guard dataViewer != nil else { return }
    guard await confirmLeaveStagedChanges() else { return }
    guard dataViewer != nil else { return }
    dataViewer?.documentSort = field.map {
      DataViewerState.DocumentSort(field: $0, ascending: ascending)
    }
    dataViewer?.page = 1
    await loadDataViewerPage()
  }
}
