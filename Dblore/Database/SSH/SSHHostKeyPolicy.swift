// SSHHostKeyPolicy.swift
// Trust on first use for SSH bastions. A pinned key is accepted, an unknown key is pinned only
// after the user confirms its fingerprint, and a changed key always blocks the connection.

import Foundation
import NIOSSH

/// What the user is asked to confirm before an unknown SSH host key is pinned.
nonisolated struct SSHHostKeyTrustRequest: Equatable, Sendable {
  var host: String
  var port: Int
  var algorithm: String
  var fingerprint: String
}

/// Asks the user whether to trust an unknown SSH host key. Only called for an unknown host,
/// never for a changed key.
nonisolated protocol SSHHostKeyPrompt: Sendable {
  func confirmUnknownHost(_ request: SSHHostKeyTrustRequest) async -> Bool
}

/// The default when no prompt is injected (the app injects `SSHHostKeyTrustCoordinator`): every
/// unknown host is declined.
nonisolated struct RejectingSSHHostKeyPrompt: SSHHostKeyPrompt {
  func confirmUnknownHost(_ request: SSHHostKeyTrustRequest) async -> Bool { false }
}

/// Checks each presented key (first key exchange and every re-key) against the pinned one.
nonisolated struct SSHHostKeyPolicy: SSHHostKeyValidating {
  let store: any SSHKnownHostStore
  let prompt: any SSHHostKeyPrompt

  init(
    store: any SSHKnownHostStore = SSHKnownHostStoreFactory.shared,
    prompt: any SSHHostKeyPrompt = RejectingSSHHostKeyPrompt()
  ) {
    self.store = store
    self.prompt = prompt
  }

  func validate(
    host: String, port: Int, hostKey: NIOSSHPublicKey, fingerprint: String
  ) async throws {
    let algorithm = SSHTunnel.algorithm(of: hostKey)
    try await check(host: host, port: port, algorithm: algorithm, fingerprint: fingerprint) {
      let request = SSHHostKeyTrustRequest(
        host: host, port: port, algorithm: algorithm, fingerprint: fingerprint)
      // A handshake that timed out cancels this task: never pin for a dead connection.
      guard await prompt.confirmUnknownHost(request), !Task.isCancelled else {
        throw DatabaseError.sshHostKeyNotTrusted(host: host, fingerprint: fingerprint)
      }
      // `trust` refuses to overwrite: a pin added meanwhile is checked again below.
      let pinned = try readingStore(host: host, port: port) {
        try store.trust(host: host, port: port, algorithm: algorithm, fingerprint: fingerprint)
      }
      if pinned { return }
      // Still unknown after Trust: the pin could not be saved. Fail closed.
      try await check(host: host, port: port, algorithm: algorithm, fingerprint: fingerprint) {
        throw DatabaseError.sshHostKeyPinFailed(host: host, port: port)
      }
    }
  }

  /// Accepts a trusted key, blocks a changed one, and runs `unknown` for an unpinned host.
  private func check(
    host: String, port: Int, algorithm: String, fingerprint: String,
    unknown: () async throws -> Void
  ) async throws {
    let stored = try readingStore(host: host, port: port) {
      try store.lookup(host: host, port: port)
    }
    let verdict = SSHKnownHostStoreFactory.evaluate(
      presented: (algorithm: algorithm, fingerprint: fingerprint), stored: stored)
    switch verdict {
    case .trusted:
      return
    case .changed(let stored):
      throw DatabaseError.sshHostKeyChanged(
        host: host, port: port, expected: stored.fingerprint, presented: fingerprint)
    case .unknown:
      try await unknown()
    }
  }

  /// An unreadable pin blocks the connection: it is never "unknown", so it is never re-prompted
  /// or overwritten.
  private func readingStore<T>(host: String, port: Int, _ read: () throws -> T) throws -> T {
    do {
      return try read()
    } catch {
      throw DatabaseError.sshHostKeyStoreUnreadable(host: host, port: port)
    }
  }
}

extension SSHTunnel {
  /// The OpenSSH key type, e.g. "ssh-ed25519" or "ecdsa-sha2-nistp256".
  static func algorithm(of key: NIOSSHPublicKey) -> String {
    String(String(openSSHPublicKey: key).split(separator: " ").first ?? "")
  }
}

extension SSHTunnelError {
  /// The user-facing error for a failed SSH connect. Nil keeps the tunnel error as is.
  func databaseError(host: String, port: Int) -> DatabaseError? {
    switch self {
    case .authenticationFailed: .sshAuthenticationFailed
    case .unsupportedHostKeyAlgorithm: .sshUnsupportedHostKeyAlgorithm(host: host, port: port)
    case .handshakeTimedOut: .sshHandshakeTimedOut
    case .hostKeyRejected, .channelOpenRejected, .closedBeforeReady, .invalidChannelData,
      .hostKeyFingerprintUnavailable, .closedWhileConfirmingHostKey:
      nil
    }
  }
}
