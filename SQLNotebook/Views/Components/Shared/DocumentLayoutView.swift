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

  @ViewBuilder let content: Content

  var body: some View {
    ZStack {
      Color.appBackground
        .ignoresSafeArea()

      // Main layout: HStack with left content area + right sidebar
      // Right sidebar now extends full height including header level
      GeometryReader { geometry in
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
              connectionConfig: connectionConfig
            )
          }

          // Right sidebar (conditionally shown) - now at same level as header
          RightSidebarContainer(viewModel: viewModel)
        }
        .onChange(of: geometry.size.width) { oldWidth, newWidth in
          handleWindowWidthChange(newWidth)
        }
        .onAppear {
          handleWindowWidthChange(geometry.size.width)
        }
      }

      // Toast notification overlay (app-level via WorkspaceWindowManager)
      ToastOverlay()
    }
    .animation(
      .easeInOut(duration: 0.4), value: WorkspaceWindowManager.shared.toastState.currentToast
    )
    .animation(.easeInOut(duration: 0.2), value: viewModel.isRightSidebarVisible)
    .animation(.easeInOut(duration: 0.2), value: viewModel.isLeftSidebarVisible)
    .windowAppearance(appSettings.themePreference.colorScheme)
    // Note: Connection modals are now handled at workspace level (WorkspaceContainerView)
  }

  // MARK: - Responsive Sidebar Logic

  /// Handle window width change for responsive sidebar behavior
  /// When width < 1200pt, only allow one sidebar to be open at a time
  private func handleWindowWidthChange(_ width: CGFloat) {
    let narrowWindowThreshold: CGFloat = 1200

    // If window is narrow and both sidebars are open, keep only right sidebar
    if width < narrowWindowThreshold
      && viewModel.isLeftSidebarVisible
      && viewModel.isRightSidebarVisible
    {
      viewModel.isLeftSidebarVisible = false
    }
  }
}
