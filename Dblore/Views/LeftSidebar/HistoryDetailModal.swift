//
//  HistoryDetailModal.swift
//  Dblore
//
//  Small modal with the full recorded SQL and Copy / Cancel.
//  A failed run shows its error under the SQL well, with the same wash as the
//  result panel after a statement fails.
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
      SQLCodeWell(sql: sql, allowsTextSelection: canCopy)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, errorMessage == nil ? Spacing.md : Spacing.sm)

      if let errorMessage {
        historyErrorResult(errorMessage)
          .padding(.horizontal, Spacing.md)
          .padding(.bottom, Spacing.md)
      }

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
    .modalFrame(width: 440, height: errorMessage == nil ? 260 : 340)
    .background(Color.cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xxl))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.xxl)
        .stroke(Color.border.opacity(0.5), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
  }

  /// Same wash and type as the editor result panel after a failed statement.
  private func historyErrorResult(_ message: String) -> some View {
    ScrollView {
      Text(message)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Color.destructive)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
    }
    .frame(maxWidth: .infinity, maxHeight: 120)
    .background(Color.red.opacity(0.05))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
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
