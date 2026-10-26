// LockPasswordChangeTests.swift
// LockCenter's Lock password change and removal (Settings > Security > Lock): a change verifies
// the owner (the current Lock password, or Touch ID / the Mac password when every locked
// workspace's key is reachable here) before anything is re-sealed, stores the new record only
// after the re-seal and lists the files that kept the old password; it also reaches locked
// workspaces that left Recents (the durable list). Removing the Lock password is refused while a
// locked workspace depends on it, checked again after the owner proved. One change or removal
// runs at a time. Also the Settings model: "Never" relock asks the owner, and the locked
// connections follow lock changes. No real Keychain, no prompt: an in-memory vault, an
// in-memory Keychain domain and injected sessions.

import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing
import os

@testable import Dblore

/// Owner authentication without a prompt: refuses until `grants`, and counts the asks. With
/// `holds`, each ask waits for `release()`; `duringPrompt` runs while it asks. `prompted()`
/// returns once asked, with the held ask already waiting.
@MainActor
private final class OwnerDouble: BiometricAuthenticator {
  var grants = false
  var holds = false
  var duringPrompt: () -> Void = {}
  private(set) var prompts = 0
  private var held: CheckedContinuation<Void, Never>?
  private var promptWaiters: [CheckedContinuation<Void, Never>] = []

  var canUseBiometrics: Bool { false }

  func authenticate(reason: String) async -> Bool { false }

  func authenticateOwner(reason: String) async -> OwnerAuthentication? {
    prompts += 1
    duringPrompt()
    // Resumed waiters run after this job, which sets `held` first: a `release()` finds it
    let waiters = promptWaiters
    promptWaiters = []
    for waiter in waiters { waiter.resume() }
    if holds { await withCheckedContinuation { held = $0 } }
    guard grants else { return nil }
    return await GrantingOwnerTestAuthenticator().authenticateOwner(reason: reason)
  }

  func release() {
    held?.resume()
    held = nil
  }

  /// Returns once the owner was asked (at once when already asked). No deadline: a busy main
  /// actor (another suite's long test) can delay the ask past any timeout, and a `release()`
  /// before the ask would leave the held ask waiting forever.
  func prompted() async {
    guard prompts == 0 else { return }
    await withCheckedContinuation { promptWaiters.append($0) }
  }
}

/// Answers every unlock prompt with `grants`, without showing anything
private struct FixedUnlockPrompter: UnlockPrompter {
  let grants: Bool

  func unlock(
    _ item: LockIdentity, reason: String, anchor: NSWindow?, lockVault: UnlockPasswordVault
  ) async -> Bool { grants }
}

@MainActor
@Suite("Lock password change and removal")
struct LockPasswordChangeTests {
  private static let oldPassword = "the old lock password"
  private static let newPassword = "the new lock password"
  private static let iterations = 100_000

  let sessions = WorkspaceLockSessions()
  let registry = LockRegistry()
  private let owner = OwnerDouble()
  let vault = UnlockPasswordVault(
    store: InMemoryPasswordStore(), minimumLength: UnlockPasswordVault.lockMinimumLength,
    iterations: 1_000)
  let directory: URL
  let defaults: UserDefaults
  let suiteName = "LockPasswordChangeTests.\(UUID().uuidString)"

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LockPasswordChangeTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defaults = try #require(UserDefaults(suiteName: suiteName))
    #expect(vault.setPassword(Self.oldPassword))
  }

  private func cleanUp() {
    try? FileManager.default.removeItem(at: directory)
    defaults.removePersistentDomain(forName: suiteName)
  }

  /// Locked workspaces kept apart from Recents, on this test's suite
  private var lockedList: LockedWorkspaceList { LockedWorkspaceList(defaults: defaults) }

  private func center(
    prompter: any UnlockPrompter = RefusingUnlockPrompter()
  ) -> LockCenter {
    LockCenter(
      registry: registry, lockVault: vault, prompter: prompter, ownerAuthenticator: owner,
      sessions: sessions, lockedWorkspaces: lockedList)
  }

  /// A content-key store over an in-memory Keychain domain (`passcodeSet` false: no item can
  /// be added, the Lock-password-only mode)
  private func keyStore(passcodeSet: Bool = true) -> LockKeyStore {
    LockKeyStore(
      vault: KeychainVault(
        service: LockKeyStore.serviceName, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        modern: OneServiceKeychain(), legacy: OneServiceKeychain()),
      modes: defaults, passcodeSet: { passcodeSet })
  }

  /// Waits until the owner was asked (a held prompt is open)
  private func untilPrompted() async {
    await owner.prompted()
  }

  /// A sealed workspace in `folder` with `.sql` tabs, its key wrapped with the old password, and
  /// its Recents entry (marked locked)
  private func sealedWorkspace(
    in folder: URL, tabs: [String]
  ) throws -> (session: WorkspaceLockSession, entry: WorkspaceHistoryEntry, files: [URL]) {
    let id = UUID()
    let key = SymmetricKey(size: .bits256)
    let block = try LockEnvelope.makeWrapBlock(
      contentKey: key, password: Self.oldPassword, workspaceId: id, iterations: Self.iterations)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var references: [WorkspaceTabReference] = []
    var files: [URL] = []
    for name in tabs {
      let url = folder.appendingPathComponent(name)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try LockEnvelope.seal(
        Data("SELECT \(name);".utf8), kind: .script, workspaceId: id, wrapBlock: block,
        contentKey: key
      ).write(to: url)
      references.append(WorkspaceTabReference(fileURL: url, documentType: .sqlFile, title: name))
      files.append(url)
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let url = folder.appendingPathComponent("ws.sqlws")
    try LockEnvelope.seal(
      encoder.encode(Workspace(id: id, name: "ws", tabs: references)), kind: .workspace,
      workspaceId: id, wrapBlock: block, contentKey: key
    ).write(to: url)
    var entry = WorkspaceHistoryEntry(id: id, fileURL: url, name: "ws")
    entry.isLocked = true
    return (
      WorkspaceLockSession(workspaceId: id, contentKey: key, wrapBlock: block), entry,
      [url] + files
    )
  }

  private func bytes(_ urls: [URL]) throws -> [Data] {
    try urls.map { try Data(contentsOf: $0) }
  }

  /// Whether `password` unwraps the key of the file at `url`
  private func opens(_ url: URL, with password: String, key: SymmetricKey) throws -> Bool {
    let header = try #require(try LockEnvelope.sniff(Data(contentsOf: url)))
    return (try? LockEnvelope.unwrapKey(header.wrapBlock, password: password)) == key
  }

  @Test("A wrong current Lock password re-seals nothing and keeps the old record")
  func wrongCurrentPasswordChangesNothing() async throws {
    defer { cleanUp() }
    let open = try sealedWorkspace(in: directory.appendingPathComponent("open"), tabs: ["a.sql"])
    sessions.hold(open.session, by: open.session.workspaceId)
    let before = try bytes(open.files)

    let result = await center().changeLockPassword(
      current: "not the password", new: Self.newPassword, workspaces: [open.entry],
      reason: "change", keyStore: keyStore(), iterations: Self.iterations)

    #expect(result == .wrongPassword)
    #expect(try bytes(open.files) == before)
    #expect(sessions.session(for: open.session.workspaceId)?.wrapBlock == open.session.wrapBlock)
    #expect(vault.verify(Self.oldPassword) == .accepted)
    #expect(owner.prompts == 0)
  }

  @Test("The current Lock password re-seals, then stores the new record; failed files are listed")
  func currentPasswordReseals() async throws {
    let closed = directory.appendingPathComponent("closed")
    let stuckFolder = closed.appendingPathComponent("stuck")
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: stuckFolder.path)
      cleanUp()
    }
    // Closed, no Keychain item: only the current password unwraps it
    let workspace = try sealedWorkspace(in: closed, tabs: ["b.sql", "stuck/c.sql"])
    let stuck = workspace.files[2]
    let stuckBefore = try Data(contentsOf: stuck)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: stuck.path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: stuckFolder.path)
    let vault = vault
    let oldPassword = Self.oldPassword
    let oldRecordDuringReseal = OSAllocatedUnfairLock(initialState: [Bool]())

    let result = await center().changeLockPassword(
      current: Self.oldPassword, new: Self.newPassword, workspaces: [workspace.entry],
      reason: "change", keyStore: keyStore(), iterations: Self.iterations
    ) { _, _ in
      let old = vault.verify(oldPassword) == .accepted
      oldRecordDuringReseal.withLock { $0.append(old) }
    }

    #expect(result == .changed(failures: [stuck]))
    // The new record is stored only once the re-seal is over
    let seen = oldRecordDuringReseal.withLock { $0 }
    #expect(!seen.isEmpty && seen.allSatisfy { $0 })
    #expect(vault.verify(Self.newPassword) == .accepted)
    let key = workspace.session.contentKey
    for url in workspace.files.prefix(2) {
      #expect(try opens(url, with: Self.newPassword, key: key))
    }
    // The file that failed is untouched: it still opens with the old password
    #expect(try Data(contentsOf: stuck) == stuckBefore)
    #expect(try opens(stuck, with: Self.oldPassword, key: key))
    #expect(owner.prompts == 0)
  }

  @Test("Without the current password the owner proves, and every workspace key must be here")
  func ownerAuthenticationNeedsEveryKey() async throws {
    defer { cleanUp() }
    let workspace = try sealedWorkspace(in: directory.appendingPathComponent("ws"), tabs: ["a.sql"])
    let store = keyStore()
    let before = try bytes(workspace.files)

    // No Keychain item and no open window: the current password is needed, nobody is asked
    var result = await center().changeLockPassword(
      current: nil, new: Self.newPassword, workspaces: [workspace.entry], reason: "change",
      keyStore: store, iterations: Self.iterations)
    #expect(result == .needsCurrentPassword)
    #expect(owner.prompts == 0)
    #expect(try bytes(workspace.files) == before)

    // Its key in this Mac's Keychain: the owner proves first; a refusal changes nothing
    _ = try store.store(workspace.session.contentKey, for: workspace.session.workspaceId)
    result = await center().changeLockPassword(
      current: "", new: Self.newPassword, workspaces: [workspace.entry], reason: "change",
      keyStore: store, iterations: Self.iterations)
    #expect(result == .notAuthenticated)
    #expect(owner.prompts == 1)
    #expect(try bytes(workspace.files) == before)
    #expect(vault.verify(Self.oldPassword) == .accepted)

    owner.grants = true
    result = await center().changeLockPassword(
      current: nil, new: Self.newPassword, workspaces: [workspace.entry], reason: "change",
      keyStore: store, iterations: Self.iterations)
    #expect(result == .changed(failures: []))
    #expect(owner.prompts == 2)
    for url in workspace.files {
      #expect(try opens(url, with: Self.newPassword, key: workspace.session.contentKey))
    }
    #expect(vault.verify(Self.newPassword) == .accepted)
  }

  @Test("Without the current password, an open relocked workspace with no key here is refused")
  func ownerPathRefusesRelockedPasswordOnlyWorkspace() async throws {
    defer { cleanUp() }
    let open = try sealedWorkspace(in: directory.appendingPathComponent("open"), tabs: ["a.sql"])
    let id = open.session.workspaceId
    sessions.hold(open.session, by: id)
    // Lock password only: no Keychain item can be added on this Mac
    let store = keyStore(passcodeSet: false)
    #expect(try store.store(open.session.contentKey, for: id) == .unavailable)
    // Relocked: locked and not unlocked in this session
    registry.registerWorkspace(id)
    #expect(registry.isBlocked(.workspace(id)))
    owner.grants = true
    let before = try bytes(open.files)

    let result = await center().changeLockPassword(
      current: nil, new: Self.newPassword, workspaces: [open.entry], reason: "change",
      keyStore: store, iterations: Self.iterations)

    #expect(result == .needsCurrentPassword)
    #expect(owner.prompts == 0)
    #expect(try bytes(open.files) == before)
    #expect(sessions.session(for: id)?.wrapBlock == open.session.wrapBlock)
    #expect(vault.verify(Self.oldPassword) == .accepted)
  }

  @Test("Removing the Lock password is refused while a locked workspace depends on it")
  func removeRefusedWhileWorkspacesDepend() async throws {
    defer { cleanUp() }
    var entry = WorkspaceHistoryEntry(
      fileURL: directory.appendingPathComponent("ws.sqlws"), name: "ws")
    entry.isLocked = true
    let center = center()

    #expect(
      await center.removeLockPassword(
        current: Self.oldPassword, workspaces: [entry], reason: "remove") == .workspacesDepend)
    #expect(vault.passwordState == .present)

    entry.isLocked = false
    #expect(
      await center.removeLockPassword(current: "wrong entry", workspaces: [entry], reason: "remove")
        == .wrongPassword)
    #expect(vault.passwordState == .present)
    #expect(
      await center.removeLockPassword(
        current: Self.oldPassword, workspaces: [entry], reason: "remove") == .removed)
    #expect(vault.passwordState == .absent)
  }

  @Test("A change re-seals a locked workspace that left Recents (the durable list)")
  func changeResealsWorkspaceOutsideRecents() async throws {
    defer { cleanUp() }
    let workspace = try sealedWorkspace(
      in: directory.appendingPathComponent("old"), tabs: ["a.sql"])
    lockedList.add(workspace.entry)

    let result = await center().changeLockPassword(
      current: Self.oldPassword, new: Self.newPassword, workspaces: [], reason: "change",
      keyStore: keyStore(), iterations: Self.iterations)

    #expect(result == .changed(failures: []))
    for url in workspace.files {
      #expect(try opens(url, with: Self.newPassword, key: workspace.session.contentKey))
    }
  }

  @Test("The durable list adds and removes one entry per workspace file")
  func durableListAddsAndRemoves() throws {
    defer { cleanUp() }
    let list = lockedList
    let id = UUID()
    let first = directory.appendingPathComponent("a.sqlws")
    let copy = directory.appendingPathComponent("copy.sqlws")
    list.add(WorkspaceHistoryEntry(id: id, fileURL: first, name: "a"))
    list.add(WorkspaceHistoryEntry(id: id, fileURL: first, name: "renamed"))
    list.add(WorkspaceHistoryEntry(id: id, fileURL: copy, name: "copy"))
    #expect(list.entries.map(\.name) == ["renamed", "copy"])
    #expect(list.entries.allSatisfy { $0.isLocked })
    // Recents' entry of the same file is not listed twice
    var recent = WorkspaceHistoryEntry(id: id, fileURL: first, name: "recent")
    recent.isLocked = true
    #expect(list.merged(with: [recent]).map(\.name) == ["recent", "copy"])

    list.remove(id: id, fileURL: first)
    #expect(list.entries.map(\.name) == ["copy"])
    // A locked Recents entry lands in the list too; Recents keeps only the latest few
    let recents = RecentManager(defaults: defaults)
    var other = WorkspaceHistoryEntry(
      fileURL: directory.appendingPathComponent("b.sqlws"), name: "b")
    other.isLocked = true
    recents.addWorkspace(other)
    #expect(list.entries.map(\.name) == ["copy", "b"])
  }

  @Test("Removal is refused while a listed workspace is sealed or unreadable; a gone file is not")
  func removeRefusedWhileDurableWorkspaceDepends() async throws {
    defer { cleanUp() }
    let workspace = try sealedWorkspace(in: directory.appendingPathComponent("old"), tabs: [])
    lockedList.add(workspace.entry)
    let center = center()

    #expect(
      await center.removeLockPassword(current: Self.oldPassword, workspaces: [], reason: "remove")
        == .workspacesDepend)
    #expect(vault.passwordState == .present)

    // A file that cannot be read cannot be checked: it still counts
    let path = workspace.entry.fileURL.path
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
    let unreadable = await center.removeLockPassword(
      current: Self.oldPassword, workspaces: [], reason: "remove")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    #expect(unreadable == .workspacesDepend)
    #expect(vault.passwordState == .present)

    try FileManager.default.removeItem(at: workspace.entry.fileURL)
    #expect(
      await center.removeLockPassword(current: Self.oldPassword, workspaces: [], reason: "remove")
        == .removed)
    #expect(vault.passwordState == .absent)
  }

  @Test("Removal checks the dependency again once the owner proved")
  func removeChecksAgainAfterOwnerPrompt() async throws {
    defer { cleanUp() }
    let registry = registry
    owner.grants = true
    owner.duringPrompt = { registry.registerWorkspace(UUID()) }

    let result = await center().removeLockPassword(current: nil, workspaces: [], reason: "remove")

    #expect(owner.prompts == 1)
    #expect(result == .workspacesDepend)
    #expect(vault.passwordState == .present)
  }

  @Test("A second change or removal is refused while one runs")
  func oneChangeAtATime() async throws {
    defer { cleanUp() }
    let center = center()
    owner.grants = true
    owner.holds = true
    let first = Task { await center.removeLockPassword(current: nil, workspaces: [], reason: "r") }
    await untilPrompted()

    #expect(
      await center.changeLockPassword(
        current: Self.oldPassword, new: Self.newPassword, workspaces: [], reason: "change",
        keyStore: keyStore(), iterations: Self.iterations) == .busy)
    #expect(
      await center.removeLockPassword(current: Self.oldPassword, workspaces: [], reason: "r")
        == .busy)
    // A first Lock password set meanwhile would be verified against a record about to go
    #expect(await center.setLockPassword("a first lock password", reason: "set") == .busy)
    #expect(vault.verify(Self.oldPassword) == .accepted)

    owner.release()
    #expect(await first.value == .removed)
    #expect(vault.passwordState == .absent)
  }

  @Test("Lock Workspace waits for a Lock password change or removal, and a change for it")
  func lockWorkspaceAndChangeExcludeEachOther() async throws {
    defer { cleanUp() }
    let center = center()
    // A Lock Workspace running: a change is refused before anything is asked or re-sealed
    #expect(center.beginWorkspaceLock())
    #expect(
      await center.changeLockPassword(
        current: Self.oldPassword, new: Self.newPassword, workspaces: [], reason: "change",
        keyStore: keyStore(), iterations: Self.iterations) == .busy)
    #expect(
      await center.removeLockPassword(current: Self.oldPassword, workspaces: [], reason: "r")
        == .busy)
    center.endWorkspaceLock()
    #expect(vault.verify(Self.oldPassword) == .accepted)

    // A removal running: Lock Workspace seals nothing (its password was checked against the
    // record that is going away)
    let url = directory.appendingPathComponent("ws.sqlws")
    let manager = WorkspaceManager(
      workspace: Workspace(name: "ws", fileURL: url), restoreTabs: false, defaults: defaults,
      sanitizesFileConfig: false)
    manager.recents = RecentManager(defaults: defaults)
    manager.lockedIO = LockedFileIO(sessions: sessions, registry: registry)
    owner.grants = true
    owner.holds = true
    let removal = Task {
      await center.removeLockPassword(current: nil, workspaces: [], reason: "r")
    }
    await untilPrompted()
    await #expect(throws: WorkspaceLockError.passwordChanging) {
      try await manager.lockWorkspace(
        password: Self.oldPassword, keyStore: keyStore(), iterations: Self.iterations,
        center: center)
    }
    #expect(manager.lockKeyId == nil)
    #expect(!registry.isLocked(.workspace(manager.workspace.id)))
    #expect(sessions.session(for: manager.workspace.id) == nil)
    #expect(lockedList.entries.isEmpty)
    owner.release()
    #expect(await removal.value == .removed)
    manager.releaseFileAccess()
  }

  @Test("A locked workspace that joins the durable list during a change is re-sealed too")
  func changeResealsWorkspaceAddedMeanwhile() async throws {
    defer { cleanUp() }
    let first = try sealedWorkspace(in: directory.appendingPathComponent("a"), tabs: ["a.sql"])
    let later = try sealedWorkspace(in: directory.appendingPathComponent("b"), tabs: ["b.sql"])
    let list = lockedList
    let added = OSAllocatedUnfairLock(initialState: false)
    let entry = later.entry

    let result = await center().changeLockPassword(
      current: Self.oldPassword, new: Self.newPassword, workspaces: [first.entry],
      reason: "change", keyStore: keyStore(), iterations: Self.iterations
    ) { _, _ in
      // Opened (and so listed) while the first workspace is re-sealed
      let isFirst = added.withLock { wasAdded in
        defer { wasAdded = true }
        return !wasAdded
      }
      if isFirst { list.add(entry) }
    }

    #expect(result == .changed(failures: []))
    for (workspace, files) in [(first, first.files), (later, later.files)] {
      for url in files {
        #expect(try opens(url, with: Self.newPassword, key: workspace.session.contentKey))
      }
    }
    #expect(vault.verify(Self.newPassword) == .accepted)
  }

  @Test("A file saved during a change keeps its newer content; one made plaintext is listed")
  func changeKeepsWritesMadeMeanwhile() async throws {
    defer { cleanUp() }
    let first = try sealedWorkspace(in: directory.appendingPathComponent("a"), tabs: ["a.sql"])
    let second = try sealedWorkspace(in: directory.appendingPathComponent("b"), tabs: ["b.sql"])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    // A save of the open window, sealed with the key the change keeps
    let newer = try LockEnvelope.seal(
      encoder.encode(
        Workspace(
          id: first.session.workspaceId, name: "newer",
          tabs: [
            WorkspaceTabReference(fileURL: first.files[1], documentType: .sqlFile, title: "a.sql")
          ])), kind: .workspace, workspaceId: first.session.workspaceId,
      wrapBlock: first.session.wrapBlock, contentKey: first.session.contentKey)
    // Its lock removed meanwhile (by an older Dblore): plaintext
    let plaintext = try encoder.encode(Workspace(id: second.session.workspaceId, name: "plain"))
    let (firstURL, secondURL) = (first.files[0], second.files[0])
    let seen = OSAllocatedUnfairLock(initialState: [Int: Int]())

    let result = await center().changeLockPassword(
      current: Self.oldPassword, new: Self.newPassword, workspaces: [first.entry, second.entry],
      reason: "change", keyStore: keyStore(), iterations: Self.iterations
    ) { done, _ in
      // The second report of a workspace: its key is ready, its files not written yet
      let count = seen.withLock { counts in
        counts[done, default: 0] += 1
        return counts[done] ?? 0
      }
      guard count == 2 else { return }
      if done == 0 { try? newer.write(to: firstURL, options: .atomic) }
      if done == 1 { try? plaintext.write(to: secondURL, options: .atomic) }
    }

    #expect(result == .changed(failures: [secondURL]))
    let key = first.session.contentKey
    for url in first.files {
      #expect(try opens(url, with: Self.newPassword, key: key))
    }
    let saved = try LockEnvelope.open(Data(contentsOf: firstURL), contentKey: key)
    #expect(String(decoding: saved, as: UTF8.self).contains("\"newer\""))
    // Left as it is now, never sealed again
    #expect(try Data(contentsOf: secondURL) == plaintext)
    #expect(try opens(second.files[1], with: Self.newPassword, key: second.session.contentKey))
  }

  @Test("Locked workspaces still joining after the last re-scan are listed as not re-sealed")
  func lateJoinersAreListed() async throws {
    defer { cleanUp() }
    let first = try sealedWorkspace(in: directory.appendingPathComponent("w0"), tabs: [])
    let joiners = try (1...4).map {
      try sealedWorkspace(in: directory.appendingPathComponent("w\($0)"), tabs: [])
    }
    let list = lockedList
    let entries = joiners.map(\.entry)
    let next = OSAllocatedUnfairLock(initialState: 0)

    let result = await center().changeLockPassword(
      current: Self.oldPassword, new: Self.newPassword, workspaces: [first.entry],
      reason: "change", keyStore: keyStore(), iterations: Self.iterations
    ) { done, total in
      // Each pass ends with done == total: one more workspace is opened (listed) meanwhile
      guard done == total else { return }
      let index = next.withLock { index in
        defer { index += 1 }
        return index
      }
      if index < entries.count { list.add(entries[index]) }
    }

    // Three re-scan passes re-seal the first three; the fourth joined during the last one
    #expect(result == .changed(failures: [joiners[3].files[0]]))
    for workspace in [first] + joiners.prefix(3) {
      #expect(
        try opens(workspace.files[0], with: Self.newPassword, key: workspace.session.contentKey))
    }
    #expect(
      try opens(joiners[3].files[0], with: Self.oldPassword, key: joiners[3].session.contentKey))
  }

  /// A saved workspace with one saved `.sql` tab, locked through `center` (key in the in-memory
  /// Keychain): the manager, its key store and the tab file
  private func lockedManager(
    _ center: LockCenter
  ) async throws -> (manager: WorkspaceManager, store: LockKeyStore, tab: URL) {
    let url = directory.appendingPathComponent("ws.sqlws")
    let manager = WorkspaceManager(
      workspace: Workspace(name: "ws", fileURL: url), restoreTabs: false, defaults: defaults,
      sanitizesFileConfig: false, lockCenter: center)
    manager.recents = RecentManager(defaults: defaults)
    manager.lockedIO = LockedFileIO(sessions: sessions, registry: registry)
    let tabId = manager.newSQLFile(content: "SELECT secret;")
    let tab = directory.appendingPathComponent("a.sql")
    let index = try #require(manager.tabs.firstIndex { $0.id == tabId })
    manager.tabs[index].fileURL = tab
    try await manager.saveTab(id: tabId)
    try await manager.saveWorkspace()
    let store = keyStore()
    _ = try await manager.lockWorkspace(
      password: Self.oldPassword, keyStore: store, iterations: Self.iterations, center: center)
    return (manager, store, tab)
  }

  @Test("Remove Lock is refused while the Lock password changes, and a change while it runs")
  func removeLockAndChangeExcludeEachOther() async throws {
    defer { cleanUp() }
    let center = center()
    let (manager, store, tab) = try await lockedManager(center)
    defer { manager.releaseFileAccess() }
    let id = manager.workspace.id
    let url = try #require(manager.workspace.fileURL)
    let confirmation = try #require(
      await center.authorizeRemoveLock(
        id, session: sessions.session(for: id), password: Self.oldPassword, reason: "remove"
      ).authorization)

    // A change running (its owner prompt open): Remove Lock writes nothing
    owner.holds = true
    let change = Task {
      await center.changeLockPassword(
        current: nil, new: Self.newPassword, workspaces: [], reason: "change", keyStore: store,
        iterations: Self.iterations)
    }
    await untilPrompted()
    let refused = await manager.removeLock(authorization: confirmation, keyStore: store)
    #expect(refused.map(\.reason) == [WorkspaceLockError.passwordChanging.errorDescription])
    #expect(manager.lockKeyId == id)
    #expect(LockedFileIO.isEnvelope(at: url))
    #expect(LockedFileIO.isEnvelope(at: tab))
    owner.release()
    #expect(await change.value == .notAuthenticated)

    // A Remove Lock running: a change is refused before anything is asked or re-sealed
    var during: Task<LockPasswordChangeResult, Never>?
    let removed = await manager.removeLock(authorization: confirmation, keyStore: store) {
      done, total in
      guard during == nil, done < total else { return }
      during = Task {
        await center.changeLockPassword(
          current: Self.oldPassword, new: Self.newPassword, workspaces: [], reason: "change",
          keyStore: store, iterations: Self.iterations)
      }
    }
    #expect(removed.isEmpty)
    #expect(manager.lockKeyId == nil)
    #expect(await during?.value == .busy)
    #expect(vault.verify(Self.oldPassword) == .accepted)
    #expect(owner.prompts == 1)
  }

  @Test("Auto-save of a locked workspace waits while the Lock password changes")
  func autoSaveWaitsForPasswordChange() async throws {
    defer { cleanUp() }
    let center = center()
    let (manager, store, _) = try await lockedManager(center)
    defer { manager.releaseFileAccess() }
    let url = try #require(manager.workspace.fileURL)
    let key = try #require(sessions.session(for: manager.workspace.id)).contentKey
    func savedName() throws -> String {
      String(
        decoding: try LockEnvelope.open(Data(contentsOf: url), contentKey: key), as: UTF8.self)
    }
    owner.holds = true
    let change = Task {
      await center.changeLockPassword(
        current: nil, new: Self.newPassword, workspaces: [], reason: "change", keyStore: store,
        iterations: Self.iterations)
    }
    await untilPrompted()

    manager.renameWorkspace(to: "renamed")
    try await Task.sleep(for: .milliseconds(1_600))
    #expect(manager.isDirty)
    #expect(try !savedName().contains("\"renamed\""))

    owner.release()
    #expect(await change.value == .notAuthenticated)
    let deadline = ContinuousClock.now + .seconds(5)
    while manager.isDirty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!manager.isDirty)
    #expect(try savedName().contains("\"renamed\""))
  }

  @Test("A listed workspace sealed with another password: no block with the current one; Forget")
  func foreignDurableWorkspace() async throws {
    defer { cleanUp() }
    // Sealed with another Lock password (another Mac's workspace), sniffed here, never unlocked
    let id = UUID()
    let url = directory.appendingPathComponent("foreign.sqlws")
    let block = try LockEnvelope.makeWrapBlock(
      contentKey: SymmetricKey(size: .bits256), password: "another mac's password",
      workspaceId: id, iterations: Self.iterations)
    try LockEnvelope.seal(
      Data("{}".utf8), kind: .workspace, workspaceId: id, wrapBlock: block,
      contentKey: SymmetricKey(size: .bits256)
    ).write(to: url)
    var foreign = WorkspaceHistoryEntry(id: id, fileURL: url, name: "foreign")
    foreign.isLocked = true
    lockedList.add(foreign)

    // Forget asks first: a refusal keeps it listed
    #expect(!(await center().forgetLockedWorkspace(foreign, reason: "forget", anchor: nil)))
    #expect(lockedList.entries.map(\.fileURL) == [url])
    // Without the current password nothing tells whose password wraps it: it still counts
    #expect(
      await center().removeLockPassword(current: nil, workspaces: [], reason: "remove")
        == .workspacesDepend)
    #expect(owner.prompts == 0)
    // The current Lock password does not unwrap it: it does not depend on this password
    #expect(
      await center().removeLockPassword(
        current: Self.oldPassword, workspaces: [], reason: "remove") == .removed)
    #expect(vault.passwordState == .absent)

    #expect(
      await center(prompter: FixedUnlockPrompter(grants: true)).forgetLockedWorkspace(
        foreign, reason: "forget", anchor: nil))
    #expect(lockedList.entries.isEmpty)
  }

  @Test("Relock Never asks the owner first; a refusal keeps the old value")
  func neverRelockAsksOwner() async throws {
    defer { cleanUp() }
    let settings = AppSettings(defaults: defaults)
    settings.lockIdleTimeout = .minutes15
    let model = LockSettingsModel(center: center(), defaults: defaults)

    await model.setIdleTimeout(.minutes30, in: settings)
    #expect(settings.lockIdleTimeout == .minutes30)
    #expect(owner.prompts == 0)

    await model.setIdleTimeout(.never, in: settings)
    #expect(owner.prompts == 1)
    #expect(settings.lockIdleTimeout == .minutes30)

    owner.grants = true
    await model.setIdleTimeout(.never, in: settings)
    #expect(owner.prompts == 2)
    #expect(settings.lockIdleTimeout == .never)
  }

  @Test("Locked items list every locked saved connection and follow lock changes")
  func lockedConnectionsFollowLockChanges() async throws {
    defer { cleanUp() }
    let sqlite = ConnectionConfig(
      databaseType: .sqlite, database: directory.appendingPathComponent("qa.sqlite").path,
      name: "qa")
    let duckdb = ConnectionConfig(
      databaseType: .duckdb, database: directory.appendingPathComponent("b6p18.duckdb").path,
      name: "b6p18")
    for config in [sqlite, duckdb] {
      SessionManager.saveConnection(
        config, defaults: defaults, passwords: NoPasswordStore(), registry: registry)
    }
    #expect(
      SessionManager.setLocked(
        true, for: LockIdentity(sqlite), defaults: defaults, registry: registry))
    let model = LockSettingsModel(center: center(), defaults: defaults)
    await model.load()
    #expect(model.lockedConnections.map(\.config.name) == ["qa"])

    // Locked while the section is open (another window's connection form): it shows up
    #expect(
      SessionManager.setLocked(
        true, for: LockIdentity(duckdb), defaults: defaults, registry: registry))
    let deadline = ContinuousClock.now + .seconds(5)
    while model.lockedConnections.count < 2, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(Set(model.lockedConnections.map(\.config.name)) == ["qa", "b6p18"])
  }
}
