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
  /// The page read now shows what other tabs wrote (`isStale` cleared before it is read, so a
  /// write landing meanwhile marks it again). A keyless table's page shown without its locator
  /// columns (`dataViewerAwaitsRowLocators`) is read once more with them.
  func loadDataViewerPage() async {
    let textMasks = await dataViewerTextMasks()
    while let current = dataViewer, let connectionManager, !isEditorQueryRunning {
      let rowLocator = dataViewerRowLocator(current)
      if current.rowLocator != rowLocator { dataViewer?.rowLocator = rowLocator }
      let columnTypeData = dataViewerColumnTypeData(current)
      let lazyColumns = dataViewerLazyColumns(
        current, rowLocator: rowLocator, textMasks: textMasks, columnTypeData: columnTypeData)
      if current.lazyColumns != lazyColumns { dataViewer?.lazyColumns = lazyColumns }
      if current.columnTypeData != columnTypeData {
        dataViewer?.columnTypeData = columnTypeData
        // The filter's operators changed with the types: count the total again
        if !current.filter.isEmpty { dataViewer?.totalRows = nil }
      }
      guard let state = dataViewer else { return }
      let key = state.loadKey
      guard let query = dataViewerQuery(state) else { return }
      if state.isStale { dataViewer?.isStale = false }
      // maxRows >= pageSize never truncates a LIMIT pageSize page (no cap notice); MongoDB's
      // `limit(min(limit, maxRows + 1))` rewrite keeps limit(pageSize)
      if let page = query.page {
        await executeEditorQuery(
          page, maxRows: max(state.pageSize, SessionBrakeLimits.rowCapRange.lowerBound),
          source: .internal, pageState: isMongoDataViewer ? nil : state)
      } else {
        showEmptyDataViewerPage()
      }

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

      guard let current = dataViewer else { return }
      // The target known now asks for locator columns this read did not have (a read that was
      // refused already had them: no second try)
      let addsLocators =
        dataViewerAwaitsRowLocators && dataViewerRowLocator(current) != state.rowLocator
      guard current.loadKey != key || addsLocators else { return }
    }
  }

  /// The locator columns the next page of the viewed table reads (`DataViewerState.rowLocator`):
  /// the shown edit target's, never from a catalog read; the ones the page was read with while
  /// its table definition is read. Nil for a table with a primary key, no target, or a table with
  /// a column named like a locator alias.
  private func dataViewerRowLocator(_ state: DataViewerState) -> RowLocatorKind? {
    guard let result = editorResult else { return state.rowLocator }
    if result.typesPending { return state.rowLocator }
    guard !isMongoDataViewer, let kind = result.editTarget?.rowLocator else { return nil }
    var located = state
    located.rowLocator = kind
    let names = Set(result.columns.map { $0.name.lowercased() })
    return located.locatorColumns.contains(where: names.contains) ? nil : kind
  }

  /// The shown page is of a keyless table but was read without its locator columns (its first
  /// page, read before its edit target was known): editing waits for the re-read that adds them
  var dataViewerAwaitsRowLocators: Bool {
    guard let state = dataViewer, let result = editorResult, result.error == nil,
      !result.typesPending, let kind = dataViewerRowLocator(state)
    else { return false }
    return result.truncation?.rowLocator != kind
  }

  /// The mask rules text prefixes are picked by (`DataViewerState.TextPrefixRules.masks`), nil
  /// when the open session's text lengths are not UTF-8 (no text is cut) or for MongoDB
  private func dataViewerTextMasks() async -> ColumnMaskRuleSet? {
    guard let connectionManager, dataViewer != nil, !isMongoDataViewer,
      await connectionManager.textLengthsAreUTF8()
    else { return nil }
    return ColumnMaskRuleSet(await connectionManager.currentMaskRules())
  }

  /// The lazy columns of the viewed table from what is cached, never a catalog read: the
  /// sidebar's columns of the table, else the shown page's columns and edit target. Nil
  /// (`SELECT *`) for MongoDB, a view, a table without a primary key that the page does not
  /// locate (`rowLocator`, the locator columns the same page reads: its cut cells are read by
  /// them), nothing cached, or a shown page without an edit target (an error, or a table that
  /// cannot be edited). A page shown before its table definition keeps the lazy columns it was
  /// read with. Text is cut only with `textMasks`; on PostgreSQL only from the cached columns
  /// (their catalog type text and `columnTypeData`), never from the shown page's columns.
  private func dataViewerLazyColumns(
    _ state: DataViewerState, rowLocator: RowLocatorKind?, textMasks: ColumnMaskRuleSet?,
    columnTypeData: [String: PostgresColumnType]
  ) -> [DataViewerState.LazyColumn]? {
    if editorResult?.typesPending == true { return state.lazyColumns }
    guard !isMongoDataViewer, editorResult.map({ $0.editTarget != nil }) ?? true else {
      return nil
    }
    var binaryValueColumns = Set<String>()
    var textValueColumns = Set<String>()
    if let result = editorResult {
      for (index, column) in result.columns.enumerated() {
        for row in result.rows where index < row.count {
          switch row[index] {
          case .data: binaryValueColumns.insert(column.name)
          case .string, .json: textValueColumns.insert(column.name)
          default: continue
          }
        }
      }
    }
    let text = textMasks.map {
      DataViewerState.TextPrefixRules(
        masks: $0, columnTypeData: columnTypeData, textValueColumns: textValueColumns)
    }
    // `SELECT *` leaves out the hidden columns of a SQLite virtual table
    let cached =
      databaseTables.first(where: {
        $0.schema == state.schema && $0.name == state.name
      })?.columns.filter { !$0.isHidden } ?? []
    // The cache, unless a shown page of the table has other columns (stale either way: a
    // column added or dropped since): then the shown page's columns
    if !cached.isEmpty, editorResult.map({ $0.columns.map(\.name) == cached.map(\.name) }) ?? true {
      return DataViewerState.lazyColumns(
        cached.map { ($0.name, $0.type, $0.isPrimaryKey) },
        databaseType: state.databaseType, orderColumns: state.orderColumns,
        binaryValueColumns: binaryValueColumns, located: rowLocator != nil, text: text)
    }
    guard let result = editorResult, let target = result.editTarget else { return nil }
    let key = Set(target.primaryKeyColumns)
    // A PostgreSQL result type has no length and no type data: its text is cut from the cache
    return DataViewerState.lazyColumns(
      result.columns.map { ($0.name, $0.type, key.contains($0.name)) },
      databaseType: state.databaseType, orderColumns: state.orderColumns,
      binaryValueColumns: binaryValueColumns, located: rowLocator != nil,
      text: state.databaseType == .postgresql ? nil : text)
  }

  /// Column name → type data of the viewed table or view from the schema cache
  /// (`DatabaseColumn.postgresType`), never a catalog read nor a result's column types. Empty
  /// while the cache does not have the relation; a column without type data (a built-in type,
  /// other engines) is left out, so its comparisons are qualified.
  private func dataViewerColumnTypeData(_ state: DataViewerState) -> [String: PostgresColumnType] {
    let columns =
      databaseTables.first(where: { $0.schema == state.schema && $0.name == state.name })?.columns
      ?? databaseViews.first(where: { $0.schema == state.schema && $0.name == state.name })?
      .columns ?? []
    return Dictionary(
      columns.compactMap { column in column.postgresType.map { (column.name, $0) } },
      uniquingKeysWith: { first, _ in first })
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

  /// An admin command on the indexes of the collection shown, gated by the connection epoch its
  /// index list was read with (a reconnect since then refuses it); the list is read again once
  /// the command ran. Nil when the tab is not connected or no list was read yet.
  func mongoIndexAdminAction() -> MongoAdminActionModel? {
    guard let collection = mongoCollection, let epoch = collection.indexEpoch else { return nil }
    return MongoAdminActionModel(
      tab: self, connectionEpoch: epoch,
      onExecuted: { [weak collection] in collection?.refreshIndexes() })
  }

  /// A `collMod` of the validation rules of the collection shown, gated by the connection epoch
  /// its rules were read with; the rules (and the draft) are read again once the command
  /// succeeded, so a refused edit stays in the editor. Nil when the tab is not connected or no
  /// rules were read yet.
  func mongoValidationAdminAction() -> MongoAdminActionModel? {
    guard let collection = mongoCollection, let epoch = collection.validationEpoch else {
      return nil
    }
    // `onExecuted` also runs after a failure; the model sets its state first
    weak var action: MongoAdminActionModel?
    let model = MongoAdminActionModel(
      tab: self, connectionEpoch: epoch,
      onExecuted: { [weak collection] in
        if action?.state == .done { collection?.refreshValidation() }
      })
    action = model
    return model
  }

  /// Bulk Update / Delete of the Documents header: a connected MongoDB collection (not a view)
  /// whose protection level allows data changes
  var canBulkWriteMongoDocuments: Bool {
    guard let state = dataViewer, mongoCollection != nil, connectionState == .connected,
      !protectionPolicy.protectionLevel.blocksDataModifications
    else { return false }
    return !databaseViews.contains(where: { $0.name == state.name })
  }

  /// Opens the bulk write form on the collection shown, prefilled with the applied filter. The
  /// header stays clickable under the form: an open form keeps its draft.
  func openMongoBulkWrite() {
    guard canBulkWriteMongoDocuments, let collection = mongoCollection,
      collection.bulkWrite == nil
    else { return }
    collection.bulkWrite = MongoBulkWriteModel(tab: self)
  }

  /// Closes the bulk write form, stopping its preview; refused while its command runs
  func closeMongoBulkWrite() {
    guard let collection = mongoCollection, let model = collection.bulkWrite,
      model.state != .running
    else { return }
    model.cancel()
    collection.bulkWrite = nil
  }

  /// Page and count text of `state`: the rendered `find` and `countDocuments` for MongoDB (the
  /// SQL paging and WHERE helpers never run there), else the SQL. The page is nil past the user
  /// limit (nothing to read). Nil, with the error shown, when the applied document filter or
  /// options do not parse.
  private func dataViewerQuery(_ state: DataViewerState) -> (page: String?, count: String)? {
    guard isMongoDataViewer else { return (state.pageSQL, state.countSQL) }
    do {
      let commands = try state.mongoQueries()
      return (commands.page?.render(), commands.count.render())
    } catch {
      editorResult = CellResult.errorResult(
        error.localizedDescription, sourceQuery: state.documentFilter, aiSessionKey: aiSessionKey)
      return nil
    }
  }

  /// Source labels of a data viewer page (`CellResult.columnSourceLabels`): every column is a
  /// column of the viewed relation, so each is `schema.name.column` with no catalog read (an
  /// empty schema is left out). DuckDB, MongoDB, ClickHouse and SQL Server pages have none.
  func dataViewerSourceLabels(_ state: DataViewerState, columns: [ColumnInfo]) -> [Int: String] {
    switch state.databaseType {
    case .postgresql, .mysql, .sqlite: break
    case .duckdb, .mongodb, .clickhouse, .sqlserver, .redis: return [:]
    }
    let relation = [state.schema, state.name].filter { !$0.isEmpty }
    var labels: [Int: String] = [:]
    for (index, column) in columns.enumerated() {
      labels[index] = (relation + [column.name]).joined(separator: ".")
    }
    return labels
  }

  /// A page past the user limit: no rows, nothing sent. The columns and edit target stay, so
  /// the grid keeps its shape.
  private func showEmptyDataViewerPage() {
    editorStatementResults = []
    selectedStatementIndex = 0
    var empty = CellResult(
      columns: editorResult?.columns ?? [], editTarget: editorResult?.editTarget,
      lookupRelation: editorResult?.lookupRelation)
    empty.columnSourceLabels = editorResult?.columnSourceLabels ?? [:]
    editorResult = empty
    syncRowDetail(cellId: nil, result: empty)
  }

  /// Write a count back only while the tab still shows the relation, filter and options it was
  /// counted for; otherwise the total stays unknown and the load loop recounts.
  func storeDataViewerTotal(_ total: Int?, for state: DataViewerState) {
    guard let current = dataViewer, current.schema == state.schema, current.name == state.name,
      current.filter == state.filter, current.documentFilter == state.documentFilter,
      current.documentOptions == state.documentOptions
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
    saveMongoViewPreference()
    await loadDataViewerPage()
  }

  /// Banner Reload after another tab wrote the table: the page and the count are read again
  /// with the staged change set kept on top (no Commit / Discard prompt). Staged changes on
  /// located rows (a keyless table) are resolved first (`confirmLeaveStagedChanges`): a changed
  /// row reads with another locator, so its staged entry would vanish from the grid while Commit
  /// still sends it. A page of a state the viewer has left meanwhile is dropped by its load key.
  /// `isStale` stays set until the read starts: while a run is in flight nothing is read and the
  /// banner stays.
  func reloadStaleDataViewer() async {
    guard dataViewer != nil, connectionManager != nil, !isEditorQueryRunning else { return }
    if stagesLocatedRows {
      guard await confirmLeaveStagedChanges(), dataViewer != nil, !isEditorQueryRunning else {
        return
      }
    }
    dataViewer?.totalRows = nil
    await loadDataViewerPage()
  }

  /// The Rollback reload of this data viewer (`WorkspaceManager`): the page and the count are
  /// read again with the staged set kept, never after a prompt (a background tab cannot answer
  /// one, and Rollback must not wait). Staged changes on located rows keep their page instead:
  /// Rollback brought back other locators, so the page is only marked stale and the Reload
  /// banner asks first; a Commit of them meanwhile ends in a conflict, never a wrong row.
  func reloadPageAfterRollback() async {
    guard dataViewer != nil else { return }
    if stagesLocatedRows {
      dataViewer?.isStale = true
      return
    }
    dataViewer?.totalRows = nil
    await loadDataViewerPage()
  }

  /// Staged changes keyed by row locators (a keyless table's `RowChangeSet`)
  private var stagesLocatedRows: Bool {
    guard let set = dataViewer?.changeSet else { return false }
    return set.rowLocator != nil && !set.isEmpty
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

  /// Freezes the leading columns through `name` (nil unfreezes) and remembers it for the table
  func setFrozenThroughColumn(_ name: String?) {
    guard dataViewer != nil else { return }
    dataViewer?.frozenThroughColumn = name
    if let key = gridColumnPrefsKey { gridColumnPrefsStore.setFrozenThrough(name, for: key) }
  }

  /// The frozen column and binary formats remembered for the table; call it when a table opens
  func applyGridColumnPrefs() {
    guard let key = gridColumnPrefsKey else { return }
    dataViewer?.frozenThroughColumn = gridColumnPrefsStore.frozenThrough(for: key)
    dataViewer?.binaryFormats = gridColumnPrefsStore.binaryFormats(for: key)
  }

  /// "Display As" of the grid's binary columns: the table's stored formats in a data viewer,
  /// else this tab's session formats
  var binaryFormats: [String: BinaryDisplayFormat] {
    dataViewer?.binaryFormats ?? resultBinaryFormats
  }

  /// Shows binary column `column` as `format` (`.size` is the default): remembered for the
  /// table in a data viewer, for the session otherwise. A Cell Value sidebar showing a cell of
  /// that column switches to the new format.
  func setBinaryFormat(_ format: BinaryDisplayFormat, column: String) {
    let stored = format == .size ? nil : format
    if dataViewer != nil {
      dataViewer?.binaryFormats[column] = stored
      if let key = gridColumnPrefsKey {
        gridColumnPrefsStore.setBinaryFormat(format, column: column, for: key)
      }
    } else {
      resultBinaryFormats[column] = stored
    }
    if case .cellInfo(let shownColumn, _, _, _, _, _, _) = rightSidebarContent,
      shownColumn == column
    {
      cellDetailBinaryFormat = format
    }
  }

  private var gridColumnPrefsKey: String? {
    guard let state = dataViewer, let config = notebook.connectionConfig else { return nil }
    return GridColumnPrefsStore.key(for: config, schema: state.schema, name: state.name)
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

  /// Apply the view mode and page size remembered for a MongoDB collection; call it before the
  /// first load, so the first page is read with the stored size. Other viewers are untouched.
  func applyMongoViewPreference() {
    guard isMongoDataViewer, let key = savedFilterKey,
      let preference = savedFilterStore.mongoViewPreference(for: key)
    else { return }
    dataViewer?.pageSize = preference.pageSize
    dataViewerDisplayMode = preference.mode
  }

  /// Remember the view mode and page size of a MongoDB data viewer for its collection. Chart is
  /// not remembered: the mode stored before it stays. Nothing is written while the view matches
  /// what reads back (no entry reads as Grid with 100 rows).
  func saveMongoViewPreference() {
    guard isMongoDataViewer, let state = dataViewer, let key = savedFilterKey else { return }
    let stored =
      savedFilterStore.mongoViewPreference(for: key)
      ?? MongoViewPreference(mode: .grid, pageSize: 100)
    let mode = dataViewerDisplayMode == .chart ? stored.mode : dataViewerDisplayMode
    let preference = MongoViewPreference(mode: mode, pageSize: state.pageSize)
    guard preference != stored else { return }
    savedFilterStore.saveMongoViewPreference(preference, for: key)
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
  /// Apply the document filter `text` with the applied options kept.
  func applyDocumentFilter(_ text: String) async -> DataViewerState.DocumentFilterError? {
    await applyDocumentQuery(
      filter: text, options: dataViewer?.documentOptions ?? MongoQueryOptions())
  }

  /// Apply the document filter and query options: back to page 1 with the count recomputed;
  /// a Sort option replaces the header sort. Returns the parse error (nothing applied, no
  /// prompt) for a filter that is not a document, an option that does not parse, or a
  /// projection that drops `_id` or reshapes a field. Staged changes must be resolved first.
  func applyDocumentQuery(
    filter text: String, options: MongoQueryOptions
  ) async -> DataViewerState.DocumentFilterError? {
    guard dataViewer != nil else { return nil }
    let value: MongoValue?
    switch DataViewerState.documentFilterValue(text) {
    case .success(let document): value = document
    case .failure(let error): return error
    }
    let parsed: MongoQueryOptions.Parsed
    do {
      parsed = try options.parsed()
    } catch {
      return error
    }
    // The grid edits documents by `_id` and writes whole top-level values back
    if let message = Self.projectionRefusal(parsed.projection) {
      return DataViewerState.DocumentFilterError(message: message, offset: nil)
    }
    guard await confirmLeaveStagedChanges() else { return nil }
    guard dataViewer != nil else { return nil }
    // Blank text and `{}` are both no filter
    dataViewer?.documentFilter =
      value == nil ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines)
    // A new Sort option replaces the header sort; re-applying the same one keeps it
    let previousSort = dataViewer?.documentOptions.sort
    dataViewer?.documentOptions = options
    if parsed.sort != nil, options.sort != previousSort { dataViewer?.documentSort = nil }
    dataViewer?.page = 1
    dataViewer?.totalRows = nil
    await loadDataViewerPage()
    return nil
  }

  /// Why `projection` cannot back an editable page, or nil. Only top-level fields set to 1 or 0
  /// keep each shown value whole, so an edit cannot write a reshaped value back; `_id` must
  /// stay, since rows are edited by it.
  private static func projectionRefusal(_ projection: MongoValue?) -> String? {
    guard case .document(let fields) = projection else { return nil }
    for field in fields {
      guard let included = projectionFlag(field.value) else { return projectionReshapes }
      if field.key == "_id" {
        if !included { return "Projection must keep _id: rows are edited by _id" }
      } else if field.key.contains(".") || field.key.hasPrefix("$") {
        return projectionReshapes
      }
    }
    return nil
  }

  private static let projectionReshapes =
    "Projection: only top-level fields set to 1 or 0 are allowed here, and _id must stay"

  /// True for a 1 or true projection value, false for 0 or false, nil for anything else
  private static func projectionFlag(_ value: MongoValue) -> Bool? {
    let number: Double?
    switch value {
    case .bool(let flag): return flag
    case .int32(let int): number = Double(int)
    case .int64(let int): number = Double(int)
    case .double(let double): number = double
    case .decimal128(let text): number = Double(text)
    default: number = nil
    }
    switch number {
    case 1: return true
    case 0: return false
    default: return nil
    }
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
