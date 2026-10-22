//
//  MongoDatabasesView.swift
//  Dblore
//
//  Databases screen of a MongoDB workspace, shown over the tabs like the schema visualizer:
//  every database of the server (or the connection's alone, with the reason) with its storage
//  size, data size, collections and indexes, sortable by any column, the current one marked.
//  Create Database asks for the name and a first collection (a database exists once it holds
//  one), then offers to switch to it. A row switches to its database, or drops it after the typed
//  name (never admin, local or config); the current one opens the Back Up Database panel.
//  Changes go through `MongoOverviewModel`'s `MongoAdminActionModel`, whose confirm sheet shows
//  the typed name, the Safe Mode panel and failures. The header, table and placeholder below
//  are shared with `MongoCollectionsView`.
//

import SwiftUI

struct MongoDatabasesView: View {
  @Bindable var workspaceManager: WorkspaceManager

  @State private var model: MongoOverviewModel
  @State private var showsCreate = false
  /// The database the Create form sent, until its command is done or the form closes
  @State private var creatingName: String?
  /// Created from this screen: offered as "Switch to <name>"
  @State private var createdName: String?
  /// The database a switch is connecting to
  @State private var switchingTo: String?
  /// Why the last switch was refused or failed
  @State private var switchError: String?

  private static let columns = [
    MongoOverviewColumn(title: "Storage size", key: .storageSize, isBytes: true),
    MongoOverviewColumn(title: "Data size", key: .dataSize, isBytes: true),
    MongoOverviewColumn(title: "Collections", key: .count),
    MongoOverviewColumn(title: "Indexes", key: .indexes),
  ]

  init(workspaceManager: WorkspaceManager) {
    self.workspaceManager = workspaceManager
    _model = State(
      initialValue: MongoOverviewModel(mode: .databases, workspaceManager: workspaceManager))
  }

  var body: some View {
    VStack(spacing: 0) {
      MongoOverviewHeader(model: model, isBusy: switchingTo != nil) {
        workspaceManager.mongoOverview = nil
      } actions: {
        if model.canChangeSchema {
          Button {
            showsCreate = true
          } label: {
            Label("Create Database…", systemImage: "plus")
          }
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(isActionBusy)
          .help("Create a database with its first collection")
        }
      }
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color.appBackground)
    .onAppear { model.load() }
    .onDisappear { model.cancel() }
    // A reconnect (Reconnect, another server) reads the list again
    .onChange(of: workspaceManager.schemaConnectionEpoch) { _, epoch in
      if let epoch, epoch != model.listEpoch, switchingTo == nil, !model.isLoading {
        model.load()
      }
    }
    .onChange(of: model.doneAction) { _, done in
      guard done != nil, let name = creatingName else { return }
      creatingName = nil
      showsCreate = false
      createdName = name
    }
    .onChange(of: showsCreate) { _, shows in
      if !shows { creatingName = nil }
    }
    .modalOverlay(isPresented: $showsCreate) {
      MongoCreateDatabaseSheet(
        isBusy: isActionBusy,
        onCreate: { name, collection in
          creatingName = name
          createdName = nil
          Task { await model.createDatabase(name, collection: collection) }
        },
        isPresented: $showsCreate)
    }
    .mongoOverviewConfirmSheet(model: model, workspaceManager: workspaceManager)
    .bridgedFocusedSceneValue(\.toggleLeftSidebarAction) { [workspaceManager] in
      workspaceManager.toggleLeftSidebar()
    }
  }

  /// The database the connection reads
  private var currentDatabase: String? {
    workspaceManager.workspace.connectionConfig.map(WorkspaceManager.mongoDatabaseName(of:))
  }

  /// A Create or Drop is being confirmed or sent
  private var isActionBusy: Bool { model.action?.isBusy == true }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if let switchingTo {
      // The reconnect leaves the connection down meanwhile
      MongoOverviewPlaceholder(text: "Connecting to \(switchingTo)...", isLoading: true)
    } else if !workspaceManager.connectionState.isConnected {
      // A failed switch leaves the workspace disconnected: its error says why
      MongoOverviewPlaceholder(text: switchError ?? "Not connected", isError: switchError != nil)
    } else if let error = model.loadError {
      MongoOverviewPlaceholder(text: error, isError: true, retry: model.load)
    } else if model.isLoading && model.rows.isEmpty {
      MongoOverviewPlaceholder(text: "Loading databases...", isLoading: true)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          notices
          MongoOverviewTable(
            title: "Databases", model: model, columns: Self.columns, emptyText: "No databases"
          ) { row in
            if row.isCurrent {
              CollectionFlagBadge(text: "current")
                .help("The connection reads this database")
            }
          } menu: { row in
            rowMenu(row)
          }
        }
        .padding(Spacing.md)
      }
    }
  }

  /// The partial-list note, the switch failure and the offer to switch to a new database
  @ViewBuilder
  private var notices: some View {
    if let note = model.note {
      Text(note)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
    }
    if let switchError {
      Text(switchError)
        .font(.small)
        .foregroundColor(.destructive)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    if let createdName, createdName != currentDatabase {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.success)
        Text("Created \(createdName)")
          .font(.small)
          .foregroundColor(.foreground)
        Button("Switch to \(createdName)") { switchTo(createdName) }
          .buttonStyle(FilledSecondaryButtonStyle())
        Spacer(minLength: 0)
        Button {
          self.createdName = nil
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .help("Dismiss")
      }
    }
  }

  /// Switch to, Back Up (the current database only) and Drop Database (not admin, local or
  /// config; only when schema changes are allowed)
  @ViewBuilder
  private func rowMenu(_ row: MongoOverviewModel.Row) -> some View {
    let canDrop = model.canChangeSchema && !row.isSystem
    let canBackUp = row.isCurrent && workspaceManager.canBackUpMongo
    if row.isCurrent && !canDrop && !canBackUp {
      Color.clear.frame(width: MongoOverviewWidth.menu, height: 0)
    } else {
      MongoOverviewRowMenu(name: row.name) {
        if !row.isCurrent {
          Button("Switch to \(row.name)") { switchTo(row.name) }
        }
        if canBackUp {
          Button("Back Up…") { workspaceManager.openMongoBackup(.backup) }
        }
        if canDrop {
          if !row.isCurrent || canBackUp { Divider() }
          Button("Drop Database…", role: .destructive) {
            Task { await model.dropDatabase(row) }
          }
        }
      }
      .disabled(switchingTo != nil || isActionBusy)
    }
  }

  /// Reconnects to `name`; once connected the Collections screen of that database shows
  private func switchTo(_ name: String) {
    guard switchingTo == nil else { return }
    switchingTo = name
    switchError = nil
    Task {
      let refusal = await model.switchTo(name)
      switchingTo = nil
      if let refusal {
        switchError = refusal
      } else {
        workspaceManager.mongoOverview = .collections
      }
    }
  }
}

// MARK: - Create Database

/// Create Database form (a `GenericModal`, presented with `modalOverlay`): the database name and
/// its first collection, with the mongosh command it sends (or what is wrong) below. It stays
/// open under the confirm sheet (the draft survives a Cancel or an error); the screen closes it
/// once the database is created.
private struct MongoCreateDatabaseSheet: View {
  /// A command is being confirmed or sent: Create waits
  let isBusy: Bool
  /// Gets the trimmed database and collection names
  let onCreate: (_ name: String, _ collection: String) -> Void
  @Binding var isPresented: Bool

  @State private var name = ""
  @State private var collection = ""

  private static let width: CGFloat = 520
  private static let height: CGFloat = 340
  private static let labelWidth: CGFloat = 130

  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var trimmedCollection: String {
    collection.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var problems: [String] {
    [MongoDatabaseName.validate(trimmedName), MongoCollectionDraft.nameProblem(trimmedCollection)]
      .compactMap { $0 }
  }

  private var command: MongoAdminCommand? {
    guard problems.isEmpty else { return nil }
    return .createDatabase(database: trimmedName, collection: trimmedCollection, options: nil)
  }

  var body: some View {
    GenericModal(
      title: "New Database", titleIcon: "cylinder", width: Self.width, height: Self.height,
      isPresented: $isPresented
    ) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        Grid(alignment: .leading, horizontalSpacing: Spacing.sm, verticalSpacing: Spacing.sm) {
          field("Database", "e.g. analytics", $name)
          field("First collection", "e.g. events", $collection)
        }
        Text("A database exists once it holds a collection.")
          .font(.small)
          .foregroundColor(.foregroundMuted)
        preview
        Spacer(minLength: 0)
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } footer: {
      GenericModalFooter {
        Spacer()
        Button("Cancel") { isPresented = false }
          .buttonStyle(FilledSecondaryButtonStyle())
        Button("Create") {
          guard !isBusy, command != nil else { return }
          onCreate(trimmedName, trimmedCollection)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isBusy || command == nil)
      }
    }
  }

  @ViewBuilder
  private var preview: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Command")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
      if let command {
        Text(verbatim: command.render())
          .font(.monoMedium)
          .foregroundColor(.foreground)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .inputStyle()
      } else {
        ForEach(problems, id: \.self) { problem in
          Text(problem)
            .font(.small)
            .foregroundColor(.destructive)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func field(
    _ title: String, _ placeholder: String, _ text: Binding<String>
  )
    -> some View
  {
    GridRow(alignment: .center) {
      Text(title)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .frame(width: Self.labelWidth, alignment: .leading)
      TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.monoMedium)
        .autocorrectionDisabled()
        .inputCapsuleStyle()
    }
  }
}

// MARK: - Shared with MongoCollectionsView

extension MongoAdminActionModel {
  /// Being confirmed or sent: another command waits
  var isBusy: Bool {
    switch state {
    case .confirming, .running: true
    case .idle, .failed, .done: false
    }
  }
}

extension MongoOverviewModel {
  /// The last action once it is done, nil before. A new action replaces the model, so a form
  /// watching this sees its own command finish even when the previous one was done too.
  var doneAction: ObjectIdentifier? {
    guard let action, action.state == .done else { return nil }
    return ObjectIdentifier(action)
  }
}

extension View {
  /// The confirm sheet of `model`'s admin action (typed name, Safe Mode panel, failure)
  func mongoOverviewConfirmSheet(
    model: MongoOverviewModel, workspaceManager: WorkspaceManager
  ) -> some View {
    sheet(isPresented: model.action.map(MongoAdminConfirmSheet.isPresented) ?? .constant(false)) {
      if let action = model.action {
        MongoAdminConfirmSheet(
          model: action, databasePassword: workspaceManager.workspace.connectionConfig?.password,
          isConnected: workspaceManager.connectionState == .connected)
      }
    }
  }
}

/// Back to the tabs, the load or action in progress, the screen's `actions` and Refresh
struct MongoOverviewHeader<Actions: View>: View {
  let model: MongoOverviewModel
  /// Something else runs (a switch): Refresh waits
  var isBusy = false
  let onBack: () -> Void
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Button(action: onBack) {
        Label("Back", systemImage: "chevron.left")
      }
      .buttonStyle(GhostButtonStyle())
      .help("Back to the tabs")
      if model.isLoading || model.action?.state == .running {
        ProgressView().controlSize(.small)
        Text(model.isLoading ? "Loading..." : "Running...")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
      Spacer(minLength: Spacing.sm)
      actions()
      Button {
        model.load()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .buttonStyle(FilledSecondaryButtonStyle())
      .disabled(model.isLoading || isBusy)
      .help("Read the list and sizes again")
    }
    .padding(.horizontal, Spacing.sm)
    .frame(height: ComponentSize.headerHeight)
    .background(Color.cardHeaderBackground)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}

/// A number column of an overview table
struct MongoOverviewColumn {
  let title: String
  let key: MongoOverviewModel.SortKey
  /// A byte size, else a count
  var isBytes = false

  /// `row`'s value: "…" while its stats load, an em dash when unknown
  func text(_ row: MongoOverviewModel.Row) -> String {
    if row.statsState == .loading { return "…" }
    guard let value = row.value(key) else { return "—" }
    return isBytes
      ? ByteCountFormatter.string(fromByteCount: value, countStyle: .file) : value.formatted()
  }
}

/// The sortable table of an overview screen: Name, then `columns`. A column title sorts by it,
/// again the other way; unknown values sort last.
struct MongoOverviewTable<NameAccessory: View, RowMenu: View>: View {
  let title: String
  let model: MongoOverviewModel
  let columns: [MongoOverviewColumn]
  let emptyText: String
  /// A double click on a row
  var onOpen: ((MongoOverviewModel.Row) -> Void)?
  /// Markers after the name
  @ViewBuilder let nameAccessory: (MongoOverviewModel.Row) -> NameAccessory
  /// Trailing row menu (`MongoOverviewRowMenu`)
  @ViewBuilder let menu: (MongoOverviewModel.Row) -> RowMenu

  var body: some View {
    let rows = model.sortedRows
    SettingsGroupCard(title: title, background: .cardBackground, contentPadding: 0) {
      EmptyView()
    } content: {
      VStack(alignment: .leading, spacing: 0) {
        header
        if rows.isEmpty {
          Text(emptyText)
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .structureTableRow(isFirst: true)
        }
        ForEach(Array(rows.enumerated()), id: \.element.id) { position, row in
          rowView(row)
            .structureTableRow(isFirst: position == 0)
            .contentShape(Rectangle())
            // Simultaneous: the row menu's click is not held back for a second one
            .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen?(row) })
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      sortButton("Name", .name, alignment: .leading)
        .frame(minWidth: MongoOverviewWidth.nameMin, maxWidth: .infinity, alignment: .leading)
      ForEach(columns, id: \.title) { column in
        sortButton(column.title, column.key, alignment: .trailing)
          .frame(width: MongoOverviewWidth.number, alignment: .trailing)
          .structureColumnDivider()
      }
      Color.clear.frame(width: MongoOverviewWidth.menu, height: 0)
    }
    .structureTableHeader()
  }

  private func sortButton(
    _ title: String, _ key: MongoOverviewModel.SortKey, alignment: Alignment
  ) -> some View {
    Button {
      model.sort(by: key)
    } label: {
      HStack(spacing: Spacing.xxs) {
        Text(title)
        if model.sortKey == key {
          Image(systemName: model.ascending ? "chevron.up" : "chevron.down")
            .font(.system(size: 8, weight: .semibold))
        }
      }
      .frame(maxWidth: .infinity, alignment: alignment)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Sort by \(title.lowercased())")
  }

  private func rowView(_ row: MongoOverviewModel.Row) -> some View {
    HStack(spacing: Spacing.sm) {
      HStack(spacing: Spacing.xs) {
        Text(row.name)
          .font(.structureField)
          .foregroundColor(.structureCellForeground)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(row.name)
        nameAccessory(row)
      }
      .frame(minWidth: MongoOverviewWidth.nameMin, maxWidth: .infinity, alignment: .leading)
      ForEach(columns, id: \.title) { column in
        Text(column.text(row))
          .font(.structureField)
          .foregroundColor(.structureCellMuted)
          .monospacedDigit()
          .lineLimit(1)
          .frame(width: MongoOverviewWidth.number, alignment: .trailing)
      }
      menu(row)
    }
  }
}

/// The ellipsis menu at the end of an overview row
struct MongoOverviewRowMenu<Items: View>: View {
  let name: String
  @ViewBuilder let items: () -> Items

  var body: some View {
    Menu {
      items()
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.foregroundMuted)
        .frame(width: MongoOverviewWidth.menu, height: MongoOverviewWidth.menu)
        .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Actions")
    .accessibilityLabel("Actions for \(name)")
  }
}

/// Column widths of an overview table; a row without actions keeps `menu` empty
enum MongoOverviewWidth {
  static let nameMin: CGFloat = 180
  static let number: CGFloat = 110
  static let menu: CGFloat = 20
}

/// A centered state of an overview screen: loading, not connected, a failure with Retry
struct MongoOverviewPlaceholder: View {
  let text: String
  var isLoading = false
  var isError = false
  var retry: (() -> Void)?

  var body: some View {
    VStack(spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        if isLoading { ProgressView().controlSize(.small) }
        Text(text)
          .font(isError ? .system(size: 12, design: .monospaced) : .small)
          .foregroundColor(isError ? .destructive : .foregroundMuted)
          .textSelection(.enabled)
          .multilineTextAlignment(.center)
      }
      if let retry {
        Button("Retry", action: retry)
          .buttonStyle(SecondaryButtonStyle())
      }
    }
    .padding(Spacing.md)
  }
}
