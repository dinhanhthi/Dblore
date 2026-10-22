//
//  MongoCollectionsView.swift
//  Dblore
//
//  Collections screen of a MongoDB workspace, shown over the tabs like the schema visualizer:
//  the collections and views of the sidebar schema (followed as it reloads) with their kind
//  (capped, time series, clustered, view), storage size, data size, documents, average document
//  size and indexes, sortable by any column. A row opens in a data viewer tab (a double click
//  too), and is renamed or dropped through the same admin flows as the sidebar; those are hidden
//  while schema changes are not allowed.
//

import SwiftUI

struct MongoCollectionsView: View {
  @Bindable var workspaceManager: WorkspaceManager

  @State private var model: MongoOverviewModel
  /// The collection the Rename form is open for
  @State private var renaming: MongoOverviewModel.Row?

  private static let columns = [
    MongoOverviewColumn(title: "Storage size", key: .storageSize, isBytes: true),
    MongoOverviewColumn(title: "Data size", key: .dataSize, isBytes: true),
    MongoOverviewColumn(title: "Documents", key: .count),
    MongoOverviewColumn(title: "Avg document size", key: .avgSize, isBytes: true),
    MongoOverviewColumn(title: "Indexes", key: .indexes),
  ]

  init(workspaceManager: WorkspaceManager) {
    self.workspaceManager = workspaceManager
    _model = State(
      initialValue: MongoOverviewModel(mode: .collections, workspaceManager: workspaceManager))
  }

  var body: some View {
    VStack(spacing: 0) {
      MongoOverviewHeader(model: model) {
        workspaceManager.mongoOverview = nil
      } actions: {
        EmptyView()
      }
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color.appBackground)
    .onAppear { model.load() }
    .onDisappear { model.cancel() }
    // The rename form leaves closing to its caller
    .onChange(of: model.doneAction) { _, done in
      if done != nil { renaming = nil }
    }
    .modalOverlay(isPresented: isRenamePresented) {
      if let row = renaming {
        RenameObjectSheet(
          title: "Rename Collection", currentName: row.name,
          validate: { MongoCollectionDraft.nameProblem($0) },
          isBusy: model.action?.isBusy == true,
          onRename: { newName in
            Task { await model.renameCollection(row, to: newName) }
          },
          isPresented: isRenamePresented)
      }
    }
    .mongoOverviewConfirmSheet(model: model, workspaceManager: workspaceManager)
    .bridgedFocusedSceneValue(\.toggleLeftSidebarAction) { [workspaceManager] in
      workspaceManager.toggleLeftSidebar()
    }
  }

  private var isRenamePresented: Binding<Bool> {
    Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
  }

  /// The database the connection reads
  private var databaseName: String? {
    workspaceManager.workspace.connectionConfig.map(WorkspaceManager.mongoDatabaseName(of:))
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if !workspaceManager.connectionState.isConnected {
      MongoOverviewPlaceholder(text: "Not connected")
    } else if model.rows.isEmpty && workspaceManager.schemaConnectionEpoch == nil
      && !workspaceManager.isLoadingSchema
    {
      // The list comes from the sidebar schema, which has not been read since the last connect
      MongoOverviewPlaceholder(
        text: "The collection list is not loaded. Refresh the schema in the sidebar.")
    } else if model.isLoading && model.rows.isEmpty {
      MongoOverviewPlaceholder(text: "Loading collections...", isLoading: true)
    } else {
      ScrollView {
        MongoOverviewTable(
          title: databaseName.map { "Collections in \($0)" } ?? "Collections", model: model,
          columns: Self.columns, emptyText: "No collections", onOpen: open
        ) { row in
          ForEach(Self.badges(row), id: \.self) { CollectionFlagBadge(text: $0) }
        } menu: { row in
          rowMenu(row)
        }
        .padding(Spacing.md)
      }
    }
  }

  /// Open, then Rename (not a view) and Drop when schema changes are allowed
  private func rowMenu(_ row: MongoOverviewModel.Row) -> some View {
    MongoOverviewRowMenu(name: row.name) {
      Button("Open") { open(row) }
      if model.canChangeSchema {
        Divider()
        if !row.isView {
          Button("Rename…") { renaming = row }
        }
        Button("Drop…", role: .destructive) {
          Task { await model.dropCollection(row) }
        }
        .disabled(model.action?.isBusy == true)
      }
    }
  }

  /// Shows `row` in a data viewer tab (as a sidebar click does) and leaves the screen
  private func open(_ row: MongoOverviewModel.Row) {
    let table = workspaceManager.databaseTables.first {
      $0.schema == row.database && $0.name == row.name
    }
    workspaceManager.openDataViewer(
      schema: row.database, name: row.name,
      orderColumns: table?.columns.filter(\.isPrimaryKey).map(\.name) ?? [])
    workspaceManager.mongoOverview = nil
  }

  /// The sidebar's markers, and "view"
  private static func badges(_ row: MongoOverviewModel.Row) -> [String] {
    let flags = [
      (DatabaseTable.CollectionFlags.capped, "capped"), (.timeSeries, "time series"),
      (.clustered, "clustered"),
    ].filter { row.flags.contains($0.0) }.map(\.1)
    return row.isView ? ["view"] : flags
  }
}
