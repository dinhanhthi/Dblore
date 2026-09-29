//
//  RightSidebarContainer.swift
//  Dblore
//

import SwiftUI

/// Right sidebar container with transition animation
/// Shared between Notebook and Editor modes
struct RightSidebarContainer: View {
  let viewModel: NotebookViewModel

  var body: some View {
    if viewModel.isRightSidebarVisible {
      RightSidebarView(viewModel: viewModel)
        .transition(.move(edge: .trailing))
    }
  }
}
