//
//  ReadOnlyFileBanner.swift
//  Dblore
//
//  Workspace-level banner shown when a SQLite file was opened read-only because the app could
//  not write its sidecar files (-wal, -shm, -journal). Dismiss hides it until the next connect.
//

import SwiftUI

struct ReadOnlyFileBanner: View {
  @Bindable var workspaceManager: WorkspaceManager

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "lock.circle.fill")
        .foregroundColor(.warning)
        .accessibilityHidden(true)

      Text(workspaceManager.readOnlyFileNotice ?? "")
        .font(.small)
        .foregroundColor(.foreground)
        .lineLimit(3)
        .textSelection(.enabled)

      Spacer(minLength: Spacing.sm)

      Button("Dismiss") {
        workspaceManager.readOnlyFileNotice = nil
      }
      .buttonStyle(FilledSecondaryButtonStyle())
      .linkPointer()
      .controlSize(.small)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .tintedChromeGlass(.warning)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.warning.opacity(0.4)).frame(height: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Database opened read-only")
  }
}
