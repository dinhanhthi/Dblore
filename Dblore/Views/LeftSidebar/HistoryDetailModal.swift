//
//  HistoryDetailModal.swift
//  Dblore
//
//  Small modal with the full recorded SQL, the recorded error of a failed run, and Copy / Cancel.
//  The SQL well matches every other read-only code modal.
//

import SwiftUI

struct HistoryDetailModal: View {
  let sql: String
  /// False for a transaction summary. The label is not SQL and must not reach the pasteboard.
  var canCopy = true
  /// Recorded error of a failed run (an import keeps only its row range), nil on success
  var errorMessage: String? = nil
  @Binding var isPresented: Bool
  let onCopy: () -> Bool

  @State private var copied = false

  var body: some View {
    VStack(spacing: 0) {
      if let errorMessage {
        Text(errorMessage)
          .font(.small)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding([.horizontal, .top], Spacing.md)
      }
      SQLCodeWell(sql: sql, allowsTextSelection: canCopy)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.md)

      GenericModalFooter {
        Spacer()
        if canCopy {
          Button(copied ? "Copied" : "Copy", action: copy)
            .buttonStyle(PrimaryButtonStyle())
        }
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
    guard onCopy() else { return }
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
          canCopy: !QueryHistoryEntry.isTransactionSummary(entry.sql),
          errorMessage: entry.status == .success ? nil : entry.errorMessage,
          isPresented: isPresented,
          onCopy: { workspaceManager.copyHistory(entry) }
        )
        .id(entry.id)
      }
    }
  }
}
