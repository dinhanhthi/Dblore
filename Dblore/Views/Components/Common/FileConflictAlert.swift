//
//  FileConflictAlert.swift
//  Dblore
//
//  ViewModifier for displaying external file conflict alerts
//

import SwiftUI

// MARK: - File Conflict Alert Modifier

/// ViewModifier that presents an alert when external file changes are detected
struct FileConflictAlertModifier: ViewModifier {
  @Binding var state: FileConflictState
  let hasUnsavedChanges: Bool
  let onKeepMyVersion: () -> Void
  let onLoadExternal: () -> Void

  func body(content: Content) -> some View {
    content
      .alert(state.alertTitle, isPresented: $state.showDialog) {
        alertButtons
      } message: {
        Text(state.alertMessage(hasUnsavedChanges: hasUnsavedChanges))
      }
  }

  @ViewBuilder
  private var alertButtons: some View {
    switch state.conflictType {
    case .modified:
      if hasUnsavedChanges {
        Button("Keep My Version", role: .cancel) {
          onKeepMyVersion()
        }
        Button("Load External Version", role: .destructive) {
          onLoadExternal()
        }
      } else {
        Button("OK") {
          onLoadExternal()
        }
      }

    case .deleted:
      if hasUnsavedChanges {
        Button("Keep Document Open", role: .cancel) {
          onKeepMyVersion()
        }
        Button("Close Document", role: .destructive) {
          onLoadExternal()
        }
      } else {
        Button("OK") {
          onLoadExternal()
        }
      }
    }
  }
}

// MARK: - View Extension

extension View {
  /// Adds a file conflict alert to the view
  /// - Parameters:
  ///   - state: Binding to the conflict state
  ///   - hasUnsavedChanges: Whether the document has unsaved changes
  ///   - onKeepMyVersion: Called when user wants to keep local version
  ///   - onLoadExternal: Called when user wants to load external version
  func fileConflictAlert(
    state: Binding<FileConflictState>,
    hasUnsavedChanges: Bool,
    onKeepMyVersion: @escaping () -> Void,
    onLoadExternal: @escaping () -> Void
  ) -> some View {
    modifier(
      FileConflictAlertModifier(
        state: state,
        hasUnsavedChanges: hasUnsavedChanges,
        onKeepMyVersion: onKeepMyVersion,
        onLoadExternal: onLoadExternal
      ))
  }
}
