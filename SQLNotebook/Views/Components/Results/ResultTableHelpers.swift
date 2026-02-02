//
//  ResultTableHelpers.swift
//  SQLNotebook
//
//  Extracted from ResultTableView.swift for better maintainability (10.3.1)
//  Contains: CellContentView, ResizeHandle, ResultMetadataBar
//

import SwiftUI

// MARK: - Cell Content View

/// Renders cell content with optional search highlighting
/// Equatable protocol allows SwiftUI to skip re-render when props unchanged (10.2.3 optimization)
struct ResultTableCellContentView: View, Equatable {
  let value: CellValue
  let searchQuery: String
  let isCaseSensitive: Bool
  let isCurrentMatch: Bool

  // Custom equality check - only re-render if relevant properties change
  static func == (lhs: ResultTableCellContentView, rhs: ResultTableCellContentView) -> Bool {
    // Only re-render if current match status changed or search query changed
    // Don't compare value equality as it's expensive for JSON/large strings
    if lhs.isCurrentMatch != rhs.isCurrentMatch {
      return false
    }
    if lhs.searchQuery != rhs.searchQuery {
      return false
    }
    if lhs.isCaseSensitive != rhs.isCaseSensitive {
      return false
    }
    // Value comparison - use identity check for performance
    return lhs.value.displayString == rhs.value.displayString
  }

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
      searchHighlightedContent
    } else {
      // No search query - render normally
      normalContent
    }
  }

  @ViewBuilder
  private var searchHighlightedContent: some View {
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
  }

  @ViewBuilder
  private var normalContent: some View {
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

// MARK: - Resize Handle

/// Column resize handle with drag gesture and double-click auto-resize
struct ResultTableResizeHandle: View {
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

// MARK: - Result Metadata Bar

/// Displays result metadata (data types summary, row count)
struct ResultMetadataBar: View {
  let result: CellResult

  var body: some View {
    HStack(spacing: Spacing.md) {
      Label("Data Types: \(dataTypeSummary)", systemImage: "tablecells")

      Spacer()

      Text("Rows: \(result.rowCount)")
    }
    .font(.labelText)
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
