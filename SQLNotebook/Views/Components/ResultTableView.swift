//
//  ResultTableView.swift
//  SQLNotebook
//

import SwiftUI

struct ResultTableView: View {
  let result: CellResult
  @Bindable var viewModel: NotebookViewModel
  let cellId: UUID?  // ID of the cell that produced this result

  @State private var columnWidths: [String: CGFloat] = [:]
  @State private var hoveredRow: Int?
  @State private var resizingColumn: String?
  @State private var resizeStartWidth: CGFloat = 0
  @State private var headerScrollPosition: ScrollPosition = ScrollPosition()
  @State private var contentScrollPosition: ScrollPosition = ScrollPosition()
  @State private var isContentScrolledByUser: Bool = false
  @State private var isHeaderScrolledByUser: Bool = false
  @State private var currentMatchId: UUID?
  @State private var matchLookup: [String: UUID] = [:]  // "rowIndex-columnName" → matchId for O(1) lookup

  private let defaultColumnWidth: CGFloat = 170  // Default width for all columns
  private let minColumnWidth: CGFloat = 100  // Minimum width when resizing
  private let maxColumnWidth: CGFloat = 500  // Maximum width when resizing
  private let rowHeight: CGFloat = 32  // Approximate row height
  private let headerHeight: CGFloat = 48  // Approximate header height
  private let maxRowsToRender: Int = 500  // Reduced from 1000 to prevent scroll conflicts with VStack

  // Limit rows to render for performance
  private var displayedRows: ArraySlice<[CellValue]> {
    result.rows.prefix(maxRowsToRender)
  }

  private var hasMoreRows: Bool {
    result.rows.count > maxRowsToRender
  }

  // Estimate if vertical scrolling is needed
  private var estimatedContentHeight: CGFloat {
    headerHeight + (CGFloat(min(result.rows.count, maxRowsToRender)) * rowHeight)
  }

  private var needsVerticalScroll: Bool {
    estimatedContentHeight > AppSettings.shared.maxResultHeight
  }

  private var scrollAxes: Axis.Set {
    needsVerticalScroll ? [.horizontal, .vertical] : .horizontal
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Custom header pinning solution (Option B)
      // Header in separate ScrollView that syncs with content via onScrollGeometryChange
      ScrollView(.horizontal, showsIndicators: false) {
        headerRow
          .background(Color.tableHeaderBackground)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: headerHeight)
      .scrollPosition($headerScrollPosition)
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        // Track header horizontal scroll offset
        geometry.contentOffset.x + geometry.contentInsets.leading
      } action: { oldValue, newValue in
        // Sync content when header scrolls
        guard oldValue != newValue else { return }
        if !isHeaderScrolledByUser {
          return  // Avoid feedback loop
        }
        contentScrollPosition.scrollTo(x: newValue)
      }
      .onScrollPhaseChange { _, newPhase in
        // Track when user is actively scrolling header
        isHeaderScrolledByUser = newPhase.isScrolling
      }

      // Content ScrollView
      // Using VStack instead of LazyVStack to prevent nested scroll crashes
      // See SCROLL_CRASH_FIX.md and RESULT_VISIBILITY_CRASH_FIX.md for details
      ScrollView(scrollAxes, showsIndicators: true) {
        VStack(alignment: .leading, spacing: 0) {
          // Data rows - limited to maxRowsToRender
          ForEach(Array(displayedRows.enumerated()), id: \.offset) { rowIndex, row in
            dataRow(row: row, rowIndex: rowIndex)
          }

          // Show warning if rows are truncated
          if hasMoreRows {
            truncationWarning
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollBounceBehavior(.basedOnSize)
      .scrollPosition($contentScrollPosition)
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        // Track horizontal scroll offset
        geometry.contentOffset.x + geometry.contentInsets.leading
      } action: { oldValue, newValue in
        // Sync header scroll when content scrolls
        guard oldValue != newValue else { return }
        if !isContentScrolledByUser {
          return  // Avoid feedback loop
        }
        headerScrollPosition.scrollTo(x: newValue)
      }
      .onScrollPhaseChange { _, newPhase in
        // Track when user is actively scrolling content
        isContentScrolledByUser = newPhase.isScrolling
      }
      .background(ScrollerConfigurator(needsVerticalScroller: needsVerticalScroll))
      .frame(maxHeight: AppSettings.shared.maxResultHeight - headerHeight)
    }
    .frame(maxWidth: .infinity)
    .background(Color.cellBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .onAppear {
      calculateInitialColumnWidths()
    }
    .onReceive(NotificationCenter.default.publisher(for: .highlightSearchMatch)) { notification in
      if let match = notification.userInfo?["match"] as? SearchMatch,
         match.cellId == cellId {
        currentMatchId = match.id
        // Build lookup table when match changes
        buildMatchLookup()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .clearSearchHighlights)) { _ in
      currentMatchId = nil
      matchLookup.removeAll()  // Clear lookup table
    }
  }

  private var truncationWarning: some View {
    HStack {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.warning)
      Text("Showing first \(maxRowsToRender) of \(result.rows.count) rows to maintain performance")
        .font(.caption)
        .foregroundColor(.foregroundSubtle)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
    .frame(maxWidth: .infinity)
    .background(Color.warning.opacity(0.1))
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
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        HStack(spacing: Spacing.xs) {
          // Primary key indicator
          if result.primaryKeyColumns.contains(column.name) {
            Image(systemName: "key")
              .font(.system(size: 10))
              .foregroundColor(.warning)
          }

          // Highlight column name if search query matches
          if !viewModel.searchState.query.isEmpty {
            // Find the match for this column name
            let columnMatch = viewModel.searchState.matches.first {
              $0.cellId == cellId &&
              ($0.matchType == .columnName(column.name))
            }
            let isCurrentMatch = columnMatch?.id == currentMatchId
            let matchRange: Range<String.Index>? = isCurrentMatch
              ? column.name.range(of: viewModel.searchState.query, options: viewModel.searchState.isCaseSensitive ? [] : .caseInsensitive)
              : nil

            SearchHighlightText(
              text: column.name,
              query: viewModel.searchState.query,
              caseSensitive: viewModel.searchState.isCaseSensitive,
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

        Text(column.type)
          .font(.small)
          .foregroundColor(.foregroundSubtle)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.xs)
      .frame(maxWidth: .infinity, alignment: .leading)

      // Resize handle
      ResizeHandle(
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

  // MARK: - Data Row

  private func dataRow(row: [CellValue], rowIndex: Int) -> some View {
    HStack(spacing: 0) {
      ForEach(Array(zip(result.columns.indices, row)), id: \.0) { columnIndex, value in
        dataCell(
          value: value,
          column: result.columns[columnIndex],
          rowIndex: rowIndex
        )
      }
    }
    .background(rowBackground(rowIndex: rowIndex))
    .onHover { hovering in
      hoveredRow = hovering ? rowIndex : nil
    }
  }

  private func dataCell(value: CellValue, column: ColumnInfo, rowIndex: Int) -> some View {
    HStack(spacing: 0) {
      cellContent(value: value, rowIndex: rowIndex, columnName: column.name)
        .frame(width: columnWidth(for: column.name) - Spacing.md, alignment: alignment(for: value))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
          handleCellTap(value: value, column: column, rowIndex: rowIndex)
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

    // Build hash map: "rowIndex-columnName" → matchId
    for match in viewModel.searchState.matches {
      if match.cellId == cellId,
         case .tableData(let rowIndex, let columnName) = match.matchType {
        let key = "\(rowIndex)-\(columnName)"
        matchLookup[key] = match.id
      }
    }
  }

  private func cellContent(value: CellValue, rowIndex: Int, columnName: String) -> CellContentView {
    // O(1) lookup instead of O(n) linear search through all matches
    let key = "\(rowIndex)-\(columnName)"
    let matchId = matchLookup[key]
    let isCurrentMatch = matchId == currentMatchId

    return CellContentView(
      value: value,
      searchQuery: viewModel.searchState.query,
      isCaseSensitive: viewModel.searchState.isCaseSensitive,
      isCurrentMatch: isCurrentMatch
    )
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
  }

  private func columnWidth(for columnName: String) -> CGFloat {
    columnWidths[columnName] ?? defaultColumnWidth
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

  private func handleCellTap(value: CellValue, column: ColumnInfo, rowIndex: Int) {
    if value.isJSON {
      if case .json(let json) = value {
        viewModel.showJSONInSidebar(
          json: json,
          path: "Row \(rowIndex + 1), Column '\(column.name)'"
        )
      }
    } else {
      // Build row data dictionary with all column values
      var rowData: [String: CellValue] = [:]
      if rowIndex < result.rows.count {
        let row = result.rows[rowIndex]
        for (index, column) in result.columns.enumerated() {
          if index < row.count {
            rowData[column.name] = row[index]
          }
        }
      }

      // Get row identifier (ctid) for this row if available
      let rowIdentifier: CellValue? =
        rowIndex < result.rowIdentifiers.count
        ? result.rowIdentifiers[rowIndex]
        : nil

      viewModel.showCellDetail(
        columnName: column.name,
        columnType: column.type,
        value: value,
        tableName: result.tableName,
        rowData: rowData,
        primaryKeyColumns: result.primaryKeyColumns,
        rowIdentifier: rowIdentifier,
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
    // Use displayedRows instead of result.rows to match what's actually rendered
    let sampleSize = min(100, displayedRows.count)  // Only sample first 100 rows
    for rowIndex in 0..<sampleSize {
      let row = displayedRows[displayedRows.startIndex + rowIndex]
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

// MARK: - Cell Content View

// Extracted to reduce type complexity in ResultTableView

private struct CellContentView: View {
  let value: CellValue
  let searchQuery: String
  let isCaseSensitive: Bool
  let isCurrentMatch: Bool

  /// Memoized display string to avoid repeated computation
  private var displayString: String {
    value.displayString
  }

  /// Memoized current match range - only computed if this is the current match
  /// This optimization prevents running String.range(of:) on every cell render
  private var currentMatchRange: Range<String.Index>? {
    guard isCurrentMatch, !searchQuery.isEmpty else { return nil }
    return displayString.range(of: searchQuery, options: isCaseSensitive ? [] : .caseInsensitive)
  }

  var body: some View {
    // Use highlighted text if there's a search query and value is searchable
    if !searchQuery.isEmpty && !displayString.isEmpty {
      switch value {
      case .null:
        Text("NULL")
          .font(.mono)
          .foregroundColor(.foregroundSubtle)
          .italic()
          .lineLimit(1)

      case .json:
        HStack(spacing: Spacing.xs) {
          SearchHighlightText(
            text: displayString,
            query: searchQuery,
            caseSensitive: isCaseSensitive,
            currentMatchRange: currentMatchRange
          )
          .font(.mono)
          .lineLimit(1)
          .truncationMode(.tail)

          Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundColor(.foregroundSubtle)
        }

      case .bool(let boolValue):
        SearchHighlightText(
          text: boolValue ? "true" : "false",
          query: searchQuery,
          caseSensitive: isCaseSensitive,
          currentMatchRange: currentMatchRange
        )
        .font(.mono)
        .lineLimit(1)

      case .int, .double:
        SearchHighlightText(
          text: displayString,
          query: searchQuery,
          caseSensitive: isCaseSensitive,
          currentMatchRange: currentMatchRange
        )
        .font(.mono)
        .lineLimit(1)

      case .date:
        SearchHighlightText(
          text: displayString,
          query: searchQuery,
          caseSensitive: isCaseSensitive,
          currentMatchRange: currentMatchRange
        )
        .font(.mono)
        .lineLimit(1)
        .truncationMode(.tail)

      case .string:
        SearchHighlightText(
          text: displayString,
          query: searchQuery,
          caseSensitive: isCaseSensitive,
          currentMatchRange: currentMatchRange
        )
        .font(.mono)
        .lineLimit(1)
        .truncationMode(.tail)

      case .data:
        SearchHighlightText(
          text: displayString,
          query: searchQuery,
          caseSensitive: isCaseSensitive,
          currentMatchRange: currentMatchRange
        )
        .font(.mono)
        .italic()
        .lineLimit(1)
        .truncationMode(.tail)
      }
    } else {
      // No search query - render normally
      switch value {
      case .null:
        Text("NULL")
          .font(.mono)
          .foregroundColor(.foregroundSubtle)
          .italic()
          .lineLimit(1)

      case .json:
        HStack(spacing: Spacing.xs) {
          Text(value.displayString)
            .font(.mono)
            .foregroundColor(.syntaxFunction)
            .lineLimit(1)
            .truncationMode(.tail)

          Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundColor(.foregroundSubtle)
        }

      case .bool(let boolValue):
        Text(boolValue ? "true" : "false")
          .font(.mono)
          .foregroundColor(boolValue ? .success : .foregroundMuted)
          .lineLimit(1)

      case .int, .double:
        Text(value.displayString)
          .font(.mono)
          .foregroundColor(.syntaxNumber)
          .lineLimit(1)

      case .date:
        Text(value.displayString)
          .font(.mono)
          .foregroundColor(.foreground)
          .lineLimit(1)
          .truncationMode(.tail)

      case .string(let str):
        Text(str)
          .font(.mono)
          .foregroundColor(.foreground)
          .lineLimit(1)
          .truncationMode(.tail)

      case .data:
        Text(value.displayString)
          .font(.mono)
          .foregroundColor(.foregroundMuted)
          .italic()
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
  }
}

// MARK: - Resize Handle

private struct ResizeHandle: View {
  let columnName: String
  @Binding var resizingColumn: String?
  @Binding var columnWidths: [String: CGFloat]
  let minWidth: CGFloat
  let maxWidth: CGFloat
  let onAutoResize: () -> Void

  @State private var isHovering = false

  var body: some View {
    Rectangle()
      .fill(isHovering ? Color.accent.opacity(0.5) : Color.clear)
      .frame(width: 4)
      .contentShape(Rectangle())
      .onHover { hovering in
        isHovering = hovering
        if hovering {
          NSCursor.resizeLeftRight.push()
        } else {
          NSCursor.pop()
        }
      }
      .onTapGesture(count: 2) {
        // Double-click to auto-resize
        onAutoResize()
      }
      .gesture(
        DragGesture()
          .onChanged { value in
            let currentWidth = columnWidths[columnName] ?? 150
            let newWidth = max(minWidth, min(maxWidth, currentWidth + value.translation.width))
            columnWidths[columnName] = newWidth
          }
      )
  }
}

// MARK: - Scroller Configurator

private struct ScrollerConfigurator: NSViewRepresentable {
  let needsVerticalScroller: Bool

  func makeNSView(context _: Context) -> NSView {
    let view = NSView()
    return view
  }

  func updateNSView(_ nsView: NSView, context _: Context) {
    DispatchQueue.main.async {
      guard let scrollView = nsView.enclosingScrollView else { return }

      // Configure scroller style
      scrollView.scrollerStyle = .overlay
      scrollView.autohidesScrollers = true
      scrollView.hasHorizontalScroller = true
      scrollView.hasVerticalScroller = needsVerticalScroller

      // Force scroller update
      scrollView.flashScrollers()
    }
  }
}

// MARK: - Result Metadata Bar

struct ResultMetadataBar: View {
  let result: CellResult

  var body: some View {
    HStack(spacing: Spacing.md) {
      Label("Data Types: \(dataTypeSummary)", systemImage: "tablecells")

      Spacer()

      Text("Rows: \(result.rowCount)")
    }
    .font(.caption)
    .foregroundColor(.foregroundSubtle)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
  }

  private var dataTypeSummary: String {
    let types = result.columns.map { $0.type }
    let uniqueTypes = Array(Set(types))
    return uniqueTypes.prefix(3).joined(separator: ", ") + (uniqueTypes.count > 3 ? "..." : "")
  }
}

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
