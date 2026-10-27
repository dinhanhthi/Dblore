//
//  WorkspaceLeftSidebarContent.swift
//  Dblore
//
//  Left sidebar content that displays schema directly from WorkspaceManager
//  Used when workspace is connected but no document is open
//  The Public tab leaves out the connection's hidden schemas (only here: the loaded schema,
//  autocomplete, schema search and AI context keep them), and lists each schema's folders
//  (`SidebarFolderStore`) above its ungrouped tables and views.
//

import SwiftUI

/// Left sidebar content that shows schema from WorkspaceManager
/// Used when connected but no active tab exists
struct WorkspaceLeftSidebarContent: View {
  @Bindable var workspaceManager: WorkspaceManager
  let onImportTable: (DatabaseTable) -> Void
  /// Import Files: the schema the files go into, and the table whose menu opened it
  let onImportFiles: (_ schema: String?, _ table: DatabaseTable?) -> Void
  /// Generate Rows into the table whose menu opened it
  let onGenerateRows: (DatabaseTable) -> Void
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
  @State private var folderStore = SidebarFolderStore.shared
  /// Folders the user closed; a new folder starts open
  @State private var collapsedFolders: Set<UUID> = []
  /// The New Folder or Rename Folder sheet
  @State private var folderPrompt: SidebarFolderPrompt?

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
    // The last tab closed: back to Public, where a table opens
    .onChange(of: workspaceManager.activeTabId) { _, tabId in
      if tabId == nil { selectedTab = .public }
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
    .sheet(item: $folderPrompt) { prompt in
      SidebarFolderNameSheet(
        prompt: prompt, onSave: { saveFolderName($0, for: prompt) },
        onClose: { folderPrompt = nil })
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
    var schemas = publicSchemas.listed
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

  private struct FilteredTable: Identifiable, SidebarFolderItem {
    let source: DatabaseTable
    let columns: [DatabaseColumn]
    let expandForMatch: Bool
    let folderMember: String
    var id: UUID { source.id }
    var folderSchema: String { source.schema }

    var display: DatabaseTable {
      var copy = source
      copy.columns = columns
      return copy
    }
  }

  private struct FilteredView: Identifiable, SidebarFolderItem {
    let source: DatabaseView
    let columns: [DatabaseColumn]
    let expandForMatch: Bool
    let folderMember: String
    var id: UUID { source.id }
    var folderSchema: String { source.schema }

    var display: DatabaseView {
      var copy = source
      copy.columns = columns
      return copy
    }
  }

  /// Schemas the Public tab leaves out; none on engines without the schema filter
  private var hiddenSchemas: Set<String> {
    guard SidebarSectionModel.filtersSchemas(connectionDatabaseType) else { return [] }
    return Set(workspaceManager.workspace.connectionConfig?.hiddenSchemas ?? [])
  }

  private func isListed(_ schema: String) -> Bool {
    !hiddenSchemas.contains(schema)
  }

  /// The Public tab's objects of the listed schemas (`hidden` left out) that match the filter
  private func publicEntities(hidden: Set<String>) -> PublicEntities {
    let keywords = publicKeywords
    func matches(_ schema: String, _ text: String) -> Bool {
      !hidden.contains(schema) && SidebarEntityFilter.matchesAll(text, keywords: keywords)
    }
    let tables = workspaceManager.databaseTables.compactMap { table -> FilteredTable? in
      guard !hidden.contains(table.schema),
        let match = SidebarEntityFilter.matchColumns(
          name: table.name, columns: table.columns, keywords: keywords)
      else { return nil }
      return FilteredTable(
        source: table, columns: match.columns, expandForMatch: match.expandForMatch,
        folderMember: SidebarFolder.member(schema: table.schema, name: table.name))
    }
    let views = workspaceManager.databaseViews.compactMap { view -> FilteredView? in
      guard !hidden.contains(view.schema),
        let match = SidebarEntityFilter.matchColumns(
          name: view.name, columns: view.columns, keywords: keywords)
      else { return nil }
      return FilteredView(
        source: view, columns: match.columns, expandForMatch: match.expandForMatch,
        folderMember: SidebarFolder.member(schema: view.schema, name: view.name))
    }
    return PublicEntities(
      tables: tables, views: views,
      functions: workspaceManager.databaseFunctions.filter { matches($0.schema, $0.name) },
      procedures: workspaceManager.databaseProcedures.filter { matches($0.schema, $0.name) },
      // A keyword may hit the trigger name or its table
      triggers: workspaceManager.databaseTriggers.filter {
        matches($0.schema, "\($0.name) \($0.table)")
      },
      // Nil until the Sequences or Types section has read them
      sequences: workspaceManager.databaseSequences.items?.filter { matches($0.schema, $0.name) },
      userTypes: workspaceManager.databaseUserTypes.items?.filter { matches($0.schema, $0.name) })
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

  /// A folder and its listed rows (members the schema no longer has, or the filter hides, are
  /// left out)
  private typealias FolderContent = SidebarFolderLayout<FilteredTable, FilteredView>.Group

  /// The open connection's folders, sorted by name, read once per render
  private struct FolderIndex {
    let key: String
    let sorted: [SidebarFolder]
    let bySchema: [String: [SidebarFolder]]

    func folders(in schemas: Set<String>) -> [SidebarFolder] {
      sorted.filter { schemas.contains($0.schema) }
    }
  }

  /// Folder key of the open connection
  private var folderKey: String? {
    workspaceManager.workspace.connectionConfig.map(SidebarFolderStore.key(for:))
  }

  /// The open connection's folders, nil without a connection
  private var folderIndex: FolderIndex? {
    guard let folderKey else { return nil }
    let sorted = folderStore.folders(for: folderKey)
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return FolderIndex(
      key: folderKey, sorted: sorted, bySchema: Dictionary(grouping: sorted, by: \.schema))
  }

  /// `entities` split into `folders` and the ungrouped rest (`SidebarFolderLayout`)
  private func foldered(
    _ entities: PublicEntities, folders: [SidebarFolder]
  ) -> (folders: [FolderContent], rest: PublicEntities) {
    let layout = SidebarFolderLayout.build(
      folders: folders, tables: entities.tables, views: entities.views,
      isFiltering: !publicKeywords.isEmpty)
    var rest = entities
    rest.tables = layout.tables
    rest.views = layout.views
    return (layout.groups, rest)
  }

  private static func member(_ table: DatabaseTable) -> String {
    SidebarFolder.member(schema: table.schema, name: table.name)
  }

  private static func member(_ view: DatabaseView) -> String {
    SidebarFolder.member(schema: view.schema, name: view.name)
  }

  /// Tables and views of `schema` the sidebar lists, as folder members (what a drop may move)
  private func listedMembers(in schema: String) -> Set<String> {
    guard isListed(schema) else { return [] }
    var members = Set(
      workspaceManager.databaseTables.filter { $0.schema == schema }.map(Self.member))
    members.formUnion(
      workspaceManager.databaseViews.filter { $0.schema == schema }.map(Self.member))
    return members
  }

  /// The row menu's folder items for the row `member` of `schema` in folder `current`
  private func folderActions(
    member: String, schema: String, current: UUID?, index: FolderIndex?
  ) -> SidebarFolderActions? {
    guard let index else { return nil }
    let folderKey = index.key
    return SidebarFolderActions(
      member: member, folders: index.bySchema[schema] ?? [], currentFolderID: current,
      onMove: { folderStore.move(member, toFolder: $0, for: folderKey) },
      onNewFolder: { folderPrompt = .create(schema: schema, member: member) },
      onRemove: { folderStore.removeMember(member, for: folderKey) })
  }

  /// Moves the dropped rows of the folder's schema in; anything else (another schema, text from
  /// another app) is refused
  private func dropOnFolder(_ items: [String], folder: SidebarFolder) -> Bool {
    guard let folderKey else { return false }
    let listed = listedMembers(in: folder.schema)
    let accepted = items.filter { listed.contains($0) }
    for member in accepted {
      folderStore.move(member, toFolder: folder.id, for: folderKey)
    }
    if !accepted.isEmpty { collapsedFolders.remove(folder.id) }
    return !accepted.isEmpty
  }

  private func saveFolderName(_ name: String, for prompt: SidebarFolderPrompt) {
    folderPrompt = nil
    guard let folderKey else { return }
    switch prompt {
    case .create(let schema, let member):
      if let folder = folderStore.createFolder(named: name, schema: schema, for: folderKey) {
        folderStore.move(member, toFolder: folder.id, for: folderKey)
      }
    case .rename(let folder):
      folderStore.renameFolder(id: folder.id, to: name, for: folderKey)
    }
  }

  private func folderSection(
    _ content: FolderContent, showsSchema: Bool, folderIndex: FolderIndex?
  ) -> some View {
    let folder = content.folder
    return SidebarFolderSection(
      folder: folder, count: content.count,
      isExpanded: !publicKeywords.isEmpty || !collapsedFolders.contains(folder.id),
      onToggle: {
        // A filter keeps every folder open
        guard publicKeywords.isEmpty else { return }
        withAnimation(.snappy(duration: 0.2)) {
          if collapsedFolders.contains(folder.id) {
            collapsedFolders.remove(folder.id)
          } else {
            collapsedFolders.insert(folder.id)
          }
        }
      },
      onRename: { folderPrompt = .rename(folder) },
      onDelete: {
        guard let folderKey else { return }
        folderStore.deleteFolder(id: folder.id, for: folderKey)
      },
      onDrop: { dropOnFolder($0, folder: folder) },
      content: {
        ForEach(content.tables) { table in
          tableRow(table, showsSchema: showsSchema, folderIndex: folderIndex, folderID: folder.id)
        }
        ForEach(content.views) { view in
          viewRow(view, showsSchema: showsSchema, folderIndex: folderIndex, folderID: folder.id)
        }
      }
    )
  }

  /// The Public tab's schemas, read once per render
  private struct PublicSchemas {
    /// Schemas the tab leaves out; none on engines without the schema filter
    let hidden: Set<String>
    /// Schemas that hold at least one object, hidden ones included
    let all: Set<String>
    /// Listed schemas holding an object read with the schema (not the sequences and types read
    /// on expand): they alone pick the flat or grouped layout, so expanding a section never
    /// flips it
    let schemaLoad: Set<String>
    /// Listed schemas that hold at least one object, the connection's default schema first
    let listed: [String]

    /// Every schema with an object is hidden: the tab says so instead of showing empty sections
    var isEverySchemaHidden: Bool { listed.isEmpty && !all.isDisjoint(with: hidden) }
  }

  private var publicSchemas: PublicSchemas {
    let hidden = hiddenSchemas
    var loaded = Set(workspaceManager.databaseTables.map(\.schema))
    loaded.formUnion(workspaceManager.databaseViews.map(\.schema))
    loaded.formUnion(workspaceManager.databaseFunctions.map(\.schema))
    loaded.formUnion(workspaceManager.databaseProcedures.map(\.schema))
    loaded.formUnion(workspaceManager.databaseTriggers.map(\.schema))
    var all = loaded
    all.formUnion((workspaceManager.databaseSequences.items ?? []).map(\.schema))
    all.formUnion((workspaceManager.databaseUserTypes.items ?? []).map(\.schema))
    return PublicSchemas(
      hidden: hidden, all: all, schemaLoad: loaded.subtracting(hidden),
      listed: SidebarSectionModel.listedSchemas(
        all, hidden: hidden, defaultSchema: connectionDatabaseType.dialect.defaultSchema))
  }

  /// The filter menu: on engines with the filter, once there is a choice or a schema is hidden
  private func showsSchemaFilter(_ schemas: PublicSchemas) -> Bool {
    SidebarSectionModel.filtersSchemas(connectionDatabaseType)
      && (schemas.all.count > 1 || !schemas.all.isDisjoint(with: schemas.hidden))
  }

  private func schemaFilterMenu(_ schemas: PublicSchemas) -> some View {
    SidebarSchemaFilterMenu(
      schemas: SidebarSectionModel.listedSchemas(
        schemas.all, hidden: [], defaultSchema: connectionDatabaseType.dialect.defaultSchema),
      hidden: schemas.hidden,
      onChange: { workspaceManager.setHiddenSchemas($0) })
  }

  private var publicTabContent: some View {
    let schemaState = publicSchemas
    let entities = publicEntities(hidden: schemaState.hidden)
    let schemas = schemaState.listed
    let index = folderIndex
    let showsFilterMenu = showsSchemaFilter(schemaState)
    let searchesEveryTable = WorkspaceManager.searchesEveryTable(connectionDatabaseType)
    return VStack(spacing: 0) {
      if searchesEveryTable || showsFilterMenu {
        SidebarFilterField(text: $publicFilter, trailingSpacing: Spacing.xs) {
          HStack(spacing: Spacing.xs) {
            if showsFilterMenu {
              schemaFilterMenu(schemaState)
            }
            if searchesEveryTable {
              Button {
                workspaceManager.openCrossTableSearch()
              } label: {
                Image(systemName: "text.magnifyingglass")
              }
              .buttonStyle(GhostButtonStyle(iconOnly: true))
              .controlSize(.small)
              .disabled(!workspaceManager.canSearchEveryTable)
              .help("Find a Value in Every Table")
            }
          }
        }
      } else {
        SidebarFilterField(text: $publicFilter)
      }

      if schemaState.isEverySchemaHidden {
        everySchemaHiddenState
      } else if !publicKeywords.isEmpty && entities.isEmpty {
        noMatchesState
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            // One schema keeps the flat layout; two or more get one group per schema
            if schemaState.schemaLoad.count > 1
              && SidebarSectionModel.groupsBySchema(queryLanguage)
            {
              ForEach(schemas, id: \.self) { schema in
                let inSchema = entities.inSchema(schema)
                if !inSchema.isEmpty {
                  let grouped = foldered(
                    inSchema, folders: index?.bySchema[schema] ?? [])
                  EntitySection(title: schema, count: inSchema.count, icon: "folder") {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                      entitySections(
                        grouped.rest, folders: grouped.folders, folderIndex: index,
                        idPrefix: "\(schema).", showsEmptySections: false, showsSchema: false,
                        schema: schema)
                    }
                  }
                  // The schema's menu: the database's, with Import Files into this schema
                  .contextMenu { databaseMenuItems(schema: schema) }
                  .id(publicKeywords.isEmpty ? schema : "\(schema)-filtered")
                }
              }
            } else {
              let flat = foldered(
                entities, folders: index?.folders(in: Set(schemas)) ?? [])
              entitySections(
                flat.rest, folders: flat.folders, folderIndex: index, idPrefix: "",
                showsEmptySections: publicKeywords.isEmpty,
                showsSchema: connectionDatabaseType.namesSchema, schema: nil)
            }
          }
          .padding(.vertical, Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The database's menu: section headers and empty space (rows keep their own menus)
        .contextMenu { databaseMenuItems(schema: nil) }
      }
    }
  }

  /// The database's menu items; `schema` is the schema group they open on (nil: the database,
  /// whose files go into the schema New Table targets)
  @ViewBuilder
  private func databaseMenuItems(schema: String?) -> some View {
    if queryLanguage == .sql {
      if connectionDatabaseType.capabilities.supportsDataImport {
        Button("Import Files...") { onImportFiles(schema ?? createTableSchemas.first, nil) }
          .disabled(!workspaceManager.canImportData)
      }
      Button("Export Data Dictionary...") { workspaceManager.openDataDictionaryExport() }
        .disabled(!workspaceManager.canExportDataDictionary)
    }
    if workspaceManager.supportsSchemaCompare {
      Button("Compare Schemas...") { workspaceManager.openSchemaCompare() }
        .disabled(!workspaceManager.canCompareSchemas)
    }
  }

  /// `folders`, then the language's sections (`SidebarSectionModel`) of the ungrouped
  /// `entities`. `idPrefix` keeps section ids unique per schema; `showsSchema` adds the
  /// "(schema)" label to table and view rows; `schema` is the group the sections sit in (nil:
  /// flat list), New Table's default target.
  @ViewBuilder
  private func entitySections(
    _ entities: PublicEntities, folders: [FolderContent], folderIndex: FolderIndex?,
    idPrefix: String, showsEmptySections: Bool, showsSchema: Bool, schema: String?
  ) -> some View {
    ForEach(folders) { content in
      folderSection(content, showsSchema: showsSchema, folderIndex: folderIndex)
    }
    ForEach(
      SidebarSectionModel.sections(
        for: queryLanguage,
        supportsUserTypes: connectionDatabaseType.capabilities.supportsUserTypes),
      id: \.kind
    ) { section in
      entitySection(
        section, entities, folderIndex: folderIndex, idPrefix: idPrefix,
        showsEmptySections: showsEmptySections, showsSchema: showsSchema, schema: schema)
    }
  }

  @ViewBuilder
  private func entitySection(
    _ section: SidebarSectionModel.Section, _ entities: PublicEntities,
    folderIndex: FolderIndex?, idPrefix: String, showsEmptySections: Bool, showsSchema: Bool,
    schema: String?
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
            tableRow(table, showsSchema: showsSchema, folderIndex: folderIndex)
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
            viewRow(view, showsSchema: showsSchema, folderIndex: folderIndex)
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

  /// `folderID` is the folder listing the row, nil when ungrouped
  private func tableRow(
    _ table: FilteredTable, showsSchema: Bool, folderIndex: FolderIndex?, folderID: UUID? = nil
  ) -> some View {
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
      onImportFiles: connectionDatabaseType.capabilities.supportsDataImport
        ? { onImportFiles(table.source.schema, table.source) } : nil,
      onGenerateRows: connectionDatabaseType.capabilities.supportsRowStaging
        ? { onGenerateRows(table.source) } : nil,
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
      },
      folderActions: folderActions(
        member: table.folderMember, schema: table.source.schema, current: folderID,
        index: folderIndex)
    )
  }

  /// `folderID` is the folder listing the row, nil when ungrouped
  private func viewRow(
    _ view: FilteredView, showsSchema: Bool, folderIndex: FolderIndex?, folderID: UUID? = nil
  ) -> some View {
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
      },
      folderActions: folderActions(
        member: view.folderMember, schema: view.source.schema, current: folderID,
        index: folderIndex)
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

  private var everySchemaHiddenState: some View {
    VStack(spacing: Spacing.sm) {
      Text("Every schema is hidden")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
      Button("Show All") { workspaceManager.setHiddenSchemas([]) }
        .buttonStyle(FilledSecondaryButtonStyle())
        .controlSize(.small)
    }
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

  /// Never over a relocked window's cover (a pending confirmation is cancelled when the cover
  /// shows; a running one shows again after the unlock)
  private var isConfirmPresented: Binding<Bool> {
    guard workspaceManager.lockCoverage == nil, let admin else { return .constant(false) }
    return MongoAdminConfirmSheet.isPresented(admin.model)
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
