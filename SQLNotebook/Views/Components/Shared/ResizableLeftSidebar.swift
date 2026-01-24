//
//  ResizableLeftSidebar.swift
//  SQLNotebook
//

import SwiftUI

/// Resizable left sidebar with divider
/// Shared between Notebook and Editor modes
struct ResizableLeftSidebar: View {
  let viewModel: NotebookViewModel
  @Bindable private var appSettings = AppSettings.shared
  let maxWidth: CGFloat

  var body: some View {
    if viewModel.isLeftSidebarVisible {
      let constrainedWidth = min(appSettings.leftSidebarWidth, maxWidth)

      LeftSidebarView(viewModel: viewModel)
        .frame(width: constrainedWidth)
        .transition(.move(edge: .leading))

      ResizableSidebarDivider(
        sidebarWidth: $appSettings.leftSidebarWidth,
        minWidth: 320,
        maxWidth: maxWidth,
        side: .left
      )
    }
  }
}
