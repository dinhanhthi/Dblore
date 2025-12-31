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

  private let padding: CGFloat = 40  // Total horizontal padding for each cell
  private let maxColumnWidth: CGFloat = 300
  private let absoluteMinWidth: CGFloat = 60  // Fallback minimum
  private let rowHeight: CGFloat = 32  // Approximate row height
  private let headerHeight: CGFloat = 48  // Approximate header height

  // Estimate if vertical scrolling is needed
  private var estimatedContentHeight: CGFloat {
    headerHeight + (CGFloat(result.rows.count) * rowHeight)
  }

  private var needsVerticalScroll: Bool {
    estimatedContentHeight > AppSettings.shared.maxResultHeight
  }

  private var scrollAxes: Axis.Set {
    needsVerticalScroll ? [.horizontal, .vertical] : .horizontal
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header and data rows
      ScrollView(scrollAxes) {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
          Section {
            // Data rows
            ForEach(Array(result.rows.enumerated()), id: \.offset) { rowIndex, row in
              dataRow(row: row, rowIndex: rowIndex)
            }
          } header: {
            // Header row (pinned at top)
            headerRow
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollBounceBehavior(.basedOnSize)
      .background(ScrollerConfigurator(needsVerticalScroller: needsVerticalScroll))
      .frame(maxHeight: AppSettings.shared.maxResultHeight)
    }
    .frame(maxWidth: .infinity)
    .background(Color.cellBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .onAppear {
      calculateInitialColumnWidths()
    }
  }

  // MARK: - Header Row

  private var headerRow: some View {
    HStack(spacing: 0) {
      ForEach(result.columns) { column in
        headerCell(column: column)
      }
    }
    .background(Color.tableHeaderBackground)
  }

  private func headerCell(column: ColumnInfo) -> some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(column.name)
          .font(.system(.body, weight: .semibold))
          .foregroundColor(.foreground)
          .lineLimit(1)
          .truncationMode(.tail)

        Text(column.type)
          .font(.small)
          .foregroundColor(.foregroundSubtle)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.xs)
      .frame(width: columnWidth(for: column.name) - 1, alignment: .leading)
    }
    .frame(width: columnWidth(for: column.name))
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
      cellContent(value: value)
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

  private func cellContent(value: CellValue) -> CellContentView {
    CellContentView(value: value)
  }

  // MARK: - Helpers

  private func calculateInitialColumnWidths() {
    for column in result.columns {
      // Skip if already set (e.g., from manual resize)
      if columnWidths[column.name] != nil {
        continue
      }

      // Calculate width based on content
      let calculatedWidth = calculateContentWidth(for: column)
      // Ensure minimum width is at least the column name width with proper font size
      let headerNameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)  // Match actual header font
      let minNameWidth = textWidth(column.name, font: headerNameFont) + padding
      columnWidths[column.name] = max(calculatedWidth, minNameWidth)
    }
  }

  private func calculateContentWidth(for column: ColumnInfo) -> CGFloat {
    // Width for header (column name + type)
    let headerNameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)  // .body weight semibold
    let headerTypeFont = NSFont.systemFont(ofSize: 11)  // .small
    let headerNameWidth = textWidth(column.name, font: headerNameFont)
    let headerTypeWidth = textWidth(column.type, font: headerTypeFont)
    // Use the wider of the two, since they stack vertically
    let headerWidth = max(headerNameWidth, headerTypeWidth)

    // Width for data cells
    var maxDataWidth: CGFloat = 0

    if let columnIndex = result.columns.firstIndex(where: { $0.name == column.name }) {
      let dataFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)  // .body monospaced
      for row in result.rows.prefix(100) {  // Sample first 100 rows for performance
        if columnIndex < row.count {
          let value = row[columnIndex]
          let dataWidth = textWidth(value.displayString, font: dataFont)
          maxDataWidth = max(maxDataWidth, dataWidth)
        }
      }
    }

    // Add padding and return the maximum, but cap at maxColumnWidth
    let contentWidth = max(headerWidth, maxDataWidth) + padding
    let clampedWidth = min(contentWidth, maxColumnWidth)
    return max(clampedWidth, absoluteMinWidth)
  }

  private func textWidth(_ text: String, font: NSFont) -> CGFloat {
    let attributes = [NSAttributedString.Key.font: font]
    let size = (text as NSString).size(withAttributes: attributes)
    return size.width
  }

  private func columnWidth(for columnName: String) -> CGFloat {
    columnWidths[columnName] ?? absoluteMinWidth
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
      let rowIdentifier: CellValue? = rowIndex < result.rowIdentifiers.count
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
}

// MARK: - Cell Content View
// Extracted to reduce type complexity in ResultTableView

private struct CellContentView: View {
  let value: CellValue

  var body: some View {
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

// MARK: - Scroller Configurator

private struct ScrollerConfigurator: NSViewRepresentable {
  let needsVerticalScroller: Bool

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
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
  let longText = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur."

  let mockResult = CellResult(
    columns: [
      ColumnInfo(name: "id", type: "INTEGER"),
      ColumnInfo(name: "description", type: "TEXT")
    ],
    rows: [
      [
        .int(1),
        .string(longText)
      ],
      [
        .int(2),
        .string("Short text")
      ],
      [
        .int(3),
        .string("The quick brown fox jumps over the lazy dog. This sentence is repeated multiple times to create a very long text value. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog.")
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
