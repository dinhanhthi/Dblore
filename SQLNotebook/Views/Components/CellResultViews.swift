//
//  CellResultViews.swift
//  SQLNotebook
//
//  Result display components for CellView (error, success, table area, metadata).
//

import SwiftUI

// MARK: - Result Area Container

struct ResultAreaView: View {
  let result: CellResult
  let viewModel: NotebookViewModel
  let cellId: UUID

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      // Fake sidebar to align with cell sidebar
      Color.clear
        .frame(width: ComponentSize.cellSidebarWidth)

      VStack(alignment: .leading, spacing: Spacing.sm) {
        // Show executed query at top of result area if available
        if let sourceQuery = result.sourceQuery {
          ExecutedQueryDisplayView(query: sourceQuery)
        }

        if let error = result.error {
          // Error display with search highlighting
          ErrorResultView(
            error: error,
            searchQuery: viewModel.searchState.query,
            isCaseSensitive: viewModel.searchState.isCaseSensitive,
            cellId: cellId
          )
        } else if let affectedRows = result.affectedRows {
          // Success message for UPDATE/DELETE/INSERT
          SuccessResultView(affectedRows: affectedRows, executionTime: result.executionTime)
        } else {
          // Result table
          ResultTableView(result: result, viewModel: viewModel, cellId: cellId)

          // Result metadata
          ResultMetadataView(result: result)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 0)
      .padding(.bottom, 0)
      .padding(.trailing, Spacing.md)
    }
    .padding(.bottom, Spacing.md)
  }
}

// MARK: - Success Result View

struct SuccessResultView: View {
  let affectedRows: Int
  let executionTime: TimeInterval

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.green)

        Text("Success")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(.green)
      }
      .padding(.bottom, Spacing.md)

      HStack(spacing: Spacing.md) {
        Text("\(affectedRows) row\(affectedRows == 1 ? "" : "s") affected")
          .font(.mono)
          .foregroundColor(.foreground)

        Text("|")
          .foregroundColor(.foregroundSubtle)

        Text(String(format: "Execution time: %.3fs", executionTime))
          .font(.mono)
          .foregroundColor(.foregroundSubtle)
      }
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.green.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }
}

// MARK: - Error Result View

struct ErrorResultView: View {
  let error: String
  let searchQuery: String
  let isCaseSensitive: Bool
  let cellId: UUID
  @State private var currentMatchRange: Range<String.Index>?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundColor(.destructive)

        Text("Error")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(.destructive)
      }
      .padding(.bottom, Spacing.md)

      // Use SearchHighlightText if there's a search query
      if !searchQuery.isEmpty {
        SearchHighlightText(
          text: error,
          query: searchQuery,
          caseSensitive: isCaseSensitive,
          currentMatchRange: currentMatchRange
        )
        .font(.mono)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text(error)
          .font(.mono)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.destructive.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .onReceive(NotificationCenter.default.publisher(for: .highlightSearchMatch)) { notification in
      if let match = notification.userInfo?["match"] as? SearchMatch,
        case .errorMessage = match.matchType,
        match.cellId == cellId
      {
        // This cell has the current match - highlight specific range
        currentMatchRange = match.matchRange
      } else {
        // Clear current match highlight (but keep all yellow highlights from query)
        currentMatchRange = nil
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .clearSearchHighlights)) { _ in
      currentMatchRange = nil
    }
  }
}

// MARK: - Result Metadata View

struct ResultMetadataView: View {
  let result: CellResult

  var body: some View {
    HStack(spacing: Spacing.md) {
      Text("Rows: \(result.rowCount)")

      // Show warning if limited (either auto-limited or user LIMIT exceeded)
      if result.wasLimited || result.userLimitExceeded {
        HStack(spacing: Spacing.xs) {
          Text("(")
            .foregroundColor(.warning)
          Text("limited to \(AppSettings.shared.maxRowLimit) rows")
            .foregroundColor(.warning)
          Text(")")
            .foregroundColor(.warning)
        }.font(.labelText)
      }

      Text("|")
        .foregroundColor(.foregroundSubtle)
      Text(String(format: "Execution time: %.3fs", result.executionTime))
      Text("|")
        .foregroundColor(.foregroundSubtle)
      Text(CellResultViews.formatTimestamp(result.timestamp))
    }
    .font(.labelText)
    .foregroundColor(.foregroundSubtle)
  }
}

// MARK: - Helper Functions

enum CellResultViews {
  // Static date formatter (cached for performance)
  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
  }()

  static func formatTimestamp(_ date: Date) -> String {
    timestampFormatter.string(from: date)
  }
}

// MARK: - Previews

#Preview("Success Result") {
  SuccessResultView(affectedRows: 5, executionTime: 0.123)
    .padding()
    .frame(width: 600)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}

#Preview("Error Result") {
  ErrorResultView(
    error:
      "ERROR: column \"invalid_column\" does not exist\nLINE 1: SELECT invalid_column FROM users;\n               ^",
    searchQuery: "",
    isCaseSensitive: false,
    cellId: UUID()
  )
  .padding()
  .frame(width: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Result Metadata - Normal") {
  let result = CellResult(
    columns: [],
    rows: [],
    executionTime: 0.087,
    rowCount: 18,
    timestamp: Date()
  )

  return ResultMetadataView(result: result)
    .padding()
    .frame(width: 600)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}

#Preview("Result Metadata - Limited") {
  let result = CellResult(
    columns: [],
    rows: [],
    executionTime: 0.087,
    rowCount: 50,
    timestamp: Date(),
    wasLimited: true
  )

  return ResultMetadataView(result: result)
    .padding()
    .frame(width: 600)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
