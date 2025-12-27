//
//  RightSidebarView+Previews.swift
//  SQLNotebook
//

import SwiftUI

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
    value: .string(longText)
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
