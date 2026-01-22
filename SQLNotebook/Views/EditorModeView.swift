//
//  EditorModeView.swift
//  SQLNotebook
//

import SwiftUI

/// Editor mode view - Single SQL editor with result panel below
struct EditorModeView: View {
  @Bindable var viewModel: NotebookViewModel
  @Bindable private var appSettings = AppSettings.shared
  @State private var textViewRef: SQLTextView?
  @State private var isFocused: Bool = false
  @State private var dividerPosition: CGFloat = 0.5  // 50% initial split
  @State private var isQueryCopied: Bool = false
  @State private var isErrorCopied: Bool = false

  /// Width of the line number gutter
  private let gutterWidth: CGFloat = 44

  var body: some View {
    GeometryReader { geometry in
      let totalHeight = geometry.size.height
      let minPanelHeight: CGFloat = 250  // Increased from 150 to 250
      let maxEditorHeight = totalHeight - minPanelHeight

      // Calculate actual heights based on divider position
      let editorHeight = max(minPanelHeight, min(maxEditorHeight, totalHeight * dividerPosition))
      let resultHeight = totalHeight - editorHeight

      VStack(spacing: 0) {
        // Top: SQL Editor (with distinct background like cell editor)
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
            textViewRef: $textViewRef,
            autocompleteProvider: viewModel.autocompleteProvider,
            maxHeight: editorHeight - Spacing.sm * 2,  // Account for padding
            isEditorMode: true,  // Remove border and focus effects
            wordWrapEnabled: appSettings.wordWrapEnabled
          )
        }
        .background(Color.inputBackground)
        .frame(width: geometry.size.width, height: editorHeight)

        // Draggable divider
        ResizableDivider(
          position: $dividerPosition,
          totalHeight: totalHeight,
          minTopHeight: minPanelHeight,
          minBottomHeight: minPanelHeight
        )

        // Bottom: Result Panel
        if let result = viewModel.editorResult {
          VStack(alignment: .leading, spacing: 0) {
            // Header at top
            resultPanelHeader(result: result)

            // Result table or error
            if let error = result.error {
              errorView(error: error)
                .frame(maxHeight: .infinity)
            } else {
              VStack(alignment: .leading, spacing: 0) {
                ResultTableView(
                  result: result,
                  viewModel: viewModel,
                  cellId: nil,  // No cell ID in editor mode
                  showBorderRadius: false,  // No border radius in editor mode
                  enableVerticalScrolling: true  // Enable vertical scrolling in editor mode
                )
                .frame(maxHeight: .infinity)  // Fill available space and enable scrolling
              }
            }

            // Footer at bottom (shows source query)
            resultPanelFooter(result: result)
          }
          .frame(width: geometry.size.width, height: resultHeight)
        } else {
          // Empty state
          VStack {
            Spacer()
            Text("No results yet")
              .font(.system(size: 14))
              .foregroundColor(.foregroundSubtle)
            Text("Run a query to see results")
              .font(.system(size: 12))
              .foregroundColor(.foregroundMuted)
            Spacer()
          }
          .frame(width: geometry.size.width, height: resultHeight)
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

  // MARK: - Result Panel Header

  /// Creates the header bar for the result panel.
  ///
  /// Displays query execution metadata and actions:
  /// - Success/error indicator icon
  /// - Row count and execution time (for successful queries)
  /// - Clear result button
  ///
  /// The header is positioned at the top of the result panel with a bottom border.
  ///
  /// - Parameter result: The query result containing metadata and optional error
  /// - Returns: A view with query result metadata and action buttons
  private func resultPanelHeader(result: CellResult) -> some View {
    HStack {
      // Result info
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
          // Show row count and execution time for success
          Text("\(result.rowCount) row\(result.rowCount == 1 ? "" : "s")")
            .font(.system(size: 12))
            .foregroundColor(.foregroundSubtle)

          Text("•")
            .foregroundColor(.foregroundMuted)

          Text(String(format: "%.2fs", result.executionTime))
            .font(.system(size: 12))
            .foregroundColor(.foregroundSubtle)
        }
      }

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

  private func copyQueryToClipboard(query: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(query, forType: .string)

    // Show checkmark feedback
    isQueryCopied = true

    // Reset back to copy icon after 1 second
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      isQueryCopied = false
    }
  }
  
  private func copyErrorToClipboard(error: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(error, forType: .string)
    
    // Show checkmark feedback
    isErrorCopied = true
    
    // Reset back to copy icon after 500ms
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      isErrorCopied = false
    }
  }

  // MARK: - Result Panel Footer

  /// Creates the footer bar for the result panel showing the source query.
  ///
  /// Displays the query that was executed with click-to-copy functionality:
  /// - Icon changes from "wallet.pass" to "checkmark.circle.fill" when copied
  /// - Long queries are truncated with "..." for better UI
  /// - Click anywhere on footer to copy the query
  ///
  /// - Parameter result: The query result containing sourceQuery
  /// - Returns: A view with clickable query text, or nil if no sourceQuery
  @ViewBuilder
  private func resultPanelFooter(result: CellResult) -> some View {
    if let sourceQuery = result.sourceQuery {
      HStack(spacing: Spacing.xs) {
        // Icon changes when query is copied (fixed width to prevent text shifting)
        Image(systemName: isQueryCopied ? "checkmark.circle.fill" : "wallet.pass")
          .font(.system(size: 11))
          .foregroundColor(isQueryCopied ? .success : .foregroundMuted)
          .frame(width: 11, alignment: .center)

        Text("Run with query (click to copy):")
          .font(.system(size: 11))
          .foregroundColor(.foregroundMuted)

        Text(sourceQuery)
          .font(.system(size: 11, design: .monospaced))
          .foregroundColor(.foregroundSubtle)
          .lineLimit(1)
          .truncationMode(.tail)
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
      .onTapGesture {
        copyQueryToClipboard(query: sourceQuery)
      }
      .cursor(NSCursor.pointingHand)
      .help(isQueryCopied ? "Copied!" : "Click to copy query")
    }
  }

  private func errorView(error: String) -> some View {
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
        Image(systemName: isErrorCopied ? "checkmark" : "doc.on.doc")
          .font(.system(size: 12))
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(FloatingPanelButtonStyle())
      .help("Copy error message")
      .padding(.top, Spacing.sm)
      .padding(.trailing, Spacing.sm)
    }
  }

  // MARK: - Actions

  private func clearResult() {
    viewModel.editorResult = nil
  }
}

// MARK: - Resizable Divider

/// A draggable horizontal divider for resizing split-view panels.
///
/// Features:
/// - Drag to resize panels with smooth animation
/// - Double-click to reset to 50/50 split
/// - Hover indicator for visual feedback
/// - Optimized hit area (8pt) to avoid overlapping with adjacent UI elements
///
/// The hit area extends **upward** (-3.5pt offset) to prevent interference with
/// the result panel header positioned below the divider.
///
/// Example:
/// ```swift
/// ResizableDivider(
///   position: $dividerPosition,
///   totalHeight: geometry.height,
///   minTopHeight: 250,
///   minBottomHeight: 250
/// )
/// ```
struct ResizableDivider: View {
  /// Position of divider as ratio (0.0 = top, 1.0 = bottom)
  @Binding var position: CGFloat

  /// Total height of the container
  let totalHeight: CGFloat

  /// Minimum height for top panel (prevents collapse)
  let minTopHeight: CGFloat

  /// Minimum height for bottom panel (prevents collapse)
  let minBottomHeight: CGFloat

  @State private var isDragging = false
  @State private var isHovering = false

  var body: some View {
    Rectangle()
      .fill(Color.border)
      .frame(height: 1)
      .background(
        // Invisible hit area for better UX - extends upward only to avoid blocking result header
        Rectangle()
          .fill(Color.clear)
          .frame(height: 8)
          .offset(y: -3.5)  // Shift up so hit area doesn't overlap with result header below
          .contentShape(Rectangle())
      )
      .background(
        // Hover indicator
        Rectangle()
          .fill(
            isDragging
              ? Color.accent.opacity(0.3) : (isHovering ? Color.accent.opacity(0.1) : Color.clear)
          )
          .frame(height: 8)
          .offset(y: -3.5)  // Match hit area position
      )
      .cursor(NSCursor.resizeUpDown)
      .onHover { hovering in
        isHovering = hovering
      }
      .onTapGesture(count: 2) {
        // Double-click to reset to 50/50
        withAnimation(.easeInOut(duration: 0.2)) {
          position = 0.5
        }
      }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            isDragging = true
            let newHeight = totalHeight * position + value.translation.height
            let maxTop = totalHeight - minBottomHeight
            let minTop = minTopHeight

            // Clamp the new height
            let clampedHeight = max(minTop, min(maxTop, newHeight))
            position = clampedHeight / totalHeight
          }
          .onEnded { _ in
            isDragging = false
          }
      )
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
