//
//  HeaderView.swift
//  SQLNotebook
//

import SwiftUI

struct HeaderView: View {
  @Bindable var viewModel: NotebookViewModel

  var body: some View {
    HStack(spacing: Spacing.sm) {
      // Leading group - Sidebars and Cell actions
      HStack(spacing: Spacing.xs) {
        // Left sidebar toggle
        Button(action: { viewModel.toggleLeftSidebar() }) {
          Image(systemName: "sidebar.left")
        }
        .buttonStyle(ToolbarButtonStyle(isActive: viewModel.isLeftSidebarVisible))
        .onHover { hovering in
          if hovering {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }

        Divider()
          .frame(height: 20)

        Button(action: { viewModel.addCell(type: .sql) }) {
          Label("Cell", systemImage: "plus")
        }
        .buttonStyle(ToolbarButtonStyle())
        .onHover { hovering in
          if hovering {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }

        Divider()
          .frame(height: 20)

        Button(action: {
          Task { await viewModel.runAllCells() }
        }) {
          Label("Run All", systemImage: "play.fill")
        }
        .buttonStyle(ToolbarButtonStyle())
        .disabled(!viewModel.connectionState.isConnected)
        .onHover { hovering in
          if hovering && viewModel.connectionState.isConnected {
            NSCursor.pointingHand.push()
          } else if !hovering && viewModel.connectionState.isConnected {
            NSCursor.pop()
          }
        }

        Button(action: { viewModel.clearAllOutputs() }) {
          Label("Clear All Outputs", systemImage: "trash")
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

      Spacer()

      // Trailing group - Settings and Connection
      HStack(spacing: Spacing.xs) {
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
        .buttonStyle(ToolbarButtonStyle(isActive: viewModel.isRightSidebarVisible && 
          (viewModel.rightSidebarContent == .settings)))
        .onHover { hovering in
          if hovering {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }

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
    .background(Color.cardBackground)
    .overlay(alignment: .bottom) {
      Divider()
    }
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
      HStack(spacing: Spacing.xs) {
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
            .foregroundColor(.foregroundMuted)
            .padding(Spacing.xs)
            .background(
              RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(isHoveringInfo ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
            )
        }
        .buttonStyle(.plain)
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
      .disabled(connectionState.isConnecting)
      .onHover { hovering in
        if hovering && !connectionState.isConnecting {
          NSCursor.pointingHand.push()
        } else if !hovering && !connectionState.isConnecting {
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
    case .disconnected:
      return "Connect"
    case .connecting:
      return "Connecting..."
    case .connected:
      return "Connected"
    case .error(let message):
      return "Error: \(message)"
    }
  }
}

// MARK: - Connection Icon View
// Extracted to reduce type complexity in ConnectionButton

private struct ConnectionIconView: View {
  let state: ConnectionState

  var body: some View {
    switch state {
    case .disconnected:
      Image(systemName: "bolt.slash")
        .foregroundColor(.foregroundMuted)
    case .connecting:
      ProgressView()
        .scaleEffect(0.7)
        .frame(width: 14, height: 14)
    case .connected:
      Image(systemName: "bolt.fill")
        .foregroundColor(.success)
    case .error:
      Image(systemName: "exclamationmark.triangle")
        .foregroundColor(.destructive)
    }
  }
}

#Preview("Connect") {
  HeaderView(viewModel: NotebookViewModel())
    .frame(width: 700)
    .preferredColorScheme(.dark)
}

#Preview("Connected") {
  let viewModel = NotebookViewModel()
  viewModel.connectionState = .connected

  return HeaderView(viewModel: viewModel)
    .frame(width: 800)
    .preferredColorScheme(.dark)
}
