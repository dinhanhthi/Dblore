//
//  WorkspaceLeftSidebarContent.swift
//  SQLNotebook
//
//  Left sidebar content that displays schema directly from WorkspaceManager
//  Used when workspace is connected but no document is open
//

import SwiftUI

/// Left sidebar content that shows schema from WorkspaceManager
/// Used when connected but no active tab exists
struct WorkspaceLeftSidebarContent: View {
  @Bindable var workspaceManager: WorkspaceManager
  @State private var selectedTab: SidebarTab = .public

  enum SidebarTab: String, CaseIterable {
    case `public` = "Public"
    case security = "Security"
  }

  var body: some View {
    VStack(spacing: 0) {
      // Tab selector (only when connected and not loading)
      if workspaceManager.connectionState.isConnected && !workspaceManager.isLoadingSchema {
        tabSelector
        Divider()
      }

      // Content
      if !workspaceManager.connectionState.isConnected {
        emptyState
      } else if workspaceManager.isLoadingSchema {
        loadingState
      } else {
        contentForSelectedTab
      }
    }
    .background(Color.cardBackground)
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
          count: workspaceManager.databaseTables.count,
          icon: "tablecells",
          isExpanded: true
        ) {
          ForEach(workspaceManager.databaseTables) { table in
            TableRowView(
              table: table,
              isExpanded: table.isExpanded,
              onToggle: {
                workspaceManager.toggleTableExpansion(tableId: table.id)
              },
              onColumnClick: { _ in
                // No active cell to insert into when no document is open
              }
            )
          }
        }

        // Views section
        EntitySection(
          title: "Views",
          count: workspaceManager.databaseViews.count,
          icon: "eye",
          isExpanded: true
        ) {
          ForEach(workspaceManager.databaseViews) { view in
            ViewRowView(
              view: view,
              isExpanded: view.isExpanded,
              onToggle: {
                workspaceManager.toggleViewExpansion(viewId: view.id)
              },
              onColumnClick: { _ in
                // No active cell to insert into when no document is open
              }
            )
          }
        }

        // Functions section
        EntitySection(
          title: "Functions",
          count: workspaceManager.databaseFunctions.count,
          icon: "function",
          isExpanded: true
        ) {
          ForEach(workspaceManager.databaseFunctions) { function in
            FunctionRowView(
              function: function,
              isExpanded: function.isExpanded,
              onToggle: {
                workspaceManager.toggleFunctionExpansion(functionId: function.id)
              }
            )
          }
        }

        // Procedures section
        EntitySection(
          title: "Procedures",
          count: workspaceManager.databaseProcedures.count,
          icon: "gearshape.2",
          isExpanded: true
        ) {
          ForEach(workspaceManager.databaseProcedures) { procedure in
            ProcedureRowView(
              procedure: procedure,
              isExpanded: procedure.isExpanded,
              onToggle: {
                workspaceManager.toggleProcedureExpansion(procedureId: procedure.id)
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
          count: workspaceManager.databaseUsers.count,
          icon: "person",
          isExpanded: true
        ) {
          ForEach(workspaceManager.databaseUsers) { user in
            UserRowView(
              user: user,
              isExpanded: user.isExpanded,
              onToggle: {
                workspaceManager.toggleUserExpansion(userId: user.id)
              }
            )
          }
        }

        // Roles section
        EntitySection(
          title: "Roles",
          count: workspaceManager.databaseRoles.count,
          icon: "person.2",
          isExpanded: true
        ) {
          ForEach(workspaceManager.databaseRoles) { role in
            RoleRowView(
              role: role,
              isExpanded: role.isExpanded,
              onToggle: {
                workspaceManager.toggleRoleExpansion(roleId: role.id)
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
    SidebarEmptyState(
      isConnected: false,
      onConnect: { workspaceManager.showConnectionForm() }
    )
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
