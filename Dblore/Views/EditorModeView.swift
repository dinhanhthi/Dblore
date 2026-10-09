//
//  EditorModeView.swift
//  Dblore
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
  /// Grid / Chart for the editor result. A new result (different timestamp) reads as Grid.
  @State private var resultDisplayMode: ResultDisplayMode = .grid
  @State private var resultDisplayModeStamp: Date?
  /// Plan / Raw for an EXPLAIN result. A new result reads as Plan.
  @State private var explainDisplayMode: ExplainDisplayMode = .plan
  @State private var explainDisplayModeStamp: Date?
  /// Object source tab: the routine or trigger shown read-only. Nil on other tabs.
  var objectSource: ObjectSourceRef?
  /// Read the object source again (Retry after a failed read, or Refresh)
  var onRetrySource: (() -> Void)?
  /// Open the loaded source in a new untitled SQL tab
  var onOpenEditableCopy: (() -> Void)?

  /// Width of the line number gutter: the widest line number in the gutter face (one point
  /// under the editor font) plus 8pt padding on each side; at least 2 digits wide
  private var gutterWidth: CGFloat {
    let lineCount = viewModel.editorContent.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
    let digits = max(String(lineCount).count, 2)
    let font = NSFont.monospacedSystemFont(
      ofSize: AppSettings.editorGutterFontSize(for: appSettings.editorFontSize), weight: .regular)
    let digitWidth = ceil(("0" as NSString).size(withAttributes: [.font: font]).width)
    return CGFloat(digits) * digitWidth + 16
  }

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

  /// Binding shared by the result header and the grid. A different result timestamp reads as Grid
  /// until the user picks a mode for that result.
  func resultDisplayModeBinding(for result: CellResult) -> Binding<ResultDisplayMode> {
    Binding(
      get: {
        resultDisplayModeStamp == result.timestamp ? resultDisplayMode : .grid
      },
      set: { newValue in
        resultDisplayModeStamp = result.timestamp
        resultDisplayMode = newValue
      }
    )
  }

  /// Binding shared by the result header and the plan view. A different result reads as Plan.
  func explainDisplayModeBinding(for result: CellResult) -> Binding<ExplainDisplayMode> {
    Binding(
      get: {
        explainDisplayModeStamp == result.timestamp ? explainDisplayMode : .plan
      },
      set: { newValue in
        explainDisplayModeStamp = result.timestamp
        explainDisplayMode = newValue
      }
    )
  }

  // MARK: - Computed Properties

  // MARK: - Body

  var body: some View {
    if viewModel.isReadOnlySource {
      readOnlySourceBody
    } else {
      editorAndResultBody
    }
  }

  /// Object source tab: banner over a read-only editor. No result pane, nothing runs.
  private var readOnlySourceBody: some View {
    VStack(spacing: 0) {
      ObjectSourceBanner(
        ref: objectSource,
        state: viewModel.objectSourceLoad,
        source: viewModel.editorContent,
        onOpenEditableCopy: onOpenEditableCopy,
        onRefresh: onRetrySource
      )
      Divider()
      switch viewModel.objectSourceLoad {
      case .loading:
        ObjectSourceStatusView(message: "Loading source…", isLoading: true, onRetry: nil)
      case .failed(let message):
        ObjectSourceStatusView(message: message, isLoading: false, onRetry: onRetrySource)
      case .idle, .loaded, .unavailable:
        SizeReader { containerSize in
          editorSection(
            width: containerSize.width, height: containerSize.height, isReadOnly: true)
        }
      }
    }
    .onChange(of: textViewRef) { _, newValue in
      viewModel.editorTextView = newValue
    }
  }

  private var editorAndResultBody: some View {
    SizeReader { containerSize in
      let totalLength = max(
        viewModel.isEditorSideBySide ? containerSize.width : containerSize.height, 1)
      let minPanelLength: CGFloat = 250
      let maxEditorLength = max(totalLength - minPanelLength, minPanelLength)

      // Calculate actual sizes (height when stacked, width when side by side) from divider position
      let editorLength = max(minPanelLength, min(maxEditorLength, totalLength * dividerPosition))
      let resultLength = max(totalLength - editorLength, 0)  // Ensure non-negative
      let otherLength = viewModel.isEditorSideBySide ? containerSize.height : containerSize.width

      let editor = editorSection(
        width: viewModel.isEditorSideBySide ? editorLength : otherLength,
        height: viewModel.isEditorSideBySide ? otherLength : editorLength)
      let divider = ResizableDivider(
        position: $dividerPosition,
        axis: viewModel.isEditorSideBySide ? .horizontal : .vertical,
        totalHeight: totalLength,
        minTopHeight: minPanelLength,
        minBottomHeight: minPanelLength
      )
      let result = resultSection(
        width: viewModel.isEditorSideBySide ? resultLength : otherLength,
        height: viewModel.isEditorSideBySide ? otherLength : resultLength)

      if viewModel.isEditorSideBySide {
        HStack(spacing: 0) {
          editor
          divider
          result
        }
      } else {
        VStack(spacing: 0) {
          // Top: SQL Editor (with distinct background like cell editor)
          editor
          // Draggable divider
          divider
          // Bottom: Result Panel
          result
        }
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
  private func editorSection(
    width: CGFloat, height editorHeight: CGFloat, isReadOnly: Bool = false
  ) -> some View {
    ZStack(alignment: .bottomTrailing) {
      HStack(spacing: 0) {
        // Line numbers gutter (conditionally shown based on settings)
        if appSettings.showLineNumbers {
          LineNumberGutterView(
            text: viewModel.editorContent,
            textView: textViewRef,
            gutterWidth: gutterWidth,
            editorFontSize: appSettings.editorFontSize
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
          autocompleteProvider: isReadOnly ? nil : viewModel.autocompleteProvider,
          viewModelId: viewModel.id,
          maxHeight: editorHeight - Spacing.sm * 2,  // Account for padding
          isEditorMode: true,  // Remove border and focus effects
          wordWrapEnabled: appSettings.wordWrapEnabled,
          dialect: viewModel.notebook.connectionConfig?.databaseType.dialect ?? .postgresql,
          isEditable: !isReadOnly
        )
      }

      // Floating format button and syntax highlighting toggle. Format rewrites the text, so a
      // read-only source has only the toggle.
      HStack(spacing: Spacing.xs) {
        if !isReadOnly {
          FormatSQLButton(textView: textViewRef)
        }
        SyntaxHighlightToggleButton()
      }
      .padding(.trailing, Spacing.lg)
      .padding(.bottom, Spacing.md)
    }
    .background(Color.inputBackground)
    .frame(width: width, height: editorHeight)
  }

  // MARK: - Result Section

  @ViewBuilder
  private func resultSection(width: CGFloat, height resultHeight: CGFloat) -> some View {
    if let result = viewModel.editorResult {
      VStack(alignment: .leading, spacing: 0) {
        // Header at top
        resultPanelHeader(result: result)

        // Result table or error
        if let error = result.error {
          errorView(error: error)
            .frame(maxHeight: .infinity)
        } else if viewModel.isEditorComparing {
          ResultComparePanel(
            pin: viewModel.editorPinnedResult,
            current: result,
            comparison: viewModel.displayedEditorComparison,
            pinNote: Self.editorPinNote,
            dialect: viewModel.sqlDialect,
            fillsAvailableHeight: true
          )
          .padding(Spacing.sm)
        } else if result.rows.isEmpty && result.columns.isEmpty {
          emptyResultView()
        } else {
          resultTableSection(result: result, displayMode: resultDisplayModeBinding(for: result))
        }

        // Footer at bottom (shows source query)
        resultPanelFooter(result: result)
      }
      .frame(width: width, height: resultHeight)
    } else {
      // Empty state
      emptyStateView()
        .frame(width: width, height: resultHeight)
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
  private func resultTableSection(
    result: CellResult, displayMode: Binding<ResultDisplayMode>
  ) -> some View {
    EditorResultGridView(
      result: result, viewModel: viewModel, displayMode: displayMode, showsDisplayPicker: false,
      explainMode: explainDisplayModeBinding(for: result), showsExplainPicker: false
    )
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

// MARK: - Object Source Banner

/// Slim bar over a read-only routine or trigger source: kind, qualified name, a Read-only
/// badge, and the copy actions. The actions wait for the source to load.
private struct ObjectSourceBanner: View {
  let ref: ObjectSourceRef?
  let state: ObjectSourceLoadState
  let source: String
  let onOpenEditableCopy: (() -> Void)?
  let onRefresh: (() -> Void)?

  @State private var isCopied = false

  var body: some View {
    HStack(spacing: Spacing.sm) {
      if let ref {
        Image(systemName: ref.kind.iconName)
          .font(.system(size: 12))
          .foregroundColor(.accent)
        Text(ref.kind.displayName)
          .font(.small)
          .foregroundColor(.foregroundMuted)
        Text(ref.qualifiedName)
          .font(.monoMedium)
          .foregroundColor(.foreground)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(ref.qualifiedName)
      }

      readOnlyBadge

      Spacer(minLength: Spacing.sm)

      Button(action: { onRefresh?() }) {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .buttonStyle(SecondaryButtonStyle(vPadding: Spacing.xs))
      .linkPointer()
      .disabled((state != .loaded && state != .unavailable) || onRefresh == nil)
      .help("Read the source again from the database")

      Button(action: { onOpenEditableCopy?() }) {
        Label("Open as editable copy", systemImage: "square.and.pencil")
      }
      .buttonStyle(SecondaryButtonStyle(vPadding: Spacing.xs))
      .linkPointer()
      .disabled(state != .loaded || onOpenEditableCopy == nil)
      .help("Open this source in a new untitled SQL tab")

      Button(action: copySource) {
        Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(SecondaryButtonStyle(vPadding: Spacing.xs))
      .linkPointer()
      .disabled(state != .loaded)
      .help("Copy the source")
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .frame(minHeight: ComponentSize.compactHeaderHeight)
  }

  private var readOnlyBadge: some View {
    HStack(spacing: Spacing.xxs) {
      Image(systemName: "lock")
        .font(.system(size: 9))
      Text("Read-only")
    }
    .font(.small)
    .foregroundColor(.foregroundMuted)
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xxs)
    .overlay(Capsule().stroke(Color.border, lineWidth: 1))
    .help("Source of a database object. Open an editable copy to change or run it.")
    .accessibilityElement(children: .combine)
  }

  private func copySource() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(source, forType: .string)
    isCopied = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      isCopied = false
    }
  }
}

/// Loading spinner, or a failed read's message with Retry, in place of the source editor
private struct ObjectSourceStatusView: View {
  let message: String
  let isLoading: Bool
  let onRetry: (() -> Void)?

  var body: some View {
    VStack(spacing: Spacing.md) {
      if isLoading {
        ProgressView()
          .controlSize(.small)
          .tint(.accent)
      }
      Text(message)
        .font(.labelText)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
      if let onRetry {
        Button("Retry", action: onRetry)
          .buttonStyle(SecondaryButtonStyle())
          .linkPointer()
      }
    }
    .padding(Spacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.inputBackground)
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
