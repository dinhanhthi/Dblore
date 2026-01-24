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

        // Main content area with sidebars
        GeometryReader { geometry in
          HStack(spacing: 0) {
            // Left sidebar (conditionally shown)
            ResizableLeftSidebar(viewModel: viewModel, maxWidth: geometry.size.width * 0.35)

            // Main content (passed from parent)
            content
              .frame(maxWidth: .infinity)

            // Right sidebar (conditionally shown)
            RightSidebarContainer(viewModel: viewModel)
          }
        }

        // Footer
        FooterView(viewModel: viewModel, lastSaved: lastSaved, isEditorMode: isEditorMode)
      }

      // Toast notification overlay
      ToastOverlay(viewModel: viewModel)
    }
    .animation(.easeInOut(duration: 0.4), value: viewModel.currentToast)
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.isSearchPanelVisible)
    .animation(.easeInOut(duration: 0.2), value: viewModel.isRightSidebarVisible)
    .animation(.easeInOut(duration: 0.2), value: viewModel.isLeftSidebarVisible)
    .windowAppearance(appSettings.themePreference.colorScheme)
  }
}
