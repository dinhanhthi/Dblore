//
//  LockCenter.swift
//  Dblore
//

import AppKit
import CryptoKit
import Foundation
import Observation

/// Asks the owner to unlock one locked item: Touch ID, the Mac password or the Lock password.
/// The prompt is a sheet on `anchor` (the window it belongs to), never app-modal.
protocol UnlockPrompter {
  /// True only after the owner authenticated for `item`
  func unlock(
    _ item: LockIdentity, reason: String, anchor: NSWindow?, lockVault: UnlockPasswordVault
  ) async -> Bool
}

/// Refuses every unlock without showing anything: the test host's prompter (the app's is
/// `AppUnlockPrompter`)
struct RefusingUnlockPrompter: UnlockPrompter {
  func unlock(
    _ item: LockIdentity, reason: String, anchor: NSWindow?, lockVault: UnlockPasswordVault
  ) async -> Bool { false }
}

/// The app's lock state for the UI: which locked items were relocked (their windows show the
/// unlock overlay) and the unlock requests, which grant through the registry.
@MainActor
@Observable
final class LockCenter {
  static let shared = LockCenter()

  let registry: LockRegistry
  /// The app's one Lock password vault: its wrong-entry throttle lives in the instance
  let lockVault: UnlockPasswordVault
  @ObservationIgnored private let prompter: any UnlockPrompter
  /// Asked before a first Lock password is set while anything is locked
  @ObservationIgnored private let ownerAuthenticator: any BiometricAuthenticator
  @ObservationIgnored private var tokens: [any NSObjectProtocol] = []
  /// The open workspace keys: an unlock of a workspace open here must give the same key
  @ObservationIgnored private let sessions: WorkspaceLockSessions
  /// The menus' values: withheld while the key window is covered, re-rendered when `relocked`
  /// changes
  @ObservationIgnored private let focusRegistry: FocusedActionRegistry
  /// Locked workspace files kept apart from Recents: a Lock password change re-seals them, and
  /// the Lock password stays while one depends on it
  @ObservationIgnored let lockedWorkspaces: LockedWorkspaceList

  /// Locked items relocked since their last unlock in this session: the windows of these
  /// workspaces and connections are covered (`coverage`)
  private(set) var relocked: Set<LockIdentity> = [] {
    didSet { if relocked != oldValue { focusRegistry.refresh() } }
  }

  /// Under the test host the Lock password lives in memory, never in the Keychain, and no
  /// prompt is shown
  init(
    registry: LockRegistry = .shared,
    lockVault: UnlockPasswordVault = .lockPassword(
      store: SessionManager.isRunningAsTestHost ? InMemoryPasswordStore() : LockPasswordStore()),
    prompter: any UnlockPrompter = SessionManager.isRunningAsTestHost
      ? RefusingUnlockPrompter() : AppUnlockPrompter(),
    ownerAuthenticator: any BiometricAuthenticator = SessionManager.isRunningAsTestHost
      ? UnavailableBiometricAuthenticator() : LAContextBiometricAuthenticator(),
    sessions: WorkspaceLockSessions = .shared, focusRegistry: FocusedActionRegistry = .shared,
    lockedWorkspaces: LockedWorkspaceList = .shared
  ) {
    self.registry = registry
    self.lockedWorkspaces = lockedWorkspaces
    self.sessions = sessions
    self.focusRegistry = focusRegistry
    self.lockVault = lockVault
    self.prompter = prompter
    self.ownerAuthenticator = ownerAuthenticator
    tokens.append(
      NotificationCenter.default.addObserver(
        forName: LockRegistry.didRelock, object: registry, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.relocked = registry.lockedIdentities
          self?.relockedBeforeGrant = []
        }
      })
  }

  /// What covers a workspace window (the unlock overlay; its menu commands are withheld): its
  /// own workspace `lockKeyId` when relocked, else the `connection` it works on when an identity
  /// that connection reaches was relocked. Nil when nothing covers it: an unlocked or plain
  /// window is untouched.
  func coverage(lockKeyId: UUID?, connection: ConnectionConfig?) -> LockCoverage? {
    // Nothing relocked: no `stat` or URI parsing for every menu read
    guard !relocked.isEmpty else { return nil }
    if let id = lockKeyId, relocked.contains(.workspace(id)), registry.isBlocked(.workspace(id)) {
      return .workspace(id)
    }
    guard let connection else { return nil }
    let reached = LockIdentity.all(connection)
    guard !reached.isDisjoint(with: relocked), reached.contains(where: registry.isBlocked) else {
      return nil
    }
    return .connection(connection)
  }

  /// Unlocks `item` for this session. A blocked item asks the prompter on `anchor` and is
  /// granted only when the owner authenticated and no relock landed while the prompt was open.
  /// True when `item` may open.
  func requestUnlock(_ item: LockIdentity, reason: String, anchor: NSWindow?) async -> Bool {
    await unlock(item, blocked: registry.isBlocked(item) ? [item] : [], reason, anchor)
  }

  /// Unlocks `config` for this session: asks once, for the config's own item, when ANY identity
  /// it reaches (`LockIdentity.all`) is blocked, and then grants every blocked one together
  /// (a `fileID` through its locked path). True when `config` may open.
  func requestUnlock(for config: ConnectionConfig, reason: String, anchor: NSWindow?) async -> Bool
  {
    await unlock(
      LockIdentity(config), blocked: LockIdentity.all(config).filter(registry.isBlocked), reason,
      anchor)
  }

  /// The owner confirms removing the lock of `config` (Settings > Locked items): asks every
  /// time, also when it was unlocked in this session, then grants what `config` reaches. Every
  /// other saved row of `rows` that reaches its lock and is still blocked asks for itself. True
  /// when the lock may go.
  func confirmLockRemoval(
    for config: ConnectionConfig, rows: [ConnectionConfig], reason: String, anchor: NSWindow?
  ) async -> Bool {
    let identity = LockIdentity(config)
    let generation = registry.generation
    guard await prompter.unlock(identity, reason: reason, anchor: anchor, lockVault: lockVault)
    else { return false }
    let blocked = LockIdentity.all(config).filter(registry.isBlocked)
    if !blocked.isEmpty {
      guard registry.grant(blocked, ifGeneration: generation) else { return false }
      relocked.subtract(blocked)
    }
    for row in rows where LockIdentity.all(row).contains(identity) {
      guard await requestUnlock(for: row, reason: reason, anchor: anchor) else { return false }
    }
    return true
  }

  /// Touch ID or the Mac password, for a setting that weakens the lock (relock Never). True
  /// when the owner confirmed.
  func authenticateOwner(reason: String) async -> Bool {
    guard let proof = await ownerAuthenticator.authenticateOwner(reason: reason) else {
      return false
    }
    // No protected read follows: end the context's reuse window at once
    proof.invalidate()
    return true
  }

  /// Sets the first Lock password (Lock Workspace, Settings). The Lock password also unlocks
  /// every locked connection, file and workspace, so while anything is locked the owner proves
  /// first (Touch ID or the Mac password). An existing or unreadable record is never replaced
  /// here: a change verifies the current password and re-seals first. The record's PBKDF2 runs
  /// off the main actor.
  func setLockPassword(_ password: String, reason: String) async -> LockPasswordSetResult {
    guard password.count >= lockVault.minimumLength else { return .tooShort }
    // The record may be about to change or go
    guard !isChangingPassword else { return .busy }
    switch await Self.passwordState(of: lockVault) {
    case .present: return .alreadySet
    case .unreadable: return .unreadable
    case .absent: break
    }
    if !registry.lockedIdentities.isEmpty {
      guard let proof = await ownerAuthenticator.authenticateOwner(reason: reason) else {
        return .notAuthenticated
      }
      // No protected read follows: end the context's reuse window at once
      proof.invalidate()
    }
    return await Self.store(password, in: lockVault) ? .set : .notStored
  }

  @concurrent nonisolated private static func passwordState(
    of vault: UnlockPasswordVault
  ) async -> UnlockPasswordVault.PasswordState {
    vault.passwordState
  }

  @concurrent nonisolated private static func store(
    _ password: String, in vault: UnlockPasswordVault
  ) async -> Bool {
    vault.setPassword(password)
  }

  /// Changes the Lock password (Settings). The owner proves first, before anything is
  /// re-sealed: with the `current` Lock password, or, when it is empty, with Touch ID or the Mac
  /// password, which is refused (`.needsCurrentPassword`, nobody asked) unless every locked
  /// workspace of `workspaces` (Recents) and of the durable list keeps its key in this Mac's
  /// Keychain, open or not (an open one may be relocked: the Mac password alone never rewraps a
  /// Lock-password-only workspace); each key is read with the owner's proof, and an open
  /// workspace's must be its session's. Then every locked workspace and its tab files are
  /// re-sealed off the main actor (each keeps its content key, so earlier backups and copies
  /// still open with the old password). Locked workspaces listed meanwhile (an open of a sealed
  /// file) are re-sealed too (three passes; any listed after the last is listed as failed), and
  /// only after that the new record is stored. Files that failed (a durable-list file that went
  /// away too) keep the old wrap block and are listed. One change or removal runs at a time,
  /// never beside a Lock Workspace or a Remove Lock (`.busy`).
  func changeLockPassword(
    current: String?, new: String, workspaces: [WorkspaceHistoryEntry], reason: String,
    keyStore: LockKeyStore = LockKeyStore(),
    iterations: Int = SafeModePasswordRecord.lockIterations,
    progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
  ) async -> LockPasswordChangeResult {
    guard new.count >= lockVault.minimumLength else { return .tooShort }
    guard !isChangingPassword, workspaceLocks == 0 else { return .busy }
    isChangingPassword = true
    defer { isChangingPassword = false }
    // Also the locked workspaces that left Recents
    let workspaces = lockedWorkspaces.merged(with: workspaces)
    let current = current?.isEmpty == false ? current : nil
    var storedKeys: [UUID: SymmetricKey] = [:]
    if let current {
      if let refusal = await verifyCurrent(current) { return refusal }
    } else {
      if let refusal = await Self.refusal(for: Self.passwordState(of: lockVault)) {
        return refusal
      }
      let locked = Set(workspaces.filter(\.isLocked).map(\.id))
      guard locked.allSatisfy({ [.presence, .appGated].contains(keyStore.mode(for: $0)) }) else {
        return .needsCurrentPassword
      }
      guard let proof = await ownerAuthenticator.authenticateOwner(reason: reason) else {
        return .notAuthenticated
      }
      // One Keychain read per workspace with the evaluated context, then its reuse window ends
      defer { proof.invalidate() }
      for id in locked {
        guard let key = try? keyStore.read(for: id, authentication: proof),
          sessions.session(for: id).map({ $0.contentKey == key }) ?? true
        else { return .needsCurrentPassword }
        storedKeys[id] = key
      }
    }
    let io = LockedFileIO(sessions: sessions, registry: registry)
    var result = await io.reseal(
      workspaces, currentPassword: current, newPassword: new, storedKeys: storedKeys,
      iterations: iterations, progress: progress)
    // Locked workspaces listed while the files were re-sealed (an open of a sealed file adds
    // it to the durable list; Lock Workspace waits for the change): re-sealed too, before the
    // new record is stored, never refused at this point (the files above already moved)
    var seen = Set(workspaces.map(\.fileURL.standardizedFileURL.path))
    for _ in 0..<3 {
      let added = lockedWorkspaces.entries.filter {
        !seen.contains($0.fileURL.standardizedFileURL.path)
      }
      guard !added.isEmpty else { break }
      seen.formUnion(added.map(\.fileURL.standardizedFileURL.path))
      // Without the current password only an open, unlocked workspace's own key re-seals one
      let unreached =
        current == nil ? added.filter { registry.isBlocked(.workspace($0.id)) } : []
      result.failures += unreached.map {
        LockedFileIO.FileFailure(url: $0.fileURL, reason: "The workspace is locked.")
      }
      let reached = added.filter { entry in !unreached.contains { $0.fileURL == entry.fileURL } }
      result.failures += await io.reseal(
        reached, currentPassword: current, newPassword: new, iterations: iterations,
        progress: progress
      ).failures
    }
    // Still joining after the last pass: not re-sealed, listed
    result.failures += lockedWorkspaces.entries
      .filter { !seen.contains($0.fileURL.standardizedFileURL.path) }
      .map {
        LockedFileIO.FileFailure(
          url: $0.fileURL, reason: "Opened while the Lock password changed, so not re-encrypted.")
      }
    let failures = result.failures.map(\.url)
    return await Self.store(new, in: lockVault)
      ? .changed(failures: failures) : .notStored(failures: failures)
  }

  /// Removes the Lock password (Settings). Refused while a locked workspace depends on it (a
  /// Recents entry marked locked, a workspace registered as locked here, or a durable-list file
  /// that is still sealed with it; a file that went away does not count, one that cannot be
  /// read does): its files are wrapped with it, and a later first password could not re-seal
  /// them. The owner proves first: the `current` Lock password, or Touch ID or the Mac password
  /// when it is empty. With the current password, a durable-list file counts only when that
  /// password unwraps it (another Mac's workspace does not), checked once the password is
  /// verified, so no unverified guess is tried against a file; without it, every sealed one
  /// counts. The dependency is checked again once the owner proved, just before the removal.
  func removeLockPassword(
    current: String?, workspaces: [WorkspaceHistoryEntry], reason: String
  ) async -> LockPasswordChangeResult {
    guard !isChangingPassword, workspaceLocks == 0 else { return .busy }
    isChangingPassword = true
    defer { isChangingPassword = false }
    let current = current?.isEmpty == false ? current : nil
    guard await !workspacesDepend(workspaces, checksDurable: current == nil, password: nil) else {
      return .workspacesDepend
    }
    if let current {
      if let refusal = await verifyCurrent(current) { return refusal }
    } else {
      if let refusal = await Self.refusal(for: Self.passwordState(of: lockVault)) {
        return refusal
      }
      guard let proof = await ownerAuthenticator.authenticateOwner(reason: reason) else {
        return .notAuthenticated
      }
      // No protected read follows: end the context's reuse window at once
      proof.invalidate()
    }
    // A workspace may have been locked while the password was checked or the owner asked
    guard await !workspacesDepend(workspaces, checksDurable: true, password: current) else {
      return .workspacesDepend
    }
    await Self.remove(from: lockVault)
    return .removed
  }

  /// A Lock password change or removal is running (one at a time): Lock Workspace and a first
  /// Lock password wait for it
  @ObservationIgnored private(set) var isChangingPassword = false {
    didSet {
      guard !isChangingPassword else { return }
      let waiting = changeWaiters
      changeWaiters = []
      for waiter in waiting { waiter.resume() }
    }
  }
  /// `passwordChangeFinished()` callers, resumed when the change or removal ends
  @ObservationIgnored private var changeWaiters: [CheckedContinuation<Void, Never>] = []

  /// Returns once no Lock password change or removal runs (at once when none does): a locked
  /// workspace's auto-save waits, so it never races the change's re-seal of its files
  func passwordChangeFinished() async {
    guard isChangingPassword else { return }
    await withCheckedContinuation { changeWaiters.append($0) }
  }
  /// Lock Workspaces running (`beginWorkspaceLock`)
  @ObservationIgnored private var workspaceLocks = 0

  /// Lock Workspace holds this from its Lock password check to its last sealed file, so its
  /// new workspace is never wrapped with a password a change is replacing, nor missed by the
  /// change's re-seal; Remove Lock holds it while it writes, so a change never seals a file
  /// again after its lock is gone. False (nothing held) while a change or removal of the Lock
  /// password runs; a change or removal is refused (`.busy`) while one is held. Each `true` is
  /// paired with one `endWorkspaceLock()`.
  func beginWorkspaceLock() -> Bool {
    guard !isChangingPassword else { return false }
    workspaceLocks += 1
    return true
  }

  func endWorkspaceLock() {
    workspaceLocks = max(0, workspaceLocks - 1)
  }

  /// Drops a locked workspace file from the durable list (Settings > Locked items): one sealed
  /// on another Mac, or moved, that would otherwise keep the Lock password and be re-sealed by
  /// every change. Its file is untouched and still opens with its own password. The owner
  /// confirms first (Touch ID, the Mac password or the Lock password). True when it is gone.
  func forgetLockedWorkspace(
    _ entry: WorkspaceHistoryEntry, reason: String, anchor: NSWindow?
  ) async -> Bool {
    guard
      await prompter.unlock(
        .workspace(entry.id), reason: reason, anchor: anchor, lockVault: lockVault)
    else { return false }
    lockedWorkspaces.remove(id: entry.id, fileURL: entry.fileURL)
    return true
  }

  /// Whether a locked workspace's files are wrapped with the Lock password: one registered as
  /// locked here, a Recents entry marked locked, or (`checksDurable`) a durable-list file still
  /// sealed, with `password` when given (`LockedWorkspaceList.stillSealed`)
  private func workspacesDepend(
    _ workspaces: [WorkspaceHistoryEntry], checksDurable: Bool, password: String?
  ) async -> Bool {
    let registered = registry.lockedIdentities.contains {
      if case .workspace = $0 { return true }
      return false
    }
    guard !registered, !workspaces.contains(where: \.isLocked) else { return true }
    guard checksDurable else { return false }
    let known = Set(workspaces.map(\.fileURL.standardizedFileURL.path))
    let durable = lockedWorkspaces.entries.filter {
      !known.contains($0.fileURL.standardizedFileURL.path)
    }
    guard !durable.isEmpty else { return false }
    return await !LockedWorkspaceList.stillSealed(durable, password: password).isEmpty
  }

  /// Nil when `password` is the stored Lock password (PBKDF2 off the main actor, throttled)
  private func verifyCurrent(_ password: String) async -> LockPasswordChangeResult? {
    switch await Self.verify(password, with: lockVault) {
    case .accepted: return nil
    case .rejected: return .wrongPassword
    case .throttled(let until): return .throttled(until: until)
    case .unreadable: return .unreadable
    case .noPassword: return .notSet
    }
  }

  private static func refusal(
    for state: UnlockPasswordVault.PasswordState
  ) -> LockPasswordChangeResult? {
    switch state {
    case .present: return nil
    case .absent: return .notSet
    case .unreadable: return .unreadable
    }
  }

  @concurrent nonisolated private static func verify(
    _ password: String, with vault: UnlockPasswordVault
  ) async -> UnlockPasswordVault.Outcome {
    vault.verify(password)
  }

  @concurrent nonisolated private static func remove(from vault: UnlockPasswordVault) async {
    vault.removePassword()
  }

  // MARK: - Locked workspaces

  /// Unlocks the workspace a sealed file belongs to through this Mac's Keychain: owner
  /// authentication (Touch ID or the Mac password, the system prompt) reads its stored content
  /// key with the evaluated context. A workspace with no key stored here (Lock password only, or
  /// sealed on another Mac) is refused without a prompt. Registered as locked before the
  /// prompt, so the grant holds and a relock covers it; a relock while the prompt is open voids
  /// the grant. A workspace open here keeps its own session and refuses any other key.
  func unlockWorkspace(
    _ header: LockEnvelope.Header, reason: String, keyStore: LockKeyStore
  ) async -> WorkspaceLockSession? {
    let id = header.workspaceId
    registry.registerWorkspace(id)
    let generation = registry.generation
    guard let mode = keyStore.mode(for: id), mode != .unavailable,
      let proof = await ownerAuthenticator.authenticateOwner(reason: reason)
    else { return nil }
    // One Keychain item read with the evaluated context (no file, no PBKDF2), then the
    // context's reuse window ends
    defer { proof.invalidate() }
    guard let key = try? keyStore.read(for: id, authentication: proof),
      let session = matchingOpenSession(
        WorkspaceLockSession(workspaceId: id, contentKey: key, wrapBlock: header.wrapBlock))
    else { return nil }
    return granted(session, generation)
  }

  /// Unlocks the workspace a sealed file belongs to with the Lock password: unwraps the file's
  /// own wrap block (PBKDF2 off the main actor), so no Lock password record is needed on this
  /// Mac. Wrong entries are throttled on the same schedule as the Lock password vault. The file's
  /// header is untrusted: when a workspace with its id is open here, only that workspace's own
  /// key unlocks (`otherKey` otherwise, nothing granted).
  func unlockWorkspace(
    _ header: LockEnvelope.Header, password: String
  ) async -> WorkspacePasswordUnlock {
    if let until = wrapAttempts.retryTime(now: Date()) { return .throttled(until: until) }
    let id = header.workspaceId
    registry.registerWorkspace(id)
    let generation = registry.generation
    wrapAttempts.count(now: Date())
    guard let unwrapped = try? await WorkspaceLockSession.unwrap(header, password: password)
    else { return .wrongPassword }
    // The password itself was right, whatever key it opens
    wrapAttempts = WrapAttempts()
    guard let session = matchingOpenSession(unwrapped) else { return .otherKey }
    return granted(session, generation).map { .unlocked($0) } ?? .relocked
  }

  /// Takes back the grant of workspace `id` after an open that ended without its content
  /// (cancelled, or its files did not open with the key): blocked again, and shown relocked
  /// again when it was before that grant
  func revokeWorkspace(_ id: UUID) {
    registry.revoke(.workspace(id))
    if relockedBeforeGrant.remove(id) != nil { relocked.insert(.workspace(id)) }
  }

  /// An unlock answered after its sheet was gone (the window closed while it ran): nothing
  /// uses the grant unless a window holds that workspace's key
  func abandonUnlock(_ session: WorkspaceLockSession) {
    guard sessions.session(for: session.workspaceId) == nil else { return }
    revokeWorkspace(session.workspaceId)
  }

  /// `candidate` when no workspace with its id is open here; the open session (its wrap block,
  /// not the file's) when the key is the same; nil for any other key
  private func matchingOpenSession(_ candidate: WorkspaceLockSession) -> WorkspaceLockSession? {
    guard let open = sessions.session(for: candidate.workspaceId) else { return candidate }
    return open.contentKey == candidate.contentKey ? open : nil
  }

  /// The owner confirms Remove Lock of the workspace `workspaceId`: the Lock password checked
  /// against the open `session`'s wrap block (no Lock password record needed), or, without a
  /// password, Touch ID or the Mac password. `WorkspaceManager.removeLock` runs only with the
  /// authorization this returns.
  func authorizeRemoveLock(
    _ workspaceId: UUID, session: WorkspaceLockSession?, password: String?, reason: String
  ) async -> RemoveLockConfirmation {
    guard let password, !password.isEmpty else {
      guard let proof = await ownerAuthenticator.authenticateOwner(reason: reason) else {
        return .refused("Touch ID or the Mac password did not confirm.")
      }
      // No protected read follows: end the context's reuse window at once
      proof.invalidate()
      return .authorized(RemoveLockAuthorization(workspaceId: workspaceId))
    }
    guard let session, session.workspaceId == workspaceId else {
      return .refused("Use Touch ID or the Mac password.")
    }
    if let until = wrapAttempts.retryTime(now: Date()) {
      return .refused(WorkspacePasswordUnlock.throttled(until: until).message ?? "")
    }
    wrapAttempts.count(now: Date())
    guard await Self.opens(session, with: password) else {
      return .refused("Wrong Lock password.")
    }
    wrapAttempts = WrapAttempts()
    return .authorized(RemoveLockAuthorization(workspaceId: workspaceId))
  }

  /// Wrong Lock password entries against wrap blocks, app-wide
  @ObservationIgnored private var wrapAttempts = WrapAttempts()
  /// Workspaces a grant took out of `relocked` since the last relock (a revoke puts them back)
  @ObservationIgnored private var relockedBeforeGrant: Set<UUID> = []

  /// The throttle of `UnlockPasswordVault` (its record-based one never runs without a record)
  private struct WrapAttempts {
    let throttle = UnlockPasswordVault.Throttle()
    var failures = 0
    var retryAt: Date?

    func retryTime(now: Date) -> Date? {
      guard let retryAt, retryAt > now else { return nil }
      return retryAt
    }

    /// Counted as wrong before PBKDF2 runs (a match resets it)
    mutating func count(now: Date) {
      failures += 1
      if failures >= throttle.freeAttempts {
        retryAt = now + throttle.delay(afterFailures: failures)
      }
    }
  }

  /// `session` granted, unless a relock landed since `generation`; registered by the caller
  private func granted(
    _ session: WorkspaceLockSession, _ generation: Int
  ) -> WorkspaceLockSession? {
    guard registry.grant(.workspace(session.workspaceId), ifGeneration: generation) else {
      return nil
    }
    if relocked.remove(.workspace(session.workspaceId)) != nil {
      relockedBeforeGrant.insert(session.workspaceId)
    }
    return session
  }

  /// Whether `password` unwraps `session`'s own key. Runs PBKDF2, off the main actor.
  @concurrent nonisolated private static func opens(
    _ session: WorkspaceLockSession, with password: String
  ) async -> Bool {
    (try? LockEnvelope.unwrapKey(session.wrapBlock, password: password)) == session.contentKey
  }

  /// `blocked` is read after the generation, so a relock in between voids the grant
  private func unlock(
    _ item: LockIdentity, blocked: @autoclosure () -> Set<LockIdentity>, _ reason: String,
    _ anchor: NSWindow?
  ) async -> Bool {
    let generation = registry.generation
    let blocked = blocked()
    guard !blocked.isEmpty else { return true }
    guard await prompter.unlock(item, reason: reason, anchor: anchor, lockVault: lockVault),
      registry.grant(blocked, ifGeneration: generation)
    else { return false }
    relocked.subtract(blocked)
    return true
  }
}

/// What covers a relocked window (`LockCenter.coverage`)
enum LockCoverage: Equatable {
  /// The window's own locked workspace
  case workspace(UUID)
  /// The locked connection the window works on
  case connection(ConnectionConfig)
}

extension WorkspaceLockSession {
  /// The envelope header of this open workspace's files: an unlock of a workspace already open
  /// here (Keychain path or the Lock password against its own wrap block) asks with it
  nonisolated var header: LockEnvelope.Header {
    LockEnvelope.Header(kind: .workspace, workspaceId: workspaceId, wrapBlock: wrapBlock)
  }
}

/// The outcome of `LockCenter.unlockWorkspace(_:password:)`
enum WorkspacePasswordUnlock: Sendable {
  case unlocked(WorkspaceLockSession)
  case wrongPassword
  /// Too many wrong entries: refused without checking until `until`
  case throttled(until: Date)
  /// Dblore relocked while the password was checked: nothing granted
  case relocked
  /// The file's key is not the key of the workspace open here with the same id
  case otherKey

  var message: String? {
    switch self {
    case .unlocked: return nil
    case .wrongPassword: return "Wrong Lock password."
    case .throttled(let until):
      let seconds = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
      return "Too many wrong entries. Try again in \(seconds) s."
    case .relocked: return "Dblore locked again while unlocking. Try again."
    case .otherKey: return "This file's key does not match the open workspace with its id."
    }
  }
}

/// Proof that the owner confirmed Remove Lock of one workspace: only `LockCenter` makes one
nonisolated struct RemoveLockAuthorization: Sendable {
  let workspaceId: UUID

  fileprivate init(workspaceId: UUID) {
    self.workspaceId = workspaceId
  }
}

/// The outcome of `LockCenter.authorizeRemoveLock`
enum RemoveLockConfirmation: Sendable {
  case authorized(RemoveLockAuthorization)
  case refused(String)

  var authorization: RemoveLockAuthorization? {
    if case .authorized(let authorization) = self { return authorization }
    return nil
  }
}

/// The outcome of `LockCenter.setLockPassword`
enum LockPasswordSetResult: Equatable, Sendable {
  case set
  /// Shorter than `UnlockPasswordVault.lockMinimumLength`
  case tooShort
  /// A Lock password is already set (a change goes through its own path)
  case alreadySet
  /// The stored record cannot be read: never treated as absent
  case unreadable
  /// Owner authentication was refused or cancelled
  case notAuthenticated
  /// The Keychain did not store the record
  case notStored
  /// A change or removal of the Lock password is running
  case busy

  var message: String? {
    switch self {
    case .set: return nil
    case .busy: return "The Lock password is being changed. Try again when it is done."
    case .tooShort:
      return "The Lock password needs at least \(UnlockPasswordVault.lockMinimumLength) characters."
    case .alreadySet: return "A Lock password is already set."
    case .unreadable: return "The Lock password cannot be read right now. Try again."
    case .notAuthenticated:
      return "Touch ID or the Mac password is needed to set the Lock password."
    case .notStored: return "The Lock password could not be stored."
    }
  }
}

/// The outcome of `LockCenter.changeLockPassword` and `removeLockPassword`
enum LockPasswordChangeResult: Equatable, Sendable {
  /// The new record is stored; `failures` were not re-sealed and still open with the old one
  case changed(failures: [URL])
  case removed
  /// Shorter than `UnlockPasswordVault.lockMinimumLength`
  case tooShort
  /// No Lock password is set (the first one goes through `setLockPassword`)
  case notSet
  /// The stored record cannot be read: never treated as absent
  case unreadable
  case wrongPassword
  /// Too many wrong entries: refused without checking until `until`
  case throttled(until: Date)
  /// A locked workspace's key is not reachable without the current Lock password
  case needsCurrentPassword
  /// Owner authentication was refused or cancelled
  case notAuthenticated
  /// The files were re-sealed with the new password, but its record was not stored
  case notStored(failures: [URL])
  /// A locked workspace is wrapped with the Lock password
  case workspacesDepend
  /// Another change or removal of the Lock password, or a Lock Workspace, is running
  case busy

  var message: String? {
    switch self {
    case .changed, .removed: return nil
    case .tooShort:
      return "The Lock password needs at least \(UnlockPasswordVault.lockMinimumLength) characters."
    case .notSet: return "No Lock password is set."
    case .unreadable: return "The Lock password cannot be read right now. Try again."
    case .wrongPassword: return "Wrong Lock password."
    case .throttled(let until):
      let seconds = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
      return "Too many wrong entries. Try again in \(seconds) s."
    case .needsCurrentPassword:
      return "A locked workspace keeps no key on this Mac, so the current Lock password is "
        + "needed to re-encrypt it."
    case .notAuthenticated: return "Touch ID or the Mac password did not confirm."
    case .notStored:
      return "The workspaces now open with the new Lock password, but it could not be stored. "
        + "Locked connections still unlock with the old one."
    case .workspacesDepend:
      return "Locked workspaces open with the Lock password. Remove their locks first."
    case .busy:
      return "The Lock password is being changed, or a workspace is being locked. Try again "
        + "when it is done."
    }
  }
}
