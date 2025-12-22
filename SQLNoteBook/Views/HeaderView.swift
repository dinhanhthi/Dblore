//
//  HeaderView.swift
//  SQLNotebook
//

import SwiftUI

struct HeaderView: View {
    @Bindable var viewModel: NotebookViewModel
    @Binding var showConnectionSheet: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Leading group - Cell actions
            HStack(spacing: Spacing.xs) {
                Button(action: { viewModel.addCell(type: .sql) }) {
                    Label("Code", systemImage: "plus")
                }
                .buttonStyle(ToolbarButtonStyle())

                Button(action: { viewModel.addCell(type: .markdown) }) {
                    Label("Markdown", systemImage: "plus")
                }
                .buttonStyle(ToolbarButtonStyle())

                Divider()
                    .frame(height: 20)

                Button(action: {
                    Task { await viewModel.runAllCells() }
                }) {
                    Label("Run All", systemImage: "play.fill")
                }
                .buttonStyle(ToolbarButtonStyle())
                .disabled(!viewModel.connectionState.isConnected)

                Button(action: { viewModel.clearAllOutputs() }) {
                    Label("Clear All Outputs", systemImage: "trash")
                }
                .buttonStyle(ToolbarButtonStyle())
            }

            Spacer()

            // Trailing group - Connection
            ConnectionButton(
                connectionState: viewModel.connectionState,
                onConnect: { showConnectionSheet = true },
                onDisconnect: { viewModel.disconnect() },
                onShowDetails: {
                    // Toggle sidebar if already showing connection details
                    if viewModel.isRightSidebarVisible,
                       case .connectionDetails = viewModel.rightSidebarContent {
                        viewModel.closeSidebar()
                    } else {
                        viewModel.showConnectionDetails()
                    }
                }
            )
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
                }
                .buttonStyle(.plain)
                
                Button(action: onShowDetails) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.foregroundMuted)
                }
                .buttonStyle(.plain)
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
            }
            .buttonStyle(ToolbarButtonStyle())
            .disabled(connectionState.isConnecting)
        }
    }

    @ViewBuilder
    private var connectionIcon: some View {
        switch connectionState {
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

#Preview("Connect") {
    HeaderView(
        viewModel: NotebookViewModel(),
        showConnectionSheet: .constant(false)
    )
    .frame(width: 800)
    .preferredColorScheme(.dark)
}

#Preview("Connected") {
    let viewModel = NotebookViewModel()
    viewModel.connectionState = .connected
    
    return HeaderView(
        viewModel: viewModel,
        showConnectionSheet: .constant(false)
    )
    .frame(width: 800)
    .preferredColorScheme(.dark)
}
