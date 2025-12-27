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

#Preview("JSON Viewer") {
  let viewModel = NotebookViewModel()
  let jsonData = """
    {
      "user": {
        "id": 456,
        "name": "Jane Smith",
        "profile": {
          "bio": "Software engineer passionate about databases",
          "location": "San Francisco, CA",
          "website": "https://janesmith.dev"
        },
        "preferences": {
          "theme": "dark",
          "notifications": true,
          "language": "en-US"
        }
      },
      "metadata": {
        "created_at": "2024-01-15T10:30:00Z",
        "updated_at": "2024-03-20T14:45:00Z",
        "version": 3
      },
      "array": [1, 2, 3, 4, 5],
      "object": {
        "key": "value",
        "key2": "value2"
      }
      "null": null,
      "boolean": true,
      "number": 123.45,
      "date": "2024-01-15T10:30:00Z",
      "binary": "SGVsbG8sIFdvcmxkIQ=="
    }
    """
  viewModel.rightSidebarContent = .jsonViewer(json: jsonData, path: "users.details")

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
