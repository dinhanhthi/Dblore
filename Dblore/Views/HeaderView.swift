//
//  HeaderView.swift
//  Dblore
//

import SwiftUI

struct HeaderView: View {
  @Bindable var viewModel: NotebookViewModel
  @Environment(WorkspaceManager.self) private var workspaceManager: WorkspaceManager?
  @State private var showRunAllConfirmation = false
  @State private var showClearAllOutputsConfirmation = false
  @State private var showResultVisibilityMenu = false
  /// Run turns into Stop once the editor query has run for a second
  @State private var canStopEditorQuery = false

  var body: some View {
    HStack(spacing: Spacing.sm) {
      // Leading group - Sidebars and Cell actions
      GlassToolbarGroup {
        if viewModel.viewMode == .notebook {
          // Notebook mode buttons
          Button(action: {
            if viewModel.isFileSizeLarge {
              viewModel.showToast(
                "File size limit exceeded. Please create a new notebook or remove old results to continue adding cells.",
                type: .error
              )
            } else {
              viewModel.addCell(type: .sql)
            }
          }) {
            Label("New", systemImage: "plus")
          }
          .buttonStyle(SecondaryButtonStyle())
          .linkPointer()
          .disabled(viewModel.isFileSizeLarge)
          .help("New Cell (⌘⌥N)")

          Button(action: {
            showRunAllConfirmation = true
          }) {
            Label("Run All", systemImage: "play.fill")
          }
          .buttonStyle(SecondaryButtonStyle())
          .linkPointer()
          .disabled(!viewModel.connectionState.isConnected)
          .help("Run All Cells")
          .confirmationDialog(
            "Run all cells?",
            isPresented: $showRunAllConfirmation,
            titleVisibility: .visible
          ) {
            Button("Run All Cells", role: .none) {
              Task { @MainActor [viewModel] in await viewModel.runAllCells() }
            }
            Button("Cancel", role: .cancel) {}
          } message: {
            Text("This will execute all cells in sequence. Existing results will be replaced.")
          }
          .confirmationDialog(
            runAllDestructiveDialogTitle,
            isPresented: Binding(
              get: { viewModel.queryConfirmationState.showRunAllConfirmation },
              set: { viewModel.queryConfirmationState.showRunAllConfirmation = $0 }
            ),
            titleVisibility: .visible
          ) {
            Button("Allow", role: .destructive) {
              Task { @MainActor [viewModel] in
                await viewModel.executeRunAllCellsWithDestructive()
              }
            }
            Button("Don't Allow", role: .none) {
              Task { @MainActor [viewModel] in
                await viewModel.executeRunAllCellsSkipDestructive()
              }
            }
            Button("Cancel", role: .cancel) {
              viewModel.cancelRunAllCells()
            }
          } message: {
            Text(runAllDestructiveDialogMessage)
          }

          Button(action: {
            showClearAllOutputsConfirmation = true
          }) {
            Label("Clear All Outputs", systemImage: "trash")
          }
          .buttonStyle(SecondaryButtonStyle())
          .linkPointer()
          .help("Clear All Outputs")
          .confirmationDialog(
            "Clear all outputs?",
            isPresented: $showClearAllOutputsConfirmation,
            titleVisibility: .visible
          ) {
            Button("Clear All Outputs", role: .destructive) {
              viewModel.clearAllOutputs()
            }
            Button("Cancel", role: .cancel) {}
          } message: {
            Text("This will remove all query results from all cells. This action can be undone.")
          }

          Menu {
            Button(action: { viewModel.hideAllResults() }) {
              Label("Hide All Results", systemImage: "eye.slash")
            }

            Button(action: { viewModel.showAllResults() }) {
              Label("Show All Results", systemImage: "eye")
            }
          } label: {
            Label("Results", systemImage: "eye")
          }
          .glassButtonStyle()
          // A Menu bezel ignores label padding and stays 24pt. `.large` is 28pt,
          // in line with the secondary buttons beside it, and it keeps the 13pt label.
          .controlSize(.large)
          .linkPointer()
          .help("Show/Hide Results")
        } else if viewModel.viewMode == .editor && viewModel.dataViewer == nil {
          // Editor mode: while a query runs, Run keeps its label and shows a spinner; it is
          // disabled for the first second, then a click stops the query (after confirmation)
          Button(action: {
            if viewModel.isEditorQueryRunning {
              viewModel.cancelEditorQuery()
            } else {
              Task { @MainActor [viewModel] in
                await viewModel.runEditorQuery()
              }
            }
          }) {
            Label {
              Text("Run")
            } icon: {
              if viewModel.isEditorQueryRunning {
                RunSpinner()
              } else {
                Image(systemName: "play.fill")
              }
            }
          }
          // Flat accent fill and white label, same paint as the selected sidebar tab.
          // glassProminent tints the glass material, so the fill reads lighter than Color.accent.
          // Spacing.xs is 2pt shorter per side than a regular primary button. editorHeaderHeight
          // drops by the same amount so the gap around Run stays put.
          .buttonStyle(PrimaryButtonStyle(vPadding: Spacing.xs, labelColor: .white))
          .linkPointer()
          .disabled(
            viewModel.isEditorQueryRunning
              ? !canStopEditorQuery
              : viewModel.editorContent.isEmpty || !viewModel.connectionState.isConnected
          )
          .help(
            viewModel.isEditorQueryRunning
              ? "Stop the running query (the connection is reset)" : editorRunButtonHelp
          )
          .task(id: viewModel.isEditorQueryRunning) {
            canStopEditorQuery = false
            guard viewModel.isEditorQueryRunning else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { canStopEditorQuery = true }
          }
        }
      }
      // Capsule shape for every header button (notebook and editor modes)
      .buttonBorderShape(.capsule)

      if viewModel.dataViewer != nil {
        DataViewerControls(viewModel: viewModel)
      }

      Spacer()

      // Trailing group - Search (common to both modes)
      // Note: Settings button removed - use menu bar (Dblore > Settings) or Cmd+,
      // Safety badge sits outside the glass group so it does not merge with the Search button
      if viewModel.connectionState.isConnected,
        let config = workspaceManager?.workspace.connectionConfig
      {
        safetyBadge(ConnectionSafetyBadge(config: config))
      }

      // Refresh and Search sit close together, tighter than the header's spacing
      HStack(spacing: Spacing.xxs) {
        if viewModel.dataViewer != nil {
          // Data viewer: Refresh reloads the page and the row count; Stop works like Run's
          Button(action: {
            if viewModel.isEditorQueryRunning {
              viewModel.cancelEditorQuery()
            } else {
              Task { @MainActor [viewModel] in
                await viewModel.refreshDataViewer()
              }
            }
          }) {
            if viewModel.isEditorQueryRunning {
              RunSpinner()
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .buttonStyle(GhostButtonStyle(iconOnly: true))
          .disabled(
            viewModel.isEditorQueryRunning
              ? !canStopEditorQuery : !viewModel.connectionState.isConnected
          )
          .help(
            viewModel.isEditorQueryRunning
              ? "Stop the running query (the connection is reset)" : "Reload this page (⌘R)"
          )
          .task(id: viewModel.isEditorQueryRunning) {
            canStopEditorQuery = false
            guard viewModel.isEditorQueryRunning else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { canStopEditorQuery = true }
          }

          // Filter rows: toggles the filter form in the right sidebar
          let isFilterShown =
            viewModel.isRightSidebarVisible && viewModel.rightSidebarContent == .tableFilter
          Button(action: {
            if isFilterShown {
              viewModel.closeSidebar()
            } else {
              viewModel.prepareFilterDraft()
              viewModel.showSidebar(content: .tableFilter)
            }
          }) {
            Image(systemName: "line.3.horizontal.decrease")
          }
          .buttonStyle(
            GhostButtonStyle(
              isActive: isFilterShown || !(viewModel.dataViewer?.filter.isEmpty ?? true),
              iconOnly: true)
          )
          .overlay(alignment: .bottomTrailing) {
            if !(viewModel.dataViewer?.filter.isEmpty ?? true) {
              Circle().fill(Color.accent).frame(width: 5, height: 5).padding(4)
                .allowsHitTesting(false)
            }
          }
          .help("Filter rows")

          // Highlight rows: toggles the highlight form in the right sidebar
          let isHighlightShown =
            viewModel.isRightSidebarVisible && viewModel.rightSidebarContent == .tableHighlight
          Button(action: {
            if isHighlightShown {
              viewModel.closeSidebar()
            } else {
              viewModel.prepareHighlightDraft()
              viewModel.showSidebar(content: .tableHighlight)
            }
          }) {
            Image(systemName: "highlighter")
          }
          .buttonStyle(
            GhostButtonStyle(
              isActive: isHighlightShown || !(viewModel.dataViewer?.highlight.isEmpty ?? true),
              iconOnly: true)
          )
          .overlay(alignment: .bottomTrailing) {
            if !(viewModel.dataViewer?.highlight.isEmpty ?? true) {
              Circle().fill(Color.accent).frame(width: 5, height: 5).padding(4)
                .allowsHitTesting(false)
            }
          }
          .help("Highlight rows")
        }

        // Layout toggle: editor/result stacked (top/bottom) or side by side (left/right)
        if viewModel.viewMode == .editor && viewModel.dataViewer == nil {
          Button(action: { viewModel.isEditorSideBySide.toggle() }) {
            Image(
              systemName: viewModel.isEditorSideBySide
                ? "rectangle.split.2x1" : "rectangle.split.1x2")
          }
          .buttonStyle(GhostButtonStyle(iconOnly: true))
          .help(
            viewModel.isEditorSideBySide
              ? "Stack editor above result" : "Place editor beside result")
        }

        // Search button (same square style as the schema visualizer's search button)
        Button(action: {
          viewModel.openSearch()
        }) {
          Image(systemName: "magnifyingglass")
        }
        .buttonStyle(GhostButtonStyle(isActive: viewModel.isSearchPanelVisible, iconOnly: true))
        .help("Search (⌘F)")
      }
    }
    .padding(.horizontal, Spacing.sm)
    .frame(height: headerBarHeight)
    .background(Color.appBackground)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  /// Notebook and data-viewer bars stay fixed. The SQL editor bar follows the shorter Run button.
  private var headerBarHeight: CGFloat {
    if viewModel.dataViewer != nil { return ComponentSize.compactHeaderHeight }
    if viewModel.viewMode == .editor { return Self.editorHeaderHeight }
    return ComponentSize.headerHeight
  }

  /// Run uses `Spacing.xs` vertical padding, 2pt less per side than a regular primary button.
  private static var editorHeaderHeight: CGFloat {
    let shrink = (ButtonMetrics.regularVerticalPadding - Spacing.xs) * 2
    return ComponentSize.headerHeight - shrink
  }

  // MARK: - Safety Badge

  /// Protection state and SSL state at a glance; tinted by the SSL level
  private func safetyBadge(_ badge: ConnectionSafetyBadge) -> some View {
    let sslColor = badge.ssl.map { color(for: $0.level) } ?? .foregroundMuted
    return HStack(spacing: Spacing.xs) {
      Image(systemName: badge.protectionIcon)
        .font(.system(size: 10))
      Text(badge.protectionLabel)
      if let ssl = badge.ssl {
        Image(systemName: "circle.fill")
          .font(.system(size: 6))
          .foregroundColor(sslColor)
        Text(ssl.label)
      }
    }
    .font(.small)
    .foregroundColor(.foreground)
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .tintedCapsuleGlass(sslColor, interactive: false)
    .help(badge.tooltip)
    .accessibilityElement(children: .combine)
  }

  private func color(for level: ConnectionSafetyBadge.Level) -> Color {
    switch level {
    case .danger: return .destructive
    case .warning: return .warning
    case .ok: return .success
    }
  }

  // MARK: - Help Text

  private var editorRunButtonHelp: String {
    if AppSettings.shared.editorSimpleMode {
      return "Run query (⌘R / ⌘Enter) - runs selection, or query at cursor"
    } else {
      return "Run query (⌘R / ⌘Enter) - runs selection, or entire file"
    }
  }

  // MARK: - Run All Destructive Dialog

  private var runAllDestructiveDialogTitle: String {
    let cells = viewModel.queryConfirmationState.runAllConfirmCells
    if cells.contains(where: \.isSafetyCritical) {
      return "Run All changes session safety settings"
    }
    let cellWord = cells.count == 1 ? "cell" : "cells"
    return "Run All contains \(cells.count) \(cellWord) that may modify your database"
  }

  private var runAllDestructiveDialogMessage: String {
    let cells = viewModel.queryConfirmationState.runAllConfirmCells
    return """
      \(NotebookViewModel.runAllSummary(cells))

      • Allow: Execute all cells
      • Don't Allow: Skip the cells listed above and run the rest
      """
  }
}

/// Three-quarter circle spinning in place of the Run icon while a query runs
private struct RunSpinner: View {
  @State private var isSpinning = false

  var body: some View {
    Circle()
      .trim(from: 0, to: 0.75)
      .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
      .frame(width: 10, height: 10)
      .rotationEffect(.degrees(isSpinning ? 360 : 0))
      .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isSpinning)
      // Opt out of the app-wide animation kill switch so the spinner keeps rotating
      .transaction { $0.disablesAnimations = false }
      .onAppear { isSpinning = true }
  }
}

// SafeModeIndicator moved to Components/Shared/SafeModeIndicator.swift

#Preview {
  HeaderView(viewModel: NotebookViewModel())
    .frame(width: 850)
    .preferredColorScheme(.dark)
}
