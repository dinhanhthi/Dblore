//
//  DocumentLayoutView.swift
//  Dblore
//

import SwiftUI

/// Shared layout structure for both Editor and Notebook modes
/// Contains common UI elements: header, sidebars, toast (the footer is window-level, see
/// WorkspaceContainerView)
struct DocumentLayoutView<Content: View>: View {
  let viewModel: NotebookViewModel
  @ReduceMotion private var reduceMotion

  @ViewBuilder let content: Content

  var body: some View {
    ZStack {
      Color.appBackground
        .ignoresSafeArea()

      // Main layout: HStack with left content area + right sidebar
      // Right sidebar now extends full height including header level
      HStack(spacing: 0) {
        // Left side: Header + Content
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
                  .frame(width: 420)
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
        }

        // Right sidebar (conditionally shown) - now at same level as header
        RightSidebarContainer(viewModel: viewModel)
      }
      // Slide the sidebar (and resize the content beside it). Only callers that use
      // `withSidebarAnimation` animate: the app-wide kill switch blocks plain state changes
      .animation(
        reduceMotion ? nil : SidebarAnimation.animation, value: viewModel.isRightSidebarVisible)

      // Toast notification overlay (app-level via WorkspaceWindowManager)
      ToastOverlay()
    }
    // Note: Connection modals are now handled at workspace level (WorkspaceContainerView)
  }

}
