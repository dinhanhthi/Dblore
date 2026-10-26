//
//  WorkspaceLockSession.swift
//  Dblore
//

import CryptoKit
import Foundation
import os

/// The open key of one locked workspace: its id (the lock key id documents carry), the content
/// key and the wrap block copied verbatim into every file it seals. Never logged or printed.
nonisolated struct WorkspaceLockSession: Sendable {
  let workspaceId: UUID
  let contentKey: SymmetricKey
  let wrapBlock: LockEnvelope.WrapBlock

  /// The session of the envelope `header` belongs to, unwrapped with the Lock password. Runs
  /// PBKDF2, so never on the main actor.
  @concurrent static func unwrap(
    _ header: LockEnvelope.Header, password: String
  ) async throws -> WorkspaceLockSession {
    WorkspaceLockSession(
      workspaceId: header.workspaceId,
      contentKey: try LockEnvelope.unwrapKey(header.wrapBlock, password: password),
      wrapBlock: header.wrapBlock)
  }
}

/// The sessions of open locked workspaces. A session is held by the windows that use it (its own
/// workspace window, or one showing a document of that workspace) and dropped when the last of
/// them releases it, so a closed workspace's key does not stay in memory.
nonisolated final class WorkspaceLockSessions: Sendable {
  static let shared = WorkspaceLockSessions()

  private struct Entry {
    var session: WorkspaceLockSession
    var holders: Set<UUID>
  }

  private let state = OSAllocatedUnfairLock(initialState: [UUID: Entry]())

  func session(for workspaceId: UUID) -> WorkspaceLockSession? {
    state.withLock { $0[workspaceId]?.session }
  }

  /// `holder` (a window's workspace id) uses `session`. The latest session of a workspace
  /// replaces an older one (a new key after Lock Workspace).
  func hold(_ session: WorkspaceLockSession, by holder: UUID) {
    state.withLock { entries in
      var holders = entries[session.workspaceId]?.holders ?? []
      holders.insert(holder)
      entries[session.workspaceId] = Entry(session: session, holders: holders)
    }
  }

  /// Swaps the open session of `session.workspaceId` for `session` (same key, a new wrap block
  /// after a Lock password change), keeping its holders. Nothing when that workspace is not open.
  func replace(_ session: WorkspaceLockSession) {
    state.withLock { entries in
      entries[session.workspaceId]?.session = session
    }
  }

  /// `holder` closed: every session it held loses it, and a session nobody holds is dropped
  func release(holder: UUID) {
    state.withLock { entries in
      for id in entries.keys {
        entries[id]?.holders.remove(holder)
        if entries[id]?.holders.isEmpty == true { entries[id] = nil }
      }
    }
  }

  /// `holder` no longer uses the session of `workspaceId` (Remove Lock); its other sessions stay
  func release(_ workspaceId: UUID, holder: UUID) {
    state.withLock { entries in
      entries[workspaceId]?.holders.remove(holder)
      if entries[workspaceId]?.holders.isEmpty == true { entries[workspaceId] = nil }
    }
  }
}
