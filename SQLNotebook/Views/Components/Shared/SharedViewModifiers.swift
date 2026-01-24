//
//  SharedViewModifiers.swift
//  SQLNotebook
//

import SwiftUI

// MARK: - Search Notification Handler

/// Handles search-related notifications
/// Used by both Notebook and Editor modes
struct SearchNotificationHandler: ViewModifier {
  let viewModel: NotebookViewModel

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .openSearch)) { _ in
        viewModel.openSearch()
      }
      .onReceive(NotificationCenter.default.publisher(for: .findNext)) { _ in
        viewModel.navigateToNextMatch()
      }
      .onReceive(NotificationCenter.default.publisher(for: .findPrevious)) { _ in
        viewModel.navigateToPreviousMatch()
      }
  }
}

// MARK: - Focused Scene Actions

/// Handles focused scene values for sidebar and search actions
/// Used by both Notebook and Editor modes
struct FocusedSceneActions: ViewModifier {
  let viewModel: NotebookViewModel
  let documentMode: DocumentMode

  func body(content: Content) -> some View {
    content
      .focusedSceneValue(\.documentMode, documentMode)
      .focusedSceneValue(\.toggleLeftSidebarAction) { [viewModel] in
        viewModel.toggleLeftSidebar()
      }
      .focusedSceneValue(\.toggleRightSidebarAction) { [viewModel] in
        viewModel.toggleSidebar()
      }
      .focusedSceneValue(\.openSearchAction) { [viewModel] in
        viewModel.openSearch()
      }
      .focusedSceneValue(\.findNextAction) { [viewModel] in
        viewModel.navigateToNextMatch()
      }
      .focusedSceneValue(\.findPreviousAction) { [viewModel] in
        viewModel.navigateToPreviousMatch()
      }
  }
}

// MARK: - Destructive Query Dialog

/// Adds destructive query confirmation dialog
/// Used by both Notebook and Editor modes
extension View {
  func destructiveQueryDialog(
    viewModel: NotebookViewModel,
    syncDocument: @escaping () -> Void
  ) -> some View {
    self.confirmationDialog(
      "Confirm Destructive Query",
      isPresented: Binding(
        get: { viewModel.showQueryConfirmationDialog },
        set: { viewModel.showQueryConfirmationDialog = $0 }
      ),
      titleVisibility: .visible
    ) {
      Button("Execute Query", role: .destructive) {
        Task { @MainActor in
          await viewModel.executePendingQuery()
          syncDocument()
        }
      }
      Button("Cancel", role: .cancel) {
        viewModel.cancelPendingQuery()
      }
    } message: {
      VStack(alignment: .leading, spacing: 8) {
        Text("This query will modify data in your database:")
          .font(.body)
        Text(viewModel.pendingQuery)
          .font(.system(.body, design: .monospaced))
          .lineLimit(5)
        Text("Are you sure you want to proceed?")
          .font(.body)
      }
    }
  }

  func searchNotifications(viewModel: NotebookViewModel) -> some View {
    modifier(SearchNotificationHandler(viewModel: viewModel))
  }

  func focusedSceneActions(viewModel: NotebookViewModel, mode: DocumentMode) -> some View {
    modifier(FocusedSceneActions(viewModel: viewModel, documentMode: mode))
  }
}
