//
//  HeaderWithSearchPanel.swift
//  SQLNotebook
//

import SwiftUI

/// Combined header and search panel with slide-in animation
/// Used by both Notebook and Editor modes
struct HeaderWithSearchPanel: View {
  let viewModel: NotebookViewModel

  var body: some View {
    ZStack(alignment: .top) {
      // Search panel (lower z-index, slides from top under header)
      VStack(spacing: 0) {
        Spacer()
          .frame(height: ComponentSize.headerHeight)

        if viewModel.isSearchPanelVisible {
          SearchPanelView(viewModel: viewModel)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
      }

      // Header (higher z-index, covers search panel animation)
      HeaderView(viewModel: viewModel)
    }
    .clipped()
  }
}
