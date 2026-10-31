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
  /// Close Document (or OK) after a deletion; nil: `onLoadExternal`. Each button is built for
  /// the alert's type, so a deletion arriving while a change is shown never swaps its action.
  var onClose: (() -> Void)? = nil

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
          (onClose ?? onLoadExternal)()
        }
      } else {
        Button("OK") {
          (onClose ?? onLoadExternal)()
        }
      }
    }
  }
}

// MARK: - Document Conflict Alert

/// A document that watches its file on disk and publishes what changed there
protocol FileConflictPresenting: ObservableObject {
  var fileConflictState: FileConflictState { get set }
  /// The file's date on disk when it changed since the document last read or wrote it
  func unseenChangeDate() -> Date?
  /// Takes the file's date on disk as seen (after this app wrote the file)
  func updateLastKnownModificationDate()
  /// Notes the file's date on disk as this app's own rewrite over a change not shown yet: that
  /// change still asks, and Keep My Version over it takes the rewrite as seen too
  func noteOwnRewrite()
}

/// The file conflict alert of a document's tab. Observes the document, so the alert shows as
/// soon as its file changes or is deleted on disk; after a deletion, Close Document (or OK)
/// calls `onClose` instead of `onLoadExternal`.
struct DocumentFileConflictAlertModifier<Document: FileConflictPresenting>: ViewModifier {
  @ObservedObject var document: Document
  let hasUnsavedChanges: Bool
  let onKeepMyVersion: () -> Void
  let onLoadExternal: () -> Void
  let onClose: () -> Void

  func body(content: Content) -> some View {
    content.modifier(
      FileConflictAlertModifier(
        state: $document.fileConflictState,
        hasUnsavedChanges: hasUnsavedChanges,
        onKeepMyVersion: onKeepMyVersion,
        onLoadExternal: onLoadExternal,
        onClose: onClose
      ))
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
