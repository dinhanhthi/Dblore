// AIAccessGate.swift
// Per-connection AI access policy and the one gate every AI feature asks first

import Foundation
import os

/// Whether AI features may read a connection's schema, queries or results.
nonisolated enum AIAccessPolicy: String, Codable, Sendable {
  /// Follow `AIConfiguration.defaultConnectionAccess`
  case useDefault
  case always
  /// Ask the first time in a session, then allow until the session is cleared
  case askOncePerSession
  /// Nothing from this connection reaches a model
  case never
}

/// Decides whether AI features may use a connection. Session approvals are kept in memory
/// only, behind a lock, so the gate can be read from any isolation (including MCP).
nonisolated final class AIAccessGate: Sendable {
  nonisolated enum Decision: Sendable {
    case allowed, needsApproval, denied
  }

  static let shared = AIAccessGate()

  private let approvedKeys = OSAllocatedUnfairLock<Set<String>>(initialState: [])

  /// The connection identity the saved-row match uses: engine, host, port, home database and
  /// username, each length-prefixed so no field value can make two identities equal. Host,
  /// username and a server database are trimmed and lowercased (a host also loses a trailing
  /// dot); a file database keeps its path byte for byte (file systems may be case-sensitive).
  /// Lowercasing a server database is intended: it matches the target check of the Safe Mode
  /// unlock (`WorkspaceManager.isSameTarget`).
  /// A switched MongoDB connection keeps its home database (`identityDatabase`): an approval
  /// survives a database switch and the key still matches the saved connection.
  static func sessionKey(for config: ConnectionConfig) -> String {
    let database =
      config.databaseType.capabilities.isFileBased
      ? config.identityDatabase : WorkspaceManager.normalized(config.identityDatabase)
    return KeychainAccount.v2([
      config.databaseType.rawValue, WorkspaceManager.normalizedHost(config.host),
      String(config.port), database, WorkspaceManager.normalized(config.username),
    ])
  }

  /// The strictest effective policy of `config` and of its saved connections (`savedPolicies`)
  /// wins, each Use default resolved first: never, then ask once per session, then always.
  func decision(
    for config: ConnectionConfig, settings: AIConfiguration, savedPolicies: [AIAccessPolicy] = []
  ) -> Decision {
    let policies = ([config.aiAccess] + savedPolicies).map {
      Self.effectivePolicy($0, settings: settings)
    }
    if policies.contains(.never) { return .denied }
    guard policies.contains(.askOncePerSession) else { return .allowed }
    let key = Self.sessionKey(for: config)
    return approvedKeys.withLock { $0.contains(key) } ? .allowed : .needsApproval
  }

  /// `.useDefault` follows the global default. A global "use default" has nothing to follow, so
  /// it asks (fail closed).
  private static func effectivePolicy(
    _ policy: AIAccessPolicy, settings: AIConfiguration
  ) -> AIAccessPolicy {
    let resolved = policy == .useDefault ? settings.defaultConnectionAccess : policy
    return resolved == .useDefault ? .askOncePerSession : resolved
  }

  func approveForSession(_ key: String) {
    _ = approvedKeys.withLock { $0.insert(key) }
  }

  func clearSession() {
    approvedKeys.withLock { $0.removeAll() }
  }
}

/// What AI features read for an open connection: its config (with the saved connection's rules
/// when one matches) and the policy of every saved row of its identity. Ask
/// `decision(settings:)`, so the strictest of the live and saved policies wins.
nonisolated struct AIAccessContext: Sendable {
  let config: ConnectionConfig
  let savedPolicies: [AIAccessPolicy]
  let gate: AIAccessGate

  func decision(settings: AIConfiguration) -> AIAccessGate.Decision {
    gate.decision(for: config, settings: settings, savedPolicies: savedPolicies)
  }
}
