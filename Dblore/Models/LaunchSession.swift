//
//  LaunchSession.swift
//  Dblore
//

import Foundation

/// Screen rectangle of a document window. Points, origin at the bottom left.
struct WindowFrame: Codable, Equatable, Sendable {
  var x: Double
  var y: Double
  var width: Double
  var height: Double
}

/// Notebook cells kept in a launch snapshot: identity, type, and source text.
/// Query results are not part of the snapshot.
struct LaunchNotebookCell: Codable, Equatable, Sendable {
  var id: UUID
  var cellType: CellType
  var content: String
}

/// Dirty or file-less tab text: notebook cells, or one SQL script.
enum LaunchOverlayText: Codable, Equatable, Sendable {
  case notebook([LaunchNotebookCell])
  case script(String)
}

/// Tab text reapplied when a session is restored.
struct LaunchTextOverlay: Codable, Equatable, Sendable {
  var tabId: UUID
  var text: LaunchOverlayText
}

/// A workspace window in the snapshot.
/// `workspace` is the embedded document for an untitled window (no file of its own).
struct LaunchWorkspace: Codable, Sendable {
  var fileURL: URL?
  var bookmark: Data?
  var folderBookmark: Data?
  var workspace: Workspace?
  var textOverlays: [LaunchTextOverlay]

  init(
    fileURL: URL? = nil,
    bookmark: Data? = nil,
    folderBookmark: Data? = nil,
    workspace: Workspace? = nil,
    textOverlays: [LaunchTextOverlay] = []
  ) {
    self.fileURL = fileURL
    self.bookmark = bookmark
    self.folderBookmark = folderBookmark
    self.workspace = workspace
    self.textOverlays = textOverlays
  }

  /// Drops the embedded connection password. Untitled notebooks reconnect through
  /// this workspace connection; overlays store text only, so they have no password.
  mutating func clearPasswords() {
    guard var embedded = workspace else { return }
    if var connection = embedded.connectionConfig {
      connection.password = ""
      embedded.connectionConfig = connection
    }
    workspace = embedded
  }
}

/// What a recorded window is showing.
enum LaunchWindowContent: Codable, Sendable {
  case welcome
  case workspace(LaunchWorkspace)
}

/// One document window at quit, including its place in a native tab group.
struct LaunchWindow: Codable, Sendable {
  var frame: WindowFrame
  var isMiniaturized: Bool
  var groupIndex: Int
  var tabIndex: Int
  var isSelectedInGroup: Bool
  var content: LaunchWindowContent
}

/// Document windows open at quit.
struct LaunchSession: Codable, Sendable {
  var windows: [LaunchWindow]

  /// Groups ordered by `groupIndex`. Windows inside a group ordered by `tabIndex`.
  /// `isSelectedInGroup` is left as recorded.
  var grouped: [[LaunchWindow]] {
    let groupIndices = Set(windows.map(\.groupIndex)).sorted()
    return groupIndices.map { groupIndex in
      windows
        .filter { $0.groupIndex == groupIndex }
        .sorted { $0.tabIndex < $1.tabIndex }
    }
  }

  /// Copy with every embedded connection password cleared.
  func clearingPasswords() -> LaunchSession {
    var copy = self
    for index in copy.windows.indices {
      guard case .workspace(var workspace) = copy.windows[index].content else { continue }
      workspace.clearPasswords()
      copy.windows[index].content = .workspace(workspace)
    }
    return copy
  }
}

/// Turns a saved snapshot into either the Welcome screen or a session to reopen.
/// `isRestoring` is shared by capture (task 3) and launch (task 4).
enum LaunchRestorer: Sendable {
  case welcome
  case restore(LaunchSession)

  @MainActor static var isRestoring = false

  /// `.welcome` when the setting is welcome, the snapshot is missing or empty, or
  /// every saved workspace file fails `readable`. Unreadable saved workspaces are
  /// removed; a group with nothing left is dropped. Untitled workspaces have no
  /// file, so they stay. `readable` is the only file check — this does not touch
  /// the disk.
  static func plan(
    behavior: LaunchBehavior,
    session: LaunchSession?,
    readable: (URL) -> Bool
  ) -> LaunchRestorer {
    guard behavior == .restoreLastSession else { return .welcome }
    guard let session, !session.windows.isEmpty else { return .welcome }

    let windows = session.windows.filter { window in
      switch window.content {
      case .welcome:
        return true
      case .workspace(let workspace):
        guard let fileURL = workspace.fileURL else { return true }
        return readable(fileURL)
      }
    }
    guard !windows.isEmpty else { return .welcome }
    return .restore(LaunchSession(windows: windows))
  }
}
