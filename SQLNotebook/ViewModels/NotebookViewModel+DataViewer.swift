//
//  NotebookViewModel+DataViewer.swift
//  SQLNotebook
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
        // The tab may show another relation by now
        if let result, dataViewer?.schema == state.schema, dataViewer?.name == state.name {
          dataViewer?.totalRows = DataViewerState.total(from: result)
        }
      }

      guard let current = dataViewer, current.loadKey != key else { return }
    }
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
