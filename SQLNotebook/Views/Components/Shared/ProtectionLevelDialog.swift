//
//  ProtectionLevelDialog.swift
//  SQLNotebook
//
//  Reusable confirmation dialog for changing connection protection level
//

import SwiftUI

/// View modifier that adds a protection level change dialog
struct ProtectionLevelDialogModifier: ViewModifier {
  @Binding var isPresented: Bool
  var currentLevel: ConnectionProtectionLevel
  var onDisableProtection: () async -> Void
  var onEnableSchemaProtection: () async -> Void
  var onEnableReadOnly: () async -> Void

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        "Change Protection Level?",
        isPresented: $isPresented,
        titleVisibility: .visible
      ) {
        Button("Disable Protection", role: .destructive) {
          Task {
            await onDisableProtection()
          }
        }
        if currentLevel == .readOnly {
          Button("Schema Protection Only") {
            Task {
              await onEnableSchemaProtection()
            }
          }
        }
        if currentLevel == .schemaOnly {
          Button("Enable Read-Only Mode") {
            Task {
              await onEnableReadOnly()
            }
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Choose a new protection level for this connection.")
      }
  }
}

extension View {
  /// Adds a confirmation dialog for changing connection protection level
  func protectionLevelDialog(
    isPresented: Binding<Bool>,
    currentLevel: ConnectionProtectionLevel,
    onDisableProtection: @escaping () async -> Void,
    onEnableSchemaProtection: @escaping () async -> Void,
    onEnableReadOnly: @escaping () async -> Void
  ) -> some View {
    modifier(
      ProtectionLevelDialogModifier(
        isPresented: isPresented,
        currentLevel: currentLevel,
        onDisableProtection: onDisableProtection,
        onEnableSchemaProtection: onEnableSchemaProtection,
        onEnableReadOnly: onEnableReadOnly
      )
    )
  }

  /// Convenience version that uses NotebookViewModel methods directly
  func protectionLevelDialog(
    isPresented: Binding<Bool>,
    viewModel: NotebookViewModel
  ) -> some View {
    protectionLevelDialog(
      isPresented: isPresented,
      currentLevel: viewModel.notebook.connectionConfig?.protectionLevel ?? .none,
      onDisableProtection: {
        viewModel.notebook.connectionConfig?.protectionLevel = .none
        viewModel.onDocumentChanged?()
      },
      onEnableSchemaProtection: {
        viewModel.notebook.connectionConfig?.protectionLevel = .schemaOnly
        viewModel.onDocumentChanged?()
      },
      onEnableReadOnly: {
        viewModel.notebook.connectionConfig?.protectionLevel = .readOnly
        viewModel.onDocumentChanged?()
      }
    )
  }
}
