//
//  NotebookLayoutView.swift
//  SQLNotebook
//

import SwiftUI

/// Shared layout structure for both Editor and Notebook modes
/// Contains common UI elements: header, sidebars, footer, toast
struct NotebookLayoutView<Content: View>: View {
  let viewModel: NotebookViewModel
  @Binding var lastSaved: Date?
  let isEditorMode: Bool
  @Bindable private var appSettings = AppSettings.shared

  @ViewBuilder let content: Content

  var body: some View {
    ZStack {
      Color.appBackground
        .ignoresSafeArea()

      VStack(spacing: 0) {
        // Header and search panel
        HeaderWithSearchPanel(viewModel: viewModel)

        // Main content area with right sidebar only
        // (Left sidebar is now rendered at TabContainerView level for full height)
        GeometryReader { geometry in
          HStack(spacing: 0) {
            // Main content (passed from parent) or Schema Visualizer
            // with search panel overlay
            ZStack(alignment: .top) {
              if viewModel.isSchemaVisualizerActive {
                SchemaVisualizerContent(viewModel: viewModel)
              } else {
                content
              }

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
            .frame(maxWidth: .infinity)
            .clipped()

            // Right sidebar (conditionally shown)
            RightSidebarContainer(viewModel: viewModel)
          }
          .onChange(of: geometry.size.width) { oldWidth, newWidth in
            handleWindowWidthChange(newWidth)
          }
          .onAppear {
            handleWindowWidthChange(geometry.size.width)
          }
        }

        // Footer
        FooterView(viewModel: viewModel, lastSaved: lastSaved, isEditorMode: isEditorMode)
      }

      // Toast notification overlay
      ToastOverlay(viewModel: viewModel)
    }
    .animation(.easeInOut(duration: 0.4), value: viewModel.toastState.currentToast)
    .animation(.easeInOut(duration: 0.2), value: viewModel.isRightSidebarVisible)
    .animation(.easeInOut(duration: 0.2), value: viewModel.isLeftSidebarVisible)
    .windowAppearance(appSettings.themePreference.colorScheme)
    .connectionFormModal(viewModel: viewModel)
    .connectionInfoModal(viewModel: viewModel)
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
