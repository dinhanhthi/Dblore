//
//  ResultTableView.swift
//  SQLNotebook
//

import SwiftUI

struct ResultTableView: View {
    let result: CellResult
    @Bindable var viewModel: NotebookViewModel

    @State private var columnWidths: [String: CGFloat] = [:]
    @State private var hoveredRow: Int?

    private let padding: CGFloat = 40 // Total horizontal padding for each cell
    private let maxColumnWidth: CGFloat = 300
    private let absoluteMinWidth: CGFloat = 60 // Fallback minimum

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                headerRow

                // Data rows
                ForEach(Array(result.rows.enumerated()), id: \.offset) { rowIndex, row in
                    dataRow(row: row, rowIndex: rowIndex)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .background(Color.cellBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
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
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(.foreground)

                Text(column.type)
                    .font(.small)
                    .foregroundColor(.foregroundSubtle)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .frame(width: columnWidth(for: column.name) - 1, alignment: .leading)

            // Column resize handle
            Rectangle()
                .fill(Color.border)
                .frame(width: 1)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let newWidth = columnWidth(for: column.name) + value.translation.width
                            columnWidths[column.name] = max(minColumnWidth(for: column.name), min(maxColumnWidth, newWidth))
                        }
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
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
                .onTapGesture {
                    handleCellTap(value: value, column: column, rowIndex: rowIndex)
                }

            Rectangle()
                .fill(Color.border.opacity(0.5))
                .frame(width: 1)
        }
        .frame(width: columnWidth(for: column.name))
    }

    @ViewBuilder
    private func cellContent(value: CellValue) -> some View {
        switch value {
        case .null:
            Text("NULL")
                .font(.mono)
                .foregroundColor(.foregroundSubtle)
                .italic()

        case .json:
            HStack(spacing: Spacing.xs) {
                Text(value.displayString)
                    .font(.mono)
                    .foregroundColor(.syntaxFunction)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.foregroundSubtle)
            }

        case .bool(let boolValue):
            Text(boolValue ? "true" : "false")
                .font(.mono)
                .foregroundColor(boolValue ? .success : .foregroundMuted)

        case .int, .double:
            Text(value.displayString)
                .font(.mono)
                .foregroundColor(.syntaxNumber)

        case .date:
            Text(value.displayString)
                .font(.mono)
                .foregroundColor(.foreground)

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
        }
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
            columnWidths[column.name] = min(calculatedWidth, maxColumnWidth)
        }
    }
    
    private func calculateContentWidth(for column: ColumnInfo) -> CGFloat {
        // Width for header (column name + type)
        let headerNameFont = NSFont.systemFont(ofSize: 11, weight: .semibold) // .caption
        let headerTypeFont = NSFont.systemFont(ofSize: 11) // .small
        let headerNameWidth = textWidth(column.name, font: headerNameFont)
        let headerTypeWidth = textWidth(column.type, font: headerTypeFont)
        let headerWidth = max(headerNameWidth, headerTypeWidth)
        
        // Width for data cells
        var maxDataWidth: CGFloat = 0
        
        if let columnIndex = result.columns.firstIndex(where: { $0.name == column.name }) {
            let dataFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) // .body monospaced
            for row in result.rows.prefix(100) { // Sample first 100 rows for performance
                if columnIndex < row.count {
                    let value = row[columnIndex]
                    let dataWidth = textWidth(value.displayString, font: dataFont)
                    maxDataWidth = max(maxDataWidth, dataWidth)
                }
            }
        }
        
        // Add padding and return the maximum
        let contentWidth = max(headerWidth, maxDataWidth) + padding
        return max(contentWidth, absoluteMinWidth)
    }
    
    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let attributes = [NSAttributedString.Key.font: font]
        let size = (text as NSString).size(withAttributes: attributes)
        return size.width
    }
    
    private func minColumnWidth(for columnName: String) -> CGFloat {
        // Use the calculated content width as minimum
        if let column = result.columns.first(where: { $0.name == columnName }) {
            return calculateContentWidth(for: column)
        }
        return absoluteMinWidth
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
            viewModel.showCellDetail(
                columnName: column.name,
                columnType: column.type,
                value: value
            )
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

#Preview {
    let mockResult = CellResult(
        columns: [
            ColumnInfo(name: "id", type: "INTEGER"),
            ColumnInfo(name: "name", type: "VARCHAR"),
            ColumnInfo(name: "email", type: "VARCHAR"),
            ColumnInfo(name: "metadata", type: "JSONB")
        ],
        rows: [
            [.int(1), .string("Alice Johnson"), .string("alice@example.com"), .json("{\"role\": \"admin\"}")],
            [.int(2), .string("Bob Williams"), .string("bob@example.com"), .json("{\"role\": \"user\"}")],
            [.int(3), .null, .string("charlie@example.com"), .null]
        ],
        executionTime: 0.034,
        rowCount: 3,
        timestamp: Date()
    )

    return ResultTableView(result: mockResult, viewModel: NotebookViewModel())
        .frame(width: 800)
        .background(Color.appBackground)
        .preferredColorScheme(.dark)
}
