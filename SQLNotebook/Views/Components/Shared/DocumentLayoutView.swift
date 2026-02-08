//
//  DocumentLayoutView.swift
//  SQLNotebook
//

import SwiftUI

/// Shared layout structure for both Editor and Notebook modes
/// Contains common UI elements: header, sidebars, footer, toast
struct DocumentLayoutView<Content: View>: View {
  let viewModel: NotebookViewModel
  @Binding var lastSaved: Date?
  let isEditorMode: Bool
  var connectionConfig: ConnectionConfig?
  @Bindable private var appSettings = AppSettings.shared
  @State private var showSafeModeModal = false

  @ViewBuilder let content: Content

  var body: some View {
    ZStack {
      Color.appBackground
        .ignoresSafeArea()

      // Main layout: HStack with left content area + right sidebar
      // Right sidebar now extends full height including header level
      HStack(spacing: 0) {
        // Left side: Header + Content + Footer
        VStack(spacing: 0) {
          // Header
          HeaderView(viewModel: viewModel)

          // Main content (passed from parent) with search panel overlay
          // Note: Schema Visualizer is now handled at WorkspaceContainerView level
          ZStack(alignment: .top) {
            content

            // Search panel overlay (slides from top, floating right)
            if viewModel.isSearchPanelVisible {
              HStack {
                Spacer()
                SearchPanelView(viewModel: viewModel)
                  .frame(width: 500)
                  .padding(.horizontal, Spacing.md)
                  .padding(.vertical, Spacing.sm)
              }
              .transition(
                .asymmetric(
                  insertion: .move(edge: .top).combined(with: .opacity),
                  removal: .move(edge: .top).combined(with: .opacity)
                )
              )
              .animation(.easeOut(duration: 0.2), value: viewModel.isSearchPanelVisible)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()

          // Footer
          FooterView(
            viewModel: viewModel,
            lastSaved: lastSaved,
            isEditorMode: isEditorMode,
            connectionConfig: connectionConfig,
            onSafeModeTap: { showSafeModeModal = true }
          )
        }

        // Right sidebar (conditionally shown) - now at same level as header
        RightSidebarContainer(viewModel: viewModel)
      }

      // Toast notification overlay (app-level via WorkspaceWindowManager)
      ToastOverlay()
    }
    .animation(
      .easeInOut(duration: 0.4), value: WorkspaceWindowManager.shared.toastState.currentToast
    )
    .windowAppearance(appSettings.themePreference.colorScheme)
    .safeModeModal(isPresented: $showSafeModeModal)
    // Note: Connection modals are now handled at workspace level (WorkspaceContainerView)
  }

}
