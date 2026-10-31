//
//  WorkspaceSchemaVisualizerContent.swift
//  Dblore
//
//  Schema visualizer content for workspace level (when no tabs are open)
//

import SwiftUI

/// Schema visualizer view for workspace level - used when no tabs are open
struct WorkspaceSchemaVisualizerContent: View {
  @Bindable var workspaceManager: WorkspaceManager
  /// Opens the join query builder with these tables picked (the selected one, or none)
  let onBuildJoinQuery: ([DatabaseTable]) -> Void
  /// The diagram's selected tables in selection order (Shift- or Command-click adds or removes one)
  @State private var selectedNodeIds: [UUID] = []
  /// The name (or new column) a diagram edit asks for
  @State private var editPrompt: SchemaDiagramEditPrompt?
  /// New Table... on a table header
  @State private var createTable: CreateTableModel?
  /// Preview SQL was clicked (the sheet also shows for the Safe Mode step)
  @State private var showsPreview = false
  /// A sheet over the window shows the toasts itself
  @Environment(\.hidesToastOverlay) private var hidesToastOverlay

  var body: some View {
    VStack(spacing: 0) {
      // Header with controls
      schemaVisualizerHeader

      // Graph content
      graphContent
    }
    .background(Color.appBackground)
    // The tabs (and their toast overlay) are hidden under the diagram; the preview sheet shows
    // the toasts itself while it is open
    .overlay {
      ToastOverlay().environment(\.hidesToastOverlay, hidesToastOverlay || isPreviewShown)
    }
    .sheet(item: $editPrompt) { prompt in
      SchemaDiagramEditPromptSheet(
        prompt: prompt,
        onSubmit: { name, type, isNullable in
          editPrompt = nil
          stage(prompt, name: name, type: type, isNullable: isNullable)
        },
        onClose: { editPrompt = nil })
    }
    .sheet(item: $createTable) { model in
      CreateTableSheet(
        model: model,
        tables: workspaceManager.databaseTables,
        databasePassword: workspaceManager.workspace.connectionConfig?.password,
        isConnected: workspaceManager.connectionState == .connected,
        isShown: { [weak model] in model != nil && createTable === model },
        onClose: { createTable = nil })
    }
    .sheet(isPresented: previewPresented) {
      if let model = workspaceManager.schemaDiagramEditor {
        SchemaDiagramPreviewSheet(
          model: model,
          databasePassword: workspaceManager.workspace.connectionConfig?.password,
          isConnected: workspaceManager.connectionState == .connected,
          isShown: { [weak model] in
            model != nil && workspaceManager.schemaDiagramEditor === model
          },
          onApply: { workspaceManager.applySchemaDiagramChanges() },
          onClose: { closePreview() })
      }
    }
    // The edit model went with the connection: its preview does not come back with the next one
    .onChange(of: workspaceManager.schemaDiagramEditor == nil) { _, isGone in
      if isGone { showsPreview = false }
    }
    // A prompt names a table of the previous database: it goes with the connection
    .onChange(of: workspaceManager.schemaConnectionEpoch) { editPrompt = nil }
    // A schema load landed: an applied (or committed) diagram change lays the diagram out again
    .onChange(of: workspaceManager.sidebarEntityIndex.id) {
      Task { await workspaceManager.relayoutSchemaDiagramIfOwed() }
    }
    // A selection made elsewhere (schema search, a reload) replaces the multi-selection
    .onChange(of: workspaceManager.selectedGraphNodeId, initial: true) { _, id in
      guard id.map({ !selectedNodeIds.contains($0) }) ?? true else { return }
      selectedNodeIds = id.map { [$0] } ?? []
    }
    // Set focused values for Cmd+F, Cmd+G shortcuts in schema visualizer
    .bridgedFocusedSceneValue(\.isSchemaVisualizerActive, true)
    .bridgedFocusedSceneValue(\.zoomTarget, .diagram)
    .bridgedFocusedSceneValue(\.openSearchAction) { [workspaceManager] in
      workspaceManager.openSchemaSearch()
    }
    .bridgedFocusedSceneValue(\.findNextAction) { [workspaceManager] in
      workspaceManager.navigateToNextSchemaMatch()
    }
    .bridgedFocusedSceneValue(\.findPreviousAction) { [workspaceManager] in
      workspaceManager.navigateToPreviousSchemaMatch()
    }
    .bridgedFocusedSceneValue(\.toggleLeftSidebarAction) { [workspaceManager] in
      workspaceManager.toggleLeftSidebar()
    }
  }

  // MARK: - Header

  private var schemaVisualizerHeader: some View {
    HStack(spacing: Spacing.sm) {
      // Back button
      Button(action: { workspaceManager.hideSchemaVisualizer() }) {
        Label("Back", systemImage: "chevron.left")
      }
      .buttonStyle(GhostButtonStyle())
      .help("Close Schema Visualizer")

      Divider()
        .frame(height: 20)

      // Zoom controls grouped together
      HStack(spacing: 0) {
        Button(action: { workspaceManager.zoomOutVisualizer() }) {
          Image(systemName: "minus.magnifyingglass")
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .help("Zoom Out")

        Text("\(Int(workspaceManager.visualizerScale * 100))%")
          .font(.monoSmall)
          .foregroundColor(.foregroundMuted)
          .frame(width: 45)

        Button(action: { workspaceManager.zoomInVisualizer() }) {
          Image(systemName: "plus.magnifyingglass")
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .help("Zoom In")
      }
      .padding(.horizontal, Spacing.xs)
      .padding(.vertical, Spacing.xxs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .fill(Color.inputBackground)
      )

      Divider()
        .frame(height: 20)

      // Reset view button
      Button(action: { workspaceManager.resetVisualizerView() }) {
        Image(systemName: "arrow.counterclockwise")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Reset View")

      // Reset layout button
      Button(action: {
        Task {
          await workspaceManager.resetSchemaLayout()
        }
      }) {
        Image(systemName: "rectangle.3.group")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Reset Layout to Default")
      // Nothing laid out (the table picker shows): nothing to reset
      .disabled(workspaceManager.isLoadingSchemaGraph || workspaceManager.schemaGraph == nil)

      // Back to the table picker of a catalog above the diagram's cap (once a connect's schema
      // landed: until then the tables are the previous database's)
      if workspaceManager.schemaConnectionEpoch != nil,
        workspaceManager.databaseTables.count > SchemaLayoutEngine.maxTables
      {
        Button(action: { workspaceManager.pickSchemaDiagramTables() }) {
          Image(systemName: "checklist")
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .help("Pick Tables")
        .accessibilityLabel("Pick Tables")
        .disabled(workspaceManager.schemaGraph == nil)
      }

      // Toggle table connection lines (ER diagram lines)
      Button(action: { workspaceManager.showTableConnections.toggle() }) {
        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
      }
      .buttonStyle(
        GhostButtonStyle(isActive: workspaceManager.showTableConnections, iconOnly: true)
      )
      .help(
        workspaceManager.showTableConnections
          ? "Hide Table Connections" : "Show Table Connections")

      // Toggle column connection lines
      Button(action: { workspaceManager.showColumnConnections.toggle() }) {
        Image(systemName: "arrow.triangle.branch")
      }
      .buttonStyle(
        GhostButtonStyle(isActive: workspaceManager.showColumnConnections, iconOnly: true)
      )
      .help(
        workspaceManager.showColumnConnections
          ? "Hide Column Connections" : "Show Column Connections")

      Divider()
        .frame(height: 20)

      // Export as PNG button
      Button(action: { workspaceManager.exportSchemaAsImage() }) {
        Image(systemName: "square.and.arrow.up")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Export as PNG")
      .disabled(workspaceManager.schemaGraph?.isEmpty ?? true)

      // Diagram as text: the tables in the diagram as Mermaid or Graphviz DOT
      Menu {
        Button("Copy as Mermaid") { copyDiagramText(SchemaGraphTextExport.mermaid) }
        Button("Copy as DOT") { copyDiagramText(SchemaGraphTextExport.dot) }
        Divider()
        Button("Save as Mermaid (.mmd)...") {
          saveDiagramText(SchemaGraphTextExport.mermaid, fileExtension: "mmd")
        }
        Button("Save as DOT (.dot)...") {
          saveDiagramText(SchemaGraphTextExport.dot, fileExtension: "dot")
        }
      } label: {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Export as Text")
      .accessibilityLabel("Export as Text")
      .disabled(workspaceManager.schemaGraph?.isEmpty ?? true)

      // Refresh button
      Button(action: {
        Task {
          await workspaceManager.refreshSchemaGraph()
        }
      }) {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Refresh Schema")
      .disabled(workspaceManager.isLoadingSchemaGraph)

      // The join query builder, the selected tables picked in selection order
      Button(action: { onBuildJoinQuery(selectedTables) }) {
        Image(systemName: "arrow.triangle.merge")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help(buildJoinQueryTitle)
      .accessibilityLabel(buildJoinQueryTitle)
      .disabled(!workspaceManager.canBuildJoinQuery)

      Spacer()

      // Search button (floated to right, same style as notebook/editor)
      Button(action: {
        workspaceManager.openSchemaSearch()
      }) {
        Image(systemName: "magnifyingglass")
      }
      .buttonStyle(
        GhostButtonStyle(
          isActive: workspaceManager.isSchemaSearchPanelVisible,
          iconOnly: true
        )
      )
      .help("Search (⌘F)")
    }
    .padding(.horizontal, Spacing.sm)
    .frame(height: ComponentSize.headerHeight)
    .background(Color.cardHeaderBackground)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  /// The tables of the selected nodes, in selection order
  private var selectedTables: [DatabaseTable] {
    let nodes = workspaceManager.schemaGraph?.nodes ?? []
    return selectedNodeIds.compactMap { id in nodes.first { $0.id == id }?.table }
  }

  private var buildJoinQueryTitle: String {
    switch selectedTables.count {
    case 0: "Build Join Query (Shift- or Command-click tables to pick them)"
    case 1: "Build Join Query From Selected Table"
    case let count: "Build Join Query From \(count) Selected Tables"
    }
  }

  private func copyDiagramText(_ render: (SchemaGraph) -> String) {
    guard let graph = workspaceManager.schemaGraph else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(render(graph), forType: .string)
  }

  private func saveDiagramText(_ render: (SchemaGraph) -> String, fileExtension: String) {
    guard let graph = workspaceManager.schemaGraph else { return }
    DataExporter.saveFile(
      content: render(graph), defaultFilename: "schema_diagram.\(fileExtension)",
      allowedFileTypes: [fileExtension])
  }

  // MARK: - Graph Content

  @ViewBuilder
  private var graphContent: some View {
    if !workspaceManager.connectionState.isConnected {
      // Show disconnected state first - this takes priority
      emptyStateView(message: "Connect to a database to visualize schema")
    } else if workspaceManager.isLoadingSchemaGraph {
      SchemaGraphLoadingView()
    } else if let graph = workspaceManager.schemaGraph {
      if graph.isEmpty {
        emptyStateView(message: "No tables found in database")
      } else if !graph.hasRelationships {
        noRelationshipsView(graph: graph)
      } else {
        graphView(graph: graph)
      }
    } else if workspaceManager.schemaConnectionEpoch != nil,
      workspaceManager.databaseTables.count > SchemaLayoutEngine.maxTables
    {
      // Only once a connect's schema landed: until then the tables are the previous database's
      SchemaDiagramTablePicker(workspaceManager: workspaceManager)
    } else {
      emptyStateView(message: "Loading schema...")
    }
  }

  private func emptyStateView(message: String) -> some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "point.3.connected.trianglepath.dotted")
        .font(.system(size: 48))
        .foregroundColor(.foregroundMuted)
      Text(message)
        .font(.body)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Spacing.xl)
  }

  private func noRelationshipsView(graph: SchemaGraph) -> some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 48))
        .foregroundColor(.warning)

      Text("No Foreign Key Relationships")
        .font(.headline)
        .foregroundColor(.foreground)

      Text("Found \(graph.nodes.count) tables but no foreign key constraints.")
        .font(.body)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)

      Text("Tables without relationships are not shown in the graph.")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Spacing.xl)
  }

  private func graphView(graph: SchemaGraph) -> some View {
    VStack(spacing: 0) {
      ZStack(alignment: .top) {
        SchemaGraphView(
          graph: Binding(
            get: { workspaceManager.schemaGraph ?? SchemaGraph() },
            set: { workspaceManager.schemaGraph = $0 }
          ),
          scale: $workspaceManager.visualizerScale,
          offset: $workspaceManager.visualizerOffset,
          selectedNodeId: $workspaceManager.selectedGraphNodeId,
          selectedNodeIds: $selectedNodeIds,
          showTableConnections: $workspaceManager.showTableConnections,
          showColumnConnections: $workspaceManager.showColumnConnections,
          searchState: workspaceManager.schemaSearchState,
          onNodeDoubleClick: { node in
            handleNodeDoubleClick(node)
          },
          onNodeDragEnded: {
            workspaceManager.saveSchemaNodePositions()
          },
          onViewCreated: { nsView in
            workspaceManager.schemaGraphNSView = nsView
          },
          onEditAction: { perform($0) },
          editDisabledReason: workspaceManager.schemaDiagramEditDisabledReason,
          foreignKeyDisabledReason: workspaceManager.schemaDiagramForeignKeyDisabledReason,
          stagedTables: workspaceManager.schemaDiagramEditor?.touchedTables ?? [],
          loadingTables: Set(
            workspaceManager.schemaDiagramEditor?.loadingTables.map(\.qualifiedName) ?? [])
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        // Search panel overlay (top-right corner, same style as notebook/editor)
        if workspaceManager.isSchemaSearchPanelVisible {
          HStack {
            Spacer()
            SchemaSearchPanelView(workspaceManager: workspaceManager)
              .frame(maxWidth: 420)
              .padding(.trailing, Spacing.md)
              .padding(.top, Spacing.sm)
          }
          .transition(.move(edge: .top).combined(with: .opacity))
        }
      }

      // Staged changes: count, Discard, Preview SQL and Apply
      if let model = workspaceManager.schemaDiagramEditor, SchemaDiagramEditBar.isShown(model) {
        SchemaDiagramEditBar(
          model: model, onPreview: { showsPreview = true },
          onApply: { workspaceManager.applySchemaDiagramChanges() })
      }

      // Footer legend
      schemaLegendFooter
    }
  }

  // MARK: - Legend Footer

  private var schemaLegendFooter: some View {
    ViewThatFits(in: .horizontal) {
      // First try: Single row layout
      HStack(spacing: Spacing.xl) {
        columnAttributesLegend

        Divider()
          .frame(height: 16)

        relationshipLegend
      }
      .frame(maxWidth: .infinity)

      // Fallback: Two rows layout for narrow width
      VStack(spacing: Spacing.sm) {
        columnAttributesLegend
        relationshipLegend
      }
      .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.xs)
    .background(Color.cardHeaderBackground)
    .overlay(
      Divider(),
      alignment: .top
    )
  }

  private var columnAttributesLegend: some View {
    HStack(spacing: Spacing.md) {
      legendItem(icon: "key.fill", color: .yellow, label: "Primary Key")
      legendItem(icon: "number", color: .blue, label: "Identity")
      legendItem(icon: "touchid", color: .purple, label: "Unique")
      legendItem(icon: "diamond.fill", color: .gray, label: "Not Null")
      legendItem(icon: "diamond", color: .gray, label: "Nullable")
    }
  }

  private var relationshipLegend: some View {
    HStack(spacing: Spacing.md) {
      relationshipLegendItem(type: .one, label: "One")
      relationshipLegendItem(type: .many, label: "Many")
      relationshipLegendItem(type: .zeroOrOne, label: "Zero or One")
      relationshipLegendItem(type: .zeroOrMany, label: "Zero or Many")
    }
  }

  private func legendItem(icon: String, color: Color, label: String) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: icon)
        .font(.system(size: 10))
        .foregroundColor(color)
        .frame(width: 12)
      Text(label)
        .font(.system(size: 10))
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  private func relationshipLegendItem(type: SchemaRelationshipType, label: String) -> some View {
    HStack(spacing: Spacing.xs) {
      SchemaRelationshipSymbolView(type: type)
        .frame(width: 24, height: 12)
      Text(label)
        .font(.system(size: 10))
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  // MARK: - Editing

  private var isPreviewShown: Bool {
    guard let model = workspaceManager.schemaDiagramEditor else { return false }
    return showsPreview || model.confirmation.pendingConfirmation != nil
  }

  private var previewPresented: Binding<Bool> {
    Binding(
      get: { isPreviewShown },
      set: { if !$0 { closePreview() } })
  }

  /// Closing the sheet cancels a Safe Mode step still open (a late Touch ID answer sends nothing)
  private func closePreview() {
    showsPreview = false
    workspaceManager.schemaDiagramEditor?.cancelConfirmation()
  }

  private static func key(_ node: SchemaNode) -> SchemaDiagramEditModel.TableKey {
    SchemaDiagramEditModel.TableKey(schema: node.table.schema, table: node.table.name)
  }

  /// A menu item or a foreign-key drop: a prompt or the Create Table sheet opens at once; the
  /// rest is staged (the table shows loading while its structure is read)
  private func perform(_ action: SchemaDiagramEditAction) {
    switch action {
    case .renameTable(let node):
      editPrompt = .renameTable(Self.key(node))
    case .addColumn(let node):
      editPrompt = .addColumn(Self.key(node))
    case .renameColumn(let node, let column):
      editPrompt = .renameColumn(Self.key(node), column: column)
    case .newTable(let schema):
      openCreateTable(schema: schema)
    case .dropColumn(let node, let column):
      workspaceManager.stageSchemaDiagramEdit { await $0.dropColumn(column, in: Self.key(node)) }
    case .dropForeignKey(let foreignKey):
      workspaceManager.stageSchemaDiagramEdit { await $0.dropForeignKey(foreignKey) }
    case .addForeignKey(let source, let column, let target, let targetColumn):
      workspaceManager.stageSchemaDiagramEdit {
        await $0.addForeignKey(
          from: Self.key(source), column: column, to: Self.key(target), column: targetColumn)
      }
    }
  }

  private func stage(
    _ prompt: SchemaDiagramEditPrompt, name: String, type: String, isNullable: Bool
  ) {
    switch prompt {
    case .renameTable(let table):
      workspaceManager.stageSchemaDiagramEdit { await $0.renameTable(table, to: name) }
    case .renameColumn(let table, let column):
      workspaceManager.stageSchemaDiagramEdit {
        await $0.renameColumn(column, in: table, to: name)
      }
    case .addColumn(let table):
      let column = StructureChange.NewColumn(
        name: name, type: type, isNullable: isNullable, defaultExpression: nil)
      workspaceManager.stageSchemaDiagramEdit { await $0.addColumn(column, to: table) }
    }
  }

  /// The Create Table sheet for a table in `schema` (the diagram's schemas are the choices); a
  /// created table lays the diagram out again once the schema reloaded
  private func openCreateTable(schema: String) {
    guard createTable == nil else { return }
    let schemas = Set((workspaceManager.schemaGraph?.nodes ?? []).map(\.table.schema))
      .union([schema]).sorted()
    guard let model = workspaceManager.makeCreateTableModel(schema: schema, schemas: schemas)
    else { return }
    let applied = model.onApplied
    model.onApplied = { [weak workspaceManager] pending in
      workspaceManager?.oweSchemaDiagramRelayout()
      await applied?(pending)
    }
    createTable = model
  }

  // MARK: - Actions

  private func handleNodeDoubleClick(_ node: SchemaNode) {
    // Find table in sidebar and expand it
    if let tableIndex = workspaceManager.databaseTables.firstIndex(where: {
      $0.schema == node.table.schema && $0.name == node.table.name
    }) {
      // Open left sidebar if not visible
      if !workspaceManager.isLeftSidebarVisible {
        workspaceManager.toggleLeftSidebar()
      }
      // Expand the table in sidebar
      if !workspaceManager.databaseTables[tableIndex].isExpanded {
        workspaceManager.databaseTables[tableIndex].isExpanded = true
      }
    }
  }
}

// MARK: - Loading

/// In the diagram's place while it lays out. Its spinner fades in after 150 ms, so a fast
/// layout never flashes it.
private struct SchemaGraphLoadingView: View {
  @State private var showsSpinner = false

  var body: some View {
    VStack(spacing: Spacing.md) {
      ProgressView()
        .opacity(showsSpinner ? 1 : 0)
        .animation(.easeIn(duration: 0.15), value: showsSpinner)
        // Opt out of the app-wide animation kill switch, only for the fade
        .transaction(value: showsSpinner) { $0.disablesAnimations = false }
      Text("Loading schema...")
        .font(.body)
        .foregroundColor(.foregroundMuted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      try? await Task.sleep(for: .milliseconds(150))
      showsSpinner = !Task.isCancelled
    }
  }
}

// MARK: - Table Picker

/// In the diagram's place when the catalog has more tables than one diagram lays out: a schema
/// (only those within the cap) or up to `SchemaLayoutEngine.maxTables` checked tables
private struct SchemaDiagramTablePicker: View {
  @Bindable var workspaceManager: WorkspaceManager
  /// Qualified names of the checked tables
  @State private var checked: Set<String> = []
  /// The schema whose tables were checked from the dropdown; nil once a row changes them
  @State private var pickedSchema: String?
  @State private var filter = ""
  /// Positions in `databaseTables` the filter keeps, in array order; nil until the first result
  @State private var shown: [Int]?
  /// Each schema with its table count, in name order
  @State private var schemas: [SchemaCount] = []

  private static let cap = SchemaLayoutEngine.maxTables

  struct SchemaCount: Hashable, Sendable {
    let name: String
    let tables: Int
  }

  /// The filter's input: a schema reload (new index) or a keystroke runs it again
  private struct FilterKey: Equatable {
    let index: UUID
    let text: String
  }

  var body: some View {
    let tables = workspaceManager.databaseTables
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text(
        "This schema has \(tables.count.formatted()) tables. The diagram shows up to \(Self.cap): pick a "
          + "schema or tables."
      )
      .font(.body)
      .foregroundColor(.foreground)

      HStack(spacing: Spacing.sm) {
        schemaDropdown
        Spacer()
        Text("\(checked.count) of \(Self.cap) tables checked")
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .monospacedDigit()
        Button("Uncheck All") {
          checked = []
          pickedSchema = nil
        }
        .buttonStyle(GhostButtonStyle())
        .disabled(checked.isEmpty)
        Button("Show Diagram") { workspaceManager.showSchemaDiagram(tables: checked) }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(checked.isEmpty)
      }

      TextField("Filter tables", text: $filter)
        .textFieldStyle(.plain)
        .font(.structureField)
        .autocorrectionDisabled()
        .structureInputStyle()

      Divider()

      if let shown, shown.isEmpty {
        Text("No table matches.")
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          // Rows are built as they scroll into view, never one per table up front
          LazyVStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(shown ?? [], id: \.self) { position in
              if tables.indices.contains(position) {
                tableRow(tables[position])
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .padding(Spacing.xl)
    .frame(maxWidth: 640, maxHeight: .infinity)
    .frame(maxWidth: .infinity)
    .onAppear { checked = workspaceManager.schemaDiagramTables ?? [] }
    .task(id: workspaceManager.sidebarEntityIndex.id) {
      let counts = await Self.schemaCounts(workspaceManager.databaseTables)
      if !Task.isCancelled { schemas = counts }
    }
    // Off the main actor; a newer keystroke cancels the run (its result is dropped)
    .task(id: FilterKey(index: workspaceManager.sidebarEntityIndex.id, text: filter)) {
      let result = await workspaceManager.sidebarEntityIndex.filterInBackground(
        keywords: SidebarEntityFilter.keywords(in: filter), hidden: [], temporarySchemas: [])
      guard !Task.isCancelled else { return }
      shown = (result.listed.tables + result.temporary.tables).map(\.position).sorted()
    }
  }

  private var schemaDropdown: some View {
    CapsulePickerMenu(title: pickedSchema ?? "Pick a Schema") {
      ForEach(schemas, id: \.self) { schema in
        Toggle(
          "\(schema.name) (\(schema.tables) tables)",
          isOn: Binding(
            get: { pickedSchema == schema.name },
            set: { _ in pick(schema: schema.name) })
        )
        .disabled(schema.tables > Self.cap)
      }
    }
    .accessibilityLabel("Schema")
    .disabled(schemas.isEmpty)
  }

  private func tableRow(_ table: DatabaseTable) -> some View {
    let name = table.qualifiedName
    let isChecked = checked.contains(name)
    return Toggle(
      isOn: Binding(
        get: { isChecked },
        set: { on in
          if on { checked.insert(name) } else { checked.remove(name) }
          pickedSchema = nil
        })
    ) {
      Text(verbatim: name)
        .font(.monoMedium)
        .foregroundColor(.foreground)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .toggleStyle(.checkbox)
    // At the cap, only checked rows change
    .disabled(!isChecked && checked.count >= Self.cap)
  }

  /// Checks every table of the schema (within the cap: larger schemas are disabled)
  private func pick(schema: String) {
    checked = Set(
      workspaceManager.databaseTables.lazy.filter { $0.schema == schema }.map(\.qualifiedName))
    pickedSchema = schema
  }

  @concurrent private nonisolated static func schemaCounts(
    _ tables: [DatabaseTable]
  ) async -> [SchemaCount] {
    var counts: [String: Int] = [:]
    for table in tables { counts[table.schema, default: 0] += 1 }
    return counts.map { SchemaCount(name: $0.key, tables: $0.value) }.sorted { $0.name < $1.name }
  }
}

// MARK: - Preview

#Preview("Schema Visualizer Header") {
  WorkspaceSchemaVisualizerContent(
    workspaceManager: WorkspaceManager.preview(), onBuildJoinQuery: { _ in }
  )
  .frame(width: 800, height: 500)
}
