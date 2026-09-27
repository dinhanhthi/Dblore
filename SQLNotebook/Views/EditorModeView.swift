//
//  EditorModeView.swift
//  SQLNotebook
//
//  Editor mode view - Single SQL editor with result panel below
//

import SwiftUI

// MARK: - Editor Mode View

/// Editor mode view - Single SQL editor with result panel below
struct EditorModeView: View {
  @Bindable var viewModel: NotebookViewModel
  @Bindable private var appSettings = AppSettings.shared
  @Environment(\.colorScheme) private var colorScheme
  @State private var textViewRef: SQLTextView?
  @State private var isFocused: Bool = false
  @State private var dividerPosition: CGFloat = 0.5  // 50% initial split
  @State private var isErrorCopied: Bool = false

  /// Width of the line number gutter
  private let gutterWidth: CGFloat = 44

  // MARK: - State Accessors (for extensions)

  func getAppSettings() -> AppSettings {
    appSettings
  }

  func getIsErrorCopied() -> Bool {
    isErrorCopied
  }

  func setIsErrorCopied(_ value: Bool) {
    isErrorCopied = value
  }

  // MARK: - Computed Properties

  // MARK: - Body

  var body: some View {
    SizeReader { containerSize in
      let totalHeight = max(containerSize.height, 1)  // Ensure non-zero
      let minPanelHeight: CGFloat = 250  // Increased from 150 to 250
      let maxEditorHeight = max(totalHeight - minPanelHeight, minPanelHeight)

      // Calculate actual heights based on divider position
      let editorHeight = max(minPanelHeight, min(maxEditorHeight, totalHeight * dividerPosition))
      let resultHeight = max(totalHeight - editorHeight, 0)  // Ensure non-negative

      VStack(spacing: 0) {
        // Top: SQL Editor (with distinct background like cell editor)
        editorSection(containerSize: containerSize, editorHeight: editorHeight)

        // Draggable divider
        ResizableDivider(
          position: $dividerPosition,
          totalHeight: totalHeight,
          minTopHeight: minPanelHeight,
          minBottomHeight: minPanelHeight
        )

        // Bottom: Result Panel
        resultSection(containerSize: containerSize, resultHeight: resultHeight)
      }
    }
    .onChange(of: textViewRef) { _, newValue in
      viewModel.editorTextView = newValue
    }
    .onChange(of: viewModel.editorResult?.timestamp) { _, _ in
      // When result timestamp changes (new query executed), reset divider to 50%
      // This ensures result panel always starts at 50% height after query execution
      withAnimation(.easeInOut(duration: 0.3)) {
        dividerPosition = 0.5
      }
    }
  }

  // MARK: - Editor Section

  @ViewBuilder
  private func editorSection(containerSize: CGSize, editorHeight: CGFloat) -> some View {
    ZStack(alignment: .bottomTrailing) {
      HStack(spacing: 0) {
        // Line numbers gutter (conditionally shown based on settings)
        if appSettings.showLineNumbers {
          LineNumberGutterView(
            text: viewModel.editorContent,
            textView: textViewRef,
            gutterWidth: gutterWidth
          )
          .frame(width: gutterWidth, height: editorHeight)
        }

        // SQL Editor
        SQLEditorView(
          content: $viewModel.editorContent,
          isSelected: true,
          isFocused: isFocused,
          onFocus: { isFocused = true },
          onTextChanged: { viewModel.onDocumentChanged?() },
          textViewRef: $textViewRef,
          autocompleteProvider: viewModel.autocompleteProvider,
          viewModelId: viewModel.id,
          maxHeight: editorHeight - Spacing.sm * 2,  // Account for padding
          isEditorMode: true,  // Remove border and focus effects
          wordWrapEnabled: appSettings.wordWrapEnabled
        )
      }

      // Floating toggle for syntax highlighting
      SyntaxHighlightToggleButton()
        .padding(.trailing, Spacing.lg)
        .padding(.bottom, Spacing.md)
    }
    .background(Color.inputBackground)
    .frame(width: containerSize.width, height: editorHeight)
  }

  // MARK: - Result Section

  @ViewBuilder
  private func resultSection(containerSize: CGSize, resultHeight: CGFloat) -> some View {
    if let result = viewModel.editorResult {
      VStack(alignment: .leading, spacing: 0) {
        // Header at top
        resultPanelHeader(result: result)

        // Result table or error
        if let error = result.error {
          errorView(error: error)
            .frame(maxHeight: .infinity)
        } else if result.rows.isEmpty && result.columns.isEmpty {
          emptyResultView()
        } else {
          resultTableSection(result: result)
        }

        // Footer at bottom (shows source query)
        resultPanelFooter(result: result)
      }
      .frame(width: containerSize.width, height: resultHeight)
    } else {
      // Empty state
      emptyStateView()
        .frame(width: containerSize.width, height: resultHeight)
    }
  }

  /// Empty result view (no rows and no columns)
  @ViewBuilder
  private func emptyResultView() -> some View {
    VStack(spacing: Spacing.sm) {
      Spacer()
      Image(systemName: "tray")
        .font(.system(size: 28))
        .foregroundColor(.foregroundSubtle)
      Text("No result")
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(.foregroundMuted)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Result table section
  @ViewBuilder
  private func resultTableSection(result: CellResult) -> some View {
    EditorResultGridView(result: result, viewModel: viewModel)
      .frame(maxWidth: .infinity, maxHeight: .infinity)  // Fill the panel; the grid scrolls
      .id(result.timestamp)  // New result: reset sort and search match
  }

  /// Empty state view (no results yet)
  @ViewBuilder
  private func emptyStateView() -> some View {
    VStack(spacing: Spacing.sm) {
      Spacer()
      Text("No results yet")
        .font(.system(size: 14))
        .foregroundColor(.foregroundSubtle)
      Text("Run a query to see results")
        .font(.system(size: 12))
        .foregroundColor(.foregroundMuted)
      Spacer()
    }
  }
}

// MARK: - Previews

#Preview("Empty State") {
  let viewModel = NotebookViewModel()
  viewModel.viewMode = .editor
  viewModel.editorContent = "SELECT * FROM users\nWHERE status = 'active'\nLIMIT 10;"
  return EditorModeView(viewModel: viewModel)
    .frame(width: 800, height: 600)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}

#Preview("With Result") {
  let viewModel = NotebookViewModel()
  viewModel.viewMode = .editor
  viewModel.editorContent = "SELECT id, name, email, status\nFROM users\nLIMIT 4;"
  viewModel.editorResult = CellResult(
    columns: [
      ColumnInfo(name: "id", type: "INTEGER"),
      ColumnInfo(name: "name", type: "VARCHAR"),
      ColumnInfo(name: "email", type: "VARCHAR"),
      ColumnInfo(name: "status", type: "VARCHAR"),
    ],
    rows: [
      [.int(1), .string("Alice"), .string("alice@example.com"), .string("Active")],
      [.int(2), .string("Bob"), .string("bob@example.com"), .string("Inactive")],
      [.int(3), .string("Charlie"), .string("charlie@example.com"), .string("Active")],
      [.int(4), .string("Diana"), .string("diana@example.com"), .string("Active")],
    ],
    executionTime: 0.045,
    rowCount: 4,
    timestamp: Date(),
    sourceQuery: "SELECT id, name, email, status FROM users LIMIT 4"
  )
  return EditorModeView(viewModel: viewModel)
    .frame(width: 800, height: 600)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}

#Preview("With Error") {
  let viewModel = NotebookViewModel()
  viewModel.viewMode = .editor
  viewModel.editorContent = "SELECT invalid_column FROM users;"
  viewModel.editorResult = CellResult(
    columns: [],
    rows: [],
    executionTime: 0.003,
    rowCount: 0,
    timestamp: Date(),
    error:
      "ERROR: column \"invalid_column\" does not exist\nLINE 1: SELECT invalid_column FROM users;\n               ^",
    sourceQuery: "SELECT invalid_column FROM users"
  )
  return EditorModeView(viewModel: viewModel)
    .frame(width: 800, height: 600)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
