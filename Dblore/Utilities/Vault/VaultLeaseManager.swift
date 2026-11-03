// VaultLeaseManager.swift
// One Vault lease of database credentials and its renewal. `VaultLeasing` takes a lease (an
// AppRole login first when the connection uses AppRole); the `VaultLeaseManager` actor renews it
// at 2/3 of its TTL (and an AppRole login token at 2/3 of the token's TTL, never by a second
// login: Vault revokes a token's leases when that token ends), retries a failed renewal every
// 10% of the TTL (at least 5 s) until the lease's known expiry, and reports the end only at that
// expiry or on a definitive answer: the lease is gone (400 `lease not found` / `invalid lease`),
// or the token is (403, and lookup-self with the same token also 403). The lease username and
// password reach only the session config (`overlay`), never a saved one. An AppRole login token
// is revoked with its lease, or at once when no lease came of it. Nothing here logs a token, a
// secret or a lease password.

import Foundation
import os

/// What lease renewal waits on: production sleeps on the continuous clock (it counts while the
/// Mac sleeps), tests move a fake one by hand. Times are seconds from the clock's own origin.
nonisolated protocol VaultLeaseClock: Sendable {
  func now() -> TimeInterval
  /// Returns at once when `deadline` has passed; throws `CancellationError` when cancelled
  func sleep(until deadline: TimeInterval) async throws
}

nonisolated struct ContinuousVaultLeaseClock: VaultLeaseClock {
  private let origin = ContinuousClock.now

  func now() -> TimeInterval {
    let elapsed = origin.duration(to: .now).components
    return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
  }

  func sleep(until deadline: TimeInterval) async throws {
    let wait = deadline - now()
    guard wait > 0 else { return try Task.checkCancellation() }
    try await Task.sleep(for: .seconds(wait))
  }
}

/// Why a lease ended, for the connection-lost banner (`WorkspaceManager.connectionLostMessage(for:leaseEnd:)`).
nonisolated struct VaultLeaseEnd: Equatable, Sendable {
  enum Reason: Equatable, Sendable {
    /// The lease's known expiry passed (renewals failing, or not renewable)
    case expired
    /// Vault no longer knows the lease (revoked, or ended with its creating token)
    case leaseGone
    /// The token is expired or revoked
    case tokenGone
  }

  let reason: Reason
  /// `SessionLostEvent.epoch` of the connection the end closed
  let epoch: UInt64

  /// What the user must do, when it is more than reconnecting
  var detail: String? {
    reason == .tokenGone ? VaultLeaseError.tokenGone.errorDescription : nil
  }
}

nonisolated enum VaultLeaseError: Error, Equatable, LocalizedError {
  case secretMissing
  /// The saved secret is bound to other Vault settings (`VaultCredentialStore.destination`)
  case destinationChanged
  case tokenGone
  /// The lease a reset kept ended before its new session was published, or a newer connect or a
  /// disconnect took this connect's lease out of the slot before it published
  case leaseEnded

  var errorDescription: String? {
    switch self {
    case .secretMissing:
      "No Vault token or AppRole secret is saved for this connection. Enter it in the "
        + "connection's settings."
    case .destinationChanged:
      "Vault settings for this connection changed; enter the Vault token or AppRole secret "
        + "again."
    case .tokenGone:
      "Vault token expired or revoked; enter a new token."
    case .leaseEnded:
      "Vault lease ended."
    }
  }
}

/// A lease's identity: the Vault source and the connection's Keychain key (the saved username,
/// never the leased one). An internal reset reuses a held lease only for an equal key.
nonisolated struct VaultLeaseKey: Equatable, Sendable {
  let source: VaultSource
  let keychainKey: String

  /// Nil without a Vault source
  init?(_ config: ConnectionConfig) {
    guard let source = config.vault else { return nil }
    self.source = source
    keychainKey = ConnectionKeychainKey.password(for: config)
  }
}

/// The lease a `DatabaseConnectionManager` holds, with the key it was taken for.
nonisolated struct VaultLeaseSlot: Sendable {
  let key: VaultLeaseKey
  let lease: VaultLeaseManager
}

/// Takes leases. The clock, the client and the secret store are injectable for tests.
nonisolated struct VaultLeasing: Sendable {
  static let app = VaultLeasing()

  var clock: any VaultLeaseClock = ContinuousVaultLeaseClock()
  var makeClient: @Sendable (VaultSource) throws -> any VaultClient = {
    try URLSessionVaultClient(source: $0)
  }
  var store: any VaultSecretStore = VaultCredentialStore.shared

  /// Signs in with `config`'s Vault secret (`VaultCredentialStore.lookup(for:)`, so an
  /// operation's scoped secret wins; nothing is sent when it is bound to other Vault settings or
  /// the Keychain could not read it) and reads one lease. Its renewal is not started. A lease
  /// that arrives once the task is cancelled is revoked, and so is a login token that got no
  /// lease.
  func take(for config: ConnectionConfig) async throws -> VaultLeaseManager {
    guard let source = config.vault else { throw VaultLeaseError.secretMissing }
    let secret: VaultSecret
    switch VaultCredentialStore.lookup(for: config, from: store) {
    case .found(let found): secret = found
    case .destinationChanged: throw VaultLeaseError.destinationChanged
    case .missing: throw VaultLeaseError.secretMissing
    case .unreadable:
      throw DatabaseError.passwordStoreUnreadable(
        name: config.name.isEmpty ? config.displayString : config.name)
    }
    let client = try makeClient(source)
    let token: String
    var login: (auth: VaultAuth, at: TimeInterval)?
    switch (source.authMethod, secret) {
    case (.token, .token(let saved)):
      token = saved
    case (.appRole, .appRole(let roleID, let secretID)):
      let at = clock.now()
      let auth = try await client.appRoleLogin(roleID: roleID, secretID: secretID)
      token = auth.clientToken
      login = (auth, at)
    default:
      throw VaultLeaseError.secretMissing
    }
    let createdAt = clock.now()
    let credentials: VaultLeasedCredentials
    do {
      credentials = try await Self.readCredentials(client, token: token)
    } catch {
      if login != nil { await VaultLeaseManager.revokeToken(token, client: client) }
      throw error
    }
    let lease = VaultLeaseManager(
      credentials: credentials, createdAt: createdAt, token: token, login: login,
      client: client, clock: clock)
    if Task.isCancelled {
      await lease.revoke()
      throw CancellationError()
    }
    return lease
  }

  /// One lease; a 403 is `tokenGone` when lookup-self with the same token is refused too
  private static func readCredentials(
    _ client: any VaultClient, token: String
  ) async throws -> VaultLeasedCredentials {
    do {
      return try await client.readCredentials(token: token)
    } catch let error as VaultClientError where error.isForbidden {
      let lookup = await lookupError(client, token: token)
      if (lookup as? VaultClientError)?.isForbidden == true { throw VaultLeaseError.tokenGone }
      throw error
    }
  }

  /// lookup-self's error with `token` (nil when it answers)
  static func lookupError(_ client: any VaultClient, token: String) async -> (any Error)? {
    do {
      _ = try await client.lookupSelf(token: token)
      return nil
    } catch {
      return error
    }
  }
}

/// One lease and its renewal. Its renewal runs only after `startRenewal`, and stops for good on
/// `cancelRenewal` / `revoke` or once it reported an end.
actor VaultLeaseManager {
  nonisolated let leaseID: String
  nonisolated let username: String
  nonisolated let password: String
  /// Seconds the lease was created for (0: no TTL)
  nonisolated let createdDuration: Int

  private let client: any VaultClient
  private let clock: any VaultLeaseClock
  /// The token that created the lease: renewed, never replaced
  private let token: String
  /// An AppRole login token: revoked after the lease (a saved token is the user's)
  private let ownsToken: Bool
  /// Seconds of the last successful create or renew
  private var leaseDuration: Int
  /// Last successful create or renew + its duration (`.infinity` for a lease without a TTL)
  private var expiry: TimeInterval = .infinity
  private var leaseRenewAt: TimeInterval?
  /// AppRole: the login token's TTL from the last login or renew-self answer
  private var tokenDuration = 0
  private var tokenRenewAt: TimeInterval?
  private nonisolated let renewal = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

  init(
    credentials: VaultLeasedCredentials, createdAt: TimeInterval, token: String,
    login: (auth: VaultAuth, at: TimeInterval)?, client: any VaultClient,
    clock: any VaultLeaseClock
  ) {
    leaseID = credentials.lease.id
    username = credentials.username
    password = credentials.password
    createdDuration = credentials.lease.duration
    self.client = client
    self.clock = clock
    self.token = token
    ownsToken = login != nil
    leaseDuration = credentials.lease.duration
    if credentials.lease.duration > 0 {
      expiry = createdAt + Double(credentials.lease.duration)
      leaseRenewAt =
        credentials.lease.renewable
        ? createdAt + Double(credentials.lease.duration) * 2 / 3 : nil
    }
    if let login {
      tokenDuration = login.auth.duration
      tokenRenewAt = Self.tokenRenewal(login.auth, from: login.at)
    }
  }

  /// `config` with this lease's username and password, for a session only
  nonisolated func overlay(on config: ConnectionConfig) -> ConnectionConfig {
    var overlaid = config
    overlaid.username = username
    overlaid.password = password
    return overlaid
  }

  /// Renews until an end, then awaits `onEnd` once with its reason.
  nonisolated func startRenewal(
    onEnd: @escaping @Sendable (VaultLeaseEnd.Reason) async -> Void
  ) {
    let task = Task { await self.renew(onEnd: onEnd) }
    renewal.withLock { $0 = task }
  }

  nonisolated func cancelRenewal() {
    renewal.withLock { $0?.cancel() }
  }

  /// The renewal stopped (cancelled or ended); at once when it never started
  func renewalFinished() async {
    await renewal.withLock { $0 }?.value
  }

  /// Cancels the renewal, then revokes the lease, then an AppRole login token. Returns why the
  /// lease could not be revoked (nil: revoked, or, its own revoke refused, with its login
  /// token); the failure is logged too, and the lease then ends at its TTL. Disconnects ignore
  /// the result. Sent from a task of its own, so a cancelled caller still revokes.
  @discardableResult
  func revoke() async -> (any Error)? {
    cancelRenewal()
    let (client, leaseID, token, ownsToken) = (client, leaseID, token, ownsToken)
    return await Task.detached { () -> (any Error)? in
      var failure: (any Error)?
      do {
        try await client.revokeLease(id: leaseID, token: token)
      } catch {
        failure = error
        await AppLogger.shared.warning(
          "Vault lease revoke failed: \(error.localizedDescription)", category: "Database")
      }
      // A refused revoke (403): Vault revokes a token's leases with the token. Not for another
      // failure: the token's revoke would meet it again, after answering
      if ownsToken, await Self.revokeToken(token, client: client),
        (failure as? VaultClientError)?.isForbidden == true
      {
        failure = nil
      }
      return failure
    }.value
  }

  /// An AppRole login token's revoke-self, once its lease ended (a saved token is the user's)
  func revokeOwnedToken() async {
    if ownsToken { await Self.revokeToken(token, client: client) }
  }

  /// revoke-self of a login token, best effort, from a task of its own. True when revoked.
  @discardableResult
  nonisolated static func revokeToken(_ token: String, client: any VaultClient) async -> Bool {
    await Task.detached {
      do {
        try await client.revokeSelf(token: token)
        return true
      } catch {
        await AppLogger.shared.warning(
          "Vault token revoke failed: \(error.localizedDescription)", category: "Database")
        return false
      }
    }.value
  }

  // MARK: - Renewal

  private enum Attempt {
    case notDue
    case renewed
    case retry
    case end(VaultLeaseEnd.Reason)
    case cancelled
  }

  private func renew(onEnd: @Sendable (VaultLeaseEnd.Reason) async -> Void) async {
    while true {
      let wake = [leaseRenewAt, tokenRenewAt, expiry].compactMap { $0 }.min() ?? .infinity
      // Nothing left to renew and no expiry: the lease lasts until it is revoked
      guard wake.isFinite else { return }
      do {
        try await clock.sleep(until: wake)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      if clock.now() >= expiry { return await onEnd(.expired) }
      // The token first: a lease renewal sent with an ended token would fail anyway
      for isLease in [false, true] {
        switch isLease ? await renewLeaseIfDue() : await renewTokenIfDue() {
        case .notDue, .renewed, .retry: continue
        case .cancelled: return
        case .end(let reason): return await onEnd(reason)
        }
      }
    }
  }

  /// AppRole: renew-self of the login token when due
  private func renewTokenIfDue() async -> Attempt {
    guard let at = tokenRenewAt, clock.now() >= at else { return .notDue }
    let sent = clock.now()
    do {
      let auth = try await client.renewSelf(increment: nil, token: token)
      guard !Task.isCancelled else { return .cancelled }
      tokenDuration = auth.duration
      tokenRenewAt = Self.tokenRenewal(auth, from: sent)
      return .renewed
    } catch {
      let attempt = await classify(error)
      if case .retry = attempt {
        tokenRenewAt = clock.now() + Self.backoff(ttl: tokenDuration)
      }
      return attempt
    }
  }

  private func renewLeaseIfDue() async -> Attempt {
    guard let at = leaseRenewAt, clock.now() >= at else { return .notDue }
    let sent = clock.now()
    do {
      let lease = try await client.renewLease(id: leaseID, increment: nil, token: token)
      guard !Task.isCancelled else { return .cancelled }
      leaseDuration = lease.duration
      // No TTL: no expiry and nothing more to renew, as for a lease created without one
      expiry = lease.duration > 0 ? sent + Double(lease.duration) : .infinity
      leaseRenewAt =
        lease.renewable && lease.duration > 0 ? sent + Double(lease.duration) * 2 / 3 : nil
      return .renewed
    } catch {
      let attempt = await classify(error)
      if case .retry = attempt {
        leaseRenewAt = clock.now() + Self.backoff(ttl: leaseDuration)
      }
      return attempt
    }
  }

  /// Renew-self at 2/3 of the token's TTL; none when it is not renewable or never expires.
  private static func tokenRenewal(_ auth: VaultAuth, from sent: TimeInterval) -> TimeInterval? {
    auth.renewable && auth.duration > 0 ? sent + Double(auth.duration) * 2 / 3 : nil
  }

  /// Definitive: the lease is gone, or the token is (403, and lookup-self 403 too). Anything
  /// else is retried until the known expiry.
  private func classify(_ error: any Error) async -> Attempt {
    if error is CancellationError || Task.isCancelled { return .cancelled }
    guard let vault = error as? VaultClientError else { return .retry }
    if vault.isLeaseGone { return .end(.leaseGone) }
    guard vault.isForbidden else { return .retry }
    let lookup = await VaultLeasing.lookupError(client, token: token)
    if lookup is CancellationError || Task.isCancelled { return .cancelled }
    return (lookup as? VaultClientError)?.isForbidden == true ? .end(.tokenGone) : .retry
  }

  /// Every 10% of the TTL, at least 5 s
  private static func backoff(ttl: Int) -> TimeInterval {
    max(5, Double(ttl) / 10)
  }
}
