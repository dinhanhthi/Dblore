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
        } else if case .settings = content {
          // SettingsContent handles its own ScrollView
          ScrollView {
            contentView(for: content)
          }
        } else if case .jsonViewer = content {
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
    case .connectionDetails:
      return "Connection"
    case .connectionForm:
      return "Database Connection"
    case .settings:
      return "Settings"
    }
  }

  private var sidebarWidth: CGFloat {
    guard let content = viewModel.rightSidebarContent else {
      return ComponentSize.sidebarWidth
    }

    switch content {
    case .connectionForm:
      return 360
    case .settings:
      return 400  // Wider for settings
    default:
      return ComponentSize.sidebarWidth
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
        onSave: { newValue in
          viewModel.handleCellValueEdit(
            columnName: columnName,
            columnType: columnType,
            newValue: newValue,
            originalValue: value,
            tableName: tableName,
            rowData: rowData,
            primaryKeyColumns: primaryKeyColumns,
            rowIdentifier: rowIdentifier,
            cellId: cellId
          )
        },
        isReadOnly: viewModel.notebook.connectionConfig?.readOnly ?? false
      )
    case .connectionDetails:
      ConnectionInfoContent(config: viewModel.notebook.connectionConfig)
    case .connectionForm:
      ConnectionFormContent(viewModel: viewModel)
    case .settings:
      SettingsContent(viewModel: viewModel)
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

#Preview("Connection - Not Configured") {
  let viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .connectionDetails

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Connection Form") {
  let viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .connectionForm

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Connection - Connected") {
  let viewModel = NotebookViewModel()
  viewModel.notebook.connectionConfig = ConnectionConfig(
    host: "db.example.com",
    port: 5432,
    database: "my_database",
    username: "admin_user",
    password: "secret123",
    sslMode: .require
  )
  viewModel.rightSidebarContent = .connectionDetails

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
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
