// WorkspaceDirtyTrackingTests.swift
// Every keystroke calls `markDirty`: once a tab is dirty, the call must not write `tabs` again,
// or every view reading `tabs` (tab bar, tab navigation) is re-evaluated per keystroke.

import Foundation
import Observation
import Testing

@testable import Dblore

@Suite("Workspace dirty tracking")
@MainActor
struct WorkspaceDirtyTrackingTests {
  /// Set from the `onChange` closure, which runs synchronously on the main actor here.
  private final class Flag: @unchecked Sendable {
    var isSet = false
  }

  /// Number of `tabs` change notifications over `calls` calls to `markDirty`.
  private static func tabsNotifications(calls: Int) -> Int {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    let id = manager.newSQLFile()
    manager.markClean(tabId: id)
    var notifications = 0
    for _ in 0..<calls {
      let changed = Flag()
      withObservationTracking {
        _ = manager.tabs
      } onChange: {
        changed.isSet = true
      }
      manager.markDirty(tabId: id)
      if changed.isSet { notifications += 1 }
    }
    #expect(manager.tabs.first { $0.id == id }?.isDirty == true)
    return notifications
  }

  @Test("Repeated markDirty notifies tabs readers only on the first change")
  func repeatedMarkDirtyNotifiesOnce() {
    #expect(Self.tabsNotifications(calls: 100) == 1)
  }
}
