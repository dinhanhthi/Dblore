//
//  RightSidebarView.swift
//  SQLNotebook
//

import SwiftUI

struct RightSidebarView: View {
  @Bindable var viewModel: NotebookViewModel

  var body: some View {
    VStack(spacing: 0) {
      // Header
      sidebarHeader

      Divider()

      // Content
      if let content = viewModel.rightSidebarContent {
        // ConnectionFormContent handles its own layout with ScrollView and fixed footer
        if case .connectionForm = content {
          contentView(for: content)
        } else {
          // Other content types use ScrollView wrapper
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              contentView(for: content)
                .padding(Spacing.md)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
          }
        }
      } else {
        emptyState
      }
    }
    .frame(width: sidebarWidth)
    .background(Color.cardBackground)
    .overlay(alignment: .leading) {
      Divider()
    }
    .animation(.easeInOut(duration: 0.2), value: sidebarWidth)
  }

  private var sidebarHeader: some View {
    HStack {
      Text(headerTitle)
        .font(.subheading)
        .foregroundColor(.foreground)

      Spacer()

      Button(action: { viewModel.closeSidebar() }) {
        Image(systemName: "xmark")
          .foregroundColor(.foregroundMuted)
      }
      .buttonStyle(GhostButtonStyle())
    }
    .padding(.horizontal, Spacing.md)
    .frame(height: ComponentSize.headerHeight)
    .background(Color.cellBackground)
  }

  private var headerTitle: String {
    guard let content = viewModel.rightSidebarContent else {
      return "Details"
    }

    switch content {
    case .jsonViewer:
      return "JSON Viewer"
    case .cellInfo:
      return "Cell Value"
    case .connectionDetails:
      return "Connection"
    case .connectionForm:
      return "Database Connection"
    }
  }

  private var sidebarWidth: CGFloat {
    guard let content = viewModel.rightSidebarContent else {
      return ComponentSize.sidebarWidth
    }

    switch content {
    case .connectionForm:
      return 360
    default:
      return ComponentSize.sidebarWidth
    }
  }

  @ViewBuilder
  private func contentView(for content: SidebarContent) -> some View {
    // Using explicit switch to help type inference
    switch content {
    case .jsonViewer(let json, let path):
      JSONViewerContent(json: json, path: path)
    case .cellInfo(let columnName, let columnType, let value):
      CellInfoContent(columnName: columnName, columnType: columnType, value: value)
    case .connectionDetails:
        ConnectionInfoContent(config: viewModel.notebook.connectionConfig)
    case .connectionForm:
      ConnectionFormContent(viewModel: viewModel)
    }
  }

  private var emptyState: some View {
    VStack(spacing: Spacing.md) {
      Image(systemName: "sidebar.right")
        .font(.system(size: 32))
        .foregroundColor(.foregroundSubtle)

      Text("JSON data will be displayed here when a cell's output is selected.")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Spacing.xl)
  }
}
