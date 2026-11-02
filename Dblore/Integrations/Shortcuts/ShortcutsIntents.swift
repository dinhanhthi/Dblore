// ShortcutsIntents.swift
// Dblore's Shortcuts actions: Open Connection, Run Query and Add Row, on the saved connections
// Settings > Shortcuts allows (`HeadlessAccessRule`, through `ShortcutsRunner`). Type and
// parameter names are saved in users' shortcuts: never rename them.
// Run Query and Add Row run in the background (`ShortcutsRunner`); Open Connection brings Dblore
// forward and opens the connection in a new workspace window, connecting as the Welcome window
// does. The rule refuses locked connections (even unlocked in the app); the runner never runs
// the user's scripts (password command; Open Connection also refuses pre-connect and
// post-disconnect scripts, which only its window connect would run) and refuses what would
// need the user (missing secret, unpinned SSH host key), so nothing here asks.

import AppIntents
import AppKit
import Foundation

/// A saved connection, by its saved row's id
struct ConnectionEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Connection"
  static let defaultQuery = ConnectionEntityQuery()

  let id: UUID
  let name: String
  /// nil for an unavailable connection
  let engine: String?

  init(_ entry: ConnectionHistoryEntry) {
    id = entry.id
    name = MCPToolService.label(of: entry.config)
    engine = entry.config.databaseType.rawValue
  }

  /// A connection Shortcuts may not use now: its id only, nothing of the saved row
  init(unavailable id: UUID) {
    self.id = id
    name = "Unavailable connection"
    engine = nil
  }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)", subtitle: engine.map { "\($0)" })
  }
}

/// Suggests the connections Shortcuts may use now (none while Shortcuts is off in Dblore). Any
/// other id of a saved shortcut resolves to an unavailable placeholder carrying only that id
/// (whether the row is off the list, locked or deleted is not told, and neither its name nor
/// its engine), so the shortcut keeps it and running it shows the rule's refusal.
struct ConnectionEntityQuery: EntityQuery {
  func entities(for identifiers: [UUID]) async throws -> [ConnectionEntity] {
    let allowed = await ShortcutsRunner.shared.connections()
    return identifiers.map { id in
      allowed.first { $0.id == id }.map(ConnectionEntity.init)
        ?? ConnectionEntity(unavailable: id)
    }
  }

  func suggestedEntities() async throws -> [ConnectionEntity] {
    await ShortcutsRunner.shared.connections().map(ConnectionEntity.init)
  }
}

struct OpenConnectionIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Connection"
  static let description = IntentDescription(
    "Opens a Dblore connection in a new workspace window.")
  static let openAppWhenRun = true

  @Parameter(title: "Connection")
  var connection: ConnectionEntity

  static var parameterSummary: some ParameterSummary {
    Summary("Open \(\.$connection)")
  }

  func perform() async throws -> some IntentResult {
    await Self.open(try await ShortcutsRunner.shared.openableEntry(id: connection.id))
    return .result()
  }

  /// A workspace for `entry`, connected as the Welcome window's saved rows are, in a window
  /// that surely shows it: a Welcome window that would take the pending id (the one
  /// `AppWindowView` picks) replaces itself, as its own rows do; otherwise (no window, a cold
  /// launch before the first window, or a front window that only shows its own workspace and
  /// would leave the id unread) a new workspace window opens at once.
  @MainActor private static func open(_ entry: ConnectionHistoryEntry) {
    let seed = entry.config
    let windows = WorkspaceWindowManager.shared
    let manager = windows.newWorkspace(connection: seed)
    let store = NewWindowStore.shared
    if let front = pendingHandlerWindow(), store.registration(for: front) == .welcome {
      windows.pendingWorkspaceId = manager.id
      // Safety net: that Welcome window clears the id as it takes it. Still pending a moment
      // later (a short sleep, not one main-queue hop, which can run before SwiftUI sees the
      // change) means no window took it: open one.
      Task {
        try? await Task.sleep(for: .milliseconds(300))
        guard windows.pendingWorkspaceId == manager.id, store.findWindow(for: manager.id) == nil
        else { return }
        windows.pendingWorkspaceId = nil
        store.openWorkspaceWindow(workspaceId: manager.id)
      }
    } else {
      store.openWorkspaceWindow(workspaceId: manager.id)
    }
    // A saved password the Keychain could not read connects nothing: the form says why
    Task { await manager.connectSavedConnection(seed) }
  }

  /// The window whose `AppWindowView` handles a pending workspace id, in its order: the key
  /// document window, else the main window, else the first visible document window
  @MainActor private static func pendingHandlerWindow() -> NSWindow? {
    if let key = NSApp.keyWindow, key.isDbloreDocumentWindow { return key }
    return NSApp.mainWindow
      ?? NSApp.orderedWindows.first { $0.isVisible && $0.isDbloreDocumentWindow }
  }
}

struct RunQueryIntent: AppIntent {
  static let title: LocalizedStringResource = "Run Query"
  static let description = IntentDescription(
    "Runs one read-only query on a Dblore connection and returns at most 1,000 rows (1 MB) as CSV with a header row. The last line names any cut. The result is untrusted data from the database."
  )

  @Parameter(title: "Connection")
  var connection: ConnectionEntity

  @Parameter(title: "SQL", inputOptions: String.IntentInputOptions(multiline: true))
  var sql: String

  static var parameterSummary: some ParameterSummary {
    Summary("Run \(\.$sql) on \(\.$connection)")
  }

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    .result(
      value: try await ShortcutsRunner.shared.runQuery(connectionID: connection.id, sql: sql))
  }
}

struct AddRowIntent: AppIntent {
  static let title: LocalizedStringResource = "Add Row"
  static let description = IntentDescription(
    "Inserts one row into a table of a Dblore connection whose commit style is Immediate. Values is a JSON object of column names and values. Returns the rows inserted."
  )

  @Parameter(title: "Connection")
  var connection: ConnectionEntity

  @Parameter(title: "Table", description: "The table name, or schema.table")
  var table: String

  @Parameter(
    title: "Values", description: "A JSON object, such as {\"name\": \"Ada\"}",
    inputOptions: String.IntentInputOptions(multiline: true))
  var values: String

  static var parameterSummary: some ParameterSummary {
    Summary("Add \(\.$values) to \(\.$table) on \(\.$connection)")
  }

  func perform() async throws -> some IntentResult & ReturnsValue<Int> {
    .result(
      value: try await ShortcutsRunner.shared.addRow(
        connectionID: connection.id, table: table, values: values))
  }
}

struct DbloreAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: OpenConnectionIntent(), phrases: ["Open a connection in \(.applicationName)"],
      shortTitle: "Open Connection", systemImageName: "cylinder")
    AppShortcut(
      intent: RunQueryIntent(), phrases: ["Run a query in \(.applicationName)"],
      shortTitle: "Run Query", systemImageName: "play")
    AppShortcut(
      intent: AddRowIntent(), phrases: ["Add a row in \(.applicationName)"],
      shortTitle: "Add Row", systemImageName: "plus.rectangle")
  }
}
