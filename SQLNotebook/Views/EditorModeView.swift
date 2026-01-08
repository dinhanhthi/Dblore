//
//  EditorModeView.swift
//  SQLNotebook
//

import SwiftUI

/// Editor mode view - Single SQL editor with result panel below
struct EditorModeView: View {
  @Bindable var viewModel: NotebookViewModel
  @State private var textViewRef: SQLTextView?
  @State private var isFocused: Bool = false

  var body: some View {
    VSplitView {
      // Top: SQL Editor
      VStack(spacing: 0) {
        // Editor toolbar
        editorToolbar

        // SQL Editor
        SQLEditorView(
          content: $viewModel.editorContent,
          isSelected: true,
          isFocused: isFocused,
          onFocus: { isFocused = true },
          textViewRef: $textViewRef,
          autocompleteProvider: viewModel.autocompleteProvider
        )
        .frame(minHeight: 200)
      }
      .frame(maxWidth: .infinity)

      // Bottom: Result Panel
      if let result = viewModel.editorResult {
        VStack(spacing: 0) {
          resultPanelHeader(result: result)

          // Result table or error
          if let error = result.error {
            errorView(error: error)
          } else {
            ResultTableView(
              result: result,
              viewModel: viewModel,
              cellId: nil  // No cell ID in editor mode
            )
          }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 200)
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
        .frame(maxWidth: .infinity)
        .frame(minHeight: 100)
      }
    }
    .padding(Spacing.md)
  }

  // MARK: - Toolbar

  private var editorToolbar: some View {
    HStack(spacing: Spacing.sm) {
      // Run button
      Button(action: runQuery) {
        Label("Run", systemImage: "play.fill")
          .font(.system(size: 12))
      }
      .buttonStyle(.borderedProminent)
      .tint(.accentColor)
      .keyboardShortcut(.return, modifiers: [.command, .shift])
      .disabled(viewModel.editorContent.isEmpty || viewModel.connectionState != .connected)

      // Run Selection button (placeholder for future)
      Button(action: runSelection) {
        Label("Run Selection", systemImage: "play.circle")
          .font(.system(size: 12))
      }
      .buttonStyle(.bordered)
      .disabled(viewModel.editorContent.isEmpty || viewModel.connectionState != .connected)

      Spacer()

      // Connection status
      connectionStatusBadge
    }
    .padding(Spacing.sm)
    .background(Color.appBackground)
  }

  private var connectionStatusBadge: some View {
    HStack(spacing: Spacing.xxs) {
      Circle()
        .fill(viewModel.connectionState == .connected ? Color.green : Color.gray)
        .frame(width: 6, height: 6)

      Text(viewModel.connectionState == .connected ? "Connected" : "Not Connected")
        .font(.system(size: 11))
        .foregroundColor(.foregroundSubtle)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xxs)
    .background(Color.inputBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
  }

  // MARK: - Result Panel Header

  private func resultPanelHeader(result: CellResult) -> some View {
    HStack {
      // Result info
      HStack(spacing: Spacing.sm) {
        Image(systemName: result.error != nil ? "xmark.circle.fill" : "checkmark.circle.fill")
          .foregroundColor(result.error != nil ? .red : .green)
          .font(.system(size: 12))

        if result.error == nil {
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
      alignment: .bottom
    )
  }

  private func errorView(error: String) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text("Error")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(.red)

        Text(error)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(Color.foreground)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.md)
    }
    .background(Color.red.opacity(0.05))
  }

  // MARK: - Actions

  private func runQuery() {
    guard !viewModel.editorContent.isEmpty else { return }
    Task { @MainActor in
      await viewModel.runEditorQuery()
    }
  }

  private func runSelection() {
    // TODO: Implement run selection functionality
    // For now, just run the full query
    runQuery()
  }

  private func clearResult() {
    viewModel.editorResult = nil
  }
}
