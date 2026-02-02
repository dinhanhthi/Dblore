//
//  RightSidebarView.swift
//  SQLNotebook
//

import SwiftUI

struct RightSidebarView: View {
  @Bindable var viewModel: NotebookViewModel
  @Environment(WorkspaceManager.self) private var workspaceManager: WorkspaceManager?

  var body: some View {
    VStack(spacing: 0) {
      // Header
      sidebarHeader

      Divider()

      // Content
      if let content = viewModel.rightSidebarContent {
        if case .jsonViewer = content {
          // JSONViewerContent handles its own ScrollView for both vertical and horizontal
          VStack(alignment: .leading, spacing: 0) {
            contentView(for: content)
              .padding(Spacing.md)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if case .cellInfo = content {
          // CellInfoContent handles its own ScrollView with fixed header
          VStack(alignment: .leading, spacing: 0) {
            contentView(for: content)
              .padding(Spacing.md)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if case .executedQuery = content {
          // ExecutedQuerySidebarContent handles its own ScrollView
          VStack(alignment: .leading, spacing: 0) {
            contentView(for: content)
              .padding(Spacing.md)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    .frame(width: ComponentSize.sidebarWidth)
    .background(Color.cardBackground)
    .overlay(alignment: .leading) {
      Divider()
    }
  }

  private var sidebarHeader: some View {
    HStack {
      Text(headerTitle)
        .font(.subheading)
        .foregroundColor(.foreground)

      Spacer()

      Button(action: { viewModel.closeSidebar() }) {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(.foregroundMuted)
      }
      .buttonStyle(SidebarHeaderButtonStyle())
    }
    .padding(.horizontal, Spacing.md)
    .frame(height: ComponentSize.headerHeight)
    .background(Color.cardHeaderBackground)
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
    case .executedQuery:
      return "Executed Query"
    }
  }

  @ViewBuilder
  private func contentView(for content: SidebarContent) -> some View {
    // Using explicit switch to help type inference
    switch content {
    case .jsonViewer(let json, let path):
      JSONViewerContent(
        json: json, path: path,
        onSave: { newJSON in
          viewModel.handleJSONEdit(newJSON: newJSON, originalPath: path)
        })
    case .cellInfo(
      let columnName, let columnType, let value, let tableName, let rowData, let primaryKeyColumns,
      let rowIdentifier, let cellId):
      CellInfoContent(
        columnName: columnName,
        columnType: columnType,
        value: value,
        onSave: { [workspaceManager] newValue in
          viewModel.handleCellValueEdit(
            columnName: columnName,
            columnType: columnType,
            newValue: newValue,
            originalValue: value,
            tableName: tableName,
            rowData: rowData,
            primaryKeyColumns: primaryKeyColumns,
            rowIdentifier: rowIdentifier,
            cellId: cellId,
            connectionManager: workspaceManager?.connectionManager
          )
        },
        isReadOnly: viewModel.notebook.connectionConfig?.isReadOnly ?? false
      )
      .environment(viewModel)
    case .executedQuery(let query, let cellId, let limitWasCapped, let actualLimit):
      ExecutedQuerySidebarContent(
        query: query,
        cellId: cellId,
        limitWasCapped: limitWasCapped,
        actualLimit: actualLimit
      )
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

// MARK: - Previews

#Preview("Empty State") {
  HStack {
    Spacer()
    RightSidebarView(viewModel: NotebookViewModel())
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Cell Info - Long Text") {
  let viewModel = NotebookViewModel()
  let longText = """
    Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.
    """
  viewModel.rightSidebarContent = .cellInfo(
    columnName: "description",
    columnType: "TEXT",
    value: .string(longText),
    tableName: nil,
    rowData: nil,
    primaryKeyColumns: [],
    rowIdentifier: nil,
    cellId: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
