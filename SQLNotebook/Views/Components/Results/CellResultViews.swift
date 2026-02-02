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
  @State private var isQueryCopied: Bool = false

  /// Get the cell from viewModel
  private var cell: NotebookCell? {
    viewModel.notebook.cells.first(where: { $0.id == cellId })
  }

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      // Fake sidebar to align with cell sidebar
      Color.clear
        .frame(width: ComponentSize.cellSidebarWidth)

      VStack(alignment: .leading, spacing: Spacing.sm) {
        // Query footer (for both single and multi-statement)
        ResultQueryFooterView(
          result: result,
          isQueryCopied: $isQueryCopied,
          viewModel: viewModel,
          cellId: cellId
        )

        if let error = result.error {
          // Error display with search highlighting
          ErrorResultView(
            error: error,
            searchQuery: viewModel.searchState.query,
            isCaseSensitive: viewModel.searchState.isCaseSensitive,
            cellId: cellId,
            viewModel: viewModel
          )
        } else if let affectedRows = result.affectedRows, affectedRows > 0, result.rows.isEmpty {
          // Success message for UPDATE/DELETE/INSERT (only when no result table)
          SuccessResultView(affectedRows: affectedRows, executionTime: result.executionTime)
        } else if result.rows.isEmpty && result.columns.isEmpty {
          // Empty result (no rows and no columns) - e.g., comment-only queries
          EmptyResultView()
        } else {
          // Result table with pagination support
          NotebookResultTableView(
            result: result,
            viewModel: viewModel,
            cellId: cellId
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 0)
      .padding(.bottom, Spacing.sm)
      .padding(.trailing, Spacing.md)
    }
    .padding(.bottom, 0)
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

        Text("Execution time: \(CellResultViews.formatExecutionTime(executionTime))")
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

// MARK: - Empty Result View

struct EmptyResultView: View {
  var body: some View {
    VStack(alignment: .center, spacing: Spacing.sm) {
      Image(systemName: "tray")
        .font(.system(size: 28))
        .foregroundColor(.foregroundSubtle)

      Text("No result")
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(.foregroundMuted)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Spacing.xl)
    .background(Color.cellBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }
}

// MARK: - Error Result View

struct ErrorResultView: View {
  let error: String
  let searchQuery: String
  let isCaseSensitive: Bool
  let cellId: UUID
  let viewModel: NotebookViewModel
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
      // Only respond if this notification is for our viewModel instance
      guard let notificationViewModelId = notification.userInfo?["viewModelId"] as? UUID,
        notificationViewModelId == viewModel.id
      else {
        return
      }

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
    .onReceive(NotificationCenter.default.publisher(for: .clearSearchHighlights)) { notification in
      // Only respond if this notification is for our viewModel instance
      guard let notificationViewModelId = notification.userInfo?["viewModelId"] as? UUID,
        notificationViewModelId == viewModel.id
      else {
        return
      }

      currentMatchRange = nil
    }
  }
}

// MARK: - Result Metadata View

struct ResultMetadataView: View {
  let result: CellResult
  var statementResults: [StatementResult]? = nil
  var selectedStatementIndex: Int? = nil
  var viewModel: NotebookViewModel? = nil
  var cellId: UUID? = nil

  /// Determine color for affected rows text based on query type
  /// - Green for INSERT/UPDATE queries with affected rows > 0
  /// - Red for DELETE queries with affected rows > 0
  /// - Subtle gray for SELECT, 0 affected rows, or when no query info available
  private func affectedRowsColor(for result: CellResult) -> Color {
    let affectedRows = result.affectedRows ?? 0

    // If no rows affected, use default gray color
    guard affectedRows > 0, let query = result.sourceQuery else {
      return .foregroundSubtle
    }

    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

    if trimmed.hasPrefix("DELETE") {
      return .red
    } else if trimmed.hasPrefix("INSERT") || trimmed.hasPrefix("UPDATE") {
      return .green
    } else {
      return .foregroundSubtle
    }
  }

  /// Truncate long query text for display in dropdown menu
  private func truncateQuery(_ query: String, maxLength: Int = 60) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= maxLength {
      return trimmed
    }
    return String(trimmed.prefix(maxLength)) + "..."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Horizontal divider line
      Rectangle()
        .fill(Color.border)
        .frame(height: 1)

      GeometryReader { geometry in
        let currentWidth = geometry.size.width
        let shouldShowTimestamp = currentWidth >= 600

        HStack(spacing: Spacing.md) {
          // Dropdown menu for multi-statement queries (at the beginning, only show when > 1 statement)
          if let statementResults = statementResults,
            let selectedIndex = selectedStatementIndex,
            let viewModel = viewModel,
            let cellId = cellId,
            statementResults.count > 1
          {
            Menu {
              ForEach(statementResults.indices, id: \.self) { index in
                let statementResult = statementResults[index]
                Button(action: {
                  viewModel.selectCellStatement(cellId: cellId, at: index)
                }) {
                  HStack {
                    // Combined text: "Result N • query text (truncated)"
                    (Text("Result \(index + 1) • ")
                      .font(.system(size: 11))
                      + Text(truncateQuery(statementResult.queryText))
                      .font(.system(size: 11, design: .monospaced)))
                      .lineLimit(1)

                    Spacer()

                    // Checkmark for selected item
                    if index == selectedIndex {
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
                Text("Result \(selectedIndex + 1)")
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
                RoundedRectangle(cornerRadius: CornerRadius.md)
                  .fill(Color.inputBackground)
              )
              .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                  .stroke(Color.border, lineWidth: 1)
              )
            }
            .id(statementResults.map { $0.id })
            .buttonStyle(.plain)
            .help("Select statement result to view")
            .fixedSize()

            Text("|")
              .foregroundColor(.foregroundSubtle)
          }

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
          Text("Affected: \(result.affectedRows ?? 0)")
            .foregroundColor(affectedRowsColor(for: result))

          Text("|")
            .foregroundColor(.foregroundSubtle)
          Text("Execution time: \(CellResultViews.formatExecutionTime(result.executionTime))")

          // Hide timestamp and separator when width < 600px
          if shouldShowTimestamp {
            Text("|")
              .foregroundColor(.foregroundSubtle)
            Text(CellResultViews.formatTimestamp(result.timestamp))
          }
        }
        .font(.labelText)
        .foregroundColor(.foregroundSubtle)
        .frame(width: geometry.size.width, alignment: .leading)
      }
      .frame(height: 30)
      .padding(.top, Spacing.sm)
      .padding(.bottom, 0)  // Add bottom padding to prevent overlap with floating action panel
    }
  }
}

// MARK: - Result Query Footer

/// Footer showing the source query with click-to-copy functionality.
struct ResultQueryFooterView: View {
  let result: CellResult
  @Binding var isQueryCopied: Bool
  var viewModel: NotebookViewModel?
  var cellId: UUID?

  /// Get the actual query that was executed (with LIMIT replaced if it was capped)
  private var actualExecutedQuery: String? {
    guard let sourceQuery = result.sourceQuery else {
      return nil
    }

    // If user's LIMIT was capped to maxRows, show the actual query sent to database
    if result.limitWasCapped, let actualLimit = result.actualLimitUsed {
      return CellResultViews.replaceLimitInQuery(sourceQuery, newLimit: actualLimit)
    }

    return sourceQuery
  }

  var body: some View {
    // Don't show if setting is enabled to hide this section
    if !AppSettings.shared.hideRunWithQuerySection, let query = actualExecutedQuery {
      VStack(alignment: .leading, spacing: 0) {
        // Horizontal divider line (top)
        Rectangle()
          .fill(Color.border)
          .frame(height: 1)

        QueryCopyBar(
          query: query,
          result: result,
          viewModel: viewModel,
          cellId: cellId,
          queryIndex: nil  // Notebook mode always uses nil
        )
        .frame(height: 24)
        .padding(.vertical, Spacing.sm)

        // Horizontal divider line (bottom)
        Rectangle()
          .fill(Color.border)
          .frame(height: 1)
      }
    }
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

  /// Format execution time with appropriate unit
  /// - If time >= 1 second: show in seconds with 3 decimal places (e.g., "1.234s")
  /// - If time < 1 second: show in milliseconds with 0 decimal places (e.g., "450ms")
  static func formatExecutionTime(_ seconds: Double) -> String {
    if seconds >= 1.0 {
      return String(format: "%.3fs", seconds)
    } else {
      let milliseconds = seconds * 1000
      return String(format: "%.0fms", milliseconds)
    }
  }

  /// Replace LIMIT value in query with a new limit value
  /// Used to show the actual executed query in UI when LIMIT was capped
  static func replaceLimitInQuery(_ query: String, newLimit: Int) -> String {
    let pattern = "\\bLIMIT\\s+\\d+"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return query
    }

    let nsRange = NSRange(query.startIndex..., in: query)
    let modifiedQuery = regex.stringByReplacingMatches(
      in: query,
      options: [],
      range: nsRange,
      withTemplate: "LIMIT \(newLimit)"
    )

    return modifiedQuery
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

#Preview("Empty Result") {
  EmptyResultView()
    .padding()
    .frame(width: 600)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}

#Preview("Error Result") {
  let notebook = SQLNotebook(
    cells: [NotebookCell(cellType: .sql, content: "SELECT * FROM test")],
    connectionConfig: nil
  )
  let viewModel = NotebookViewModel(notebook: notebook)

  return ErrorResultView(
    error:
      "ERROR: column \"invalid_column\" does not exist\nLINE 1: SELECT invalid_column FROM users;\n               ^",
    searchQuery: "",
    isCaseSensitive: false,
    cellId: UUID(),
    viewModel: viewModel
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

// MARK: - Notebook Result Table View

/// Wrapper for ResultTableView that provides pagination support for notebook mode
struct NotebookResultTableView: View {
  let result: CellResult
  @Bindable var viewModel: NotebookViewModel
  let cellId: UUID

  /// Get the cell from viewModel
  private var cell: NotebookCell? {
    viewModel.notebook.cells.first(where: { $0.id == cellId })
  }

  /// Get pagination info for this cell
  private var paginationInfo: PaginationInfo? {
    viewModel.getPaginationInfo(for: cellId)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Result table
      ResultTableView(
        result: result,
        viewModel: viewModel,
        cellId: cellId,
        showBorderRadius: false,
        enableVerticalScrolling: false,
        paginationInfo: paginationInfo,
        onPageChange: handlePageChange
      )

      // Result metadata (below table) with dropdown for multi-statement (only show when > 1 statement)
      if let cell = cell, cell.statementResults.count > 1 {
        // Multi-statement: show dropdown in metadata bar
        ResultMetadataView(
          result: result,
          statementResults: cell.statementResults,
          selectedStatementIndex: cell.selectedStatementIndex,
          viewModel: viewModel,
          cellId: cellId
        )
      } else {
        // Single statement: no dropdown
        ResultMetadataView(result: result)
      }
    }
  }

  /// Handle page change for single statement or selected statement in multi-statement
  private func handlePageChange(_ page: Int) {
    Task { @MainActor in
      guard let cell = cell else { return }

      if !cell.statementResults.isEmpty {
        // Multi-statement mode - navigate for selected statement
        let selectedStatement = cell.statementResults[cell.selectedStatementIndex]
        await viewModel.navigateToPageForCellStatement(
          cellId: cellId,
          statementId: selectedStatement.id,
          page: page
        )
      } else {
        // Single statement mode
        await viewModel.navigateToPageForCell(cellId: cellId, page: page)
      }
    }
  }
}
