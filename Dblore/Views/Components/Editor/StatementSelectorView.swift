//
//  StatementSelectorView.swift
//  Dblore
//
//  Reusable component for selecting and displaying results from multi-statement queries.
//  Used in both notebook mode and editor mode.
//

import SwiftUI

/// A reusable component that displays a dropdown selector for multi-statement query results.
///
/// Features:
/// - Dropdown menu showing all statement results with query text preview
/// - Displays "Result N • query text" for each statement
/// - Shows checkmark for currently selected statement
/// - Integrates with QueryCopyBar for query display and actions
///
/// Usage:
/// ```swift
/// // For notebook mode (with cellId)
/// StatementSelectorView(
///   statementResults: cell.statementResults,
///   selectedIndex: cell.selectedStatementIndex,
///   cellId: cell.id,
///   viewModel: viewModel,
///   onSelect: { index in
///     viewModel.selectCellStatement(cellId: cell.id, at: index)
///   }
/// )
///
/// // For editor mode (without cellId)
/// StatementSelectorView(
///   statementResults: viewModel.editorStatementResults,
///   selectedIndex: viewModel.selectedStatementIndex,
///   cellId: nil,
///   viewModel: viewModel,
///   onSelect: { index in
///     viewModel.selectEditorStatement(at: index)
///   }
/// )
/// ```
struct StatementSelectorView: View {
  /// Array of statement results to display
  let statementResults: [StatementResult]

  /// Currently selected statement index (0-based)
  let selectedIndex: Int

  /// Optional cell ID (for notebook mode, nil for editor mode)
  let cellId: UUID?

  /// View model for query actions (View Query, Download)
  let viewModel: NotebookViewModel?

  /// Callback when a statement is selected
  let onSelect: (Int) -> Void

  /// Truncate long query text for display in menu
  private func truncateQuery(_ query: String, maxLength: Int = 60) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= maxLength {
      return trimmed
    }
    return String(trimmed.prefix(maxLength)) + "..."
  }

  /// Get the currently selected result
  private var selectedResult: CellResult? {
    guard selectedIndex >= 0 && selectedIndex < statementResults.count else {
      return nil
    }
    return statementResults[selectedIndex].result
  }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      // Dropdown menu for statement selection
      Menu {
        ForEach(statementResults.indices, id: \.self) { index in
          let statementResult = statementResults[index]
          Button(action: {
            onSelect(index)
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
              if index == selectedIndex {
                Image(systemName: "checkmark")
                  .font(.system(size: 10))
                  .foregroundColor(.accentColor)
              }
            }
          }
          .id(statementResult.id)  // Force Button to recreate when data changes
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
      .linkPointer()
      .help("Select statement result to view")
      .fixedSize()  // Don't expand

      // QueryCopyBar for displaying query and actions
      if let result = selectedResult {
        let actualQuery = getActualExecutedQuery(result: result)
        let displayQuery = SQLSyntaxHighlighter.removeComments(actualQuery)
        QueryCopyBar(
          query: displayQuery,
          result: result,
          viewModel: viewModel,
          cellId: cellId,
          queryIndex: cellId == nil ? (selectedIndex + 1) : nil  // Only show index in editor mode
        )
      }
    }
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

  // MARK: - Helper Methods

  /// The query that was executed (sent to the database as written)
  private func getActualExecutedQuery(result: CellResult) -> String {
    result.sourceQuery ?? ""
  }
}

// MARK: - Previews

#Preview("Statement Selector - Multi-statement") {
  let mockResults = [
    StatementResult(
      queryText: "SELECT * FROM users WHERE status = 'active'",
      result: CellResult(
        columns: [],
        rows: [],
        executionTime: 0.045,
        rowCount: 10,
        timestamp: Date()
      ),
      statementIndex: 0
    ),
    StatementResult(
      queryText: "UPDATE users SET last_login = NOW() WHERE id = 1",
      result: CellResult(
        columns: [],
        rows: [],
        executionTime: 0.023,
        rowCount: 0,
        timestamp: Date(),
        affectedRows: 1
      ),
      statementIndex: 1
    ),
    StatementResult(
      queryText: "SELECT COUNT(*) FROM orders WHERE created_at > '2024-01-01'",
      result: CellResult(
        columns: [],
        rows: [],
        executionTime: 0.067,
        rowCount: 1,
        timestamp: Date()
      ),
      statementIndex: 2
    ),
  ]

  return VStack(spacing: 20) {
    Text("Notebook Mode (with Cell ID)")
      .font(.headline)

    StatementSelectorView(
      statementResults: mockResults,
      selectedIndex: 0,
      cellId: UUID(),
      viewModel: NotebookViewModel(),
      onSelect: { index in
        print("Selected statement \(index + 1)")
      }
    )

    Text("Editor Mode (without Cell ID)")
      .font(.headline)

    StatementSelectorView(
      statementResults: mockResults,
      selectedIndex: 1,
      cellId: nil,
      viewModel: NotebookViewModel(),
      onSelect: { index in
        print("Selected statement \(index + 1)")
      }
    )
  }
  .frame(width: 800)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
