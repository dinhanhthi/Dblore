//
//  WorkspaceLeftSidebarContent.swift
//  Dblore
//
//  Left sidebar content that displays schema directly from WorkspaceManager
//  Used when workspace is connected but no document is open
//

import SwiftUI

/// Left sidebar content that shows schema from WorkspaceManager
/// Used when connected but no active tab exists
struct WorkspaceLeftSidebarContent: View {
  @Bindable var workspaceManager: WorkspaceManager
  let onImportTable: (DatabaseTable) -> Void
  @State private var selectedTab: SidebarTab = .public
  @State private var publicFilter = ""
  @State private var securityFilter = ""
  @State private var favoriteFilter = ""
  /// The aggregation builder opened from a collection's menu
  @State private var aggregationBuilder: AggregationBuilderModel?

  enum SidebarTab: String, CaseIterable {
    case `public` = "Public"
    case security = "Security"
    case favorite = "Favorite"
    case history = "History"
  }

  var body: some View {
    VStack(spacing: 0) {
      // Tab selector (always visible)
      tabSelector
      Divider()

      // Content. Favorites and history read local data, so they stay up while disconnected.
      if selectedTab == .favorite {
        FavoritesTabContent(
          workspaceManager: workspaceManager,
          filterText: $favoriteFilter
        )
      } else if selectedTab == .history {
        HistoryTabContent(workspaceManager: workspaceManager)
      } else if !workspaceManager.connectionState.isConnected {
        emptyState
      } else if workspaceManager.isLoadingSchema {
        loadingState
      } else {
        contentForSelectedTab
      }
    }
    .sheet(item: $aggregationBuilder) { model in
      AggregationBuilderSheet(
        model: model, insertTarget: workspaceManager.activeViewModel,
        onClose: { aggregationBuilder = nil },
        fieldSource: workspaceManager.autocompleteProvider,
        aiAssistant: workspaceManager.aiAssistant)
    }
  }

  /// Security (users and roles) is hidden for MongoDB
  private var visibleTabs: [SidebarTab] {
    SidebarSectionModel.showsSecurityTab(queryLanguage)
      ? SidebarTab.allCases : SidebarTab.allCases.filter { $0 != .security }
  }

  /// The selected tab, or Public when the connection hides it
  private var shownTab: SidebarTab {
    visibleTabs.contains(selectedTab) ? selectedTab : .public
  }

  private var tabSelector: some View {
    CapsuleTabPicker(
      selection: Binding(get: { shownTab }, set: { selectedTab = $0 }),
      tabs: visibleTabs,
      height: 28
    ) { tab in
      tabLabel(tab)
    }
    .padding(Spacing.sm)
  }

  /// "History" keeps the four titles on one row. The tooltip still says History.
  @ViewBuilder
  private func tabLabel(_ tab: SidebarTab) -> some View {
    let isSelected = shownTab == tab
    let label = Text(tab == .history ? "History" : tab.rawValue)
      .font(.body)
      .fontWeight(isSelected ? .semibold : .regular)
      .foregroundColor(isSelected ? .onAccentFill : .foreground)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .accessibilityLabel(tab.rawValue)
    if tab == .history {
      label.help("History")
    } else {
      label
    }
  }

  @ViewBuilder
  private var contentForSelectedTab: some View {
    // Favorite and history are handled in body; only the schema tabs reach here
    if shownTab == .security {
      securityTabContent
    } else {
      publicTabContent
    }
  }

  /// Database of the open connection; PostgreSQL when the workspace has no config yet
  private var connectionDatabaseType: DatabaseType {
    workspaceManager.workspace.connectionConfig?.databaseType ?? .postgresql
  }

  private var queryLanguage: DatabaseCapabilities.QueryLanguage {
    connectionDatabaseType.capabilities.queryLanguage
  }

  /// Whether the active tab is a data viewer showing this relation
  private func isOpenInActiveTab(schema: String, name: String) -> Bool {
    guard let state = workspaceManager.activeViewModel?.dataViewer else { return false }
    return state.schema == schema && state.name == name
  }

  private var publicKeywords: [String] {
    SidebarEntityFilter.keywords(in: publicFilter)
  }

  private var securityKeywords: [String] {
    SidebarEntityFilter.keywords(in: securityFilter)
  }

  private struct FilteredTable: Identifiable {
    let source: DatabaseTable
    let columns: [DatabaseColumn]
    let expandForMatch: Bool
    var id: UUID { source.id }

    var display: DatabaseTable {
      var copy = source
      copy.columns = columns
      return copy
    }
  }

  private struct FilteredView: Identifiable {
    let source: DatabaseView
    let columns: [DatabaseColumn]
    let expandForMatch: Bool
    var id: UUID { source.id }

    var display: DatabaseView {
      var copy = source
      copy.columns = columns
      return copy
    }
  }

  private var filteredTables: [FilteredTable] {
    workspaceManager.databaseTables.compactMap { table in
      guard
        let match = SidebarEntityFilter.matchColumns(
          name: table.name,
          columns: table.columns,
          keywords: publicKeywords
        )
      else { return nil }
      return FilteredTable(
        source: table,
        columns: match.columns,
        expandForMatch: match.expandForMatch
      )
    }
  }

  private var filteredViews: [FilteredView] {
    workspaceManager.databaseViews.compactMap { view in
      guard
        let match = SidebarEntityFilter.matchColumns(
          name: view.name,
          columns: view.columns,
          keywords: publicKeywords
        )
      else { return nil }
      return FilteredView(
        source: view,
        columns: match.columns,
        expandForMatch: match.expandForMatch
      )
    }
  }

  private var filteredFunctions: [DatabaseFunction] {
    workspaceManager.databaseFunctions.filter {
      SidebarEntityFilter.matchesAll($0.name, keywords: publicKeywords)
    }
  }

  private var filteredProcedures: [DatabaseProcedure] {
    workspaceManager.databaseProcedures.filter {
      SidebarEntityFilter.matchesAll($0.name, keywords: publicKeywords)
    }
  }

  /// A keyword may hit the trigger name or its table
  private var filteredTriggers: [DatabaseTrigger] {
    workspaceManager.databaseTriggers.filter {
      SidebarEntityFilter.matchesAll("\($0.name) \($0.table)", keywords: publicKeywords)
    }
  }

  private var filteredUsers: [DatabaseUser] {
    workspaceManager.databaseUsers.filter {
      SidebarEntityFilter.matchesAll($0.name, keywords: securityKeywords)
    }
  }

  private var filteredRoles: [DatabaseRole] {
    workspaceManager.databaseRoles.filter {
      SidebarEntityFilter.matchesAll($0.name, keywords: securityKeywords)
    }
  }

  /// Filtered Public tab objects, for the whole database or one schema
  private struct PublicEntities {
    var tables: [FilteredTable]
    var views: [FilteredView]
    var functions: [DatabaseFunction]
    var procedures: [DatabaseProcedure]
    var triggers: [DatabaseTrigger]

    var isEmpty: Bool {
      tables.isEmpty && views.isEmpty && functions.isEmpty && procedures.isEmpty
        && triggers.isEmpty
    }

    var count: Int {
      tables.count + views.count + functions.count + procedures.count + triggers.count
    }

    func inSchema(_ schema: String) -> PublicEntities {
      PublicEntities(
        tables: tables.filter { $0.source.schema == schema },
        views: views.filter { $0.source.schema == schema },
        functions: functions.filter { $0.schema == schema },
        procedures: procedures.filter { $0.schema == schema },
        triggers: triggers.filter { $0.schema == schema })
    }
  }

  /// Schemas that hold at least one object, the connection's default schema first
  private var publicSchemas: [String] {
    var names = Set(workspaceManager.databaseTables.map(\.schema))
    names.formUnion(workspaceManager.databaseViews.map(\.schema))
    names.formUnion(workspaceManager.databaseFunctions.map(\.schema))
    names.formUnion(workspaceManager.databaseProcedures.map(\.schema))
    names.formUnion(workspaceManager.databaseTriggers.map(\.schema))
    var sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    if let index = sorted.firstIndex(of: connectionDatabaseType.dialect.defaultSchema) {
      sorted.insert(sorted.remove(at: index), at: 0)
    }
    return sorted
  }

  private var publicTabContent: some View {
    let entities = PublicEntities(
      tables: filteredTables, views: filteredViews, functions: filteredFunctions,
      procedures: filteredProcedures, triggers: filteredTriggers)
    let schemas = publicSchemas
    return VStack(spacing: 0) {
      SidebarFilterField(text: $publicFilter)

      if !publicKeywords.isEmpty && entities.isEmpty {
        noMatchesState
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            // One schema keeps the flat layout; two or more get one group per schema
            if schemas.count > 1 && SidebarSectionModel.groupsBySchema(queryLanguage) {
              ForEach(schemas, id: \.self) { schema in
                let inSchema = entities.inSchema(schema)
                if !inSchema.isEmpty {
                  EntitySection(title: schema, count: inSchema.count, icon: "folder") {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                      entitySections(
                        inSchema, idPrefix: "\(schema).", showsEmptySections: false,
                        showsSchema: false)
                    }
                  }
                  .id(publicKeywords.isEmpty ? schema : "\(schema)-filtered")
                }
              }
            } else {
              entitySections(
                entities, idPrefix: "", showsEmptySections: publicKeywords.isEmpty,
                showsSchema: connectionDatabaseType.namesSchema)
            }
          }
          .padding(.vertical, Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  /// The language's sections (`SidebarSectionModel`). `idPrefix` keeps section ids
  /// unique per schema; `showsSchema` adds the "(schema)" label to table and view rows.
  @ViewBuilder
  private func entitySections(
    _ entities: PublicEntities, idPrefix: String, showsEmptySections: Bool, showsSchema: Bool
  ) -> some View {
    ForEach(SidebarSectionModel.sections(for: queryLanguage), id: \.kind) { section in
      entitySection(
        section, entities, idPrefix: idPrefix, showsEmptySections: showsEmptySections,
        showsSchema: showsSchema)
    }
  }

  @ViewBuilder
  private func entitySection(
    _ section: SidebarSectionModel.Section, _ entities: PublicEntities, idPrefix: String,
    showsEmptySections: Bool, showsSchema: Bool
  ) -> some View {
    switch section.kind {
    case .tables:
      if showsEmptySections || !entities.tables.isEmpty {
        EntitySection(
          title: section.title,
          count: entities.tables.count,
          icon: section.icon,
          isExpanded: true
        ) {
          ForEach(entities.tables) { table in
            tableRow(table, showsSchema: showsSchema)
          }
        }
        .id(idPrefix + (publicKeywords.isEmpty ? "tables" : "tables-filtered"))
      }

    case .views:
      if showsEmptySections || !entities.views.isEmpty {
        EntitySection(
          title: section.title,
          count: entities.views.count,
          icon: section.icon,
          isExpanded: true
        ) {
          ForEach(entities.views) { view in
            viewRow(view, showsSchema: showsSchema)
          }
        }
        .id(idPrefix + (publicKeywords.isEmpty ? "views" : "views-filtered"))
      }

    case .functions:
      if showsEmptySections || !entities.functions.isEmpty {
        EntitySection(
          title: section.title,
          count: entities.functions.count,
          icon: section.icon,
          isExpanded: true
        ) {
          ForEach(entities.functions) { function in
            FunctionRowView(
              function: function,
              isExpanded: function.isExpanded,
              onToggle: {
                workspaceManager.toggleFunctionExpansion(functionId: function.id)
              },
              onViewSource: { workspaceManager.openObjectSource(.function(function)) }
            )
          }
        }
        .id(idPrefix + (publicKeywords.isEmpty ? "functions" : "functions-filtered"))
      }

    case .procedures:
      if showsEmptySections || !entities.procedures.isEmpty {
        EntitySection(
          title: section.title,
          count: entities.procedures.count,
          icon: section.icon,
          isExpanded: true
        ) {
          ForEach(entities.procedures) { procedure in
            ProcedureRowView(
              procedure: procedure,
              isExpanded: procedure.isExpanded,
              onToggle: {
                workspaceManager.toggleProcedureExpansion(procedureId: procedure.id)
              },
              onViewSource: { workspaceManager.openObjectSource(.procedure(procedure)) }
            )
          }
        }
        .id(idPrefix + (publicKeywords.isEmpty ? "procedures" : "procedures-filtered"))
      }

    case .triggers:
      if showsEmptySections || !entities.triggers.isEmpty {
        EntitySection(
          title: section.title,
          count: entities.triggers.count,
          icon: section.icon,
          isExpanded: true
        ) {
          ForEach(entities.triggers) { trigger in
            TriggerRowView(
              trigger: trigger,
              onViewSource: { workspaceManager.openObjectSource(.trigger(trigger)) }
            )
          }
        }
        .id(idPrefix + (publicKeywords.isEmpty ? "triggers" : "triggers-filtered"))
      }
    }
  }

  private func tableRow(_ table: FilteredTable, showsSchema: Bool) -> some View {
    TableRowView(
      table: table.display,
      isExpanded: table.expandForMatch || table.source.isExpanded,
      isSelected: isOpenInActiveTab(
        schema: table.source.schema, name: table.source.name),
      databaseType: connectionDatabaseType,
      showsSchema: showsSchema,
      onToggle: {
        if !table.expandForMatch {
          workspaceManager.toggleTableExpansion(tableId: table.id)
        }
      },
      onOpen: { openTable(table.source) },
      onColumnClick: { _ in
        // No active cell to insert into when no document is open
      },
      onImport: connectionDatabaseType.capabilities.supportsDataImport
        ? { onImportTable(table.source) } : nil,
      structureMenuTitle: SidebarSectionModel.structureMenuTitle(for: connectionDatabaseType),
      onEditStructure: {
        workspaceManager.openStructureEditor(
          schema: table.source.schema, table: table.source.name)
      },
      menuActions: SidebarSectionModel.rowActions(
        for: .tables, name: table.source.name, language: queryLanguage),
      onMenuAction: { action in
        perform(action, name: table.source.name) { openTable(table.source) }
      }
    )
  }

  private func viewRow(_ view: FilteredView, showsSchema: Bool) -> some View {
    ViewRowView(
      view: view.display,
      isExpanded: view.expandForMatch || view.source.isExpanded,
      isSelected: isOpenInActiveTab(
        schema: view.source.schema, name: view.source.name),
      databaseType: connectionDatabaseType,
      showsSchema: showsSchema,
      onToggle: {
        if !view.expandForMatch {
          workspaceManager.toggleViewExpansion(viewId: view.id)
        }
      },
      onOpen: { openView(view.source) },
      onColumnClick: { _ in
        // No active cell to insert into when no document is open
      },
      menuActions: SidebarSectionModel.rowActions(
        for: .views, name: view.source.name, language: queryLanguage),
      onMenuAction: { action in
        perform(action, name: view.source.name) { openView(view.source) }
      }
    )
  }

  private func openTable(_ table: DatabaseTable) {
    workspaceManager.openDataViewer(
      schema: table.schema,
      name: table.name,
      orderColumns: table.columns.filter(\.isPrimaryKey).map(\.name)
    )
  }

  private func openView(_ view: DatabaseView) {
    workspaceManager.openDataViewer(schema: view.schema, name: view.name, orderColumns: [])
  }

  /// Runs a row menu item: Open as a row click, Copy Name to the pasteboard, Insert at the
  /// cursor of the active cell (as favorites and history do), Build Aggregation in a sheet
  private func perform(
    _ action: SidebarSectionModel.RowAction, name: String, open: () -> Void
  ) {
    switch action {
    case .open:
      open()
    case .copyName:
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(name, forType: .string)
    case .insert(let text):
      workspaceManager.activeViewModel?.insertTextIntoSelectedCell(text)
    case .buildAggregation:
      let model = AggregationBuilderModel(
        collection: name, connectionManager: workspaceManager.connectionManager)
      model.addStage()
      aggregationBuilder = model
    }
  }

  private var securityTabContent: some View {
    VStack(spacing: 0) {
      SidebarFilterField(text: $securityFilter)

      if !securityKeywords.isEmpty && filteredUsers.isEmpty && filteredRoles.isEmpty {
        noMatchesState
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            if securityKeywords.isEmpty || !filteredUsers.isEmpty {
              EntitySection(
                title: "Users",
                count: filteredUsers.count,
                icon: "person",
                isExpanded: true
              ) {
                ForEach(filteredUsers) { user in
                  UserRowView(
                    user: user,
                    isExpanded: user.isExpanded,
                    onToggle: {
                      workspaceManager.toggleUserExpansion(userId: user.id)
                    }
                  )
                }
              }
              .id(securityKeywords.isEmpty ? "users" : "users-filtered")
            }

            if securityKeywords.isEmpty || !filteredRoles.isEmpty {
              EntitySection(
                title: "Roles",
                count: filteredRoles.count,
                icon: "person.2",
                isExpanded: true
              ) {
                ForEach(filteredRoles) { role in
                  RoleRowView(
                    role: role,
                    isExpanded: role.isExpanded,
                    onToggle: {
                      workspaceManager.toggleRoleExpansion(roleId: role.id)
                    }
                  )
                }
              }
              .id(securityKeywords.isEmpty ? "roles" : "roles-filtered")
            }
          }
          .padding(.vertical, Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  private var noMatchesState: some View {
    Text("No matches")
      .font(.caption)
      .foregroundColor(.foregroundMuted)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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
