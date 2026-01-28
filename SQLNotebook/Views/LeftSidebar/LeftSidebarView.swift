//
//  LeftSidebarView.swift
//  SQLNotebook
//

import SwiftUI

struct LeftSidebarView: View {
  @Bindable var viewModel: NotebookViewModel
  @State private var selectedTab: SidebarTab = .public

  enum SidebarTab: String, CaseIterable {
    case `public` = "Public"
    case security = "Security"
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      sidebarHeader

      Divider()

      // Tab selector
      if viewModel.connectionState.isConnected && !viewModel.isLoadingSchema {
        tabSelector
        Divider()
      }

      // Content
      if !viewModel.connectionState.isConnected {
        emptyState
      } else if viewModel.isLoadingSchema {
        loadingState
      } else {
        contentForSelectedTab
      }
    }
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

      HStack(spacing: Spacing.sm) {
        // Expand/Collapse all button
        if viewModel.connectionState.isConnected && !viewModel.isLoadingSchema {
          // Schema Visualizer button
          Button(action: {
            viewModel.toggleSchemaVisualizer()
          }) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
              .font(.system(size: 12, weight: .medium))
              .foregroundColor(.accent)
          }
          .buttonStyle(SidebarHeaderButtonStyle(isActive: viewModel.isSchemaVisualizerActive))
          .help(
            viewModel.isSchemaVisualizerActive
              ? "Close Schema Visualizer" : "Visualize Schema Relationships")

          Button(action: {
            viewModel.toggleExpandCollapseAll()
          }) {
            Image(
              systemName: viewModel.areAllEntitiesExpanded
                ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.foregroundMuted)
          }
          .buttonStyle(SidebarHeaderButtonStyle())
          .help(viewModel.areAllEntitiesExpanded ? "Collapse all" : "Expand all")
        }

        // Refresh button
        if viewModel.connectionState.isConnected {
          Button(action: {
            Task { @MainActor [viewModel] in
              await viewModel.refreshDatabaseSchema()
            }
          }) {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(.foregroundMuted)
          }
          .buttonStyle(SidebarHeaderButtonStyle())
          .disabled(viewModel.isLoadingSchema)
        }

        // Close button
        Button(action: { viewModel.toggleLeftSidebar() }) {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.foregroundMuted)
        }
        .buttonStyle(SidebarHeaderButtonStyle())
      }
    }
    .padding(.horizontal, Spacing.md)
    .frame(height: ComponentSize.headerHeight)
    .background(Color.cardHeaderBackground)
  }

  private var tabSelector: some View {
    let selectedIndex = SidebarTab.allCases.firstIndex(of: selectedTab) ?? 0

    return ZStack {
      // Background
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(Color.inputBackground)
        .overlay(
          RoundedRectangle(cornerRadius: CornerRadius.md)
            .stroke(Color.border, lineWidth: 1)
        )

      // Content with padding
      GeometryReader { geometry in
        let inset: CGFloat = 3
        let availableWidth = geometry.size.width - (inset * 2)
        let tabWidth = availableWidth / CGFloat(SidebarTab.allCases.count)

        ZStack(alignment: .leading) {
          // Sliding indicator
          RoundedRectangle(cornerRadius: CornerRadius.md - 2)
            .fill(Color.accent)
            .frame(width: tabWidth, height: geometry.size.height - (inset * 2))
            .offset(x: inset + CGFloat(selectedIndex) * tabWidth)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selectedTab)

          // Tab buttons
          HStack(spacing: 0) {
            ForEach(SidebarTab.allCases, id: \.self) { tab in
              Button(action: {
                withAnimation {
                  selectedTab = tab
                }
              }) {
                Text(tab.rawValue)
                  .font(.body)
                  .fontWeight(selectedTab == tab ? .semibold : .regular)
                  .foregroundColor(selectedTab == tab ? .white : .foreground)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                  .contentShape(Rectangle())
              }
              .buttonStyle(PlainButtonStyle())
              .onHover { hovering in
                if hovering {
                  NSCursor.pointingHand.push()
                } else {
                  NSCursor.pop()
                }
              }
            }
          }
        }
        .padding(inset)
      }
    }
    .frame(height: 28)
    .padding(.horizontal, Spacing.sm)
    .padding(.top, Spacing.sm)
    .padding(.bottom, Spacing.xs)
  }

  @ViewBuilder
  private var contentForSelectedTab: some View {
    switch selectedTab {
    case .public:
      publicTabContent
    case .security:
      securityTabContent
    }
  }

  private var publicTabContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        // Tables section
        EntitySection(
          title: "Tables",
          count: viewModel.databaseTables.count,
          icon: "tablecells",
          isExpanded: true
        ) {
          ForEach(viewModel.databaseTables) { table in
            TableRowView(
              table: table,
              isExpanded: table.isExpanded,
              onToggle: {
                viewModel.toggleTableExpansion(tableId: table.id)
              },
              onColumnClick: { columnName in
                viewModel.insertTextIntoSelectedCell(columnName)
              }
            )
          }
        }

        // Views section
        EntitySection(
          title: "Views",
          count: viewModel.databaseViews.count,
          icon: "eye",
          isExpanded: true
        ) {
          ForEach(viewModel.databaseViews) { view in
            ViewRowView(
              view: view,
              isExpanded: view.isExpanded,
              onToggle: {
                viewModel.toggleViewExpansion(viewId: view.id)
              },
              onColumnClick: { columnName in
                viewModel.insertTextIntoSelectedCell(columnName)
              }
            )
          }
        }

        // Functions section
        EntitySection(
          title: "Functions",
          count: viewModel.databaseFunctions.count,
          icon: "function",
          isExpanded: true
        ) {
          ForEach(viewModel.databaseFunctions) { function in
            FunctionRowView(
              function: function,
              isExpanded: function.isExpanded,
              onToggle: {
                viewModel.toggleFunctionExpansion(functionId: function.id)
              }
            )
          }
        }

        // Procedures section
        EntitySection(
          title: "Procedures",
          count: viewModel.databaseProcedures.count,
          icon: "gearshape.2",
          isExpanded: true
        ) {
          ForEach(viewModel.databaseProcedures) { procedure in
            ProcedureRowView(
              procedure: procedure,
              isExpanded: procedure.isExpanded,
              onToggle: {
                viewModel.toggleProcedureExpansion(procedureId: procedure.id)
              }
            )
          }
        }
      }
      .padding(.vertical, Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var securityTabContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        // Users section
        EntitySection(
          title: "Users",
          count: viewModel.databaseUsers.count,
          icon: "person",
          isExpanded: true
        ) {
          ForEach(viewModel.databaseUsers) { user in
            UserRowView(
              user: user,
              isExpanded: user.isExpanded,
              onToggle: {
                viewModel.toggleUserExpansion(userId: user.id)
              }
            )
          }
        }

        // Roles section
        EntitySection(
          title: "Roles",
          count: viewModel.databaseRoles.count,
          icon: "person.2",
          isExpanded: true
        ) {
          ForEach(viewModel.databaseRoles) { role in
            RoleRowView(
              role: role,
              isExpanded: role.isExpanded,
              onToggle: {
                viewModel.toggleRoleExpansion(roleId: role.id)
              }
            )
          }
        }
      }
      .padding(.vertical, Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
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

  // Create sample tables
  let usersTable = DatabaseTable(
    schema: "public",
    name: "users",
    columns: [
      DatabaseColumn(name: "id", type: "integer", isNullable: false, isPrimaryKey: true),
      DatabaseColumn(name: "email", type: "varchar", isNullable: false),
      DatabaseColumn(name: "name", type: "varchar", isNullable: true),
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
    ],
    isExpanded: false,
    rowCount: 5678
  )

  viewModel.databaseTables = [usersTable, postsTable]

  // Create sample views
  viewModel.databaseViews = [
    DatabaseView(schema: "public", name: "active_users"),
    DatabaseView(schema: "public", name: "recent_posts"),
  ]

  // Create sample functions
  viewModel.databaseFunctions = [
    DatabaseFunction(
      schema: "public", name: "calculate_age", returnType: "integer", arguments: "birth_date date"
    ),
    DatabaseFunction(
      schema: "public", name: "get_user_posts", returnType: "SETOF posts", arguments: "user_id int"
    ),
  ]

  // Create sample users
  viewModel.databaseUsers = [
    DatabaseUser(name: "postgres", canLogin: true, isSuperuser: true),
    DatabaseUser(name: "app_user", canLogin: true),
  ]

  // Create sample roles
  viewModel.databaseRoles = [
    DatabaseRole(name: "read_only", members: ["app_user"]),
    DatabaseRole(name: "admin", canCreateDB: true, members: ["postgres"]),
  ]

  return HStack {
    LeftSidebarView(viewModel: viewModel)
    Spacer()
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
