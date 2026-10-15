// SSHTunnelFactory.swift
// Opening an SSH tunnel for any network engine: the factory seam, the host-key validator, the
// stored SSH secret as an authentication, and the bastion connect through the validator (which
// runs the trust prompt for an unknown host).

import Foundation
import NIOCore
import NIOSSH

/// Opens an SSH tunnel. Production calls `SSHTunnel.connect`; tests inject fakes or spies.
nonisolated protocol SSHTunnelFactory: Sendable {
  func connect(
    host: String, port: Int, username: String, authentication: SSHTunnelAuthentication,
    hostKeyValidator: @escaping SSHHostKeyValidator, connectTimeout: TimeAmount,
    handshakeTimeout: TimeAmount
  ) async throws -> any SSHTunneling
}

nonisolated struct LiveSSHTunnelFactory: SSHTunnelFactory {
  func connect(
    host: String, port: Int, username: String, authentication: SSHTunnelAuthentication,
    hostKeyValidator: @escaping SSHHostKeyValidator, connectTimeout: TimeAmount,
    handshakeTimeout: TimeAmount
  ) async throws -> any SSHTunneling {
    try await SSHTunnel.connect(
      host: host, port: port, username: username, authentication: authentication,
      hostKeyValidator: hostKeyValidator, connectTimeout: connectTimeout,
      handshakeTimeout: handshakeTimeout)
  }
}

/// Decides whether the SSH server at `host:port` is trusted. Throw to reject the key.
nonisolated protocol SSHHostKeyValidating: Sendable {
  func validate(
    host: String, port: Int, hostKey: NIOSSHPublicKey, fingerprint: String)
    async throws
}

/// The default until the trust prompt exists: no host key is trusted.
nonisolated struct RejectUnknownSSHHostKeys: SSHHostKeyValidating {
  func validate(
    host: String, port: Int, hostKey: NIOSSHPublicKey, fingerprint: String
  )
    async throws
  {
    throw SSHTunnelError.hostKeyRejected
  }
}

/// Opens the tunnel for a connection with `sshTunnel`. Shared by every engine that tunnels.
nonisolated enum SSHTunnelConnector {
  /// The SSH secret as an authentication: the operation's scoped credential (form, unremembered
  /// connection) for this account, else the stored one. Private keys are restored from their
  /// decrypted Keychain form.
  static func sshAuthentication(for config: ConnectionConfig) throws -> SSHTunnelAuthentication {
    guard let stored = SSHCredentialStoreFactory.load(for: config) else {
      throw DatabaseError.sshCredentialMissing
    }
    switch stored {
    case .password(let password):
      return .password(password)
    case .privateKey(let keychainRepresentation):
      return .privateKey(try SSHPrivateKeyParser.restore(from: keychainRepresentation).privateKey)
    }
  }

  /// Connects to the bastion. The session timeout bounds both the TCP connect and the
  /// handshake (key exchange, user auth); time spent in the host-key check (trust sheet) is
  /// not counted.
  static func connectTunnel(
    config: ConnectionConfig, authentication: SSHTunnelAuthentication,
    hostKeyValidator: any SSHHostKeyValidating, factory: any SSHTunnelFactory
  ) async throws
    -> any SSHTunneling
  {
    guard let ssh = config.sshTunnel else { throw DatabaseError.sshCredentialMissing }
    let validator = hostKeyValidator
    let host = ssh.host
    let port = ssh.port
    let timeout = TimeAmount.seconds(Int64(config.timeoutSeconds))
    do {
      return try await PerfSignpost.interval("ssh-tunnel-connect") {
        try await factory.connect(
          host: host, port: port, username: ssh.username, authentication: authentication,
          hostKeyValidator: { key, fingerprint in
            try await validator.validate(
              host: host, port: port, hostKey: key, fingerprint: fingerprint)
          },
          connectTimeout: timeout, handshakeTimeout: timeout)
      }
    } catch let error as SSHTunnelError {
      throw error.databaseError(host: host, port: port) ?? error
    }
  }
}
