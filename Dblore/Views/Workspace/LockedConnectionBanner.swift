//
//  LockedConnectionBanner.swift
//  Dblore
//
//  Workspace-level banner shown when auto-connect stopped on a locked connection: the saved tabs
//  stay usable, Unlock asks (on this window) and then connects.
//

import SwiftUI

struct LockedConnectionBanner: View {
  @Bindable var workspaceManager: WorkspaceManager

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "lock.fill")
        .foregroundColor(.warning)
        .accessibilityHidden(true)

      Text("Locked: unlock to connect")
        .font(.labelText.weight(.medium))
        .foregroundColor(.foreground)

      Spacer(minLength: Spacing.sm)

      Button("Unlock") {
        Task { await workspaceManager.unlockAndConnect() }
      }
      .buttonStyle(PrimaryButtonStyle())
      .linkPointer()
      .controlSize(.small)
      .disabled(
        workspaceManager.isUnlockingConnect || workspaceManager.connectionState.isConnecting)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .tintedChromeGlass(.warning)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.warning.opacity(0.4)).frame(height: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Locked: unlock to connect")
  }
}
