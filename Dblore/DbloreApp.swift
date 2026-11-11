//
//  DbloreApp.swift
//  Dblore
//

import AppKit
import Combine
@preconcurrency import SQLite3
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import os

// MARK: - App Delegate for file handling

class AppDelegate: NSObject, NSApplicationDelegate {
  /// Set once quitting is confirmed, so closing the windows on quit does not reopen Welcome
  private var isTerminating = false
  /// Files that launch the app arrive before this is set
  private var didFinishLaunching = false
  /// File opens whose window is not made yet
  private var fileOpensInFlight = 0
  /// The first screen wake or activation after launch (see `watchForMissingLaunchWindow`)
  private var missingLaunchWindowObservers: [(NotificationCenter, NSObjectProtocol)] = []
  private var didCheckMissingLaunchWindow = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    PerfSignpost.event("launch.didFinish")
    didFinishLaunching = true
    // Read now: restore clears it once its windows are open
    watchForMissingLaunchWindow(plansWelcome: !LaunchRestorer.isRestoring)
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let window = note.object as? NSWindow else { return }
      // Read now, on this main-queue callback: the content view is still attached
      // while the window closes. A later hop would miss the marker.
      let (wasWelcome, isDocument) = MainActor.assumeIsolated {
        (WelcomeWindowMarker.isWelcome(window), window.isDbloreDocumentWindow)
      }
      Task { @MainActor in
        self?.reopenWelcomeIfLastWindowClosed(window, wasWelcome: wasWelcome)
        // Quit writes its own snapshot while the windows are still open, then closes them.
        guard let self, isDocument, !self.isTerminating else { return }
        LaunchSessionCapture.schedule()
      }
    }
    openLaunchWindowIfMissing()
    // Start Sparkle (no-op under tests)
    UpdaterController.shared.start()
    // The MCP server runs only while enabled in Settings
    if !SessionManager.isRunningAsTestHost {
      MCPServerController.shared.activate()
      // Sleep, screen lock and idle relock the locked items
      RelockMonitor.shared.start()
    }
  }

  /// The system window (a normal launch) or the Welcome window a launch by a file opens takes the
  /// restored front window. A launch with neither (a Shortcut, or a file opened just after launch:
  /// the scene makes no window for them, and a workspace window never takes the claim) would
  /// leave the restore waiting all session: a Welcome window opens to take it.
  private func openLaunchWindowIfMissing() {
    Task { @MainActor in
      guard LaunchRestorer.hasStagedFrontWindowClaim else { return }
      let store = NewWindowStore.shared
      let hasLaunchWindow = NSApp.windows.contains {
        $0.isDbloreDocumentWindow && !store.isWorkspaceWindow($0)
      }
      guard !hasLaunchWindow else { return }
      store.openWelcomeWindow(frame: .zero)
    }
  }

  /// A launch while the display sleeps is not activated, so SwiftUI makes no window: Welcome
  /// opens on the first screen wake or activation instead, if no window came by then
  /// (`opensMissingLaunchWindow`). A normal launch already has its window: the check is a no-op.
  private func watchForMissingLaunchWindow(plansWelcome: Bool) {
    guard !SessionManager.isRunningAsTestHost else { return }
    let triggers: [(NotificationCenter, Notification.Name)] = [
      (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification),
      (.default, NSApplication.didBecomeActiveNotification),
    ]
    for (center, name) in triggers {
      let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.checkMissingLaunchWindow(plansWelcome: plansWelcome)
        }
      }
      missingLaunchWindowObservers.append((center, token))
    }
  }

  /// Taken once, on the first trigger. The observers go at once: opening Welcome activates the app.
  @MainActor
  private func checkMissingLaunchWindow(plansWelcome: Bool) {
    let alreadyFired = didCheckMissingLaunchWindow
    didCheckMissingLaunchWindow = true
    for (center, token) in missingLaunchWindowObservers {
      center.removeObserver(token)
    }
    missingLaunchWindowObservers = []
    // SwiftUI may make its first window on activation itself: decide one turn later
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let opens = LaunchSessionRestore.opensMissingLaunchWindow(
        plansWelcome: plansWelcome,
        hasDocumentWindow: NSApp.windows.contains(where: \.isOpenDbloreDocumentWindow),
        isFileOpenPending: fileOpensInFlight > 0
          || WorkspaceWindowManager.shared.pendingWorkspaceId != nil,
        isTerminating: isTerminating, alreadyFired: alreadyFired)
      guard opens else { return }
      NewWindowStore.shared.openWelcomeWindow(frame: .zero)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    guard !SessionManager.isRunningAsTestHost else { return }
    MCPServerController.shared.stopForQuit()
    // After the quit's transaction prompts and flushes, which may still use an unlock
    LockRegistry.shared.relockAll()
  }

  /// Set before launch finishes, so a click that launches the app is delivered too
  func applicationWillFinishLaunching(_ notification: Notification) {
    // Debug builds, or Release with -DbloreStallMonitor YES: logs main-thread stalls
    MainThreadStallMonitor.installIfEnabled()
    // Before the first window, so every scroll view gets the soft scroll bar
    NSScrollView.installSoftScrollers()
    // Long-query notification clicks open their tab
    if !SessionManager.isRunningAsTestHost {
      UNUserNotificationCenter.current().delegate = self
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    // A launch by a file opens no system window (the scene handles no external event): the
    // launch window opens here, takes a restored window's claim, then the file's workspace
    if !didFinishLaunching {
      NewWindowStore.shared.openWelcomeWindow(frame: .zero)
    }

    // Separate workspace files from document files
    var workspaceURLs: [URL] = []
    var documentURLs: [URL] = []

    for url in urls {
      switch WorkspaceManager.fileOpenRoute(url) {
      case .workspace: workspaceURLs.append(url)
      case .ignored: continue  // A DuckDB .wal opens with its database, not alone
      case .duckDBDatabase, .document: documentURLs.append(url)
      }
    }

    fileOpensInFlight += 1
    Task { @MainActor in
      defer { fileOpensInFlight -= 1 }
      // Open workspace files directly
      // A locked workspace's window opens first with its locked placeholder and asks there; a
      // file that does not open says why in a toast
      for url in workspaceURLs {
        if let id = await WorkspaceWindowManager.shared.requestWorkspaceReportingError(url: url) {
          WorkspaceWindowManager.shared.showPendingWorkspace(id)
        }
      }

      // For document files, check if we have existing workspaces
      if !documentURLs.isEmpty {
        let existingWorkspaces = WorkspaceWindowManager.shared.allWorkspaces

        if existingWorkspaces.isEmpty {
          // No existing workspaces - create new one and open files
          let newManager = WorkspaceWindowManager.shared.newWorkspace()
          WorkspaceWindowManager.shared.showPendingWorkspace(newManager.id)
          for url in documentURLs {
            try? await newManager.openFile(url: url, checksScriptKind: true)
          }
        } else {
          // Have existing workspaces - store URLs for chooser dialog
          // A new window on the welcome screen shows the chooser
          PendingFileOpen.shared.addFiles(documentURLs)
          NewWindowStore.shared.openWelcomeWindow(frame: .zero, reuseExisting: false)
        }
      }
    }
  }

  /// The "+" button in a window's tab bar sends this down the responder chain.
  @MainActor @objc func newWindowForTab(_ sender: Any?) {
    NewWindowStore.shared.openWelcomeWindowTab()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false  // Keep app running even when all windows are closed
  }

  /// Closing the last workspace/welcome window opens a new window on the welcome screen.
  /// Closing the welcome window itself never reopens it.
  /// Another document window (including a minimized one) just lets this window close.
  /// About and other small windows are not resizable, so they never trigger this.
  @MainActor
  private func reopenWelcomeIfLastWindowClosed(_ closed: NSWindow, wasWelcome: Bool) {
    guard !wasWelcome, !isTerminating, !LaunchRestorer.isRestoring,
      !SessionManager.isRunningAsTestHost,
      closed.isDbloreDocumentWindow
    else { return }
    let frame = closed.frame
    // Let a quit in progress (which closes the windows too) win over the reopen
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self, !self.isTerminating, !LaunchRestorer.isRestoring else { return }
      let hasOtherDocumentWindow = NSWindow.hasOtherOpenDocumentWindow(
        in: NSApp.windows, excluding: closed)
      guard !hasOtherDocumentWindow else { return }
      NewWindowStore.shared.openWelcomeWindow(frame: frame)
    }
  }

  /// Quitting with a pending Protected transaction asks Commit / Roll back / Cancel for each
  /// workspace (Cancel keeps the app running). A force-quit skips this: the connection closes
  /// without COMMIT, so the server rolls the transaction back. Connections with a
  /// post-disconnect script or a Vault lease are closed (their scripts started, their leases
  /// revoked) before the app exits. A connect still waiting for its lease is not among them
  /// (its slot is empty until the lease arrives): that lease ends at its TTL.
  ///
  /// First of all, running work (queries, imports, copies, dumps, restores) asks once ("Stop and
  /// Quit" / "Cancel"); with nothing running, "Confirm before quitting" asks on Cmd+Q.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let managers = WorkspaceWindowManager.shared.allWorkspaces
    let registry = RunningWorkRegistry.shared
    // Read now: `NSApp.currentEvent` is gone once the quit waits
    let confirmBeforeQuit = asksBeforeKeyboardQuit
    let closing = managers.map(\.connectionManager).filter(\.closesAtQuit)
    // Nothing runs, nothing is pending and nothing closes: at most the generic question
    if registry.items.isEmpty, closing.isEmpty,
      managers.allSatisfy({ $0.pendingTransaction.isIdle && !$0.isAnyTabExecuting })
    {
      guard !confirmBeforeQuit || confirmKeyboardQuit() else { return .terminateCancel }
      isTerminating = true
      recordLaunchSession()
      return .terminateNow
    }
    // Waits without blocking the app; every path replies once
    Task { @MainActor in
      guard
        await WorkspaceManager.answerQuitQuestions(
          managers, runningWork: registry, confirmBeforeQuit: confirmBeforeQuit,
          confirmQuit: confirmKeyboardQuit)
      else {
        NSApp.reply(toApplicationShouldTerminate: false)
        return
      }
      isTerminating = true
      recordLaunchSession()
      await Self.closeConnectionsForQuit(closing)
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// Closes `connections` (a Vault lease is revoked after its close) and starts the
  /// post-disconnect scripts taken (started, not awaited: they run outside the app). After
  /// `quitCloseLimit`, the scripts of connections still closing start anyway, so a quit never
  /// hangs on a server.
  @concurrent nonisolated private static func closeConnectionsForQuit(
    _ connections: [DatabaseConnectionManager]
  ) async {
    let scripts = connections.map { $0.takePostDisconnectForQuit() }
    guard !connections.isEmpty else { return }
    let started = OSAllocatedUnfairLock(
      initialState: [Bool](repeating: false, count: scripts.count))
    /// Starts script `index` once, whichever of its close and the limit comes first
    let start: @Sendable (Int) -> Void = { index in
      let first = started.withLock { flags in
        defer { flags[index] = true }
        return !flags[index]
      }
      if first { scripts[index]?() }
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let resumed = OSAllocatedUnfairLock(initialState: false)
      let resume: @Sendable () -> Void = {
        let first = resumed.withLock { done in
          defer { done = true }
          return !done
        }
        if first { continuation.resume() }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + quitCloseLimit) {
        scripts.indices.forEach(start)
        resume()
      }
      Task {
        await withTaskGroup(of: Void.self) { group in
          for (index, connection) in connections.enumerated() {
            group.addTask {
              await connection.disconnect()
              start(index)
            }
          }
        }
        resume()
      }
    }
  }

  /// Longest a quit waits for connections with a post-disconnect script or a lease to close
  nonisolated private static let quitCloseLimit: TimeInterval = 3

  /// With "Confirm before quitting" on, Cmd+Q asks first. Quit from the Dock, logout and
  /// update relaunches come without a key event, so they never ask.
  private var asksBeforeKeyboardQuit: Bool {
    AppSettings.shared.confirmBeforeQuit && NSApp.currentEvent?.type == .keyDown
      && !SessionManager.isRunningAsTestHost
  }

  /// The generic "Quit Dblore?" when nothing runs (running work asks its own question instead)
  private func confirmKeyboardQuit() -> Bool {
    let alert = NSAlert()
    alert.messageText = "Quit Dblore?"
    alert.informativeText = "You can turn this off in Settings > General."
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// Writes the launch snapshot, and flushes workspaces that already have a file, before the
  /// process exits. Untitled workspaces stay in the snapshot only — this does not show a save panel.
  private func recordLaunchSession() {
    guard !SessionManager.isRunningAsTestHost else { return }
    LaunchSessionCapture.prepareForQuit()
    for manager in WorkspaceWindowManager.shared.allWorkspaces {
      manager.flushToExistingFile()
    }
    LaunchSessionCapture.saveNow()
  }
}

// MARK: - Long-query notification clicks

extension AppDelegate: UNUserNotificationCenterDelegate {
  /// A click activates the app and selects the tab the run finished in
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let tabID =
      (response.notification.request.content.userInfo[
        QueryCompletionNotifier.tabIDKey] as? String).flatMap(UUID.init(uuidString:))
    await MainActor.run { QueryNotificationRouter.open(tabID: tabID) }
  }

  /// Delivered while Dblore is active: shown only when "only when inactive" is off
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    await MainActor.run {
      AppSettings.shared.notifyOnlyWhenInactive ? [] : [.banner, .sound]
    }
  }
}

/// Brings the tab of a long-query notification to the front
@MainActor
enum QueryNotificationRouter {
  /// Activates the app; selects the tab and fronts its window when it is still open
  static func open(tabID: UUID?) {
    NSApp.activate()
    guard let tabID,
      let manager = WorkspaceWindowManager.shared.allWorkspaces.first(where: {
        $0.tabs.contains { $0.id == tabID }
      })
    else { return }
    manager.selectTab(id: tabID)
    let store = NewWindowStore.shared
    if let window = store.findWindow(for: manager.id)
      ?? NSApp.windows.first(where: { store.registration(for: $0) == .workspace(manager.id) })
    {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
    } else {
      WorkspaceWindowManager.shared.showPendingWorkspace(manager.id)
    }
  }
}

// MARK: - Pending File Open Manager

/// Manages files that are waiting to be opened when user chooses a workspace
@MainActor
@Observable
class PendingFileOpen {
  static let shared = PendingFileOpen()

  /// Files waiting to be opened
  private(set) var pendingFiles: [URL] = []

  /// Whether there are pending files
  var hasPendingFiles: Bool {
    !pendingFiles.isEmpty
  }

  private init() {}

  /// Add files to pending list
  func addFiles(_ urls: [URL]) {
    pendingFiles.append(contentsOf: urls)
  }

  /// Take all pending files (clears the list)
  func takePendingFiles() -> [URL] {
    let files = pendingFiles
    pendingFiles = []
    return files
  }

  /// Clear pending files without opening
  func clearPendingFiles() {
    pendingFiles = []
  }
}

/// The entry point: launches the SwiftUI app.
@main
enum DbloreMain {
  @MainActor static func main() {
    DbloreApp.main()
  }
}

struct DbloreApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  init() {
    PerfSignpost.event("launch.init")
    // Show .help() tooltips after 300ms instead of the slow system default (read when AppKit
    // creates its tooltip manager, so it must be registered this early)
    UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 300])
    // Migrate from single session to connection history (one-time operation)
    if !SessionManager.isRunningAsTestHost {
      SessionManager.migrateIfNeeded()
      pruneQueryHistoryOnLaunch()
      RewindPrune.schedule()
      // Publish the saved locks before any connect path runs (no Keychain read)
      _ = SessionManager.loadHistory(passwords: NoPasswordStore())
      LaunchSessionRestore.prepare()
    }

    // Configure SQLite temp directory to use app's temp directory
    configureSQLiteTempDirectory()
  }

  var body: some Scene {
    // Main window group - each window can show Welcome or a Workspace
    // Window-local state determines what to show
    WindowGroup {
      AppWindowView()
        // Disable all SwiftUI animations app-wide for snappier tab and layout switches
        .transaction {
          // Sidebar show/hide keeps its animation
          guard !$0.isSidebarAnimation else { return }
          $0.disablesAnimations = true
          $0.animation = nil
        }
    }
    .windowStyle(.hiddenTitleBar)
    .commands {
      SharedCommands()
      WorkspaceCommands()
      TabCommands()
      NotebookCommands()
      EditorCommands()
      SchemaVisualizerCommands()
    }
    .defaultSize(DocumentWindowSizing.compactSize)
    // Min and max follow the content (`documentWindowMode`): Welcome screens are not resizable
    .windowResizability(.contentSize)
    // A file opened from Finder or `open` (or another external event) makes no window here:
    // by default each one adds a Welcome window beside the one `application(_:open:)` shows.
    // The Dock's reopen still makes one.
    .handlesExternalEvents(matching: [])
  }

  /// Drop expired history rows. A failure is logged; launch continues either way.
  /// Skipped under XCTest so the test host never opens History.sqlite.
  private func pruneQueryHistoryOnLaunch() {
    guard !SessionManager.isRunningAsTestHost else { return }
    Task { @MainActor in
      let days = AppSettings.shared.historyRetentionDays
      let olderThan = QueryHistoryStore.retentionCutoff(retentionDays: days)
      let maxEntries = AppSettings.shared.historyMaxEntries
      do {
        try await QueryHistoryStore.shared.prune(olderThan: olderThan, maxEntries: maxEntries)
      } catch {
        await AppLogger.shared.error(
          "Query history prune failed: \(error.localizedDescription)", category: "History")
      }
    }
  }

  /// Configure SQLite to use app's temporary directory to avoid sandbox issues
  private func configureSQLiteTempDirectory() {
    let tempDir = FileManager.default.temporaryDirectory.path
    // Safe: called once during app initialization on main thread
    MainActor.assumeIsolated {
      sqlite3_temp_directory = strdup(tempDir)
    }
  }
}

// MARK: - FocusedValues Extension

/// Represents the document type/mode of the currently focused window/tab.
enum DocumentMode {
  case notebook  // Notebook mode (.dblore files) - has Cell menu, custom Find
  case editor  // Editor mode (.sql files) - uses native macOS menus
  case markdown  // Markdown notes (.md files) - no Cell or Query menu
}

/// FocusedValue key for tracking document mode across the app.
struct DocumentModeFocusedValueKey: FocusedValueKey {
  typealias Value = DocumentMode
}

/// FocusedValue key for tracking active tab ID
struct ActiveTabIdKey: FocusedValueKey {
  typealias Value = UUID
}

/// FocusedValue key for accessing active tab's ViewModel
struct ActiveViewModelKey: FocusedValueKey {
  typealias Value = NotebookViewModel
}

extension FocusedValues {
  /// Document mode of the active tab
  var documentMode: DocumentMode? {
    get { self[DocumentModeFocusedValueKey.self] }
    set { self[DocumentModeFocusedValueKey.self] = newValue }
  }

  /// Active tab ID
  var activeTabId: UUID? {
    get { self[ActiveTabIdKey.self] }
    set { self[ActiveTabIdKey.self] = newValue }
  }

  /// Active tab's ViewModel
  var activeViewModel: NotebookViewModel? {
    get { self[ActiveViewModelKey.self] }
    set { self[ActiveViewModelKey.self] = newValue }
  }

  /// Action to toggle the left sidebar in the focused tab.
  var toggleLeftSidebarAction: (() -> Void)? {
    get { self[ToggleLeftSidebarActionKey.self] }
    set { self[ToggleLeftSidebarActionKey.self] = newValue }
  }

  /// Action to toggle the right sidebar in the focused tab.
  var toggleRightSidebarAction: (() -> Void)? {
    get { self[ToggleRightSidebarActionKey.self] }
    set { self[ToggleRightSidebarActionKey.self] = newValue }
  }

  var openSearchAction: (() -> Void)? {
    get { self[OpenSearchActionKey.self] }
    set { self[OpenSearchActionKey.self] = newValue }
  }

  /// Opens Find and Replace; nil where Replace may not edit (data viewer, read-only source)
  var findReplaceAction: (() -> Void)? {
    get { self[FindReplaceActionKey.self] }
    set { self[FindReplaceActionKey.self] = newValue }
  }

  var findNextAction: (() -> Void)? {
    get { self[FindNextActionKey.self] }
    set { self[FindNextActionKey.self] = newValue }
  }

  var findPreviousAction: (() -> Void)? {
    get { self[FindPreviousActionKey.self] }
    set { self[FindPreviousActionKey.self] = newValue }
  }

  /// Toggles the line bookmark at the caret; nil outside a SQL editor tab
  var toggleLineBookmarkAction: (() -> Void)? {
    get { self[ToggleLineBookmarkActionKey.self] }
    set { self[ToggleLineBookmarkActionKey.self] = newValue }
  }

  /// Moves the caret to the next line bookmark; nil outside a SQL editor tab
  var nextLineBookmarkAction: (() -> Void)? {
    get { self[NextLineBookmarkActionKey.self] }
    set { self[NextLineBookmarkActionKey.self] = newValue }
  }

  /// Moves the caret to the previous line bookmark; nil outside a SQL editor tab
  var previousLineBookmarkAction: (() -> Void)? {
    get { self[PreviousLineBookmarkActionKey.self] }
    set { self[PreviousLineBookmarkActionKey.self] = newValue }
  }

  /// Whether schema visualizer is active
  var isSchemaVisualizerActive: Bool? {
    get { self[IsSchemaVisualizerActiveKey.self] }
    set { self[IsSchemaVisualizerActiveKey.self] = newValue }
  }
}

/// FocusedValue key for left sidebar toggle action.
struct ToggleLeftSidebarActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// FocusedValue key for right sidebar toggle action.
struct ToggleRightSidebarActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// FocusedValue key for schema visualizer active state.
struct IsSchemaVisualizerActiveKey: FocusedValueKey {
  typealias Value = Bool
}

/// FocusedValue key for opening search panel.
struct OpenSearchActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// FocusedValue key for opening the search panel with its Replace row.
struct FindReplaceActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// FocusedValue key for find next match.
struct FindNextActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// FocusedValue key for find previous match.
struct FindPreviousActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// FocusedValue keys for the SQL editor's line bookmarks.
struct ToggleLineBookmarkActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

struct NextLineBookmarkActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

struct PreviousLineBookmarkActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

// MARK: - Shared Commands

struct SharedCommands: Commands {
  var body: some Commands {
    // About command
    CommandGroup(replacing: .appInfo) {
      Button("About Dblore") {
        showAboutWindow()
      }
    }

    // Owns the system Settings slot, so Cmd+, opens this modal in notebook, SQL,
    // and data viewer instead of a second SwiftUI Settings window.
    CommandGroup(replacing: .appSettings) {
      Button("Settings") {
        NotificationCenter.default.post(name: .openSettings, object: nil)
      }
      .keyboardShortcut(",", modifiers: .command)
    }

    // Document windows carry an empty toolbar only for its titlebar row: no
    // Show/Hide Toolbar or Customize Toolbar items (window tab items stay).
    CommandGroup(replacing: .toolbar) {}

    CommandGroup(after: .appInfo) {
      CheckForUpdatesButton()
    }

    // Cell and staged grid edits live on the view model's undo manager, not the text
    // view's. No key equivalent: Cmd+Z stays on the system Undo item.
    CommandGroup(after: .undoRedo) {
      CellUndoCommandButtons()
    }
  }

  private func showAboutWindow() {
    let aboutView = AboutView()
    let hostingController = NSHostingController(rootView: aboutView)

    let window = NSWindow(contentViewController: hostingController)
    window.title = "About Dblore"
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.center()
    window.makeKeyAndOrderFront(nil)
  }
}

/// "Check for Updates" menu item; observes the updater so the disabled state stays current.
private struct CheckForUpdatesButton: View {
  @ObservedObject private var updater = UpdaterController.shared

  var body: some View {
    Button("Check for Updates") {
      updater.checkForUpdates()
    }
    .disabled(!updater.canCheckForUpdates)
  }
}

/// "Reopen Closed Tab" menu item. A view body tracks `closedTabs`; read straight from the
/// `Commands` body the disabled state went stale and Cmd+Shift+T stayed off after a close.
private struct ReopenClosedTabButton: View {
  /// Re-renders when a lock state change covers or uncovers the key window
  @ObservedObject private var focusRegistry = FocusedActionRegistry.shared

  /// The active workspace, nil while covered
  private var workspace: WorkspaceManager? {
    focusRegistry.commandWorkspace(WorkspaceWindowManager.shared.activeWorkspaceManager)
  }

  var body: some View {
    Button("Reopen Closed Tab") {
      Task {
        do {
          try await workspace?.reopenClosedTab()
        } catch {
          WorkspaceWindowManager.shared.showToast(
            "Could not reopen tab: \(error.localizedDescription)", type: .warning)
        }
      }
    }
    .keyboardShortcut("t", modifiers: [.command, .shift])
    .disabled(workspace?.canReopenClosedTab != true)
  }
}

/// Edit menu items for the focused notebook or data viewer undo stack.
private struct CellUndoCommandButtons: View {
  @ObservedObject private var refresh = CellUndoMenuRefresh.shared
  @BridgedFocusedValue(\.activeViewModel) private var activeViewModel: NotebookViewModel?

  var body: some View {
    let _ = refresh.revision
    Button(title(prefix: "Undo", actionName: cellUndoTarget?.undoManager.undoActionName)) {
      cellUndoTarget?.undoCellChange()
    }
    .disabled(cellUndoTarget?.undoManager.canUndo != true)

    Button(title(prefix: "Redo", actionName: cellUndoTarget?.undoManager.redoActionName)) {
      cellUndoTarget?.redoCellChange()
    }
    .disabled(cellUndoTarget?.undoManager.canRedo != true)
  }

  /// Notebook tabs and data viewer tabs. A plain SQL editor keeps the system items only.
  private var cellUndoTarget: NotebookViewModel? {
    guard let activeViewModel else { return nil }
    guard activeViewModel.viewMode == .notebook || activeViewModel.dataViewer != nil else {
      return nil
    }
    return activeViewModel
  }

  /// Empty stack (no action name) stays "Undo Cell Change" / "Redo Cell Change".
  private func title(prefix: String, actionName: String?) -> String {
    guard let actionName, !actionName.isEmpty else { return "\(prefix) Cell Change" }
    return "\(prefix) \(actionName)"
  }
}

/// Republishes when a menu opens, so the cell undo titles match the focused view model's undo
/// manager. The items have no key equivalent, so they are only read while a menu is open.
/// Undo group notifications are not observed: every text view typing burst posts one.
@MainActor
private final class CellUndoMenuRefresh: ObservableObject {
  static let shared = CellUndoMenuRefresh()

  @Published private(set) var revision = 0
  private var tokens: [any NSObjectProtocol] = []
  private var didRefreshForTracking = false

  private init() {
    tokens.append(
      NotificationCenter.default.addObserver(
        forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated {
          CellUndoMenuRefresh.shared.menuDidBeginTracking()
        }
      })
    tokens.append(
      NotificationCenter.default.addObserver(
        forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated {
          CellUndoMenuRefresh.shared.menuDidEndTracking()
        }
      })
  }

  /// One refresh per tracking session, so rebuilding the items cannot loop.
  private func menuDidBeginTracking() {
    guard !didRefreshForTracking else { return }
    didRefreshForTracking = true
    revision += 1
  }

  private func menuDidEndTracking() {
    didRefreshForTracking = false
  }
}

// MARK: - Tab Commands

struct TabCommands: Commands {
  // Note: All tab operations now go through WorkspaceManager
  // No fallback to legacy TabStateManager.shared
  @BridgedFocusedValue(\.openTableImportAction) private var openTableImportAction
  @BridgedFocusedValue(\.openSQLDumpAction) private var openSQLDumpAction
  @BridgedFocusedValue(\.openSQLRestoreAction) private var openSQLRestoreAction
  @BridgedFocusedValue(\.openDatabaseFileCopyAction) private var openDatabaseFileCopyAction
  @BridgedFocusedValue(\.openDataDictionaryAction) private var openDataDictionaryAction
  @BridgedFocusedValue(\.openTableHealthAction) private var openTableHealthAction
  @BridgedFocusedValue(\.openSchemaCompareAction) private var openSchemaCompareAction
  @BridgedFocusedValue(\.openJoinBuilderAction) private var openJoinBuilderAction
  @BridgedFocusedValue(\.openCopyObjectsAction) private var openCopyObjectsAction
  @BridgedFocusedValue(\.activeWorkspace) private var focusedWorkspace

  var body: some Commands {
    // File menu - New documents (includes workspace commands)
    CommandGroup(replacing: .newItem) {
      // Workspace commands first
      Button {
        let manager = WorkspaceWindowManager.shared.newWorkspace()
        WorkspaceWindowManager.shared.showPendingWorkspace(manager.id)
      } label: {
        Label("New Workspace", systemImage: "folder.badge.plus")
      }
      .keyboardShortcut("n", modifiers: [.command, .control])

      Button {
        Task {
          if let id = await openWorkspaceWithPanel() {
            WorkspaceWindowManager.shared.showPendingWorkspace(id)
          }
        }
      } label: {
        Label("Open Workspace", systemImage: "folder")
      }
      .keyboardShortcut("o", modifiers: [.command, .option])

      // Recent Workspaces submenu
      Menu("Open Recent Workspace") {
        ForEach(RecentManager.shared.recentWorkspaces.prefix(10)) { workspace in
          Button(workspace.displayString) {
            Task {
              if let id = await WorkspaceWindowManager.shared.requestWorkspaceReportingError(
                url: workspace.fileURL)
              {
                WorkspaceWindowManager.shared.showPendingWorkspace(id)
              }
            }
          }
        }

        if !RecentManager.shared.recentWorkspaces.isEmpty {
          Divider()
          Button("Clear Recent Workspaces") {
            RecentManager.shared.clearWorkspaces()
          }
        }
      }
      .disabled(RecentManager.shared.recentWorkspaces.isEmpty)

      Divider()

      // Document commands - create workspace if needed
      Button {
        guard let manager = activeWorkspaceOrNew else { return }
        switch AppSettings.shared.defaultNewTabType {
        case .notebook: manager.newNotebook()
        case .sqlFile: manager.newSQLFile()
        case .markdownFile: manager.newMarkdownFile()
        }
      } label: {
        Label("New Tab", systemImage: "plus.square")
      }
      .keyboardShortcut("t", modifiers: .command)
      .disabled(isKeyWindowCovered)

      Button {
        activeWorkspaceOrNew?.newNotebook()
      } label: {
        Label("New Notebook", systemImage: "doc.badge.plus")
      }
      .disabled(isKeyWindowCovered)

      Button {
        activeWorkspaceOrNew?.newSQLFile()
      } label: {
        Label(activeWorkspace?.newScriptLabel ?? "New SQL File", systemImage: "doc.text")
      }
      .keyboardShortcut("j", modifiers: [.command, .shift])
      .disabled(isKeyWindowCovered)

      Button {
        activeWorkspaceOrNew?.newMarkdownFile()
      } label: {
        Label("New Markdown Note", systemImage: "doc.richtext")
      }
      .keyboardShortcut("m", modifiers: [.command, .shift])
      .disabled(isKeyWindowCovered)

      Divider()

      Button {
        openFile()
      } label: {
        Label("Open", systemImage: "folder")
      }
      .keyboardShortcut("o", modifiers: .command)
      .disabled(isKeyWindowCovered)

      // Lives here: a separate CommandGroup(after: .newItem) is dropped by SwiftUI
      // because this group replaces .newItem
      Divider()

      Button("Import Data...") { openTableImportAction?() }
        .disabled(openTableImportAction == nil)

      // MongoDB has its own backup file: same actions, its own titles
      let isMongo = activeWorkspace?.isMongoWorkspace == true
      Button(isMongo ? "Back Up Database..." : "Export SQL Dump...") { openSQLDumpAction?() }
        .disabled(openSQLDumpAction == nil)

      Button(isMongo ? "Restore Backup..." : "Restore SQL Dump...") { openSQLRestoreAction?() }
        .disabled(openSQLRestoreAction == nil)

      // SQL engines only: MongoDB collections have no catalog structure to document
      if !isMongo {
        Button("Export Data Dictionary...") { openDataDictionaryAction?() }
          .disabled(openDataDictionaryAction == nil)

        Button("Table Health...") { openTableHealthAction?() }
          .disabled(openTableHealthAction == nil)
      }

      // PostgreSQL, MySQL / MariaDB and SQLite only
      if activeWorkspace?.supportsSchemaCompare != false {
        Button("Compare Schemas...") { openSchemaCompareAction?() }
          .disabled(openSchemaCompareAction == nil)
      }

      // SQL engines only: a join needs tables and foreign keys
      if !isMongo {
        Button("Build Join Query...") { openJoinBuilderAction?() }
          .disabled(openJoinBuilderAction == nil)
      }

      // PostgreSQL, MySQL / MariaDB, SQLite and DuckDB sources (disabled on MongoDB)
      Button("Copy Objects...") { openCopyObjectsAction?() }
        .disabled(openCopyObjectsAction == nil)

      Button("Copy Database File...") { openDatabaseFileCopyAction?() }
        .disabled(openDatabaseFileCopyAction == nil)

      // Works with no window open: the sheet opens the Welcome window first.
      Button("Import Connections...") { ConnectionImportPresenter.present() }
    }

    // File menu - Save
    CommandGroup(replacing: .saveItem) {
      Button {
        // If active tab, save tab; otherwise save workspace
        if activeTabId != nil {
          saveActiveTab()
        } else {
          saveActiveWorkspace()
        }
      } label: {
        Text("Save")
      }
      .keyboardShortcut("s", modifiers: .command)
      .disabled(isKeyWindowCovered)

      Button {
        // If active tab, save as; otherwise save workspace as
        if activeTabId != nil {
          saveActiveTabAs()
        } else {
          saveActiveWorkspaceAs()
        }
      } label: {
        Text("Save As")
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
      .disabled(isKeyWindowCovered)

      // Workspace save commands live here: a separate CommandGroup(after: .saveItem)
      // is dropped by SwiftUI because this group replaces .saveItem
      Divider()

      Button("Save Workspace") {
        saveActiveWorkspace()
      }
      .keyboardShortcut("s", modifiers: [.command, .option])
      .disabled(activeWorkspaceForSave == nil)

      Button("Save Workspace As") {
        saveActiveWorkspaceAs()
      }
      .keyboardShortcut("s", modifiers: [.command, .option, .shift])
      .disabled(activeWorkspaceForSave?.workspace.isSaved != true)

      Divider()

      // The focused workspace window's own: the sheet opens on it at once
      if focusedWorkspace?.lockKeyId != nil {
        Button("Remove Lock...") { focusedWorkspace?.openLockSheet(.remove) }
      } else {
        Button("Lock Workspace...") { focusedWorkspace?.openLockSheet(.lock) }
          .disabled(focusedWorkspace?.canLockWorkspace != true)
      }

      Divider()

      Button("Close Workspace") {
        guard !isKeyWindowCovered else { return }
        Task {
          _ = await WorkspaceWindowManager.shared.closeActiveWorkspace()
        }
      }
      .keyboardShortcut("w", modifiers: [.command, .option])
      .disabled(isKeyWindowCovered)
    }

    // Window menu - Tab navigation
    CommandGroup(after: .windowArrangement) {
      Divider()

      Button("New Window Tab") {
        NewWindowStore.shared.openWelcomeWindowTab()
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])

      Button("Close Tab") {
        if let workspaceManager = activeWorkspace, let id = workspaceManager.activeTabId {
          workspaceManager.requestCloseTab(id: id)
        }
      }
      .keyboardShortcut("w", modifiers: .command)
      .disabled(activeTabId == nil)

      ReopenClosedTabButton()

      Divider()

      Button("Next Tab") {
        activeWorkspace?.selectNextTab()
      }
      .keyboardShortcut("]", modifiers: [.command, .shift])
      .disabled(activeTabCount < 2)

      Button("Previous Tab") {
        activeWorkspace?.selectPreviousTab()
      }
      .keyboardShortcut("[", modifiers: [.command, .shift])
      .disabled(activeTabCount < 2)

      Divider()

      // Tab shortcuts 1-9 (only show if tabs exist)
      ForEach(Array(activeTabs.prefix(9).enumerated()), id: \.element.id) { index, tab in
        Button("Tab \(index + 1): \(tab.title)") {
          activeWorkspace?.selectTab(atIndex: index + 1)
        }
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
      }
    }
  }

  /// The active workspace for these commands: nil while the key window or that workspace is
  /// covered by the unlock overlay, so they do nothing and the tab list is empty
  private var activeWorkspace: WorkspaceManager? {
    FocusedActionRegistry.shared.commandWorkspace(
      WorkspaceWindowManager.shared.activeWorkspaceManager)
  }

  /// The key window is covered (or the active workspace is): the commands that would create a
  /// workspace or open a panel do nothing
  private var isKeyWindowCovered: Bool {
    FocusedActionRegistry.shared.isKeyWindowLocked
      || WorkspaceWindowManager.shared.activeWorkspaceManager?.lockCoverage != nil
  }

  /// Get active workspace or create new one, shown in a window; nil (nothing created) while
  /// covered
  private var activeWorkspaceOrNew: WorkspaceManager? {
    FocusedActionRegistry.shared.commandWorkspace(
      WorkspaceWindowManager.shared.activeWorkspaceManager,
      orNew: { WorkspaceWindowManager.shared.activeWorkspaceOrNew() })
  }

  /// The workspace Save Workspace / Save As act on, nil while covered
  private var activeWorkspaceForSave: WorkspaceManager? {
    FocusedActionRegistry.shared.commandWorkspace(WorkspaceWindowManager.shared.activeWorkspace)
  }

  /// Get active tab ID from workspace manager
  private var activeTabId: UUID? {
    activeWorkspace?.activeTabId
  }

  /// Get tab count from workspace manager
  private var activeTabCount: Int {
    activeWorkspace?.tabs.count ?? 0
  }

  /// Get tabs from workspace manager
  private var activeTabs: [TabItem] {
    activeWorkspace?.tabs ?? []
  }

  private func openFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.dblore, .sql, .javaScript, .markdownText]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false

    panel.begin { response in
      guard response == .OK else { return }
      Task { @MainActor in
        // Covered meanwhile: nothing opens into it
        let windows = WorkspaceWindowManager.shared
        let active = windows.activeWorkspaceManager
        var manager = FocusedActionRegistry.shared.commandWorkspace(active)
        if manager == nil, active == nil, !FocusedActionRegistry.shared.isKeyWindowLocked {
          manager = windows.newWorkspace()
          windows.showPendingWorkspace(manager!.id)
        }
        for url in panel.urls {
          try? await manager?.openFile(url: url, checksScriptKind: true)
        }
      }
    }
  }

  /// Open workspace with file panel and return the id its window shows (a locked workspace's
  /// window opens with its locked placeholder and asks there; a failure shows a toast)
  private func openWorkspaceWithPanel() async -> UUID? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = UTType.sqlWorkspaceOpenTypes
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Select a workspace file to open"

    let response = await withCheckedContinuation { continuation in
      panel.begin { result in
        continuation.resume(returning: result)
      }
    }

    guard response == .OK, let url = panel.url else { return nil }
    return await WorkspaceWindowManager.shared.requestWorkspaceReportingError(url: url)
  }

  private func saveActiveTab() {
    guard let manager = activeWorkspace,
      let id = manager.activeTabId
    else { return }
    Task {
      try? await manager.saveTab(id: id)
    }
  }

  private func saveActiveTabAs() {
    guard let manager = activeWorkspace,
      let id = manager.activeTabId,
      let index = manager.tabs.firstIndex(where: { $0.id == id })
    else { return }
    // For Save As, we clear the fileURL first to force save panel
    manager.tabs[index].fileURL = nil
    Task {
      try? await manager.saveTab(id: id)
    }
  }

  private func saveActiveWorkspace() {
    guard let workspace = activeWorkspaceForSave else { return }
    Task {
      try? await workspace.saveWorkspace()
    }
  }

  private func saveActiveWorkspaceAs() {
    guard let workspace = activeWorkspaceForSave else { return }
    Task {
      try? await workspace.saveWorkspaceWithPanel()
    }
  }
}

// MARK: - Notebook Commands (chỉ cho Notebook mode)

struct NotebookCommands: Commands {
  @BridgedFocusedValue(\.isCellValueEditing) private var isCellValueEditing: Bool?
  @BridgedFocusedValue(\.documentMode) private var documentMode: DocumentMode?
  @BridgedFocusedValue(\.toggleLeftSidebarAction) private var toggleLeftSidebarAction
  @BridgedFocusedValue(\.toggleRightSidebarAction) private var toggleRightSidebarAction
  @BridgedFocusedValue(\.openSearchAction) private var openSearchAction
  @BridgedFocusedValue(\.findReplaceAction) private var findReplaceAction
  @BridgedFocusedValue(\.findNextAction) private var findNextAction
  @BridgedFocusedValue(\.findPreviousAction) private var findPreviousAction

  var body: some Commands {
    // Chỉ show Cell menu khi documentMode == .notebook
    if documentMode == .notebook {
      // Cell commands
      CommandMenu("Cell") {
        Button("Add New") {
          NotificationCenter.default.post(name: .addCodeCell, object: nil)
        }
        .keyboardShortcut("n", modifiers: [.command, .option])

        Divider()
        Button("Run Cell") {
          NotificationCenter.default.post(name: .runCell, object: nil)
        }
        .keyboardShortcut(.return, modifiers: .control)

        Button("Run Cell and Select Next") {
          NotificationCenter.default.post(name: .runCellAndSelectNext, object: nil)
        }
        .keyboardShortcut(.return, modifiers: .shift)

        Button("Run Cell and Insert Below") {
          NotificationCenter.default.post(name: .runCellAndInsertBelow, object: nil)
        }
        .keyboardShortcut(.return, modifiers: .option)

        Button("Run All Cells") {
          NotificationCenter.default.post(name: .runAllCells, object: nil)
        }
        .keyboardShortcut(.return, modifiers: [.command, .shift])

        Divider()

        ExplainCommandButtons()

        Divider()

        Button("Clear Cell Output") {
          NotificationCenter.default.post(name: .clearCellOutput, object: nil)
        }

        Button("Clear All Outputs") {
          NotificationCenter.default.post(name: .clearAllOutputs, object: nil)
        }

        Divider()

        Button("Delete Cell") {
          NotificationCenter.default.post(name: .deleteCell, object: nil)
        }
        .keyboardShortcut(.delete, modifiers: .command)

        Button("Duplicate Cell") {
          NotificationCenter.default.post(name: .duplicateCell, object: nil)
        }
        .keyboardShortcut("d", modifiers: .command)
      }

      // View commands - use focused actions for tab-specific behavior
      CommandGroup(after: .sidebar) {
        Button {
          toggleLeftSidebarAction?()
        } label: {
          Label("Toggle Left Sidebar", systemImage: "sidebar.left")
        }
        .keyboardShortcut("b", modifiers: .command)

        Button {
          toggleRightSidebarAction?()
        } label: {
          Label("Toggle Right Sidebar", systemImage: "sidebar.right")
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
      }

      // Edit commands - use focused actions for tab-specific behavior
      CommandGroup(after: .textEditing) {
        Button("Find in Notebook") {
          openSearchAction?()
        }
        .keyboardShortcut("f", modifiers: .command)

        Button("Find and Replace…") {
          findReplaceAction?()
        }
        .keyboardShortcut("f", modifiers: [.command, .option])
        .disabled(findReplaceAction == nil)

        Divider()

        Button("Find Next") {
          findNextAction?()
        }
        .keyboardShortcut("g", modifiers: .command)

        Button("Find Previous") {
          findPreviousAction?()
        }
        .keyboardShortcut("g", modifiers: [.command, .shift])
      }
    }
  }
}

// MARK: - Editor Commands (chỉ cho Editor mode)

struct EditorCommands: Commands {
  @BridgedFocusedValue(\.documentMode) private var documentMode: DocumentMode?
  @BridgedFocusedValue(\.toggleLeftSidebarAction) private var toggleLeftSidebarAction
  @BridgedFocusedValue(\.toggleRightSidebarAction) private var toggleRightSidebarAction
  @BridgedFocusedValue(\.openSearchAction) private var openSearchAction
  @BridgedFocusedValue(\.findReplaceAction) private var findReplaceAction
  @BridgedFocusedValue(\.findNextAction) private var findNextAction
  @BridgedFocusedValue(\.findPreviousAction) private var findPreviousAction
  @BridgedFocusedValue(\.toggleLineBookmarkAction) private var toggleLineBookmarkAction
  @BridgedFocusedValue(\.nextLineBookmarkAction) private var nextLineBookmarkAction
  @BridgedFocusedValue(\.previousLineBookmarkAction) private var previousLineBookmarkAction
  @BridgedFocusedValue(\.focusSQLEditorAction) private var focusSQLEditorAction
  @BridgedFocusedValue(\.focusResultGridAction) private var focusResultGridAction

  /// The F2 key (a function key has no character of its own: AppKit's private-use scalar)
  private static let f2Key = KeyEquivalent(Character(Unicode.Scalar(UInt32(NSF2FunctionKey))!))

  var body: some Commands {
    // Chỉ show khi documentMode == .editor
    if documentMode == .editor {
      // Query menu for editor mode
      CommandMenu("Query") {
        Button("Run") {
          NotificationCenter.default.post(name: .runEditorQuery, object: nil)
        }
        .keyboardShortcut("r", modifiers: .command)

        Button("Run (Alt)") {
          NotificationCenter.default.post(name: .runEditorQuery, object: nil)
        }
        .keyboardShortcut(.return, modifiers: .command)

        Divider()

        ExplainCommandButtons()

        Divider()

        Button("Focus SQL Editor") {
          focusSQLEditorAction?()
        }
        .keyboardShortcut("1", modifiers: [.command, .option])
        .disabled(focusSQLEditorAction == nil)

        Button("Focus Results") {
          focusResultGridAction?()
        }
        .keyboardShortcut("2", modifiers: [.command, .option])
        .disabled(focusResultGridAction == nil)
      }

      // Edit commands - use focused actions for tab-specific behavior
      CommandGroup(after: .textEditing) {
        Button("Find") {
          openSearchAction?()
        }
        .keyboardShortcut("f", modifiers: .command)

        Button("Find and Replace…") {
          findReplaceAction?()
        }
        .keyboardShortcut("f", modifiers: [.command, .option])
        .disabled(findReplaceAction == nil)

        Divider()

        Button("Find Next") {
          findNextAction?()
        }
        .keyboardShortcut("g", modifiers: .command)

        Button("Find Previous") {
          findPreviousAction?()
        }
        .keyboardShortcut("g", modifiers: [.command, .shift])

        Divider()

        Button("Toggle Bookmark") {
          toggleLineBookmarkAction?()
        }
        .keyboardShortcut(Self.f2Key, modifiers: .command)
        .disabled(toggleLineBookmarkAction == nil)

        Button("Next Bookmark") {
          nextLineBookmarkAction?()
        }
        .keyboardShortcut(Self.f2Key, modifiers: [])
        .disabled(nextLineBookmarkAction == nil)

        Button("Previous Bookmark") {
          previousLineBookmarkAction?()
        }
        .keyboardShortcut(Self.f2Key, modifiers: .shift)
        .disabled(previousLineBookmarkAction == nil)
      }

      // View Menu - Sidebar toggles
      CommandGroup(after: .sidebar) {
        Button {
          toggleLeftSidebarAction?()
        } label: {
          Label("Toggle Left Sidebar", systemImage: "sidebar.left")
        }
        .keyboardShortcut("b", modifiers: .command)

        Button {
          toggleRightSidebarAction?()
        } label: {
          Label("Toggle Right Sidebar", systemImage: "sidebar.right")
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])

        Divider()

        Button {
          AppSettings.shared.wordWrapEnabled.toggle()
        } label: {
          if AppSettings.shared.wordWrapEnabled {
            Label("Disable Word Wrap", systemImage: "text.alignleft")
          } else {
            Label("Enable Word Wrap", systemImage: "text.word.spacing")
          }
        }
        .keyboardShortcut("z", modifiers: .option)
      }
    }
  }
}

// MARK: - Schema Visualizer Commands

struct SchemaVisualizerCommands: Commands {
  @BridgedFocusedValue(\.isSchemaVisualizerActive) private var isSchemaVisualizerActive: Bool?
  @BridgedFocusedValue(\.openSearchAction) private var openSearchAction
  @BridgedFocusedValue(\.findNextAction) private var findNextAction
  @BridgedFocusedValue(\.findPreviousAction) private var findPreviousAction
  @BridgedFocusedValue(\.toggleLeftSidebarAction) private var toggleLeftSidebarAction

  var body: some Commands {
    // Only show when schema visualizer is active
    if isSchemaVisualizerActive == true {
      // Edit commands for schema search
      CommandGroup(after: .textEditing) {
        Button("Find in Schema") {
          openSearchAction?()
        }
        .keyboardShortcut("f", modifiers: .command)

        Divider()

        Button("Find Next") {
          findNextAction?()
        }
        .keyboardShortcut("g", modifiers: .command)

        Button("Find Previous") {
          findPreviousAction?()
        }
        .keyboardShortcut("g", modifiers: [.command, .shift])
      }

      // View commands
      CommandGroup(after: .sidebar) {
        Button {
          toggleLeftSidebarAction?()
        } label: {
          Label("Toggle Left Sidebar", systemImage: "sidebar.left")
        }
        .keyboardShortcut("b", modifiers: .command)
      }
    }
  }
}

/// Explain actions for the Cell and Query menus. Shortcuts stay on these items.
private struct ExplainCommandButtons: View {
  @BridgedFocusedValue(\.activeViewModel) private var activeViewModel: NotebookViewModel?

  private var isDisabled: Bool {
    guard let activeViewModel else { return true }
    return activeViewModel.viewMode == .editor && activeViewModel.dataViewer != nil
  }

  var body: some View {
    Button("Explain") {
      NotificationCenter.default.post(name: .explainStatement, object: nil)
    }
    .keyboardShortcut("e", modifiers: .command)
    .disabled(isDisabled || activeViewModel?.explainUnavailableReason != nil)

    Button("Explain Analyze (runs the statement)") {
      NotificationCenter.default.post(name: .explainAnalyzeStatement, object: nil)
    }
    .keyboardShortcut("e", modifiers: [.command, .shift])
    .disabled(isDisabled || activeViewModel?.canExplainAnalyze == false)
  }
}

// MARK: - Notification Names

extension Notification.Name {
  static let addCodeCell = Notification.Name("addCodeCell")
  static let runCell = Notification.Name("runCell")
  static let runCellAndSelectNext = Notification.Name("runCellAndSelectNext")
  static let runCellAndInsertBelow = Notification.Name("runCellAndInsertBelow")
  static let runAllCells = Notification.Name("runAllCells")
  static let clearCellOutput = Notification.Name("clearCellOutput")
  static let clearAllOutputs = Notification.Name("clearAllOutputs")
  static let deleteCell = Notification.Name("deleteCell")
  static let duplicateCell = Notification.Name("duplicateCell")
  static let toggleSidebar = Notification.Name("toggleSidebar")
  static let toggleLeftSidebar = Notification.Name("toggleLeftSidebar")
  static let selectNextCell = Notification.Name("selectNextCell")
  static let selectPreviousCell = Notification.Name("selectPreviousCell")
  static let focusEditor = Notification.Name("focusEditor")
  static let unfocusEditor = Notification.Name("unfocusEditor")
  static let undo = Notification.Name("undo")
  static let redo = Notification.Name("redo")
  static let editorFocused = Notification.Name("editorFocused")
  static let editorUnfocused = Notification.Name("editorUnfocused")
  static let insertTextIntoCell = Notification.Name("insertTextIntoCell")
  static let cellValueEditingStarted = Notification.Name("cellValueEditingStarted")
  static let cellValueEditingEnded = Notification.Name("cellValueEditingEnded")
  static let openSettings = Notification.Name("openSettings")

  // Search notifications
  static let openSearch = Notification.Name("openSearch")
  static let findNext = Notification.Name("findNext")
  static let findPrevious = Notification.Name("findPrevious")
  static let highlightSearchMatch = Notification.Name("highlightSearchMatch")
  static let clearSearchHighlights = Notification.Name("clearSearchHighlights")

  // Editor mode notifications
  static let runEditorQuery = Notification.Name("runEditorQuery")
  static let explainStatement = Notification.Name("explainStatement")
  static let explainAnalyzeStatement = Notification.Name("explainAnalyzeStatement")
  static let toggleWordWrap = Notification.Name("toggleWordWrap")

  // Settings change notifications
  static let syntaxHighlightingChanged = Notification.Name("syntaxHighlightingChanged")
  static let accentColorChanged = Notification.Name("accentColorChanged")
  static let scrollToSafeModeSettings = Notification.Name("scrollToSafeModeSettings")
}
