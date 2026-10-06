//
//  LaunchSessionRestore.swift
//  Dblore
//

import AppKit
import Foundation

extension WindowFrame {
  /// AppKit screen rect. Origin is the bottom left, matching `NSWindow.frame`.
  var rect: NSRect {
    NSRect(x: x, y: y, width: width, height: height)
  }
}

extension LaunchRestorer {
  /// Hands the system `WindowGroup` window the front restored window, once.
  /// Every later caller, including Welcome and Cmd+N, gets nil.
  static func takeFrontWindowClaim() -> LaunchWindow? {
    let step = LaunchClaimStore.step
    LaunchClaimStore.step = nil
    return step
  }

  static func stageFrontWindowClaim(_ window: LaunchWindow) {
    LaunchClaimStore.step = window
  }

  /// Clears the in-memory claim and the restoring flag. Tests call this so a later case
  /// does not see a staged window or a stuck restore.
  static func resetLaunchState() {
    LaunchClaimStore.step = nil
    isRestoring = false
    LaunchSessionRestore.reset()
  }
}

private enum LaunchClaimStore {
  static var step: LaunchWindow?
}

/// Opens a saved snapshot at launch. The system window claims the front window; every other
/// window is created here. The test host never calls `prepare`.
enum LaunchSessionRestore {
  private struct GroupTab: Hashable {
    var group: Int
    var tab: Int
  }

  private static var pendingGroups: [[LaunchWindow]]?
  private static var didFinish = false

  static func reset() {
    pendingGroups = nil
    didFinish = false
  }

  /// Plans welcome vs restore before the system window appears. A missing file is named in a
  /// toast and left out of the plan; the other windows still open. Welcome (the fallback and
  /// the setting) does not open anything else.
  static func prepare() {
    guard !SessionManager.isRunningAsTestHost else { return }
    let session = LaunchSessionStore(defaults: .standard).load()
    var skippedNames: [String] = []
    var skippedURLs: Set<URL> = []
    let plan = LaunchRestorer.plan(
      behavior: AppSettings.shared.launchBehavior, session: session
    ) { url in
      let readable = scopedFileIsReadable(url, session: session)
      if !readable, skippedURLs.insert(url).inserted {
        skippedNames.append(url.lastPathComponent)
      }
      return readable
    }
    showSkipped(skippedNames)
    guard case .restore(let restored) = plan else { return }
    guard let front = restored.grouped.first?.first else { return }
    LaunchRestorer.isRestoring = true
    LaunchRestorer.stageFrontWindowClaim(front)
    pendingGroups = restored.grouped
  }

  /// Opens the claimed window's workspace, then every other window. `assign` receives the
  /// claimed workspace id so the system window shows it and does not open a second copy, and
  /// whether the claimed window shares its tab group with other restored windows.
  /// `isRestoring` stays set until this returns, including when a window is skipped. Then a
  /// fresh snapshot is scheduled so the one just restored does not linger.
  static func finish(
    claim: LaunchWindow, host: NSWindow, assign: @escaping (UUID, _ isTabbed: Bool) -> Void
  ) async {
    guard !didFinish else { return }
    didFinish = true
    let groups = pendingGroups
    pendingGroups = nil
    defer {
      LaunchRestorer.isRestoring = false
      LaunchSessionCapture.schedule()
    }
    guard let groups else { return }

    var claimedID: UUID?
    if case .workspace(let launch) = claim.content {
      claimedID = await openContent(launch)
      if let claimedID {
        assign(claimedID, (groups.first?.count ?? 0) > 1)
      }
    }
    await openRemaining(groups, host: host, claim: claim, claimedID: claimedID)
  }

  /// Bookmark first, then the resolved file. Never `FileManager` on the raw saved URL:
  /// under the sandbox that check fails even when the bookmark can still open the file.
  private static func scopedFileIsReadable(_ url: URL, session: LaunchSession?) -> Bool {
    guard let bookmark = bookmark(for: url, in: session) else { return false }
    let resolved: URL
    do {
      resolved = try SecurityScopedAccess.resolve(bookmark).url
    } catch {
      return false
    }
    let access = SecurityScopedAccessToken(url: resolved)
    defer { access.release() }
    guard access.isGranted else { return false }
    return (try? resolved.resourceValues(forKeys: [.isReadableKey]).isReadable) == true
  }

  private static func bookmark(for url: URL, in session: LaunchSession?) -> Data? {
    guard let session else { return nil }
    for window in session.windows {
      guard case .workspace(let workspace) = window.content, workspace.fileURL == url else {
        continue
      }
      return workspace.bookmark
    }
    return nil
  }

  private static func showSkipped(_ names: [String]) {
    guard !names.isEmpty else { return }
    WorkspaceWindowManager.shared.showToast(
      "Couldn't reopen \(names.joined(separator: ", "))", type: .warning)
  }

  private static func openRemaining(
    _ groups: [[LaunchWindow]], host: NSWindow, claim: LaunchWindow, claimedID: UUID?
  ) async {
    let claimKey = GroupTab(group: claim.groupIndex, tab: claim.tabIndex)
    var anchors: [Int: NSWindow] = [:]
    var opened: [GroupTab: NSWindow] = [claimKey: host]
    var workspaceIDs: [GroupTab: UUID] = [:]
    if let claimedID {
      workspaceIDs[claimKey] = claimedID
    }

    for group in groups {
      guard let groupIndex = group.first?.groupIndex else { continue }
      for window in group {
        let key = GroupTab(group: window.groupIndex, tab: window.tabIndex)
        if key == claimKey {
          if anchors[groupIndex] == nil {
            anchors[groupIndex] = host
          } else if let parent = anchors[groupIndex], parent !== host {
            parent.addTabbedWindow(host, ordered: .above)
          }
          continue
        }
        let parent = anchors[groupIndex]
        guard let created = await openOne(window, asTabOf: parent) else { continue }
        opened[key] = created.window
        if let id = created.workspaceID {
          workspaceIDs[key] = id
        }
        if anchors[groupIndex] == nil {
          anchors[groupIndex] = created.window
        }
      }
      select(group, opened: opened)
      let selected = group.first(where: \.isSelectedInGroup) ?? group.first
      if selected?.isMiniaturized == true, let anchor = anchors[groupIndex], anchor !== host {
        anchor.miniaturize(nil)
      }
    }

    guard let front = groups.first else { return }
    let selected = front.first(where: \.isSelectedInGroup) ?? front.first
    guard let selected else { return }
    let key = GroupTab(group: selected.groupIndex, tab: selected.tabIndex)
    if let id = workspaceIDs[key] {
      WorkspaceWindowManager.shared.setActiveWorkspace(id)
    } else if case .welcome = selected.content {
      WorkspaceWindowManager.shared.clearActiveWorkspace()
    }
    if let window = opened[key], !selected.isMiniaturized {
      window.makeKeyAndOrderFront(nil)
    }
  }

  private static func select(_ group: [LaunchWindow], opened: [GroupTab: NSWindow]) {
    guard let selected = group.first(where: \.isSelectedInGroup),
      let window = opened[GroupTab(group: selected.groupIndex, tab: selected.tabIndex)]
    else { return }
    window.tabGroup?.selectedWindow = window
  }

  private static func openOne(
    _ window: LaunchWindow, asTabOf parent: NSWindow?
  ) async -> (window: NSWindow, workspaceID: UUID?)? {
    switch window.content {
    case .welcome:
      guard
        let opened = NewWindowStore.shared.openWelcomeWindow(
          frame: window.frame.rect, parent: parent, reuseExisting: false)
      else { return nil }
      return (opened, nil)
    case .workspace(let launch):
      guard let id = await openContent(launch) else { return nil }
      let opened = NewWindowStore.shared.openWorkspaceWindow(
        workspaceId: id, frame: window.frame.rect, asTabOf: parent)
      return (opened, id)
    }
  }

  /// Saved files go through `openWorkspace` with the snapshot bookmarks. Untitled workspaces
  /// are rebuilt in memory and registered; they are not given a file.
  private static func openContent(_ launch: LaunchWorkspace) async -> UUID? {
    if let fileURL = launch.fileURL {
      do {
        let manager = try await WorkspaceWindowManager.shared.openWorkspace(
          url: fileURL, bookmark: launch.bookmark, folderBookmark: launch.folderBookmark)
        manager.applyLaunchOverlays(launch.textOverlays)
        return manager.id
      } catch {
        WorkspaceWindowManager.shared.showToast(
          "Couldn't reopen \(fileURL.lastPathComponent)", type: .warning)
        return nil
      }
    }
    guard let embedded = launch.workspace else { return nil }
    if let existing = WorkspaceWindowManager.shared.workspace(for: embedded.id) {
      return existing.id
    }
    let manager = WorkspaceManager(workspace: embedded, restoreTabs: false)
    WorkspaceWindowManager.shared.workspaces[manager.id] = manager
    await manager.restoreLaunchTabs(overlays: launch.textOverlays)
    return manager.id
  }
}
