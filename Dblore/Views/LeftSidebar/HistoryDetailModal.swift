//
//  HistoryDetailModal.swift
//  Dblore
//
//  Small modal with the full recorded SQL, and Copy / Cancel.
//  The SQL well matches every other read-only code modal.
//

import SwiftUI

struct HistoryDetailModal: View {
  let sql: String
  @Binding var isPresented: Bool
  let onCopy: () -> Void

  @State private var copied = false

  var body: some View {
    VStack(spacing: 0) {
      SQLCodeWell(sql: sql)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.md)

      GenericModalFooter {
        Spacer()
        Button(copied ? "Copied" : "Copy", action: copy)
          .buttonStyle(PrimaryButtonStyle())
        Button("Cancel") { isPresented = false }
          .buttonStyle(SecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
      }
    }
    .frame(width: 440, height: 260)
    .background(Color.cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xxl))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.xxl)
        .stroke(Color.border.opacity(0.5), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
  }

  private func copy() {
    onCopy()
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      copied = false
    }
  }
}

extension View {
  /// Presents the history detail modal driven by `workspaceManager.historyDetail`.
  func historyDetailModal(workspaceManager: WorkspaceManager) -> some View {
    let isPresented = Binding(
      get: { workspaceManager.historyDetail != nil },
      set: { if !$0 { workspaceManager.historyDetail = nil } }
    )
    return modalOverlay(isPresented: isPresented) {
      if let entry = workspaceManager.historyDetail {
        HistoryDetailModal(
          sql: entry.sql,
          isPresented: isPresented,
          onCopy: { workspaceManager.copyHistory(entry) }
        )
        .id(entry.id)
      }
    }
  }
}
