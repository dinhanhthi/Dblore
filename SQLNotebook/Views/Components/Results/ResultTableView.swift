//
//  ResultTableView.swift
//  SQLNotebook
//
//  Main result table view for displaying query results
//  Helper components extracted to ResultTableHelpers.swift and ResultTableScrollView.swift (10.3.1)
//

import SwiftUI

struct ResultTableView: View {
  let result: CellResult
  @Bindable var viewModel: NotebookViewModel
  @Bindable var appSettings = AppSettings.shared
  let cellId: UUID?  // ID of the cell that produced this result
  var showBorderRadius: Bool = true  // Whether to show border radius (disabled in editor mode)
  var enableVerticalScrolling: Bool = false  // Whether to enable vertical scrolling (enabled in editor mode)

  @State private var columnWidths: [String: CGFloat] = [:]
  @State private var hoveredRow: Int?
  @State private var resizingColumn: String?
  @State private var resizeStartWidth: CGFloat = 0
  @State private var headerScrollPosition: ScrollPosition = ScrollPosition()
  @State private var currentMatchId: UUID?
  @State private var matchLookup: [String: UUID] = [:]  // "rowIndex-columnName" → matchId for O(1) lookup
  @State private var cachedTotalColumnsWidth: CGFloat = 0  // Cached total width (10.1.6 optimization)
  @State private var searchVersion: Int = 0  // Increment only when current match changes (10.2.3 optimization)

  // Column sorting state
  @State private var sortColumn: String? = nil  // Column name to sort by
  @State private var sortAscending: Bool = true  // Sort direction (true = ascending)
  @State private var hoveredHeaderColumn: String? = nil  // Track which header is hovered

  private let defaultColumnWidth: CGFloat = 170  // Default width for all columns
  private let minColumnWidth: CGFloat = 100  // Minimum width when resizing
  private let maxColumnWidth: CGFloat = 500  // Maximum width when resizing
  private let rowHeight: CGFloat = 32  // Approximate row height
  private let headerHeightWithType: CGFloat = 48  // Header height when showing column type
  private let headerHeightWithoutType: CGFloat = 32  // Header height when hiding column type

  /// Dynamic header height based on hideColumnTypes setting
  private var headerHeight: CGFloat {
    appSettings.hideColumnTypes ? headerHeightWithoutType : headerHeightWithType
  }
  // Note: Row limiting is handled by the capped reader (effective result row cap)
  // All rows from result are rendered since the reader already stops at the cap

  // Computed properties for search state (read-only, not tracked for re-render)
  // Only searchVersion state triggers re-renders (10.2.3 optimization)
  private var searchQuery: String { viewModel.searchState.query }
  private var searchCaseSensitive: Bool { viewModel.searchState.isCaseSensitive }

  var body: some View {
    // Only track searchVersion for re-renders, not individual search properties
    // This prevents unnecessary re-renders when query changes but match doesn't
    let _ = searchVersion

    return VStack(alignment: .leading, spacing: 0) {
      // Header - syncs horizontal scroll position with content
      ScrollView(.horizontal, showsIndicators: false) {
        headerRow
          .frame(width: totalColumnsWidth, alignment: .leading)
          .background(Color.tableHeaderBackground)
      }
      .scrollDisabled(true)  // Disable direct scrolling - synced via HorizontalScrollableContent
      .frame(height: headerHeight)
      .animation(.easeInOut(duration: 0.15), value: appSettings.hideColumnTypes)
      .scrollPosition($headerScrollPosition)

      // Content area - wrapped in custom NSScrollView for horizontal scrolling
      // Vertical scrolling behavior depends on mode:
      // - Notebook mode: passes through to parent list
      // - Editor mode: handled internally with vertical scrollbar
      HorizontalScrollableContent(
        totalWidth: totalColumnsWidth,
        headerScrollPosition: $headerScrollPosition,
        enableVerticalScrolling: enableVerticalScrolling
      ) {
        VStack(alignment: .leading, spacing: 0) {
          // Data rows - the capped reader already limits to the effective result row cap
          // Use sortedRows for display (sorted based on selected column)
          ForEach(Array(sortedRows.enumerated()), id: \.offset) { rowIndex, row in
            dataRow(row: row, rowIndex: rowIndex)
          }
        }
        .frame(width: totalColumnsWidth, alignment: .leading)
        // Add bottom padding to prevent horizontal scrollbar from covering last row
        .padding(.bottom, 12)
      }
    }
    .frame(maxWidth: .infinity)
    .background(Color.cellBackground)
    .clipShape(RoundedRectangle(cornerRadius: showBorderRadius ? CornerRadius.md : 0))
    .onAppear {
      calculateInitialColumnWidths()
    }
    .onReceive(NotificationCenter.default.publisher(for: .highlightSearchMatch)) { notification in
      // Only respond if this notification is for our viewModel instance
      guard let notificationViewModelId = notification.userInfo?["viewModelId"] as? UUID,
        notificationViewModelId == viewModel.id
      else {
        return
      }

      if let match = notification.userInfo?["match"] as? SearchMatch {
        // In editor mode, cellId is nil - accept all matches
        // In notebook mode, only accept matches for this cell
        let isEditorMode = cellId == nil
        let matchesThisCell = isEditorMode || match.cellId == cellId

        if matchesThisCell {
          // Only update if match actually changed (10.2.3 optimization)
          if currentMatchId != match.id {
            currentMatchId = match.id
            // Increment searchVersion to trigger re-render
            searchVersion += 1
            // Build lookup table when match changes
            buildMatchLookup()
          }
          // Note: Vertical scrolling to matched row is handled by parent notebook list
          // since result table no longer has internal vertical scrolling
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .clearSearchHighlights)) { notification in
      // Only respond if this notification is for our viewModel instance
      guard let notificationViewModelId = notification.userInfo?["viewModelId"] as? UUID,
        notificationViewModelId == viewModel.id
      else {
        return
      }

      // Only clear if there was a match (10.2.3 optimization)
      if currentMatchId != nil {
        currentMatchId = nil
        matchLookup.removeAll()  // Clear lookup table
        searchVersion += 1  // Trigger re-render to clear highlights
      }
    }
    .onChange(of: viewModel.searchState.matches.count) { oldCount, newCount in
      // Only rebuild lookup when match count actually changes (10.2.3 optimization)
      if oldCount != newCount {
        buildMatchLookup()
        // Don't increment searchVersion here - only when currentMatch changes
      }
    }
    // Note: macOS doesn't have memory warnings like iOS (10.1.2 optimization)
    // matchLookup cache is already limited by search logic and cleared on panel close
    .onChange(of: columnWidths) { _, _ in
      // Recalculate total width when column widths change (10.1.6 optimization)
      recalculateTotalWidth()
    }
  }

  // MARK: - Header Row

  private var headerRow: some View {
    HStack(spacing: 0) {
      ForEach(result.columns) { column in
        headerCell(column: column)
      }
    }
  }

  private func headerCell(column: ColumnInfo) -> some View {
    HStack(spacing: 0) {
      HStack(spacing: Spacing.xs) {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          HStack(spacing: Spacing.xs) {
            // Primary key indicator
            if result.primaryKeyColumns.contains(column.name) {
              Image(systemName: "key")
                .font(.system(size: 10))
                .foregroundColor(.warning)
            }

            // Highlight column name if search query matches
            if !searchQuery.isEmpty {
              // Find the match for this column name
              // In editor mode (cellId is nil), accept all matches
              let isEditorMode = cellId == nil
              let columnMatch = viewModel.searchState.matches.first {
                (isEditorMode || $0.cellId == cellId) && ($0.matchType == .columnName(column.name))
              }
              let isCurrentMatch = columnMatch?.id == currentMatchId
              let matchRange: Range<String.Index>? =
                isCurrentMatch
                ? column.name.range(
                  of: searchQuery, options: searchCaseSensitive ? [] : .caseInsensitive)
                : nil

              SearchHighlightText(
                text: column.name,
                query: searchQuery,
                caseSensitive: searchCaseSensitive,
                currentMatchRange: matchRange
              )
              .font(.system(.body, weight: .semibold))
              .lineLimit(1)
              .truncationMode(.tail)
            } else {
              Text(column.name)
                .font(.system(.body, weight: .semibold))
                .foregroundColor(.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
            }
          }

          // Show column type unless hideColumnTypes is enabled
          if !appSettings.hideColumnTypes {
            Text(column.type)
              .font(.small)
              .foregroundColor(.foregroundSubtle)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }

        Spacer()

        // Sort indicator
        if sortColumn == column.name {
          // Active sort indicator
          Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.accentColor)
        } else if hoveredHeaderColumn == column.name {
          // Show subtle indicator on hover (hint that column is sortable)
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 10, weight: .regular))
            .foregroundColor(.foregroundSubtle)
        }
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.xs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .onHover { isHovering in
        hoveredHeaderColumn = isHovering ? column.name : nil
      }
      .onTapGesture {
        toggleSort(for: column.name)
      }

      // Resize handle
      ResultTableResizeHandle(
        columnName: column.name,
        resizingColumn: $resizingColumn,
        columnWidths: $columnWidths,
        minWidth: minColumnWidth,
        maxWidth: maxColumnWidth,
        onAutoResize: {
          autoResizeColumn(column: column)
        }
      )
    }
    .frame(width: columnWidth(for: column.name), alignment: .leading)
  }

  /// Toggle sort for a column
  private func toggleSort(for columnName: String) {
    if sortColumn == columnName {
      // Same column: toggle direction or clear
      if sortAscending {
        sortAscending = false
      } else {
        // Already descending, clear sort
        sortColumn = nil
        sortAscending = true
      }
    } else {
      // New column: start with ascending
      sortColumn = columnName
      sortAscending = true
    }
  }

  // MARK: - Data Row

  private func dataRow(row: [CellValue], rowIndex: Int) -> some View {
    HStack(spacing: 0) {
      ForEach(Array(zip(result.columns.indices, row)), id: \.0) { columnIndex, value in
        dataCell(
          value: value,
          column: result.columns[columnIndex],
          row: row,
          rowIndex: rowIndex
        )
      }
    }
    .background(rowBackground(rowIndex: rowIndex))
    .onHover { hovering in
      hoveredRow = hovering ? rowIndex : nil
    }
  }

  /// `row` is the displayed row (sorted order); `rowIndex` its display position
  private func dataCell(
    value: CellValue, column: ColumnInfo, row: [CellValue], rowIndex: Int
  )
    -> some View
  {
    HStack(spacing: 0) {
      cellContent(value: value, rowIndex: rowIndex, columnName: column.name)
        .frame(width: columnWidth(for: column.name) - Spacing.md, alignment: alignment(for: value))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
          handleCellTap(value: value, column: column, row: row, rowIndex: rowIndex)
        }

      Rectangle()
        .fill(Color.border.opacity(0.5))
        .frame(width: 1)
    }
    .frame(width: columnWidth(for: column.name))
  }

  /// Build lookup table for fast O(1) match access
  /// This replaces O(n) linear search through all matches for every cell render
  private func buildMatchLookup() {
    matchLookup.removeAll()

    // In editor mode, cellId is nil - accept all matches
    // In notebook mode, only accept matches for this cell
    let isEditorMode = cellId == nil

    // Build hash map: "rowIndex-columnName" → matchId
    for match in viewModel.searchState.matches {
      let matchesThisCell = isEditorMode || match.cellId == cellId
      if matchesThisCell,
        case .tableData(let rowIndex, let columnName) = match.matchType
      {
        let key = "\(rowIndex)-\(columnName)"
        matchLookup[key] = match.id
      }
    }
  }

  private func cellContent(value: CellValue, rowIndex: Int, columnName: String) -> some View {
    // O(1) lookup instead of O(n) linear search through all matches
    let key = "\(rowIndex)-\(columnName)"
    let matchId = matchLookup[key]
    let isCurrentMatch = matchId == currentMatchId

    return ResultTableCellContentView(
      value: value,
      searchQuery: searchQuery,
      isCaseSensitive: searchCaseSensitive,
      isCurrentMatch: isCurrentMatch
    )
    .equatable()  // Use Equatable protocol to skip re-render when props unchanged (10.2.3)
  }

  // MARK: - Sorting

  /// Sorted rows based on current sort column and direction
  private var sortedRows: [[CellValue]] {
    result.sortedRows(byColumn: sortColumn, ascending: sortAscending)
  }

  // MARK: - Helpers

  private func calculateInitialColumnWidths() {
    // Only calculate widths if not already set
    // Use a keyed approach to avoid recalculation
    guard columnWidths.isEmpty else { return }

    for column in result.columns {
      // Set default width for all columns
      columnWidths[column.name] = defaultColumnWidth
    }

    // Update cached total width (10.1.6 optimization)
    recalculateTotalWidth()
  }

  private func columnWidth(for columnName: String) -> CGFloat {
    columnWidths[columnName] ?? defaultColumnWidth
  }

  // Calculate total width of all columns for consistent alignment (cached - 10.1.6 optimization)
  private var totalColumnsWidth: CGFloat {
    cachedTotalColumnsWidth
  }

  /// Recalculate cached total columns width
  private func recalculateTotalWidth() {
    cachedTotalColumnsWidth = result.columns.reduce(0) { total, column in
      total + columnWidth(for: column.name)
    }
  }

  private func alignment(for value: CellValue) -> Alignment {
    switch value {
    case .int, .double:
      return .trailing
    default:
      return .leading
    }
  }

  private func rowBackground(rowIndex: Int) -> Color {
    if hoveredRow == rowIndex {
      return Color.cellBackgroundHover
    }
    return rowIndex % 2 == 0 ? Color.cellBackground : Color.tableRowAlternate
  }

  /// Row data (and so the primary key of an edit) comes from the tapped displayed `row`, never
  /// from `result.rows[rowIndex]`: once sorted, the display index points at another row.
  private func handleCellTap(value: CellValue, column: ColumnInfo, row: [CellValue], rowIndex: Int)
  {
    if value.isJSON {
      if case .json(let json) = value {
        viewModel.showJSONInSidebar(
          json: json,
          path: "Row \(rowIndex + 1), Column '\(column.name)'"
        )
      }
    } else {
      let rowData = CellResult.rowData(columns: result.columns, row: row)

      viewModel.showCellDetail(
        columnName: column.name,
        columnType: column.type,
        value: value,
        tableName: result.tableName,
        rowData: rowData,
        primaryKeyColumns: result.primaryKeyColumns,
        editTarget: result.editTarget,
        cellId: cellId
      )
    }
  }

  // MARK: - Auto Resize

  // Cached fonts for performance (avoid recreating on every resize)
  private nonisolated(unsafe) static let headerNameFont = NSFont.systemFont(
    ofSize: NSFont.systemFontSize, weight: .semibold)
  private nonisolated(unsafe) static let headerTypeFont = NSFont.systemFont(
    ofSize: NSFont.smallSystemFontSize)
  private nonisolated(unsafe) static let dataFont = NSFont.monospacedSystemFont(
    ofSize: NSFont.systemFontSize, weight: .regular)

  private func autoResizeColumn(column: ColumnInfo) {
    let columnIndex = result.columns.firstIndex(where: { $0.name == column.name })
    guard let columnIndex = columnIndex else { return }

    // Calculate width needed for header (both name and type should fit)
    let headerNameWidth = estimateTextWidth(text: column.name, nsFont: Self.headerNameFont)
    let headerTypeWidth = estimateTextWidth(text: column.type, nsFont: Self.headerTypeFont)
    // Both texts are stacked vertically, so we need the wider of the two
    let headerTextWidth = max(headerNameWidth, headerTypeWidth)
    // Add horizontal padding (lg on both sides), resize handle width (4pt), and extra buffer (8pt)
    let headerWidth = headerTextWidth + (Spacing.lg * 2) + 4 + 8

    // Calculate width needed for data cells (sample first 100 rows for performance)
    var maxDataWidth: CGFloat = 0
    let sampleSize = min(100, result.rows.count)  // Only sample first 100 rows
    for rowIndex in 0..<sampleSize {
      let row = result.rows[rowIndex]
      guard columnIndex < row.count else { continue }
      let value = row[columnIndex]
      let displayText = value.displayString
      let textWidth = estimateTextWidth(text: displayText, nsFont: Self.dataFont)
      // Add horizontal padding (sm on both sides), cell border (Spacing.md on right), and extra buffer
      maxDataWidth = max(maxDataWidth, textWidth + (Spacing.sm * 2) + Spacing.md + 8)
    }

    // Choose the larger of header or data width, but respect min/max bounds
    let optimalWidth = max(headerWidth, maxDataWidth)
    let constrainedWidth = min(max(optimalWidth, minColumnWidth), maxColumnWidth)

    columnWidths[column.name] = constrainedWidth
  }

  private func estimateTextWidth(text: String, nsFont: NSFont) -> CGFloat {
    let attributes: [NSAttributedString.Key: Any] = [.font: nsFont]
    let size = (text as NSString).size(withAttributes: attributes)
    return size.width
  }
}

// MARK: - Previews

#Preview("Standard Data") {
  let mockResult = CellResult(
    columns: [
      ColumnInfo(name: "id", type: "INTEGER"),
      ColumnInfo(name: "name", type: "VARCHAR"),
      ColumnInfo(name: "email", type: "VARCHAR"),
      ColumnInfo(name: "metadata", type: "JSONB"),
    ],
    rows: [
      [
        .int(1), .string("Alice Johnson"), .string("alice@example.com"),
        .json("{\"role\": \"admin\"}"),
      ],
      [
        .int(2), .string("Bob Williams"), .string("bob@example.com"), .json("{\"role\": \"user\"}"),
      ],
      [.int(3), .null, .string("charlie@example.com"), .null],
    ],
    executionTime: 0.034,
    rowCount: 3,
    timestamp: Date()
  )

  ResultTableView(result: mockResult, viewModel: NotebookViewModel(), cellId: nil)
    .frame(width: 600, height: 300)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}

#Preview("Long Text Values") {
  let longText =
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur."

  let mockResult = CellResult(
    columns: [
      ColumnInfo(name: "id", type: "INTEGER"),
      ColumnInfo(name: "description", type: "TEXT"),
    ],
    rows: [
      [
        .int(1),
        .string(longText),
      ],
      [
        .int(2),
        .string("Short text"),
      ],
      [
        .int(3),
        .string(
          "The quick brown fox jumps over the lazy dog. This sentence is repeated multiple times to create a very long text value. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog."
        ),
      ],
    ],
    executionTime: 0.021,
    rowCount: 3,
    timestamp: Date()
  )

  ResultTableView(result: mockResult, viewModel: NotebookViewModel(), cellId: nil)
    .frame(width: 600, height: 300)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
