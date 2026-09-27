//
//  EditorModeView+ResultPanel.swift
//  SQLNotebook
//
//  Result panel header and footer for editor mode
//

import SwiftUI

// MARK: - Result Panel Extension

extension EditorModeView {

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

        Spacer()

        // Clear button
        Button(action: clearResult) {
          Image(systemName: "xmark")
            .font(.system(size: 10))
            .foregroundColor(.foregroundSubtle)
        }
        .buttonStyle(.plain)
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
      .overlay(
        Capsule()
          .stroke(Color.border, lineWidth: 1)
      )
    }
    .id(viewModel.editorStatementResults.map { $0.id })
    .buttonStyle(.plain)
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
    if !getAppSettings().hideRunWithQuerySection, result.sourceQuery != nil {
      // Show clickable query text + Download button for both single and multi-statement
      let actualQuery = getActualExecutedQuery(result: result)
      let displayQuery = SQLSyntaxHighlighter.removeComments(actualQuery)
      QueryCopyBar(
        query: displayQuery,
        result: result,
        viewModel: viewModel,
        cellId: nil,  // Editor mode has no cell ID
        queryIndex: !viewModel.editorStatementResults.isEmpty
          ? (viewModel.selectedStatementIndex + 1) : nil
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
  @State private var sortColumn: String?
  @State private var sortAscending = true
  /// Current search match when it is in the result data or column names
  @State private var currentMatch: SearchMatch?

  var body: some View {
    ResultGridView(
      result: result,
      sortColumn: sortColumn,
      ascending: sortAscending,
      isEditable: viewModel.canEdit(result),
      onCommitEdit: { row, column, newValue in
        viewModel.handleGridCellEdit(
          row: row, column: column, newValue: newValue, result: result, cellId: nil,
          connectionManager: viewModel.connectionManager)
      },
      onSortChange: { column, ascending in
        sortColumn = column
        sortAscending = ascending
      },
      onCellClick: { row, originalRow, column in
        viewModel.showGridCellInSidebar(
          row: row, originalRow: originalRow, column: column, result: result, cellId: nil)
      },
      searchQuery: viewModel.searchState.query,
      caseSensitive: viewModel.searchState.isCaseSensitive,
      currentMatch: currentMatch,
      forwardsScrollToParent: false,
      hideColumnTypes: AppSettings.shared.hideColumnTypes
    )
    .onReceive(NotificationCenter.default.publisher(for: .highlightSearchMatch)) { notification in
      guard let notificationViewModelId = notification.userInfo?["viewModelId"] as? UUID,
        notificationViewModelId == viewModel.id
      else { return }
      if let match = notification.userInfo?["match"] as? SearchMatch, match.isInResultGrid {
        currentMatch = match
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
}
