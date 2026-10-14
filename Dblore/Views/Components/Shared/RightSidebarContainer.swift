//
//  RightSidebarContainer.swift
//  Dblore
//

import SwiftUI

/// Right sidebar container with transition animation
/// Shared between Notebook and Editor modes
struct RightSidebarContainer: View {
  let viewModel: NotebookViewModel
  @ReduceMotion private var reduceMotion

  var body: some View {
    // The `if` and its animation live in this view so removal slides off the
    // trailing edge the same way insertion slides in from it.
    Group {
      if viewModel.isRightSidebarVisible {
        RightSidebarView(viewModel: viewModel)
          .transition(SidebarAnimation.trailingSlide)
      }
    }
    .animation(
      reduceMotion ? nil : SidebarAnimation.animation, value: viewModel.isRightSidebarVisible)
  }
}
