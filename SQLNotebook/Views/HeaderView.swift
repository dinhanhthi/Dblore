//
//  HeaderView.swift
//  SQLNotebook
//

import SwiftUI

struct HeaderView: View {
  @Bindable var viewModel: NotebookViewModel
  @State private var showRunAllConfirmation = false
  @State private var showClearAllOutputsConfirmation = false
  @State private var showResultVisibilityMenu = false

  var body: some View {
    HStack(spacing: Spacing.sm) {
      // Leading group - Sidebars and Cell actions
      HStack(spacing: Spacing.xs) {
        // Left sidebar toggle (common to both modes)
        Button(action: { viewModel.toggleLeftSidebar() }) {
          Image(systemName: "sidebar.left")
        }
        .buttonStyle(ToolbarButtonStyle(isActive: viewModel.isLeftSidebarVisible, iconOnly: true))
        .help("Toggle Sidebar (⌘⇧L)")

        // Schema Visualizer mode buttons (replaces normal buttons when active)
        if viewModel.isSchemaVisualizerActive {
          Divider()
            .frame(height: 20)

          schemaVisualizerButtons
        } else if viewModel.viewMode == .notebook {
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
          .buttonStyle(ToolbarButtonStyle())
          .disabled(viewModel.isFileSizeLarge)
          .opacity(viewModel.isFileSizeLarge ? 0.5 : 1.0)
          .help("New Cell (⌘N)")

          Button(action: {
            showRunAllConfirmation = true
          }) {
            Label("Run All", systemImage: "play.fill")
          }
          .buttonStyle(ToolbarButtonStyle())
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
          .buttonStyle(ToolbarButtonStyle())
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
          .buttonStyle(ToolbarButtonStyle())
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
          .buttonStyle(ToolbarButtonStyle())
          .disabled(viewModel.editorContent.isEmpty || !viewModel.connectionState.isConnected)
          .help(editorRunButtonHelp)
        }
      }

      Spacer()

      // Trailing group - Search, Settings and Connection (common to both modes)
      HStack(spacing: Spacing.sm) {
        // Search button
        Button(action: {
          viewModel.openSearch()
        }) {
          Image(systemName: "magnifyingglass")
        }
        .buttonStyle(
          ToolbarButtonStyle(
            isActive: viewModel.isSearchPanelVisible,
            iconOnly: true
          )
        )
        .help("Search (⌘F)")

        // Settings button
        Button(action: {
          // Toggle sidebar if already showing settings
          if viewModel.isRightSidebarVisible,
            case .settings = viewModel.rightSidebarContent
          {
            viewModel.closeSidebar()
          } else {
            viewModel.showSettings()
          }
        }) {
          Image(systemName: "gearshape")
        }
        .buttonStyle(
          ToolbarButtonStyle(
            isActive: viewModel.isRightSidebarVisible
              && (viewModel.rightSidebarContent == .settings),
            iconOnly: true
          )
        )
        .help("Settings")

        Divider()
          .frame(height: 20)

        ConnectionButton(
          connectionState: viewModel.connectionState,
          connectionConfig: viewModel.notebook.connectionConfig,
          isSchemaVisualizerActive: viewModel.isSchemaVisualizerActive,
          onConnect: {
            // Toggle sidebar if already showing connection form
            if viewModel.isRightSidebarVisible,
              case .connectionForm = viewModel.rightSidebarContent
            {
              viewModel.closeSidebar()
            } else {
              viewModel.showConnectionForm()
            }
          },
          onDisconnect: { viewModel.disconnect() },
          onShowDetails: {
            // Toggle sidebar if already showing connection details
            if viewModel.isRightSidebarVisible,
              case .connectionDetails = viewModel.rightSidebarContent
            {
              viewModel.closeSidebar()
            } else {
              viewModel.showConnectionDetails()
            }
          },
          onToggleSchemaVisualizer: { viewModel.toggleSchemaVisualizer() },
          onSwitchToReadOnly: {
            Task {
              await viewModel.enableReadOnlyMode()
            }
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

  // MARK: - Schema Visualizer Buttons

  private var schemaVisualizerButtons: some View {
    HStack(spacing: Spacing.sm) {
      // Back button
      Button(action: { viewModel.hideSchemaVisualizer() }) {
        Label("Back", systemImage: "chevron.left")
      }
      .buttonStyle(ToolbarButtonStyle())
      .help("Back to \(viewModel.viewMode == .notebook ? "Notebook" : "Editor")")

      Divider()
        .frame(height: 20)

      // Zoom controls grouped together (tight spacing inside)
      HStack(spacing: 0) {
        Button(action: { viewModel.zoomOutVisualizer() }) {
          Image(systemName: "minus.magnifyingglass")
        }
        .buttonStyle(ToolbarButtonStyle(iconOnly: true))
        .help("Zoom Out")

        Text("\(Int(viewModel.visualizerScale * 100))%")
          .font(.monoSmall)
          .foregroundColor(.foregroundMuted)
          .frame(width: 45)

        Button(action: { viewModel.zoomInVisualizer() }) {
          Image(systemName: "plus.magnifyingglass")
        }
        .buttonStyle(ToolbarButtonStyle(iconOnly: true))
        .help("Zoom In")
      }
      .padding(.horizontal, Spacing.xs)
      .padding(.vertical, Spacing.xxs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .fill(Color.inputBackground)
      )

      Divider()
        .frame(height: 20)

      // Reset view button
      Button(action: { viewModel.resetVisualizerView() }) {
        Image(systemName: "arrow.counterclockwise")
      }
      .buttonStyle(ToolbarButtonStyle(iconOnly: true))
      .help("Reset View")

      // Reset layout button
      Button(action: {
        Task {
          await viewModel.resetSchemaLayout()
        }
      }) {
        Image(systemName: "rectangle.3.group")
      }
      .buttonStyle(ToolbarButtonStyle(iconOnly: true))
      .help("Reset Layout to Default")
      .disabled(viewModel.isLoadingSchemaGraph)

      // Toggle table connection lines (ER diagram lines)
      Button(action: { viewModel.showTableConnections.toggle() }) {
        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
      }
      .buttonStyle(ToolbarButtonStyle(isActive: viewModel.showTableConnections, iconOnly: true))
      .help(
        viewModel.showTableConnections
          ? "Hide Table Connections" : "Show Table Connections")

      // Toggle column connection lines
      Button(action: { viewModel.showColumnConnections.toggle() }) {
        Image(systemName: "arrow.triangle.branch")
      }
      .buttonStyle(ToolbarButtonStyle(isActive: viewModel.showColumnConnections, iconOnly: true))
      .help(
        viewModel.showColumnConnections
          ? "Hide Column Connections" : "Show Column Connections")

      Divider()
        .frame(height: 20)

      // Export as PNG button
      Button(action: { viewModel.exportSchemaAsImage() }) {
        Image(systemName: "square.and.arrow.up")
      }
      .buttonStyle(ToolbarButtonStyle(iconOnly: true))
      .help("Export as PNG")
      .disabled(viewModel.schemaGraph?.isEmpty ?? true)

      // Refresh button
      Button(action: {
        Task {
          await viewModel.refreshSchemaGraph()
        }
      }) {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(ToolbarButtonStyle(iconOnly: true))
      .help("Refresh Schema")
      .disabled(viewModel.isLoadingSchemaGraph)
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
  let isSchemaVisualizerActive: Bool
  let onConnect: () -> Void
  let onDisconnect: () -> Void
  let onShowDetails: () -> Void
  let onToggleSchemaVisualizer: () -> Void
  let onSwitchToReadOnly: () -> Void

  @State private var showDisconnectConfirmation = false
  @State private var isHoveringDisconnect = false
  @State private var isHoveringInfo = false

  /// Check if connection is in read-only mode
  private var isReadOnly: Bool {
    connectionConfig?.isReadOnly ?? false
  }

  var body: some View {
    if connectionState.isConnected {
      // Connected state - no button style, green text, with info icon
      HStack(spacing: Spacing.xs) {
        HStack(spacing: 0) {
          Button(action: { showDisconnectConfirmation = true }) {
            HStack(spacing: Spacing.xs) {
              connectionIcon
              Text(connectionText)
                .foregroundColor(.success)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
              RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(isHoveringDisconnect ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
            )
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("Click to Disconnect")
          .animation(.easeInOut(duration: 0.15), value: isHoveringDisconnect)
          .onHover { hovering in
            isHoveringDisconnect = hovering
            if hovering {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }

          Button(action: onShowDetails) {
            Image(systemName: "info.circle")
          }
          .buttonStyle(ToolbarButtonStyle(iconOnly: true))
          .help("Connection Details")
          .animation(.easeInOut(duration: 0.15), value: isHoveringInfo)
          .onHover { hovering in
            isHoveringInfo = hovering
            if hovering {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }
        }

        // Schema Visualizer button
        Button(action: onToggleSchemaVisualizer) {
          Image(systemName: "point.3.connected.trianglepath.dotted")
            .foregroundColor(.accent)
        }
        .buttonStyle(ToolbarButtonStyle(isActive: isSchemaVisualizerActive, iconOnly: true))
        .help(
          isSchemaVisualizerActive
            ? "Close Schema Visualizer" : "Visualize Schema Relationships")
      }
      .confirmationDialog(
        disconnectDialogTitle,
        isPresented: $showDisconnectConfirmation,
        titleVisibility: .visible
      ) {
        Button("Disconnect", role: .destructive) {
          onDisconnect()
        }
        // Show "Switch to Read-only" only when not already in read-only mode
        if !isReadOnly {
          Button("Switch to Read-only") {
            onSwitchToReadOnly()
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This will close the database connection and you won't be able to run queries.")
      }
    } else {
      // Other states - use button style
      Button(action: {
        if connectionState.isConnected {
          onDisconnect()
        } else {
          onConnect()
        }
      }) {
        HStack(spacing: Spacing.sm) {
          connectionIcon
          Text(connectionText)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(ToolbarButtonStyle())
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

  private var disconnectDialogTitle: String {
    if let config = connectionConfig, !config.name.isEmpty {
      return "Disconnect from database \(config.name)?"
    }
    return "Disconnect from database?"
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
