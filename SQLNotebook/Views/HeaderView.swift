//
//  HeaderView.swift
//  SQLNotebook
//

import SwiftUI

struct HeaderView: View {
  @Bindable var viewModel: NotebookViewModel
  @Environment(WorkspaceManager.self) private var workspaceManager: WorkspaceManager?
  @State private var showRunAllConfirmation = false
  @State private var showClearAllOutputsConfirmation = false
  @State private var showResultVisibilityMenu = false

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
          .buttonStyle(.glass)
          .pointerStyle(.link)
          .disabled(viewModel.isFileSizeLarge)
          .opacity(viewModel.isFileSizeLarge ? 0.5 : 1.0)
          .help("New Cell (⌘N)")

          Button(action: {
            showRunAllConfirmation = true
          }) {
            Label("Run All", systemImage: "play.fill")
          }
          .buttonStyle(.glass)
          .pointerStyle(.link)
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
            Text("This will execute all SQL cells in sequence. Existing results will be replaced.")
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
          .buttonStyle(.glass)
          .pointerStyle(.link)
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
          .buttonStyle(.glass)
          .pointerStyle(.link)
          .help("Show/Hide Results")
        } else if viewModel.viewMode == .editor {
          // Editor mode buttons: while a query runs, Run keeps its label, shows a spinner and
          // is disabled; Stop is always there so the layout never shifts
          Button(action: {
            Task { @MainActor [viewModel] in
              await viewModel.runEditorQuery()
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
          .buttonStyle(.glassProminent)
          .pointerStyle(.link)
          .tint(Color.accent)
          .disabled(
            viewModel.isEditorQueryRunning || viewModel.editorContent.isEmpty
              || !viewModel.connectionState.isConnected
          )
          .help(editorRunButtonHelp)

          // Stops the query on the server (asks first if pending changes would be discarded)
          Button(action: { viewModel.cancelEditorQuery() }) {
            Image(systemName: "stop.fill")
          }
          .buttonStyle(.glass)
          .pointerStyle(.link)
          .disabled(!viewModel.isEditorQueryRunning)
          .help("Cancel the running query (the connection is reset)")
        }
      }
      // Capsule shape for every header button (notebook and editor modes)
      .buttonBorderShape(.capsule)

      Spacer()

      // Trailing group - Search (common to both modes)
      // Note: Settings button removed - use menu bar (SQLNotebook > Settings) or Cmd+,
      // Safety badge sits outside the glass group so it does not merge with the Search button
      if viewModel.connectionState.isConnected,
        let config = workspaceManager?.workspace.connectionConfig
      {
        safetyBadge(ConnectionSafetyBadge(config: config))
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
    .padding(.horizontal, Spacing.sm)
    .frame(height: ComponentSize.headerHeight)
    .chromeGlass()
    .overlay(alignment: .bottom) {
      Divider()
    }
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
      .onAppear { isSpinning = true }
  }
}

// SafeModeIndicator moved to Components/Shared/SafeModeIndicator.swift

#Preview {
  HeaderView(viewModel: NotebookViewModel())
    .frame(width: 850)
    .preferredColorScheme(.dark)
}
