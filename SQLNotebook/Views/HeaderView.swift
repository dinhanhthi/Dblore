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
          Divider()
            .frame(height: 20)

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

          Divider()
            .frame(height: 20)

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
        } else if viewModel.viewMode == .editor {
          // Editor mode buttons
          Divider()
            .frame(height: 20)

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

      // Trailing group - Search and Connection (common to both modes)
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

        Divider()
          .frame(height: 20)

        ConnectionButton(
          connectionState: viewModel.connectionState,
          connectionConfig: viewModel.notebook.connectionConfig,
          onConnect: {
            // Toggle modal visibility at workspace level
            workspaceManager?.isConnectionFormModalVisible.toggle()
          },
          onShowConnectionInfo: {
            // Show connection info modal at workspace level
            workspaceManager?.isConnectionInfoModalVisible = true
          }
        )
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
    let count = viewModel.queryConfirmationState.runAllDestructiveCount
    let queryWord = count == 1 ? "query" : "queries"
    return "Run All contains \(count) destructive \(queryWord)"
  }

  private var runAllDestructiveDialogMessage: String {
    let count = viewModel.queryConfirmationState.runAllDestructiveCount
    let queryWord = count == 1 ? "query" : "queries"
    return """
      This batch contains \(count) destructive \(queryWord) (UPDATE, DELETE, INSERT) \
      that will modify your database.

      • Allow: Execute all queries including destructive ones
      • Don't Allow: Skip destructive queries and run the rest
      """
  }
}

struct ConnectionButton: View {
  let connectionState: ConnectionState
  let connectionConfig: ConnectionConfig?
  let onConnect: () -> Void
  let onShowConnectionInfo: () -> Void

  @State private var isHoveringConnection = false

  var body: some View {
    if connectionState.isConnected {
      // Connected state - no button style, green text, with info icon
      HStack(spacing: 0) {
        Button(action: onShowConnectionInfo) {
          HStack(spacing: Spacing.xs) {
            connectionIcon
            Text(connectionText)
              .foregroundColor(.success)
          }
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .background(
            RoundedRectangle(cornerRadius: CornerRadius.md)
              .fill(isHoveringConnection ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Connection Details")
        .animation(.easeInOut(duration: 0.15), value: isHoveringConnection)
        .onHover { hovering in
          isHoveringConnection = hovering
          if hovering {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }
      }
    } else {
      // Other states - use button style
      Button(action: onConnect) {
        HStack(spacing: Spacing.sm) {
          connectionIcon
          Text(connectionText)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(GhostButtonStyle())
      .help("Connect to Database")
      .onHover { hovering in
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
    }
  }

  private var connectionIcon: some View {
    ConnectionIconView(state: connectionState)
  }

  private var connectionText: String {
    switch connectionState {
    case .connected:
      return "Connected"
    default:
      // Show "Connect" for all other states (disconnected, connecting, error)
      // The icon will indicate the actual state
      return "Connect"
    }
  }
}

// MARK: - Connection Icon View

// Extracted to reduce type complexity in ConnectionButton

private struct ConnectionIconView: View {
  let state: ConnectionState

  var body: some View {
    switch state {
    case .connected:
      Image(systemName: "bolt.fill")
        .foregroundColor(.success)
    default:
      // Show disconnected icon for all non-connected states
      // (.disconnected, .connecting, .error)
      Image(systemName: "bolt.slash")
        .foregroundColor(.foregroundMuted)
    }
  }
}

// SafeModeIndicator moved to Components/Shared/SafeModeIndicator.swift

#Preview("Connect") {
  HeaderView(viewModel: NotebookViewModel())
    .frame(width: 850)
    .preferredColorScheme(.dark)
}

#Preview("Connected") {
  let viewModel = NotebookViewModel()
  viewModel.connectionState = .connected

  return HeaderView(viewModel: viewModel)
    .frame(width: 850)
    .preferredColorScheme(.dark)
}
