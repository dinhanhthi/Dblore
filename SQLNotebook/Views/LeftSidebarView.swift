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

      HStack(spacing: Spacing.lg) {
        // Expand/Collapse all button
        if viewModel.connectionState.isConnected && !viewModel.isLoadingSchema {
          Button(action: {
            viewModel.toggleExpandCollapseAll()
          }) {
            Image(
              systemName: viewModel.areAllEntitiesExpanded
                ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            )
            .foregroundColor(.foregroundMuted)
          }
          .buttonStyle(GhostButtonStyle())
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
              onTableClick: {
                viewModel.insertTextIntoSelectedCell(table.name)
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
              onViewClick: {
                viewModel.insertTextIntoSelectedCell(view.name)
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
              },
              onFunctionClick: {
                viewModel.insertTextIntoSelectedCell(function.name)
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
              },
              onProcedureClick: {
                viewModel.insertTextIntoSelectedCell(procedure.name)
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
              },
              onUserClick: {
                viewModel.insertTextIntoSelectedCell(user.name)
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
              },
              onRoleClick: {
                viewModel.insertTextIntoSelectedCell(role.name)
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

// MARK: - Entity Section

struct EntitySection<Content: View>: View {
  let title: String
  let count: Int
  let icon: String
  let isExpanded: Bool
  let content: () -> Content

  @State private var sectionExpanded: Bool

  init(
    title: String,
    count: Int,
    icon: String,
    isExpanded: Bool = true,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.count = count
    self.icon = icon
    self.isExpanded = isExpanded
    self.content = content
    _sectionExpanded = State(initialValue: isExpanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Section header
      Button(action: {
        sectionExpanded.toggle()
      }) {
        HStack(spacing: Spacing.xs) {
          Image(systemName: sectionExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.foregroundMuted)
            .frame(width: 12, height: 12)

          Image(systemName: icon)
            .font(.system(size: 12))
            .foregroundColor(.accent)

          Text(title)
            .font(.monoMedium)
            .foregroundColor(.foreground)

          Text("(\(count))")
            .font(.monoSmall)
            .foregroundColor(.foregroundSubtle)

          Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
      }
      .buttonStyle(.plain)

      // Section content
      if sectionExpanded {
        content()
          .padding(.leading, Spacing.lg)  // Indent section content
          .overlay(alignment: .leading) {
            Rectangle()
              .fill(Color.foregroundSubtle.opacity(0.2))
              .frame(width: 1)
              .padding(.leading, Spacing.md + 6)  // Align with chevron center
          }
      }
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
  @State private var singleClickTask: Task<Void, Never>?

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
            .font(.monoMedium)
            .foregroundColor(.foreground)

          if !table.schema.isEmpty && table.schema != "public" {
            Text("(\(table.schema))")
              .font(.monoSmall)
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
          // Double click: cancel pending single click and insert table name
          singleClickTask?.cancel()
          singleClickTask = nil
          onTableClick()
        }
        .onTapGesture(count: 1) {
          // Single click: schedule toggle with delay
          singleClickTask?.cancel()
          singleClickTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            if !Task.isCancelled {
              onToggle()
            }
          }
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
        .padding(.leading, Spacing.lg)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.foregroundSubtle.opacity(0.2))
            .frame(width: 1)
            .padding(.leading, Spacing.md + 6)  // Align with chevron center
        }
      }
    }
  }
}

// MARK: - View Row View

struct ViewRowView: View {
  let view: DatabaseView
  let isExpanded: Bool
  let onToggle: () -> Void
  let onViewClick: () -> Void
  let onColumnClick: (String) -> Void

  @State private var isHovering = false
  @State private var singleClickTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // View row
      HStack(spacing: Spacing.xs) {
        // Expand/collapse chevron
        Button(action: onToggle) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.foregroundMuted)
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)

        // View icon
        Image(systemName: "eye")
          .font(.system(size: 12))
          .foregroundColor(.accent)

        // View name
        HStack(spacing: Spacing.xs) {
          Text(view.name)
            .font(.monoMedium)
            .foregroundColor(.foreground)

          if !view.schema.isEmpty && view.schema != "public" {
            Text("(\(view.schema))")
              .font(.monoSmall)
              .foregroundColor(.foregroundSubtle)
          }

          Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
          singleClickTask?.cancel()
          singleClickTask = nil
          onViewClick()
        }
        .onTapGesture(count: 1) {
          singleClickTask?.cancel()
          singleClickTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            if !Task.isCancelled {
              onToggle()
            }
          }
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(isHovering ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
      )
      .onHover { hovering in
        isHovering = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }

      // Columns (when expanded)
      if isExpanded {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(view.columns) { column in
            ColumnRowView(
              column: column,
              onClick: {
                onColumnClick(column.name)
              }
            )
          }
        }
        .padding(.leading, Spacing.lg)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.foregroundSubtle.opacity(0.2))
            .frame(width: 1)
            .padding(.leading, Spacing.md + 6)  // Align with chevron center
        }
      }
    }
  }
}

// MARK: - Function Row View

struct FunctionRowView: View {
  let function: DatabaseFunction
  let isExpanded: Bool
  let onToggle: () -> Void
  let onFunctionClick: () -> Void

  @State private var isHovering = false
  @State private var singleClickTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Function row
      HStack(alignment: .top, spacing: Spacing.xs) {
        // Expand/collapse chevron
        Button(action: onToggle) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.foregroundMuted)
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)  // Fine-tune alignment with text

        // Function icon
        Image(systemName: "function")
          .font(.system(size: 12))
          .foregroundColor(.accent)
          .padding(.top, 2)  // Fine-tune alignment with text

        // Function signature
        VStack(alignment: .leading, spacing: 2) {
          Text(function.name)
            .font(.monoMedium)
            .foregroundColor(.foreground)

          if !function.arguments.isEmpty {
            Text("(\(function.arguments))")
              .font(.monoSmall)
              .foregroundColor(.foregroundSubtle)
              .lineLimit(1)
          }
        }

        Spacer()
      }
      .contentShape(Rectangle())
      .onTapGesture(count: 2) {
        singleClickTask?.cancel()
        singleClickTask = nil
        onFunctionClick()
      }
      .onTapGesture(count: 1) {
        singleClickTask?.cancel()
        singleClickTask = Task {
          try? await Task.sleep(for: .milliseconds(50))
          if !Task.isCancelled {
            onToggle()
          }
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(isHovering ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
      )
      .onHover { hovering in
        isHovering = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }

      // Details (when expanded)
      if isExpanded {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          HStack {
            Text("Returns:")
              .font(.monoSmall)
              .foregroundColor(.foregroundMuted)
            Text(function.returnType)
              .font(.monoSmall)
              .foregroundColor(.foreground)
          }
          .padding(.leading, Spacing.lg)
          .padding(.horizontal, Spacing.md)
        }
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.foregroundSubtle.opacity(0.2))
            .frame(width: 1)
            .padding(.leading, Spacing.md + 6)  // Align with chevron center
        }
      }
    }
  }
}

// MARK: - Procedure Row View

struct ProcedureRowView: View {
  let procedure: DatabaseProcedure
  let isExpanded: Bool
  let onToggle: () -> Void
  let onProcedureClick: () -> Void

  @State private var isHovering = false
  @State private var singleClickTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Procedure row
      HStack(alignment: .top, spacing: Spacing.xs) {
        // Expand/collapse chevron
        Button(action: onToggle) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.foregroundMuted)
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)  // Fine-tune alignment with text

        // Procedure icon
        Image(systemName: "gearshape.2")
          .font(.system(size: 12))
          .foregroundColor(.accent)
          .padding(.top, 2)  // Fine-tune alignment with text

        // Procedure signature
        VStack(alignment: .leading, spacing: 2) {
          Text(procedure.name)
            .font(.monoMedium)
            .foregroundColor(.foreground)

          if !procedure.arguments.isEmpty {
            Text("(\(procedure.arguments))")
              .font(.monoSmall)
              .foregroundColor(.foregroundSubtle)
              .lineLimit(1)
          }
        }

        Spacer()
      }
      .contentShape(Rectangle())
      .onTapGesture(count: 2) {
        singleClickTask?.cancel()
        singleClickTask = nil
        onProcedureClick()
      }
      .onTapGesture(count: 1) {
        singleClickTask?.cancel()
        singleClickTask = Task {
          try? await Task.sleep(for: .milliseconds(50))
          if !Task.isCancelled {
            onToggle()
          }
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(isHovering ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
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
}

// MARK: - User Row View

struct UserRowView: View {
  let user: DatabaseUser
  let isExpanded: Bool
  let onToggle: () -> Void
  let onUserClick: () -> Void

  @State private var isHovering = false
  @State private var singleClickTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // User row
      HStack(spacing: Spacing.xs) {
        // Expand/collapse chevron
        Button(action: onToggle) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.foregroundMuted)
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)

        // User icon
        Image(systemName: user.isSuperuser ? "person.badge.key" : "person")
          .font(.system(size: 12))
          .foregroundColor(user.isSuperuser ? .warning : .accent)

        // User name
        Text(user.name)
          .font(.monoMedium)
          .foregroundColor(.foreground)

        Spacer()
      }
      .contentShape(Rectangle())
      .onTapGesture(count: 2) {
        singleClickTask?.cancel()
        singleClickTask = nil
        onUserClick()
      }
      .onTapGesture(count: 1) {
        singleClickTask?.cancel()
        singleClickTask = Task {
          try? await Task.sleep(for: .milliseconds(50))
          if !Task.isCancelled {
            onToggle()
          }
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(isHovering ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
      )
      .onHover { hovering in
        isHovering = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }

      // Attributes (when expanded)
      if isExpanded && !user.attributes.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          ForEach(user.attributes, id: \.self) { attribute in
            HStack {
              Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 8))
                .foregroundColor(.success)
              Text(attribute)
                .font(.monoSmall)
                .foregroundColor(.foregroundMuted)
            }
          }
        }
        .padding(.leading, Spacing.lg)
        .padding(.horizontal, Spacing.md)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.foregroundSubtle.opacity(0.2))
            .frame(width: 1)
            .padding(.leading, Spacing.md + 6)  // Align with chevron center
        }
      }
    }
  }
}

// MARK: - Role Row View

struct RoleRowView: View {
  let role: DatabaseRole
  let isExpanded: Bool
  let onToggle: () -> Void
  let onRoleClick: () -> Void

  @State private var isHovering = false
  @State private var singleClickTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Role row
      HStack(spacing: Spacing.xs) {
        // Expand/collapse chevron
        Button(action: onToggle) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.foregroundMuted)
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)

        // Role icon
        Image(systemName: role.isSuperuser ? "person.2.badge.key" : "person.2")
          .font(.system(size: 12))
          .foregroundColor(role.isSuperuser ? .warning : .accent)

        // Role name
        Text(role.name)
          .font(.monoMedium)
          .foregroundColor(.foreground)

        Spacer()

        // Member count badge
        if !role.members.isEmpty {
          Text("\(role.members.count)")
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
        singleClickTask?.cancel()
        singleClickTask = nil
        onRoleClick()
      }
      .onTapGesture(count: 1) {
        singleClickTask?.cancel()
        singleClickTask = Task {
          try? await Task.sleep(for: .milliseconds(50))
          if !Task.isCancelled {
            onToggle()
          }
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(isHovering ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
      )
      .onHover { hovering in
        isHovering = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }

      // Details (when expanded)
      if isExpanded {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          // Attributes
          if !role.attributes.isEmpty {
            ForEach(role.attributes, id: \.self) { attribute in
              HStack {
                Image(systemName: "checkmark.circle.fill")
                  .font(.system(size: 8))
                  .foregroundColor(.success)
                Text(attribute)
                  .font(.monoSmall)
                  .foregroundColor(.foregroundMuted)
              }
            }
          }

          // Members
          if !role.members.isEmpty {
            Divider()
              .padding(.vertical, Spacing.xs)
            Text("Members:")
              .font(.monoSmall)
              .foregroundColor(.foregroundMuted)
            ForEach(role.members, id: \.self) { member in
              HStack {
                Image(systemName: "person.fill")
                  .font(.system(size: 8))
                  .foregroundColor(.accent)
                Text(member)
                  .font(.monoSmall)
                  .foregroundColor(.foreground)
              }
            }
          }
        }
        .padding(.leading, Spacing.lg)
        .padding(.horizontal, Spacing.md)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.foregroundSubtle.opacity(0.2))
            .frame(width: 1)
            .padding(.leading, Spacing.md + 6)  // Align with chevron center
        }
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
          .font(.monoSmall)
          .foregroundColor(.foregroundMuted)

        Spacer()

        // Type and nullable indicator
        HStack(spacing: 2) {
          Text(column.type.uppercased())
            .font(.monoSmall)
            .foregroundColor(.foregroundSubtle)

          if column.isNullable {
            Text("?")
              .font(.monoSmall)
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
    .onTapGesture(count: 2) {
      onClick()
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
