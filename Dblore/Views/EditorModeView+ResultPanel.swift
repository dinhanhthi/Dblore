//
//  EditorModeView+ResultPanel.swift
//  Dblore
//
//  Result panel header and footer for editor mode
//

import SwiftUI

// MARK: - Result Panel Extension

extension EditorModeView {

  /// The editor pin is not written to the file
  static let editorPinNote = "Kept for this session only"

  /// Whether the "Run with query" footer is shown; it holds the Grid / Chart slider when it is
  func showsResultPanelFooter(result: CellResult) -> Bool {
    !getAppSettings().hideRunWithQuerySection && result.sourceQuery != nil
  }

  // MARK: - Result Panel Header

  /// Creates the header bar for the result panel.
  ///
  /// Displays query execution metadata for both single and multi-statement queries:
  /// - For multi-statement: Total statements count + total time, and current statement info
  /// - For single statement: Row count and execution time
  /// - Success/error indicator icon
  /// - Clear result button
  ///
  /// - Parameter result: The query result containing metadata and optional error
  /// - Returns: A view with query result metadata and action buttons
  func resultPanelHeader(result: CellResult) -> some View {
    VStack(spacing: 0) {
      // Warning banner (row cap reached; session reset details when the cap closed it)
      if result.error == nil, let notice = result.capNotice {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundColor(.warning)

          Text(notice)
            .font(.system(size: 11))
            .foregroundColor(.foreground)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          Color.warning.opacity(0.2)
        )
        .overlay(
          Rectangle()
            .fill(Color.foregroundMuted.opacity(0.1))
            .frame(height: 1),
          alignment: .bottom
        )
      }

      // Main header
      HStack {
        // Dropdown for multi-statement queries (at the beginning, only show when > 1 statement)
        if viewModel.editorStatementResults.count > 1 {
          multiStatementDropdown()
        }

        // Result info
        resultInfoSection(result: result)

        if let summary = viewModel.editorSelectionSummary, result.error == nil,
          !viewModel.isEditorComparing, resultDisplayModeBinding(for: result).wrappedValue == .grid
        {
          Rectangle()
            .fill(Color.foregroundMuted.opacity(0.3))
            .frame(width: 1, height: 12)
          ResultSelectionSummaryView(summary: summary)
            .font(.system(size: 12))
            .foregroundColor(.foregroundSubtle)
        }

        Spacer()

        // Grid / Documents / Chart falls back here when the "Run with query" footer is hidden
        if !showsResultPanelFooter(result: result),
          let displayTabs = ResultDisplayMode.pickerTabs(
            chartable: ChartSpec.suggested(for: ChartQueryResult.make(result)) != nil,
            documents: viewModel.sqlDialect == .mongodb)
        {
          ResultDisplayPicker(mode: resultDisplayModeBinding(for: result), tabs: displayTabs)
        }

        if ExplainResultPlan.parse(result) != nil {
          ExplainDisplayPicker(mode: explainDisplayModeBinding(for: result))
        }

        ResultPinControls(
          isPinned: viewModel.editorPinnedResult != nil,
          canPin: result.error == nil,
          isComparing: viewModel.isEditorComparing,
          pinNote: Self.editorPinNote,
          onPin: { viewModel.pinEditorResult() },
          onUnpin: { viewModel.unpinEditorResult() },
          onToggleCompare: { viewModel.toggleEditorCompare() }
        )

        explainToolbarMenu()

        Button(action: clearResult) {
          Image(systemName: "xmark")
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .controlSize(.small)
        .help("Clear result")
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .background(Color.appBackground)
      .overlay(
        Rectangle()
          .fill(Color.foregroundMuted.opacity(0.1))
          .frame(height: 1),
        alignment: .bottom  // Border on bottom since this is now a header
      )
    }
  }

  /// Multi-statement dropdown menu
  @ViewBuilder
  private func multiStatementDropdown() -> some View {
    Menu {
      ForEach(viewModel.editorStatementResults.indices, id: \.self) { index in
        let statementResult = viewModel.editorStatementResults[index]
        Button(action: {
          viewModel.selectEditorStatement(at: index)
        }) {
          HStack {
            // Combined text: "Result N • query text (truncated)"
            let resultLabel = Text("Result \(index + 1) • ").font(.system(size: 11))
            let queryLabel = Text(truncateQuery(statementResult.queryText))
              .font(.system(size: 11, design: .monospaced))
            Text("\(resultLabel)\(queryLabel)")
              .lineLimit(1)

            Spacer()

            // Checkmark for selected item
            if index == viewModel.selectedStatementIndex {
              Image(systemName: "checkmark")
                .font(.system(size: 10))
                .foregroundColor(.accentColor)
            }
          }
        }
        .id(statementResult.id)
      }
    } label: {
      HStack {
        Text("Result \(viewModel.selectedStatementIndex + 1)")
          .font(.system(size: 11))
          .foregroundColor(.foreground)
        Spacer()
        Image(systemName: "chevron.down")
          .font(.system(size: 9))
          .foregroundColor(.foregroundMuted)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(
        Capsule()
          .fill(Color.inputBackground)
      )
      .overlay(HairlineBorder(shape: Capsule()))
    }
    .id(viewModel.editorStatementResults.map { $0.id })
    .buttonStyle(.plain)
    .linkPointer()
    .help("Select statement result to view")
    .fixedSize()
  }

  /// Result info section showing row count and execution time
  @ViewBuilder
  private func resultInfoSection(result: CellResult) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: result.error != nil ? "xmark.circle.fill" : "checkmark.circle.fill")
        .foregroundColor(result.error != nil ? .red : .green)
        .font(.system(size: 12))

      if result.error != nil {
        // Show "Error" label next to red cross icon
        Text("Error")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(.red)
      } else {
        // Check if multi-statement query
        if !viewModel.editorStatementResults.isEmpty {
          multiStatementResultInfo(result: result)
        } else {
          singleStatementResultInfo(result: result)
        }
      }
    }
  }

  /// Multi-statement result info
  @ViewBuilder
  private func multiStatementResultInfo(result: CellResult) -> some View {
    // Show total stats
    Text(
      "Total: \(viewModel.editorStatementResults.count) statement\(viewModel.editorStatementResults.count == 1 ? "" : "s")"
    )
    .font(.system(size: 12))
    .foregroundColor(.foregroundSubtle)

    Text("•")
      .foregroundColor(.foregroundMuted)

    Text(formatExecutionTime(viewModel.totalExecutionTime))
      .font(.system(size: 12))
      .foregroundColor(.foregroundSubtle)

    // Divider
    Rectangle()
      .fill(Color.foregroundMuted.opacity(0.3))
      .frame(width: 1, height: 12)

    // Current statement stats
    Text("Current:")
      .font(.system(size: 12))
      .foregroundColor(.foregroundMuted)

    Text("\(result.rowCount) row\(result.rowCount == 1 ? "" : "s")")
      .font(.system(size: 12))
      .foregroundColor(.foregroundSubtle)

    Text("(\(result.affectedRows ?? 0) affected)")
      .font(.system(size: 12))
      .foregroundColor(affectedRowsColor(for: result))

    Text("•")
      .foregroundColor(.foregroundMuted)

    Text(formatExecutionTime(result.executionTime))
      .font(.system(size: 12))
      .foregroundColor(.foregroundSubtle)
  }

  /// Single statement result info
  @ViewBuilder
  private func singleStatementResultInfo(result: CellResult) -> some View {
    Text("\(result.rowCount) row\(result.rowCount == 1 ? "" : "s")")
      .font(.system(size: 12))
      .foregroundColor(.foregroundSubtle)

    Text("(\(result.affectedRows ?? 0) affected)")
      .font(.system(size: 12))
      .foregroundColor(affectedRowsColor(for: result))

    Text("•")
      .foregroundColor(.foregroundMuted)

    Text(formatExecutionTime(result.executionTime))
      .font(.system(size: 12))
      .foregroundColor(.foregroundSubtle)
  }

  // MARK: - Result Panel Footer

  /// Creates the footer bar for the result panel.
  ///
  /// For both single and multi-statement: Shows the query with click-to-copy functionality
  ///
  /// - Parameter result: The query result containing sourceQuery
  /// - Returns: A view with clickable query text
  @ViewBuilder
  func resultPanelFooter(result: CellResult) -> some View {
    // Don't show if setting is enabled to hide this section
    if showsResultPanelFooter(result: result) {
      // Show clickable query text + Download button for both single and multi-statement
      let actualQuery = getActualExecutedQuery(result: result)
      let displayQuery = SQLSyntaxHighlighter.removeComments(actualQuery)
      QueryCopyBar(
        query: displayQuery,
        result: result,
        viewModel: viewModel,
        cellId: nil,  // Editor mode has no cell ID
        queryIndex: !viewModel.editorStatementResults.isEmpty
          ? (viewModel.selectedStatementIndex + 1) : nil,
        dialect: viewModel.sqlDialect,
        displayMode: resultDisplayModeBinding(for: result)
      )
      .frame(height: 24)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.appBackground)
      .overlay(
        Rectangle()
          .fill(Color.foregroundMuted.opacity(0.1))
          .frame(height: 1),
        alignment: .top  // Border on top
      )
    }
  }

  // MARK: - Error View

  func errorView(error: String) -> some View {
    ZStack(alignment: .topTrailing) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          Text(error)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color.foreground)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
      }
      .background(Color.red.opacity(0.05))

      // Copy button (top-right, using FloatingPanelButton style)
      Button(action: { copyErrorToClipboard(error: error) }) {
        Image(systemName: getIsErrorCopied() ? "checkmark" : "doc.on.doc")
          .font(.system(size: 12))
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(FloatingPanelButtonStyle())
      .help("Copy error message")
      .padding(.top, Spacing.sm)
      .padding(.trailing, Spacing.sm)
    }
  }
}

// MARK: - Editor Result Grid

/// Result grid filling the editor result panel: it owns vertical scrolling (no hand-off to the
/// parent). Sort, inline edit, cell click to the sidebar and search highlights as in a notebook
/// cell; editor results have no cell ID, so every data or column-name search match applies.
struct EditorResultGridView: View {
  let result: CellResult
  @Bindable var viewModel: NotebookViewModel
  /// Names of result columns hidden in the grid (data viewer); empty shows every column
  var hiddenColumns: Set<String> = []
  /// Highlight rules of the data viewer, painted in the grid without changing its rows
  var highlights: [TableHighlight] = []
  var dialect: DatabaseType = .postgresql
  /// Adds the highlight items to the cell context menu (data viewer)
  var canHighlight = false
  @State private var sortColumn: String?
  @State private var sortAscending = true
  /// Session chart for this editor result. A new result view starts from the suggestion.
  @State private var chartSpec: ChartSpec?
  /// Nil keeps an internal mode. The editor header and the data viewer paging bar pass
  /// the shared mode and set `showsDisplayPicker` to false so this grid does not draw
  /// a second slider.
  var displayMode: Binding<ResultDisplayMode>? = nil
  var showsDisplayPicker = true
  /// Nil keeps an internal Plan / Raw mode. The editor header passes the shared mode
  /// and sets `showsExplainPicker` to false so the plan view does not draw a second slider.
  var explainMode: Binding<ExplainDisplayMode>? = nil
  var showsExplainPicker = true
  /// Category keys hidden per column. The loaded result and its LIMIT stay unchanged.
  @State private var valueFilter = ColumnValueFilter()
  /// Current search match when it is in the result data or column names
  @State private var currentMatch: SearchMatch?
  /// MongoDB: the staged documents drawn as a row overlay, rebuilt only when they change
  @State private var documentOverlay = StagedDocumentOverlay()

  var body: some View {
    ExplainableResult(
      result: result, fillsAvailableHeight: true, mode: explainMode, showsPicker: showsExplainPicker
    ) {
      ChartableResult(
        result: result, chartSpec: $chartSpec, fillsAvailableHeight: true, mode: displayMode,
        showsPicker: showsDisplayPicker
      ) {
        if showsDocuments {
          documentCards
        } else if showsJSON {
          MongoJSONDocumentsView(
            result: result, format: $viewModel.mongoJSONFormat,
            findRequest: viewModel.mongoJSONFindRequest)
        } else {
          resultGrid
        }
      }
    }
    .onChange(of: result.timestamp) { valueFilter = ColumnValueFilter() }
    .onChange(of: valueFilter) {
      currentMatch = gridSearchMatchOnScreen(
        currentMatch, result: result, sortColumn: gridSort.column, ascending: gridSort.ascending,
        valueFilter: valueFilter, viewModel: viewModel)
    }
    .onReceive(NotificationCenter.default.publisher(for: .highlightSearchMatch)) { notification in
      guard let notificationViewModelId = notification.userInfo?["viewModelId"] as? UUID,
        notificationViewModelId == viewModel.id
      else { return }
      if notification.userInfo?["resolved"] as? Bool == true {
        if let match = notification.userInfo?["match"] as? SearchMatch {
          currentMatch = assignedSearchMatch(
            match, cellId: match.cellId, result: result, sortColumn: gridSort.column,
            ascending: gridSort.ascending, valueFilter: valueFilter)
        } else {
          currentMatch = nil
        }
      } else if let match = notification.userInfo?["match"] as? SearchMatch, match.isInResultGrid {
        currentMatch = gridSearchMatchOnScreen(
          match, result: result, sortColumn: gridSort.column, ascending: gridSort.ascending,
          valueFilter: valueFilter, viewModel: viewModel)
      } else {
        currentMatch = nil
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .clearSearchHighlights)) { notification in
      guard let notificationViewModelId = notification.userInfo?["viewModelId"] as? UUID,
        notificationViewModelId == viewModel.id
      else { return }
      currentMatch = nil
    }
  }

  /// A MongoDB data viewer sorts on the server: the header shows the page's `documentSort`.
  /// Other grids sort the loaded rows locally.
  private var gridSort: (column: String?, ascending: Bool) {
    guard viewModel.isMongoDataViewer else { return (sortColumn, sortAscending) }
    let sort = viewModel.dataViewer?.documentSort
    return (sort?.field, sort?.ascending ?? true)
  }

  /// The Documents view replaces the grid for a MongoDB result
  private var showsDocuments: Bool {
    viewModel.sqlDialect == .mongodb && displayMode?.wrappedValue == .documents
  }

  /// The JSON text replaces the grid for a MongoDB result (data viewer tabs only)
  private var showsJSON: Bool {
    viewModel.sqlDialect == .mongodb && displayMode?.wrappedValue == .json
  }

  /// Staged rows drawn on the grid: the SQL change set, else the data viewer's staged MongoDB
  /// documents (drawing only; it never reaches the SQL builders).
  private var stagedOverlay: RowChangeSet? {
    guard let state = viewModel.dataViewer else { return nil }
    if let set = state.changeSet { return set }
    return documentOverlay.rowChangeSet(for: state.documentChangeSet, target: result.editTarget)
  }

  /// The Documents cards. A MongoDB data viewer that can stage also draws its staged inserts and
  /// deletes and offers Duplicate, Delete and Revert, through the grid's staging entry points.
  private var documentCards: some View {
    let stages = viewModel.isMongoDataViewer && viewModel.stagingEnabled
    return DocumentTreeView(
      result: result,
      fillsAvailableHeight: true,
      isEditable: viewModel.canEdit(result),
      stagedInserts: stages
        ? viewModel.dataViewer?.documentChangeSet?.inserts.map(\.document) ?? [] : [],
      deletedRows: stages ? viewModel.stagedDeletedDocumentRows(result: result) : [],
      onShowDetails: { row in
        guard result.rows.indices.contains(row) else { return }
        viewModel.showRowDetail(
          row: result.rows[row], originalRow: row, result: result, cellId: nil)
      },
      onShowFieldDetails: { row, key in
        guard result.rows.indices.contains(row),
          let column = result.columns.firstIndex(where: { $0.name == key })
        else { return }
        viewModel.showGridCellInSidebar(
          row: result.rows[row], originalRow: row, column: column, result: result, cellId: nil)
      },
      onEditField: { row, keys, editType, text, current in
        viewModel.handleDocumentFieldEdit(
          row: row, keys: keys, editType: editType, text: text, current: current, result: result,
          cellId: nil)
      },
      onDuplicate: stages
        ? { row in
          Task {
            if let message = await viewModel.stageDuplicate(rows: [row]) {
              viewModel.showToast(message, type: .error)
            }
          }
        } : nil,
      onDelete: stages
        ? { row in
          if let message = viewModel.stageDelete(rows: [row]) {
            viewModel.showToast(message, type: .error)
          }
        } : nil,
      onRevert: stages
        ? { row in
          if let message = viewModel.revertStaged(rows: [row]) {
            viewModel.showToast(message, type: .error)
          }
        } : nil,
      expansionRequest: viewModel.isMongoDataViewer ? viewModel.documentExpansionRequest : nil
    )
  }

  @ViewBuilder
  private var resultGrid: some View {
    let relation = referencedRelation(
      dataViewer: viewModel.dataViewer, editTarget: result.editTarget,
      lookupRelation: result.lookupRelation)
    let referencedRow = referencedRowHandlers(
      viewModel, editTarget: result.editTarget, lookupRelation: result.lookupRelation)
    ResultGridView(
      result: result,
      sortColumn: gridSort.column,
      ascending: gridSort.ascending,
      isEditable: viewModel.canEdit(result),
      readOnlyColumns: viewModel.readOnlyColumnIndexes(result),
      onCommitEdit: { row, column, newValue in
        viewModel.handleGridCellEdit(
          row: row, column: column, newValue: newValue, result: result, cellId: nil,
          connectionManager: viewModel.connectionManager)
      },
      stagesEdits: viewModel.stagingEnabled,
      changeSet: stagedOverlay,
      onStageEdit: { row, column, newValue in
        viewModel.handleStagedGridCellEdit(
          row: row, column: column, newValue: newValue, result: result)
      },
      onStageInsert: {
        Task { await viewModel.openAddRowForm() }
      },
      onStageDuplicate: { rows in
        Task {
          if let message = await viewModel.stageDuplicate(rows: rows) {
            viewModel.showToast(message, type: .error)
          }
        }
      },
      onStageDelete: { rows in
        if let message = viewModel.stageDelete(rows: rows) {
          viewModel.showToast(message, type: .error)
        }
      },
      onRevertStaged: { rows in
        if let message = viewModel.revertStaged(rows: rows) {
          viewModel.showToast(message, type: .error)
        }
      },
      onStageCells: { rows, column, values in
        guard result.columns.indices.contains(column) else { return }
        if let message = viewModel.stageEdits(
          rows: rows, column: result.columns[column].name, values: values)
        {
          viewModel.showToast(message, type: .error)
        }
      },
      offersDefaultValue: viewModel.unavailableFeatureMessage(
        "Setting a cell to DEFAULT", \.supportsDefaultInUpdate) == nil,
      onSortChange: { column, ascending in
        if viewModel.isMongoDataViewer {
          Task { @MainActor in await viewModel.setDocumentSort(column, ascending: ascending) }
          return
        }
        guard viewModel.hasPendingStagedChanges else {
          sortColumn = column
          sortAscending = ascending
          return
        }
        Task { @MainActor in
          guard await viewModel.confirmLeaveStagedChanges() else { return }
          sortColumn = column
          sortAscending = ascending
        }
      },
      valueFilter: valueFilter,
      onValueFilterChange: { valueFilter = $0 },
      onShowCellDetails: { row, originalRow, column in
        viewModel.showGridCellInSidebar(
          row: row, originalRow: originalRow, column: column, result: result, cellId: nil)
      },
      onShowRowDetails: { row, originalRow in
        viewModel.showRowDetail(
          row: row, originalRow: originalRow, result: result, cellId: nil)
      },
      onHighlightCell: canHighlight
        ? { column, value, style, color in
          guard result.columns.indices.contains(column) else { return }
          viewModel.highlightCell(
            column: result.columns[column].name, value: value, style: style, color: color)
        } : nil,
      onClearHighlight: canHighlight ? { viewModel.clearHighlight() } : nil,
      searchQuery: viewModel.searchState.query,
      caseSensitive: viewModel.searchState.isCaseSensitive,
      wholeWord: viewModel.searchState.isWholeWord,
      currentMatch: currentMatch,
      searchMatches: viewModel.searchState.matches,
      forwardsScrollToParent: false,
      hideColumnTypes: AppSettings.shared.hideColumnTypes,
      hiddenColumns: hiddenColumns,
      highlights: highlights,
      highlightDialect: dialect,
      relationSchema: relation?.schema,
      relationTable: relation?.table,
      baseColumnNames: relation?.baseColumns,
      foreignKeys: viewModel.lookupForeignKeys,
      lookupDialect: viewModel.sqlDialect,
      onLookupReferencedRow: referencedRow.lookup,
      onJumpToReferencedRow: referencedRow.jump,
      onSelectionSummaryChange: { viewModel.editorSelectionSummary = $0 }
    )
  }
}

/// The drawing-only `RowChangeSet` of a staged `MongoDocumentChangeSet`, kept while the set and
/// target are unchanged: `displayRowChangeSet(target:)` makes new insert ids on every call, and
/// the grid redraws its staged rows whenever the overlay differs.
final class StagedDocumentOverlay {
  private var source: (set: MongoDocumentChangeSet, target: EditTarget)?
  private var display: RowChangeSet?

  /// Nil when nothing is staged or the result has no edit target.
  func rowChangeSet(for set: MongoDocumentChangeSet?, target: EditTarget?) -> RowChangeSet? {
    guard let set, !set.isEmpty, let target else {
      source = nil
      display = nil
      return nil
    }
    if let source, source.set == set, source.target == target { return display }
    let next = set.displayRowChangeSet(target: target)
    source = (set, target)
    display = next
    return next
  }
}
