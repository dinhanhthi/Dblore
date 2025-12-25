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
        ScrollView {
          contentView(for: content)
            .padding(Spacing.md)
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
          .foregroundColor(.foregroundMuted)
      }
      .buttonStyle(GhostButtonStyle())
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
    case .connectionDetails:
      return "Connection"
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

// MARK: - JSON Viewer

struct JSONViewerContent: View {
  let json: String
  let path: String
  @State private var isPrettyPrinted = true
  @State private var searchText = ""

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Path info
      Text(path)
        .font(.caption)
        .foregroundColor(.foregroundMuted)

      // Toolbar
      HStack {
        Toggle("Pretty Print", isOn: $isPrettyPrinted)
          .toggleStyle(.switch)
          .controlSize(.small)

        Spacer()

        Button(action: copyToClipboard) {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(GhostButtonStyle())
      }

      // JSON content
      ScrollView(.horizontal, showsIndicators: false) {
        Text(formattedJSON)
          .font(.monoSmall)
          .foregroundColor(.foreground)
          .textSelection(.enabled)
      }
      .padding(Spacing.sm)
      .background(Color.cellBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    }
  }

  private var formattedJSON: String {
    if isPrettyPrinted {
      guard let data = json.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data),
        let prettyData = try? JSONSerialization.data(
          withJSONObject: object, options: .prettyPrinted),
        let prettyString = String(data: prettyData, encoding: .utf8)
      else {
        return json
      }
      return prettyString
    }
    return json
  }

  private func copyToClipboard() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(formattedJSON, forType: .string)
  }
}

// MARK: - Cell Info Content

struct CellInfoContent: View {
  let columnName: String
  let columnType: String
  let value: CellValue

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Column info
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Column")
          .font(.caption)
          .foregroundColor(.foregroundSubtle)

        Text("\(columnName) (\(columnType))")
          .font(.mono)
          .foregroundColor(.foreground)
      }

      Divider()

      // Value type
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Type")
          .font(.caption)
          .foregroundColor(.foregroundSubtle)

        Text(valueTypeName)
          .font(.mono)
          .foregroundColor(.foregroundMuted)
      }

      Divider()

      // Full value
      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack {
          Text("Value")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)

          Spacer()

          Button(action: copyToClipboard) {
            Label("Copy", systemImage: "doc.on.doc")
          }
          .buttonStyle(GhostButtonStyle())
        }

        ScrollView {
          Text(value.fullString)
            .font(.mono)
            .foregroundColor(value.isNull ? .foregroundSubtle : .foreground)
            .italic(value.isNull)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
        .padding(Spacing.sm)
        .background(Color.cellBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      }
    }
  }

  private var valueTypeName: String {
    switch value {
    case .string: return "String"
    case .int: return "Integer"
    case .double: return "Double"
    case .bool: return "Boolean"
    case .null: return "NULL"
    case .json: return "JSON"
    case .date: return "Date"
    case .data: return "Binary Data"
    }
  }

  private func copyToClipboard() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value.fullString, forType: .string)
  }
}

// MARK: - Connection Info Content

struct ConnectionInfoContent: View {
  let config: ConnectionConfig?

  var body: some View {
    if let config {
      VStack(alignment: .leading, spacing: Spacing.md) {
        infoRow(label: "Host", value: config.host)
        infoRow(label: "Port", value: String(config.port))
        infoRow(label: "Database", value: config.database)
        infoRow(label: "Username", value: config.username)
        infoRow(label: "SSL Mode", value: config.sslMode.displayName)
      }
    } else {
      Text("No connection configured")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
    }
  }

  private func infoRow(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.caption)
        .foregroundColor(.foregroundSubtle)

      Text(value)
        .font(.mono)
        .foregroundColor(.foreground)
    }
  }
}

#Preview {
  HStack {
    Spacer()
    RightSidebarView(viewModel: NotebookViewModel())
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
