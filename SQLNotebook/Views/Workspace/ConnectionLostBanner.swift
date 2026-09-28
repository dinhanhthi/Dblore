//
//  ConnectionLostBanner.swift
//  SQLNotebook
//
//  Workspace-level banner shown when the server (or the network) closed the connection:
//  "Connection lost", what happened to pending changes, Reconnect and Dismiss.
//

import SwiftUI

struct ConnectionLostBanner: View {
  @Bindable var workspaceManager: WorkspaceManager

  @State private var isReconnecting = false

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "bolt.horizontal.circle.fill")
        .foregroundColor(.destructive)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Connection lost")
          .font(.labelText.weight(.medium))
          .foregroundColor(.foreground)
        Text(workspaceManager.connectionLostMessage ?? "")
          .font(.small)
          .foregroundColor(.foreground)
          .lineLimit(3)
          .textSelection(.enabled)
      }

      Spacer(minLength: Spacing.sm)

      Button("Dismiss") {
        workspaceManager.dismissConnectionLost()
      }
      .glassButtonStyle()
      .linkPointer()
      .controlSize(.small)

      Button("Reconnect") {
        isReconnecting = true
        Task {
          await workspaceManager.reconnectAfterConnectionLoss()
          isReconnecting = false
        }
      }
      .glassButtonStyle(prominent: true)
      .linkPointer()
      .controlSize(.small)
      .disabled(isReconnecting || workspaceManager.connectionState.isConnecting)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .tintedChromeGlass(.destructive)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.destructive.opacity(0.4)).frame(height: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Connection lost")
  }
}
