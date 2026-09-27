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
      HStack(spacing: Spacing.xs) {
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
          .buttonStyle(GhostButtonStyle())
          .disabled(viewModel.isFileSizeLarge)
          .opacity(viewModel.isFileSizeLarge ? 0.5 : 1.0)
          .help("New Cell (⌘N)")

          Button(action: {
            showRunAllConfirmation = true
          }) {
            Label("Run All", systemImage: "play.fill")
          }
          .buttonStyle(GhostButtonStyle())
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
          .buttonStyle(GhostButtonStyle())
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
          .buttonStyle(GhostButtonStyle())
          .help("Show/Hide Results")
        } else if viewModel.viewMode == .editor, viewModel.isEditorQueryRunning {
          // Stops the query on the server (asks first if pending changes would be discarded)
          Button(action: { viewModel.cancelEditorQuery() }) {
            Label("Cancel", systemImage: "stop.fill")
          }
          .buttonStyle(GhostButtonStyle())
          .help("Cancel the running query (the connection is reset)")
        } else if viewModel.viewMode == .editor {
          // Editor mode buttons
          Button(action: {
            Task { @MainActor [viewModel] in
              await viewModel.runEditorQuery()
            }
          }) {
            Label("Run", systemImage: "play.fill")
          }
          .buttonStyle(GhostButtonStyle())
          .disabled(viewModel.editorContent.isEmpty || !viewModel.connectionState.isConnected)
          .help(editorRunButtonHelp)
        }
      }

      Spacer()

      // Trailing group - Search (common to both modes)
      // Note: Settings button removed - use menu bar (SQLNotebook > Settings) or Cmd+,
      HStack(spacing: Spacing.sm) {
        // Search button
        Button(action: {
          viewModel.openSearch()
        }) {
          Image(systemName: "magnifyingglass")
        }
        .buttonStyle(
          GhostButtonStyle(
            isActive: viewModel.isSearchPanelVisible,
            iconOnly: true
          )
        )
        .help("Search (⌘F)")
      }
    }
    .padding(.horizontal, Spacing.sm)
    .frame(height: ComponentSize.headerHeight)
    .background(Color.appBackground)
    .overlay(alignment: .bottom) {
      Divider()
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

// SafeModeIndicator moved to Components/Shared/SafeModeIndicator.swift

#Preview {
  HeaderView(viewModel: NotebookViewModel())
    .frame(width: 850)
    .preferredColorScheme(.dark)
}
