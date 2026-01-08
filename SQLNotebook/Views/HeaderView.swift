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
        // Left sidebar toggle
        Button(action: { viewModel.toggleLeftSidebar() }) {
          Image(systemName: "sidebar.left")
        }
        .buttonStyle(ToolbarButtonStyle(isActive: viewModel.isLeftSidebarVisible, iconOnly: true))

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

        Button(action: {
          showRunAllConfirmation = true
        }) {
          Label("Run All", systemImage: "play.fill")
        }
        .buttonStyle(ToolbarButtonStyle())
        .disabled(!viewModel.connectionState.isConnected)
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

        Button(action: {
          showClearAllOutputsConfirmation = true
        }) {
          Label("Clear All Outputs", systemImage: "trash")
        }
        .buttonStyle(ToolbarButtonStyle())
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
      }

      Spacer()

      // Trailing group - View mode toggle, Settings and Connection
      HStack(spacing: Spacing.xs) {
        // View mode toggle
        viewModeToggle()

        Divider()
          .frame(height: 20)

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

        Divider()
          .frame(height: 20)

        ConnectionButton(
          connectionState: viewModel.connectionState,
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

  @ViewBuilder
  private func viewModeToggle() -> some View {
    let selectedIndex = ViewMode.allCases.firstIndex(of: viewModel.viewMode) ?? 0

    ZStack {
      // Background
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(Color.inputBackground)
        .overlay(
          RoundedRectangle(cornerRadius: CornerRadius.md)
            .stroke(Color.border, lineWidth: 1)
        )

      // Content with padding
      GeometryReader { geometry in
        let inset: CGFloat = 3
        let availableWidth = geometry.size.width - (inset * 2)
        let tabWidth = availableWidth / CGFloat(ViewMode.allCases.count)

        ZStack(alignment: .leading) {
          // Sliding indicator
          RoundedRectangle(cornerRadius: CornerRadius.md - 2)
            .fill(Color.accent)
            .frame(width: tabWidth, height: geometry.size.height - (inset * 2))
            .offset(x: inset + CGFloat(selectedIndex) * tabWidth)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.viewMode)

          // Tab buttons
          HStack(spacing: 0) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
              Button(action: {
                withAnimation {
                  if viewModel.viewMode != mode {
                    viewModel.toggleViewMode()
                  }
                }
              }) {
                HStack(spacing: Spacing.xxs) {
                  Image(systemName: mode.icon)
                    .font(.system(size: 11))
                  Text(mode.displayName)
                    .font(.system(size: 12))
                }
                .fontWeight(viewModel.viewMode == mode ? .semibold : .regular)
                .foregroundColor(viewModel.viewMode == mode ? .white : .foreground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
              }
              .buttonStyle(PlainButtonStyle())
              .onHover { hovering in
                if hovering {
                  NSCursor.pointingHand.push()
                } else {
                  NSCursor.pop()
                }
              }
            }
          }
        }
      }
    }
    .frame(width: 180, height: 25)
  }
}

struct ConnectionButton: View {
  let connectionState: ConnectionState
  let onConnect: () -> Void
  let onDisconnect: () -> Void
  let onShowDetails: () -> Void

  @State private var showDisconnectConfirmation = false
  @State private var isHoveringDisconnect = false
  @State private var isHoveringInfo = false

  var body: some View {
    if connectionState.isConnected {
      // Connected state - no button style, green text, with info icon
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
      .confirmationDialog(
        "Disconnect from database?",
        isPresented: $showDisconnectConfirmation,
        titleVisibility: .visible
      ) {
        Button("Disconnect", role: .destructive) {
          onDisconnect()
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
