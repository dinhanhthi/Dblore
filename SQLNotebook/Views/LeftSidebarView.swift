//
//  LeftSidebarView.swift
//  SQLNotebook
//

import SwiftUI

struct LeftSidebarView: View {
  @Bindable var viewModel: NotebookViewModel

  var body: some View {
    VStack(spacing: 0) {
      // Header
      sidebarHeader

      Divider()

      // Content
      if !viewModel.connectionState.isConnected {
        emptyState
      } else if viewModel.isLoadingSchema {
        loadingState
      } else if viewModel.databaseTables.isEmpty {
        emptySchemaState
      } else {
        schemaTreeView
      }
    }
    .frame(width: ComponentSize.sidebarWidth)
    .background(Color.cardBackground)
    .overlay(alignment: .trailing) {
      Divider()
    }
  }

  private var sidebarHeader: some View {
    HStack {
      Text("Database")
        .font(.subheading)
        .foregroundColor(.foreground)

      Spacer()

      HStack(spacing: Spacing.lg) {
        // Refresh button
        if viewModel.connectionState.isConnected {
          Button(action: {
            Task { @MainActor [viewModel] in
              await viewModel.refreshDatabaseSchema()
            }
          }) {
            Image(systemName: "arrow.clockwise")
              .foregroundColor(.foregroundMuted)
          }
          .buttonStyle(GhostButtonStyle())
          .disabled(viewModel.isLoadingSchema)
        }

        // Close button
        Button(action: { viewModel.toggleLeftSidebar() }) {
          Image(systemName: "xmark")
            .foregroundColor(.foregroundMuted)
        }
        .buttonStyle(GhostButtonStyle())
      }
    }
    .padding(.horizontal, Spacing.md)
    .frame(height: ComponentSize.headerHeight)
    .background(Color.cardHeaderBackground)
  }

  private var emptyState: some View {
    VStack(spacing: Spacing.md) {
      Image(systemName: "cylinder")
        .font(.system(size: 32))
        .foregroundColor(.foregroundSubtle)

      Text("Connect to a database to view schema")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Spacing.xl)
  }

  private var loadingState: some View {
    VStack(spacing: Spacing.md) {
      ProgressView()
        .controlSize(.regular)
        .tint(.accent)

      Text("Loading schema...")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptySchemaState: some View {
    VStack(spacing: Spacing.md) {
      Image(systemName: "tablecells.badge.ellipsis")
        .font(.system(size: 32))
        .foregroundColor(.foregroundSubtle)

      Text("No tables found in this database")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Spacing.xl)
  }

  private var schemaTreeView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(viewModel.databaseTables) { table in
          TableRowView(
            table: table,
            isExpanded: table.isExpanded,
            onToggle: {
              viewModel.toggleTableExpansion(tableId: table.id)
            },
            onTableClick: {
              viewModel.insertTextIntoSelectedCell(table.name)
            },
            onColumnClick: { columnName in
              viewModel.insertTextIntoSelectedCell(columnName)
            }
          )
        }
      }
      .padding(.vertical, Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - Table Row View

struct TableRowView: View {
  let table: DatabaseTable
  let isExpanded: Bool
  let onToggle: () -> Void
  let onTableClick: () -> Void
  let onColumnClick: (String) -> Void

  @State private var isHoveringTable = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Table row
      HStack(spacing: Spacing.xs) {
        // Expand/collapse chevron
        Button(action: onToggle) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.foregroundMuted)
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)

        // Table icon
        Image(systemName: "tablecells")
          .font(.system(size: 12))
          .foregroundColor(.accent)

        // Table name
        HStack(spacing: Spacing.xs) {
          Text(table.name)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.foreground)

          if !table.schema.isEmpty && table.schema != "public" {
            Text("(\(table.schema))")
              .font(.system(.caption2, design: .monospaced))
              .foregroundColor(.foregroundSubtle)
          }

          Spacer()

          // Row count badge
          if let rowCount = table.rowCount {
            Text("\(rowCount)")
              .font(.system(.caption2))
              .foregroundColor(.foregroundSubtle)
              .padding(.horizontal, Spacing.xs)
              .padding(.vertical, 1)
              .background(
                RoundedRectangle(cornerRadius: 3)
                  .fill(Color.inputBackground)
              )
          }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
          onTableClick()
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(isHoveringTable ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
      )
      .onHover { hovering in
        isHoveringTable = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }

      // Columns (when expanded)
      if isExpanded {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(table.columns) { column in
            ColumnRowView(
              column: column,
              onClick: {
                onColumnClick(column.name)
              }
            )
          }
        }
        .padding(.leading, Spacing.xl)
      }
    }
  }
}

// MARK: - Column Row View

struct ColumnRowView: View {
  let column: DatabaseColumn
  let onClick: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: onClick) {
      HStack(spacing: Spacing.xs) {
        // Column icon
        Image(systemName: column.typeIcon)
          .font(.system(size: 10))
          .foregroundColor(column.isPrimaryKey ? .warning : .foregroundSubtle)
          .frame(width: 12)

        // Column name
        Text(column.name)
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.foregroundMuted)

        Spacer()

        // Type and nullable indicator
        HStack(spacing: 2) {
          Text(column.type.uppercased())
            .font(.system(.caption2))
            .foregroundColor(.foregroundSubtle)

          if column.isNullable {
            Text("?")
              .font(.system(.caption2, weight: .bold))
              .foregroundColor(.foregroundSubtle)
          }
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.sm)
        .fill(isHovering ? Color.cellBackgroundHover.opacity(0.3) : Color.clear)
    )
    .onHover { hovering in
      isHovering = hovering
      if hovering {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
      }
    }
  }
}

// MARK: - Preview

#Preview("Empty State") {
  let viewModel = NotebookViewModel()

  return HStack {
    LeftSidebarView(viewModel: viewModel)
    Spacer()
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Loading State") {
  let viewModel = NotebookViewModel()
  viewModel.connectionState = .connected
  viewModel.isLoadingSchema = true

  return HStack {
    LeftSidebarView(viewModel: viewModel)
    Spacer()
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("With Schema") {
  let viewModel = NotebookViewModel()
  viewModel.connectionState = .connected

  // Create sample tables with various data types
  let usersTable = DatabaseTable(
    schema: "public",
    name: "users",
    columns: [
      DatabaseColumn(name: "id", type: "integer", isNullable: false, isPrimaryKey: true),
      DatabaseColumn(name: "uuid", type: "uuid", isNullable: false),
      DatabaseColumn(name: "email", type: "varchar", isNullable: false),
      DatabaseColumn(name: "name", type: "varchar", isNullable: true),
      DatabaseColumn(name: "age", type: "integer", isNullable: true),
      DatabaseColumn(name: "balance", type: "decimal", isNullable: true),
      DatabaseColumn(name: "is_active", type: "boolean", isNullable: false),
      DatabaseColumn(name: "created_at", type: "timestamp", isNullable: false),
      DatabaseColumn(name: "metadata", type: "jsonb", isNullable: true),
      DatabaseColumn(name: "tags", type: "text[]", isNullable: true),
    ],
    isExpanded: true,
    rowCount: 1234
  )

  let postsTable = DatabaseTable(
    schema: "public",
    name: "posts",
    columns: [
      DatabaseColumn(name: "id", type: "bigserial", isNullable: false, isPrimaryKey: true),
      DatabaseColumn(name: "user_id", type: "integer", isNullable: false),
      DatabaseColumn(name: "title", type: "varchar", isNullable: false),
      DatabaseColumn(name: "content", type: "text", isNullable: true),
      DatabaseColumn(name: "published", type: "boolean", isNullable: false),
      DatabaseColumn(name: "views", type: "bigint", isNullable: true),
      DatabaseColumn(name: "rating", type: "float", isNullable: true),
    ],
    isExpanded: false,
    rowCount: 5678
  )

  viewModel.databaseTables = [usersTable, postsTable]

  return HStack {
    LeftSidebarView(viewModel: viewModel)
    Spacer()
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
