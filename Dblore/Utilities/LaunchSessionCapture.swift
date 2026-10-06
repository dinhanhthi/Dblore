//
//  LaunchSessionCapture.swift
//  Dblore
//

import AppKit
import Foundation

/// Builds a launch snapshot from document windows.
/// `session(windows:workspaces:)` is pure: tests pass descriptors and in-memory workspaces.
/// The AppKit adapter that reads `NSWindow` is separate and is not unit-tested.
@MainActor
enum LaunchSessionCapture {
  /// One open document window, already read off AppKit.
  struct WindowDescriptor: Equatable, Sendable {
    var frame: WindowFrame
    var isMiniaturized: Bool
    /// Same value for every window in one native tab group. A window with no group has its own id.
    var groupID: String
    /// Index in that group's `tabbedWindows`.
    var tabIndex: Int
    var isSelectedInGroup: Bool
    /// Index in `NSApp.orderedWindows` (0 is frontmost). A group's place is its smallest index.
    var orderedIndex: Int
    var content: Content

    enum Content: Equatable, Sendable {
      case welcome
      case workspace(UUID)
    }
  }

  private static let debounceDelay: Duration = .seconds(1)
  private static var pending: Task<Void, Never>?
  /// Quit already wrote the snapshot. A later window-close or tab-group event must not replace it.
  private static var isQuitting = false

  /// Debounced snapshot so a force-quit still has a recent session.
  /// Does nothing under the test host, while a launch restore is in progress, or once quit has started.
  static func schedule() {
    guard !SessionManager.isRunningAsTestHost, !isQuitting, !LaunchRestorer.isRestoring else {
      return
    }
    pending?.cancel()
    pending = Task { @MainActor in
      do {
        try await Task.sleep(for: debounceDelay)
      } catch {
        return
      }
      guard !Task.isCancelled, !isQuitting, !LaunchRestorer.isRestoring else { return }
      saveNow()
    }
  }

  /// Stops the debounced writer. Called once quit will proceed, before the synchronous snapshot.
  static func prepareForQuit() {
    isQuitting = true
    pending?.cancel()
    pending = nil
  }

  /// Reads the open document windows and stores the snapshot. The test host writes nothing.
  static func saveNow() {
    guard !SessionManager.isRunningAsTestHost else { return }
    let captured = descriptors(windows: NSApp.windows, orderedWindows: NSApp.orderedWindows)
    let session = session(
      windows: captured, workspaces: WorkspaceWindowManager.shared.workspaces)
    LaunchSessionStore(defaults: .standard).save(session)
  }

  /// Groups windows by tab-group identity, orders each group by `tabIndex`, and orders groups by
  /// the frontmost window (`orderedIndex`). Welcome stays welcome. A saved workspace stores its
  /// file and bookmarks. An untitled workspace stores the encoded document with the password
  /// cleared. Preview tabs are omitted. Text overlays are the live editor contents of dirty or
  /// file-less tabs.
  static func session(
    windows: [WindowDescriptor], workspaces: [UUID: WorkspaceManager]
  ) -> LaunchSession {
    let grouped = Dictionary(grouping: windows, by: \.groupID)
    let groupOrder = grouped.keys.sorted { lhs, rhs in
      let left = grouped[lhs]?.map(\.orderedIndex).min() ?? Int.max
      let right = grouped[rhs]?.map(\.orderedIndex).min() ?? Int.max
      if left != right { return left < right }
      return lhs < rhs
    }

    var launchWindows: [LaunchWindow] = []
    var groupIndex = 0
    for groupID in groupOrder {
      let members = (grouped[groupID] ?? []).sorted { lhs, rhs in
        if lhs.tabIndex != rhs.tabIndex { return lhs.tabIndex < rhs.tabIndex }
        return lhs.orderedIndex < rhs.orderedIndex
      }
      let recorded: [LaunchWindow] = members.compactMap { descriptor in
        guard let content = content(for: descriptor, workspaces: workspaces) else { return nil }
        return LaunchWindow(
          frame: descriptor.frame,
          isMiniaturized: descriptor.isMiniaturized,
          groupIndex: groupIndex,
          tabIndex: descriptor.tabIndex,
          isSelectedInGroup: descriptor.isSelectedInGroup,
          content: content)
      }
      guard !recorded.isEmpty else { continue }
      launchWindows.append(contentsOf: recorded)
      groupIndex += 1
    }
    return LaunchSession(windows: launchWindows).clearingPasswords()
  }

  /// Document windows only, one descriptor per registered window.
  private static func descriptors(
    windows: [NSWindow], orderedWindows: [NSWindow]
  ) -> [WindowDescriptor] {
    var order: [Int: Int] = [:]
    for (index, window) in orderedWindows.enumerated() where order[window.windowNumber] == nil {
      let number = window.windowNumber
      guard number > 0 else { continue }
      order[number] = index
    }

    return windows.compactMap { window in
      guard window.isDbloreDocumentWindow else { return nil }
      guard let registration = NewWindowStore.shared.registration(for: window) else { return nil }
      let tabs = window.tabbedWindows ?? [window]
      let frame = window.frame
      let content: WindowDescriptor.Content
      switch registration {
      case .welcome:
        content = .welcome
      case .workspace(let id):
        content = WelcomeWindowMarker.isWelcome(window) ? .welcome : .workspace(id)
      }
      let selected: Bool
      if let group = window.tabGroup {
        selected = group.selectedWindow === window
      } else {
        selected = true
      }
      return WindowDescriptor(
        frame: WindowFrame(
          x: Double(frame.origin.x), y: Double(frame.origin.y),
          width: Double(frame.size.width), height: Double(frame.size.height)),
        isMiniaturized: window.isMiniaturized,
        groupID: groupID(for: window),
        tabIndex: tabs.firstIndex { $0 === window } ?? 0,
        isSelectedInGroup: selected,
        orderedIndex: order[window.windowNumber] ?? Int.max,
        content: content)
    }
  }

  private static func groupID(for window: NSWindow) -> String {
    if let group = window.tabGroup {
      return "tab-\(ObjectIdentifier(group))"
    }
    return "window-\(window.windowNumber)"
  }

  private static func content(
    for descriptor: WindowDescriptor, workspaces: [UUID: WorkspaceManager]
  ) -> LaunchWindowContent? {
    switch descriptor.content {
    case .welcome:
      return .welcome
    case .workspace(let id):
      guard let manager = workspaces[id] else { return nil }
      return .workspace(launchWorkspace(for: manager))
    }
  }

  private static func launchWorkspace(for manager: WorkspaceManager) -> LaunchWorkspace {
    let overlays = textOverlays(of: manager)
    if let fileURL = manager.workspace.fileURL {
      return LaunchWorkspace(
        fileURL: fileURL,
        bookmark: manager.workspaceBookmark,
        folderBookmark: manager.folderBookmark,
        textOverlays: overlays)
    }
    var embedded = LaunchWorkspace(
      workspace: decodedWorkspace(from: manager), textOverlays: overlays)
    embedded.clearPasswords()
    return embedded
  }

  /// Same document `encodedWorkspaceData()` would write, decoded so the snapshot can hold it.
  /// `Workspace` already omits the password; `clearPasswords()` runs on the result as well.
  private static func decodedWorkspace(from manager: WorkspaceManager) -> Workspace? {
    guard let data = try? manager.encodedWorkspaceData() else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(Workspace.self, from: data)
  }

  /// Live notebook cells or SQL editor text. The stored document can be behind the editor.
  /// Preview tabs are omitted, matching `encodedWorkspaceData()`.
  private static func textOverlays(of manager: WorkspaceManager) -> [LaunchTextOverlay] {
    manager.tabs.compactMap { tab in
      guard !tab.isPreview, tab.isDirty || tab.fileURL == nil else { return nil }
      guard let viewModel = manager.viewModel(for: tab.id) else { return nil }
      switch tab.documentType {
      case .notebook:
        let cells = viewModel.notebook.cells.map {
          LaunchNotebookCell(id: $0.id, cellType: $0.cellType, content: $0.content)
        }
        return LaunchTextOverlay(tabId: tab.id, text: .notebook(cells))
      case .sqlFile:
        return LaunchTextOverlay(tabId: tab.id, text: .script(viewModel.editorContent))
      case .dataViewer:
        return nil
      }
    }
  }
}
