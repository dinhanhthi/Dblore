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
  /// The collection or view change started here; the workspace container presents its form
  @Binding var mongoAdmin: SidebarMongoAdmin?
  @State private var selectedTab: SidebarTab = .public
  @State private var publicFilter = ""
  @State private var securityFilter = ""
  @State private var favoriteFilter = ""
  /// The aggregation builder opened from a collection's menu
  @State private var aggregationBuilder: AggregationBuilderModel?
  /// The Create Table sheet opened from the Tables header
  @State private var createTable: CreateTableModel?

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
    .sheet(item: $createTable) { model in
      CreateTableSheet(
        model: model,
        tables: workspaceManager.databaseTables,
        databasePassword: workspaceManager.workspace.connectionConfig?.password,
        isConnected: workspaceManager.connectionState == .connected,
        isShown: { [weak model] in model != nil && createTable === model },
        onClose: closeCreateTable)
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

  /// SQL: `WorkspaceManager.canChangeTableSchema` (New Table, Rename, Drop Table; hidden
  /// without it). MongoDB: an active tab connected to MongoDB whose protection allows schema
  /// changes: the collection and view changes run through it. Without one they are not offered
  /// and "+" is disabled.
  private var canChangeSchema: Bool {
    if queryLanguage == .sql { return workspaceManager.canChangeTableSchema }
    guard queryLanguage == .mongosh, let tab = workspaceManager.activeViewModel,
      tab.connectionManager != nil, tab.connectionState == .connected,
      tab.notebook.connectionConfig?.databaseType == .mongodb,
      workspaceManager.schemaConnectionEpoch != nil  // A schema read since the last connect
    else { return false }
    return !tab.protectionPolicy.protectionLevel.blocksSchemaChanges
  }

  /// The section's "+" action, nil while the schema may not change
  private func createAction(_ form: SidebarMongoAdmin.Form) -> (() -> Void)? {
    canChangeSchema ? { startMongoAdmin(form) } : nil
  }

  /// The Tables header's "+" title: New Table... on SQL only while tables may change (hidden
  /// otherwise), New Collection... on MongoDB (disabled while the schema may not change)
  private var tablesCreateTitle: String? {
    let title = SidebarSectionModel.createActionTitle(
      for: .tables, databaseType: connectionDatabaseType)
    return queryLanguage == .sql && !canChangeSchema ? nil : title
  }

  /// The Tables header's "+" action; `schema` is the group it sits in (nil: flat list)
  private func tablesCreateAction(schema: String?) -> (() -> Void)? {
    guard queryLanguage == .sql else { return createAction(.createCollection) }
    return canChangeSchema ? { openCreateTable(schema: schema) } : nil
  }

  /// Where New Table can put a table: the listed schemas and the connection's default one
  private var createTableSchemas: [String] {
    let fallback: String
    switch connectionDatabaseType {
    case .mysql: fallback = workspaceManager.workspace.connectionConfig?.database ?? ""
    case .postgresql, .sqlite, .duckdb, .mongodb:
      fallback = connectionDatabaseType.dialect.defaultSchema
    }
    var schemas = publicSchemas
    // The default schema stays pickable but goes last, so "+" on a flat list targets its schema
    if !fallback.isEmpty, !schemas.contains(fallback) { schemas.append(fallback) }
    return schemas
  }

  private func openCreateTable(schema: String?) {
    guard createTable == nil else { return }
    let schemas = createTableSchemas
    guard let target = schema ?? schemas.first else { return }
    createTable = workspaceManager.makeCreateTableModel(schema: target, schemas: schemas)
  }

  /// Closes the sheet unless a CREATE is being sent; a Safe Mode step still open is cancelled,
  /// so a late Touch ID answer sends nothing
  private func closeCreateTable() {
    guard createTable?.isCreating != true else { return }
    createTable?.cancelConfirmation()
    createTable = nil
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

  /// Nil until the Sequences section has read them
  private var filteredSequences: [DatabaseSequence]? {
    workspaceManager.databaseSequences.items?.filter {
      SidebarEntityFilter.matchesAll($0.name, keywords: publicKeywords)
    }
  }

  /// Nil until the Types section has read them
  private var filteredUserTypes: [DatabaseUserType]? {
    workspaceManager.databaseUserTypes.items?.filter {
      SidebarEntityFilter.matchesAll($0.name, keywords: publicKeywords)
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
    /// Nil until read (the section was never expanded)
    var sequences: [DatabaseSequence]?
    var userTypes: [DatabaseUserType]?

    var isEmpty: Bool {
      tables.isEmpty && views.isEmpty && functions.isEmpty && procedures.isEmpty
        && triggers.isEmpty && (sequences ?? []).isEmpty && (userTypes ?? []).isEmpty
    }

    var count: Int {
      tables.count + views.count + functions.count + procedures.count + triggers.count
        + (sequences?.count ?? 0) + (userTypes?.count ?? 0)
    }

    func inSchema(_ schema: String) -> PublicEntities {
      PublicEntities(
        tables: tables.filter { $0.source.schema == schema },
        views: views.filter { $0.source.schema == schema },
        functions: functions.filter { $0.schema == schema },
        procedures: procedures.filter { $0.schema == schema },
        triggers: triggers.filter { $0.schema == schema },
        sequences: sequences?.filter { $0.schema == schema },
        userTypes: userTypes?.filter { $0.schema == schema })
    }
  }

  /// Schemas holding an object read with the schema (not the sequences and types read on
  /// expand): they alone pick the flat or grouped layout, so expanding a section never flips it
  private var schemaLoadSchemas: Set<String> {
    var names = Set(workspaceManager.databaseTables.map(\.schema))
    names.formUnion(workspaceManager.databaseViews.map(\.schema))
    names.formUnion(workspaceManager.databaseFunctions.map(\.schema))
    names.formUnion(workspaceManager.databaseProcedures.map(\.schema))
    names.formUnion(workspaceManager.databaseTriggers.map(\.schema))
    return names
  }

  /// Schemas that hold at least one object, the connection's default schema first
  private var publicSchemas: [String] {
    var names = schemaLoadSchemas
    names.formUnion((workspaceManager.databaseSequences.items ?? []).map(\.schema))
    names.formUnion((workspaceManager.databaseUserTypes.items ?? []).map(\.schema))
    var sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    if let index = sorted.firstIndex(of: connectionDatabaseType.dialect.defaultSchema) {
      sorted.insert(sorted.remove(at: index), at: 0)
    }
    return sorted
  }

  private var publicTabContent: some View {
    let entities = PublicEntities(
      tables: filteredTables, views: filteredViews, functions: filteredFunctions,
      procedures: filteredProcedures, triggers: filteredTriggers, sequences: filteredSequences,
      userTypes: filteredUserTypes)
    let schemas = publicSchemas
    return VStack(spacing: 0) {
      SidebarFilterField(text: $publicFilter)

      if !publicKeywords.isEmpty && entities.isEmpty {
        noMatchesState
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            // One schema keeps the flat layout; two or more get one group per schema
            if schemaLoadSchemas.count > 1 && SidebarSectionModel.groupsBySchema(queryLanguage) {
              ForEach(schemas, id: \.self) { schema in
                let inSchema = entities.inSchema(schema)
                if !inSchema.isEmpty {
                  EntitySection(title: schema, count: inSchema.count, icon: "folder") {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                      entitySections(
                        inSchema, idPrefix: "\(schema).", showsEmptySections: false,
                        showsSchema: false, schema: schema)
                    }
                  }
                  .id(publicKeywords.isEmpty ? schema : "\(schema)-filtered")
                }
              }
            } else {
              entitySections(
                entities, idPrefix: "", showsEmptySections: publicKeywords.isEmpty,
                showsSchema: connectionDatabaseType.namesSchema, schema: nil)
            }
          }
          .padding(.vertical, Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  /// The language's sections (`SidebarSectionModel`). `idPrefix` keeps section ids
  /// unique per schema; `showsSchema` adds the "(schema)" label to table and view rows;
  /// `schema` is the group the sections sit in (nil: flat list), New Table's default target.
  @ViewBuilder
  private func entitySections(
    _ entities: PublicEntities, idPrefix: String, showsEmptySections: Bool, showsSchema: Bool,
    schema: String?
  ) -> some View {
    ForEach(
      SidebarSectionModel.sections(
        for: queryLanguage,
        supportsUserTypes: connectionDatabaseType.capabilities.supportsUserTypes),
      id: \.kind
    ) { section in
      entitySection(
        section, entities, idPrefix: idPrefix, showsEmptySections: showsEmptySections,
        showsSchema: showsSchema, schema: schema)
    }
  }

  @ViewBuilder
  private func entitySection(
    _ section: SidebarSectionModel.Section, _ entities: PublicEntities, idPrefix: String,
    showsEmptySections: Bool, showsSchema: Bool, schema: String?
  ) -> some View {
    switch section.kind {
    case .tables:
      if showsEmptySections || !entities.tables.isEmpty {
        EntitySection(
          title: section.title,
          count: entities.tables.count,
          icon: section.icon,
          isExpanded: true,
          createTitle: tablesCreateTitle,
          onCreate: tablesCreateAction(schema: schema)
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
          isExpanded: true,
          createTitle: SidebarSectionModel.createActionTitle(
            for: .views, databaseType: connectionDatabaseType),
          onCreate: createAction(.createView)
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

    case .sequences:
      // Shown unread too: expanding the section is what reads it
      if showsEmptySections || entities.sequences?.isEmpty != true {
        EntitySection(
          title: section.title,
          count: entities.sequences?.count,
          icon: section.icon,
          isExpanded: !publicKeywords.isEmpty && entities.sequences != nil
        ) {
          catalogStatus(workspaceManager.databaseSequences, isEmpty: entities.sequences?.isEmpty) {
            await workspaceManager.loadSequencesIfNeeded()
          }
          ForEach(entities.sequences ?? []) { sequence in
            SequenceRowView(
              sequence: sequence,
              onShowDDL: { workspaceManager.openObjectSource(.sequence(sequence)) },
              onCopyName: { copyName(sequence.name, schema: sequence.schema) }
            )
          }
        }
        .id(idPrefix + (publicKeywords.isEmpty ? "sequences" : "sequences-filtered"))
      }

    case .types:
      if showsEmptySections || entities.userTypes?.isEmpty != true {
        EntitySection(
          title: section.title,
          count: entities.userTypes?.count,
          icon: section.icon,
          isExpanded: !publicKeywords.isEmpty && entities.userTypes != nil
        ) {
          catalogStatus(workspaceManager.databaseUserTypes, isEmpty: entities.userTypes?.isEmpty) {
            await workspaceManager.loadUserTypesIfNeeded()
          }
          ForEach(entities.userTypes ?? []) { type in
            UserTypeRowView(
              type: type,
              onShowDDL: { workspaceManager.openObjectSource(.userType(type)) },
              onCopyName: { copyName(type.name, schema: type.schema) }
            )
          }
        }
        .id(idPrefix + (publicKeywords.isEmpty ? "types" : "types-filtered"))
      }
    }
  }

  /// First row of a section read on expand: starts the read, then shows its progress or error
  private func catalogStatus<Item>(
    _ catalog: LazyCatalog<Item>, isEmpty: Bool?, load: @escaping () async -> Void
  ) -> some View {
    CatalogStatusRow(
      status: catalog.status(isEmpty: isEmpty), onAppear: { Task { await load() } },
      onRetry: { Task { await load() } })
  }

  private func copyName(_ name: String, schema: String) {
    perform(.copyName, name: name, schema: schema, open: {})
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
        for: .tables, name: table.source.name, language: queryLanguage,
        canChangeSchema: canChangeSchema,
        canImportDocuments: workspaceManager.canImportDocuments),
      onMenuAction: { action in
        perform(action, name: table.source.name, schema: table.source.schema) {
          openTable(table.source)
        }
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
        for: .views, name: view.source.name, language: queryLanguage,
        canChangeSchema: canChangeSchema),
      onMenuAction: { action in
        perform(action, name: view.source.name, schema: view.source.schema, view: view.source) {
          openView(view.source)
        }
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
  /// cursor of the active cell (as favorites and history do), Build Aggregation in a sheet,
  /// Export Collection in the export form, Import Documents in the import form, and the schema
  /// changes through `startMongoAdmin`. An SQL table's Rename and Drop open the structure
  /// editor on its Name field or its typed-name drop step.
  /// `view` is the row's view, nil for a collection.
  private func perform(
    _ action: SidebarSectionModel.RowAction, name: String, schema: String,
    view: DatabaseView? = nil, open: () -> Void
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
    case .exportCollection:
      // A read: no active tab or schema-change permission needed. The schema load's epoch
      // keeps a reconnect since then from exporting another database's namesake.
      guard workspaceManager.mongoExport == nil,
        let epoch = workspaceManager.schemaConnectionEpoch
      else { return }
      workspaceManager.mongoExport = MongoExportModel(
        collection: name, database: schema, connectionManager: workspaceManager.connectionManager,
        connectionEpoch: epoch)
    case .importDocuments:
      // Offered on collections only
      if view == nil { workspaceManager.openMongoImport(collection: name) }
    case .rename where queryLanguage == .sql:
      workspaceManager.openStructureEditor(schema: schema, table: name, start: .rename)
    case .drop where queryLanguage == .sql:
      workspaceManager.openStructureEditor(schema: schema, table: name, start: .drop)
    case .rename:
      startMongoAdmin(.rename(schema: schema, name: name))
    case .drop:
      startMongoAdmin(.drop(schema: schema, name: name, isView: view != nil))
    case .duplicate:
      if let view { startMongoAdmin(.duplicateView(view)) }
    case .editDefinition:
      if let view { startMongoAdmin(.editView(view)) }
    }
  }

  /// Opens `form` with an action model on the active MongoDB tab (its connection, rules, commit
  /// style and history); a drop asks for the typed name at once. The command is gated on the
  /// epoch the sidebar schema was read with: a reconnect since that load (another database or
  /// server) refuses it, and nothing starts before a load since the last connect.
  private func startMongoAdmin(_ form: SidebarMongoAdmin.Form) {
    guard canChangeSchema, mongoAdmin?.model.state != .running,
      let tab = workspaceManager.activeViewModel, let manager = tab.connectionManager,
      let epoch = workspaceManager.schemaConnectionEpoch,
      let model = MongoAdminActionModel(tab: tab, connectionEpoch: epoch)
    else { return }
    mongoAdmin = SidebarMongoAdmin(model: model, manager: manager, form: form)
    if case .drop(let schema, let name, let isView) = form {
      Task { await model.request(.drop(collection: name), isView: isView, database: schema) }
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

// MARK: - Collection and View Changes

/// A collection or view change started from the sidebar: its form (a drop has none, only the
/// confirm sheet) and the action model that runs its command
struct SidebarMongoAdmin {
  enum Form {
    case createCollection
    case createView
    case editView(DatabaseView)
    case duplicateView(DatabaseView)
    case rename(schema: String, name: String)
    case drop(schema: String, name: String, isView: Bool)
  }

  let model: MongoAdminActionModel
  /// For the server version (New Collection)
  let manager: DatabaseConnectionManager
  let form: Form
  var isFormOpen: Bool
  /// The name the rename was sent with
  var newName: String?

  init(model: MongoAdminActionModel, manager: DatabaseConnectionManager, form: Form) {
    self.model = model
    self.manager = manager
    self.form = form
    if case .drop = form { isFormOpen = false } else { isFormOpen = true }
  }
}

extension View {
  /// Presents `admin`'s form and confirm sheet over the whole window (a form would be clipped
  /// at sidebar width). Once its command is done, the data viewer tabs of a dropped collection
  /// or view close and those of a renamed collection show the new name. Also presents the
  /// Export form of a row (`WorkspaceManager.mongoExport`) and the Import form
  /// (`WorkspaceManager.mongoImport`, from a collection row or the File menu).
  func sidebarMongoAdmin(
    _ admin: Binding<SidebarMongoAdmin?>, workspaceManager: WorkspaceManager
  ) -> some View {
    modifier(SidebarMongoAdminPresenter(admin: admin, workspaceManager: workspaceManager))
  }
}

private struct SidebarMongoAdminPresenter: ViewModifier {
  @Binding var admin: SidebarMongoAdmin?
  let workspaceManager: WorkspaceManager

  private var isFormPresented: Binding<Bool> {
    Binding(
      get: { admin?.isFormOpen == true },
      set: { if !$0 { admin?.isFormOpen = false } })
  }

  /// The Export form of a collection or view row; closing it is refused while an export runs
  /// (its Cancel stops it)
  private var isExportPresented: Binding<Bool> {
    Binding(
      get: { workspaceManager.mongoExport != nil },
      set: {
        guard !$0, let model = workspaceManager.mongoExport, !model.isRunning else { return }
        model.dismiss()
        workspaceManager.mongoExport = nil
      })
  }

  /// The Import form; closing it is refused while an import runs (its Cancel stops it)
  private var isImportPresented: Binding<Bool> {
    Binding(
      get: { workspaceManager.mongoImport != nil },
      set: {
        guard !$0, let model = workspaceManager.mongoImport?.model, !model.isRunning else {
          return
        }
        model.dismiss()
        workspaceManager.mongoImport = nil
      })
  }

  private var isConfirmPresented: Binding<Bool> {
    admin.map { MongoAdminConfirmSheet.isPresented($0.model) } ?? .constant(false)
  }

  func body(content: Content) -> some View {
    content
      .modalOverlay(isPresented: isFormPresented) {
        if let admin { form(admin) }
      }
      .modalOverlay(isPresented: isExportPresented) {
        if let model = workspaceManager.mongoExport {
          MongoExportSheet(model: model, isPresented: isExportPresented)
        }
      }
      .modalOverlay(isPresented: isImportPresented) {
        if let request = workspaceManager.mongoImport {
          MongoImportSheet(
            model: request.model, collection: request.collection,
            // Collections only (views are not in `databaseTables`); `system.` ones never take
            // an import
            collections: workspaceManager.databaseTables.map(\.name)
              .filter { !$0.hasPrefix("system.") },
            databasePassword: workspaceManager.workspace.connectionConfig?.password,
            isConnected: workspaceManager.connectionState == .connected,
            isPresented: isImportPresented)
        }
      }
      .sheet(isPresented: isConfirmPresented) {
        if let model = admin?.model {
          MongoAdminConfirmSheet(
            model: model, databasePassword: workspaceManager.workspace.connectionConfig?.password,
            isConnected: workspaceManager.connectionState == .connected)
        }
      }
      .onChange(of: admin?.model.state) { _, state in
        if state == .done, let admin { finish(admin) }
      }
  }

  @ViewBuilder
  private func form(_ admin: SidebarMongoAdmin) -> some View {
    switch admin.form {
    case .createCollection:
      MongoCreateCollectionSheet(
        model: admin.model, manager: admin.manager, isPresented: isFormPresented)
    case .createView:
      MongoViewEditorSheet(
        model: admin.model, mode: .create, sources: sources, isPresented: isFormPresented)
    case .editView(let view):
      MongoViewEditorSheet(
        model: admin.model, mode: .edit(view), sources: sources, isPresented: isFormPresented)
    case .duplicateView(let view):
      MongoViewEditorSheet(
        model: admin.model, mode: .duplicate(of: view), sources: sources,
        isPresented: isFormPresented)
    case .rename(let schema, let name):
      // Failures show in the confirm sheet, as for the other forms
      RenameObjectSheet(
        title: "Rename Collection", currentName: name,
        validate: { MongoCollectionDraft.nameProblem($0) },
        isBusy: isBusy(admin.model),
        onRename: { newName in
          self.admin?.newName = newName
          Task {
            await admin.model.request(
              .renameCollection(collection: name, to: newName), database: schema)
          }
        },
        isPresented: isFormPresented)
    case .drop:
      EmptyView()
    }
  }

  /// Collections and views of the database, for the view editor's source picker
  private var sources: [String] {
    workspaceManager.databaseTables.map(\.name) + workspaceManager.databaseViews.map(\.name)
  }

  private func isBusy(_ model: MongoAdminActionModel) -> Bool {
    switch model.state {
    case .confirming, .running: true
    case .idle, .failed, .done: false
    }
  }

  private func finish(_ admin: SidebarMongoAdmin) {
    switch admin.form {
    case .drop(let schema, let name, _):
      workspaceManager.closeDataViewerTabs(schema: schema, name: name)
    case .rename(let schema, let name):
      // The rename form leaves closing to its caller
      self.admin?.isFormOpen = false
      if let newName = admin.newName {
        workspaceManager.renameDataViewerTabs(schema: schema, from: name, to: newName)
      }
    case .editView(let view):
      workspaceManager.reloadDataViewerTabs(schema: view.schema, name: view.name)
    case .createCollection, .createView, .duplicateView:
      // These forms close themselves; the sidebar reloads after every command
      break
    }
  }
}
