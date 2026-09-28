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
    .chromeGlass()
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
          .foregroundColor(.foregroundMuted)
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .controlSize(.small)
      .help("Close sidebar")
    }
    .padding(.horizontal, Spacing.md)
    .frame(height: ComponentSize.headerHeight)
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
      let cellId):
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
            cellId: cellId,
            connectionManager: workspaceManager?.connectionManager
          )
        },
        // Editable only for a single table with a primary key, on a writable connection
        isReadOnly: !viewModel.canEdit(
          tableName: tableName, primaryKeyColumns: primaryKeyColumns,
          columnNames: Set(rowData.map { Array($0.keys) } ?? []))
      )
      .environment(viewModel)
    case .executedQuery(let query, let cellId):
      ExecutedQuerySidebarContent(query: query, cellId: cellId)
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
