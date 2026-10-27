// LockedWorkspaceIOTests.swift
// LockedFileIO is the only reader and writer of a locked workspace's files: a document with a lock
// key id is always written as an envelope (never plaintext, even when sealing fails), and an
// envelope opens with the workspace's session key or only after an unlock. No Keychain, no prompt:
// sessions live in an injected store and the unlock is a stub.

import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing
import os

@testable import Dblore

@Suite("Locked Workspace IO")
struct LockedWorkspaceIOTests {
  let workspaceId = UUID()
  let session: WorkspaceLockSession
  let sessions = WorkspaceLockSessions()
  let directory: URL

  init() throws {
    let key = SymmetricKey(size: .bits256)
    let block = try LockEnvelope.makeWrapBlock(
      contentKey: key, password: "a lock password", workspaceId: workspaceId,
      iterations: 100_000)
    session = WorkspaceLockSession(workspaceId: workspaceId, contentKey: key, wrapBlock: block)
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LockedWorkspaceIOTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  private var io: LockedFileIO { LockedFileIO(sessions: sessions, registry: LockRegistry()) }

  @Test("A locked document round-trips through an envelope with the session key")
  func roundTripWithSessionKey() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("query.sql")
    let text = Data("SELECT secret FROM vault;\n".utf8)
    sessions.hold(session, by: workspaceId)

    try await io.write(text, kind: .script, lockKeyId: workspaceId, to: url)

    let onDisk = try Data(contentsOf: url)
    #expect(onDisk.prefix(LockEnvelope.magic.count).elementsEqual(LockEnvelope.magic))
    #expect(onDisk.range(of: Data("secret".utf8)) == nil)
    let read = try await io.read(from: url) { _ in
      Issue.record("an open session must not ask")
      return nil
    }
    #expect(read.plaintext == text)
    #expect(read.session?.workspaceId == workspaceId)

    // A document without a lock key id stays plaintext
    let plainURL = directory.appendingPathComponent("plain.sql")
    try await io.write(text, kind: .script, lockKeyId: nil, to: plainURL)
    #expect(try Data(contentsOf: plainURL) == text)
    #expect(try await io.read(from: plainURL) { _ in nil }.session == nil)
  }

  @Test("A seal error writes nothing: no session, or a key the envelope refuses")
  func noPlaintextFallback() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("notebook.dblore")
    let before = Data("previous envelope".utf8)
    try before.write(to: url)
    let text = Data("{\"cells\":[]}".utf8)

    // The last holder released the session: the key is gone
    sessions.hold(session, by: workspaceId)
    sessions.release(holder: workspaceId)
    #expect(sessions.session(for: workspaceId) == nil)
    await #expect(throws: LockedFileIOError.sessionMissing(workspaceId)) {
      try await io.write(text, kind: .notebook, lockKeyId: workspaceId, to: url)
    }

    let weak = WorkspaceLockSession(
      workspaceId: workspaceId, contentKey: SymmetricKey(size: .bits128),
      wrapBlock: session.wrapBlock)
    sessions.hold(weak, by: workspaceId)
    await #expect(throws: LockEnvelopeError.invalidContentKey) {
      try await io.write(text, kind: .notebook, lockKeyId: workspaceId, to: url)
    }
    #expect(try Data(contentsOf: url) == before)
  }

  @Test("The synchronous quit seal copies the wrap block and opens with the session key")
  func sealPayloadOpensWithSessionKey() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    sessions.hold(session, by: workspaceId)
    let text = Data("{\"tabs\":[]}".utf8)

    let sealed = try io.sealPayload(text, kind: .workspace, lockKeyId: workspaceId)

    let header = try #require(try LockEnvelope.sniff(sealed))
    #expect(header.kind == .workspace)
    #expect(header.wrapBlock == session.wrapBlock)
    #expect(try LockEnvelope.open(sealed, contentKey: session.contentKey) == text)
  }

  @Test("An envelope without an open session asks; a refused unlock opens nothing")
  func readWithoutSessionAsks() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("notes.md")
    let text = Data("# secret".utf8)
    let sealed = try LockEnvelope.seal(
      text, kind: .markdown, workspaceId: workspaceId, wrapBlock: session.wrapBlock,
      contentKey: session.contentKey)
    try sealed.write(to: url)

    await #expect(throws: LockedFileIOError.unlockRefused(workspaceId)) {
      try await io.read(from: url) { _ in nil }
    }

    let session = self.session
    let read = try await io.read(from: url) { header in
      header.workspaceId == session.workspaceId ? session : nil
    }
    #expect(read.plaintext == text)
    #expect(read.session?.workspaceId == workspaceId)

    // Relocked: the session key stays for autosave, but a read asks again
    sessions.hold(session, by: workspaceId)
    let registry = LockRegistry()
    registry.registerWorkspace(workspaceId)
    let relocked = LockedFileIO(sessions: sessions, registry: registry)
    await #expect(throws: LockedFileIOError.unlockRefused(workspaceId)) {
      try await relocked.read(from: url) { _ in nil }
    }
  }

  @Test("A read expecting one kind refuses an envelope of another kind before asking")
  func readRefusesOtherKind() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("query.sql")
    let text = Data("SELECT 1;".utf8)
    try LockEnvelope.seal(
      text, kind: .script, workspaceId: workspaceId, wrapBlock: session.wrapBlock,
      contentKey: session.contentKey
    ).write(to: url)

    await #expect(throws: LockedFileIOError.wrongKind) {
      try await io.read(from: url, kind: .workspace) { _ in
        Issue.record("a mismatched kind must not ask")
        return nil
      }
    }
    let session = self.session
    #expect(try await io.read(from: url, kind: .script) { _ in session }.plaintext == text)
  }

  // MARK: - Read sites

  private func sealed(_ text: Data, _ kind: LockEnvelope.Kind) throws -> Data {
    try LockEnvelope.seal(
      text, kind: kind, workspaceId: workspaceId, wrapBlock: session.wrapBlock,
      contentKey: session.contentKey)
  }

  /// A sealed .sqlws named "Secret" with one sealed .sql tab
  @MainActor private func sealedWorkspace() throws -> (url: URL, tabId: UUID) {
    let tabURL = directory.appendingPathComponent("query.sql")
    try sealed(Data("SELECT secret;".utf8), .script).write(to: tabURL)
    let tab = WorkspaceTabReference(fileURL: tabURL, documentType: .sqlFile, title: "query.sql")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = try encoder.encode(Workspace(id: workspaceId, name: "Secret", tabs: [tab]))
    let url = directory.appendingPathComponent("ws.sqlws")
    try sealed(json, .workspace).write(to: url)
    return (url, tab.id)
  }

  /// Hooks that never touch real bookmarks or show a panel
  @MainActor private var hooks: SecurityScopedAccessHooks {
    var hooks = SecurityScopedAccessHooks()
    hooks.makeBookmark = { _ in nil }
    hooks.chooseFile = { _ in nil }
    hooks.chooseFolder = { _ in nil }
    return hooks
  }

  /// An unlock that counts its calls and answers `session`
  private func unlock(
    _ asks: OSAllocatedUnfairLock<Int>, answering session: WorkspaceLockSession?
  ) -> LockedFileIO.Unlock {
    { _ in
      asks.withLock { $0 += 1 }
      return session
    }
  }

  @Test("Loading a sealed workspace asks, opens it and its tabs; a refusal decodes nothing")
  @MainActor
  func loadOpensSealedWorkspace() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let (url, tabId) = try sealedWorkspace()
    let asks = OSAllocatedUnfairLock(initialState: 0)

    await #expect(throws: LockedFileIOError.unlockRefused(workspaceId)) {
      try await WorkspaceManager.load(
        from: url, hooks: hooks, lockedIO: io, unlock: unlock(asks, answering: nil))
    }
    #expect(asks.withLock { $0 } == 1)
    #expect(sessions.session(for: workspaceId) == nil)

    let manager = try await WorkspaceManager.load(
      from: url, hooks: hooks, lockedIO: io, unlock: unlock(asks, answering: session))

    // One ask for the .sqlws; its tab opens with the session the manager now holds
    #expect(asks.withLock { $0 } == 2)
    #expect(manager.workspace.name == "Secret")
    #expect(manager.lockKeyId == workspaceId)
    let document = try #require(manager.editorDocument(for: tabId))
    #expect(document.content == "SELECT secret;")
    #expect(document.lockKeyId == workspaceId)
    #expect(sessions.session(for: workspaceId) != nil)

    // Closing the workspace releases its hold, so the key leaves memory
    manager.releaseFileAccess()
    #expect(sessions.session(for: workspaceId) == nil)
  }

  @Test("A sealed tab file opened alone asks; a refusal adds no tab")
  @MainActor
  func openFileOfSealedTabAsks() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("alone.sql")
    try sealed(Data("SELECT 1;".utf8), .script).write(to: url)
    let suiteName = "LockedWorkspaceIOTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let manager = WorkspaceManager(workspace: Workspace(name: "Plain"), restoreTabs: false)
    manager.recents = RecentManager(defaults: defaults)
    manager.accessHooks = hooks
    manager.lockedIO = io
    let asks = OSAllocatedUnfairLock(initialState: 0)

    manager.unlockLockedFile = unlock(asks, answering: nil)
    await #expect(throws: LockedFileIOError.unlockRefused(workspaceId)) {
      try await manager.openFile(url: url)
    }
    #expect(manager.tabs.isEmpty)

    manager.unlockLockedFile = unlock(asks, answering: session)
    try await manager.openFile(url: url)

    #expect(asks.withLock { $0 } == 2)
    let tab = try #require(manager.tabs.first)
    let document = try #require(manager.editorDocument(for: tab.id))
    #expect(document.content == "SELECT 1;")
    // The tab keeps the key of the workspace that sealed it, not this plain one's
    #expect(document.lockKeyId == workspaceId)
    #expect(manager.lockKeyId == nil)
    manager.releaseFileAccess()
    #expect(sessions.session(for: workspaceId) == nil)
  }

  @Test("Reloading a sealed notebook or script from disk opens it and keeps its lock key id")
  @MainActor
  func reloadFromDiskOpensEnvelope() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let holder = UUID()
    let notebookURL = directory.appendingPathComponent("book.dblore")
    let notebook = DbloreNotebook(cells: [NotebookCell(cellType: .sql, content: "SELECT 2;")])
    try sealed(DocumentCoder.encode(notebook, includeResultsOnSave: false), .notebook)
      .write(to: notebookURL)
    let scriptURL = directory.appendingPathComponent("script.sql")
    try sealed(Data("SELECT 3;".utf8), .script).write(to: scriptURL)
    let asks = OSAllocatedUnfairLock(initialState: 0)

    let book = DbloreDocument(notebook: DbloreNotebook(cells: []))
    book.setFileURL(notebookURL)
    defer { book.setFileURL(nil) }
    let script = SQLEditorDocument(content: "")
    script.setFileURL(scriptURL)
    defer { script.setFileURL(nil) }

    await #expect(throws: LockedFileIOError.unlockRefused(workspaceId)) {
      try await script.reloadFromDisk(holder: holder, io: io, unlock: unlock(asks, answering: nil))
    }
    #expect(script.content == "")

    try await book.reloadFromDisk(holder: holder, io: io, unlock: unlock(asks, answering: session))
    try await script.reloadFromDisk(holder: holder, io: io, unlock: unlock(asks, answering: nil))

    // The notebook's unlock opened the session the script then reads with
    #expect(asks.withLock { $0 } == 2)
    #expect(book.notebook.cells.map(\.content) == ["SELECT 2;"])
    #expect(book.lockKeyId == workspaceId)
    #expect(script.content == "SELECT 3;")
    #expect(script.lockKeyId == workspaceId)
    sessions.release(holder: holder)
    #expect(sessions.session(for: workspaceId) == nil)
  }

  @Test("A sealed notebook or script replaced on disk by plaintext keeps its lock key id")
  @MainActor
  func reloadOfPlaintextReplacementKeepsKey() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let holder = UUID()
    sessions.hold(session, by: holder)
    defer { sessions.release(holder: holder) }
    let notebookURL = directory.appendingPathComponent("book.dblore")
    let notebook = DbloreNotebook(cells: [NotebookCell(cellType: .sql, content: "SELECT 2;")])
    try sealed(DocumentCoder.encode(notebook, includeResultsOnSave: false), .notebook)
      .write(to: notebookURL)
    let scriptURL = directory.appendingPathComponent("script.sql")
    try sealed(Data("SELECT 3;".utf8), .script).write(to: scriptURL)
    let asks = OSAllocatedUnfairLock(initialState: 0)
    let book = DbloreDocument(notebook: DbloreNotebook(cells: []))
    book.setFileURL(notebookURL)
    defer { book.setFileURL(nil) }
    let script = SQLEditorDocument(content: "")
    script.setFileURL(scriptURL)
    defer { script.setFileURL(nil) }
    try await book.reloadFromDisk(holder: holder, io: io, unlock: unlock(asks, answering: nil))
    try await script.reloadFromDisk(holder: holder, io: io, unlock: unlock(asks, answering: nil))

    // Another app replaces both sealed files with plaintext
    let replaced = DbloreNotebook(cells: [NotebookCell(cellType: .sql, content: "SELECT 4;")])
    try DocumentCoder.encode(replaced, includeResultsOnSave: false).write(to: notebookURL)
    try Data("SELECT 5;".utf8).write(to: scriptURL)
    try await book.reloadFromDisk(holder: holder, io: io, unlock: unlock(asks, answering: nil))
    try await script.reloadFromDisk(holder: holder, io: io, unlock: unlock(asks, answering: nil))

    #expect(asks.withLock { $0 } == 0)
    #expect(book.notebook.cells.map(\.content) == ["SELECT 4;"])
    #expect(book.lockKeyId == workspaceId)
    #expect(script.content == "SELECT 5;")
    #expect(script.lockKeyId == workspaceId)
    // So their next save seals again
    try await io.write(
      Data(script.content.utf8), kind: .script, lockKeyId: script.lockKeyId, to: scriptURL)
    #expect(
      String(decoding: try opened(Data(contentsOf: scriptURL), kind: .script), as: UTF8.self)
        == "SELECT 5;")
  }

  @Test("Renaming a locked recent asks and returns plaintext JSON; it never seals")
  @MainActor
  func renamedDataOfLockedRecent() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let (url, _) = try sealedWorkspace()
    let onDisk = try Data(contentsOf: url)
    let asks = OSAllocatedUnfairLock(initialState: 0)

    await #expect(throws: LockedFileIOError.unlockRefused(workspaceId)) {
      try await RecentWorkspaceEditor.renamedData(
        onDisk, name: "Renamed", io: io, unlock: unlock(asks, answering: nil))
    }

    let renamed = try await RecentWorkspaceEditor.renamedData(
      onDisk, name: "Renamed", io: io, unlock: unlock(asks, answering: session))

    #expect(try LockEnvelope.sniff(renamed.plaintext) == nil)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let workspace = try decoder.decode(Workspace.self, from: renamed.plaintext)
    #expect(workspace.name == "Renamed")
    #expect(workspace.id == workspaceId)
    #expect(renamed.session?.workspaceId == workspaceId)
    #expect(try Data(contentsOf: url) == onDisk)
  }

  // MARK: - Write sites

  /// A manager writing through `io`: no real bookmarks, recents or panel
  @MainActor private func writingManager(
    _ workspace: Workspace, defaults: UserDefaults
  ) -> WorkspaceManager {
    let manager = WorkspaceManager(
      workspace: workspace, restoreTabs: false, defaults: defaults, sanitizesFileConfig: false)
    manager.recents = RecentManager(defaults: defaults)
    manager.accessHooks = hooks
    manager.lockedIO = io
    return manager
  }

  /// The plaintext of one envelope of `kind` (exactly one layer: the plaintext is no envelope)
  private func opened(
    _ onDisk: Data, kind: LockEnvelope.Kind, key: SymmetricKey? = nil
  ) throws -> Data {
    let header = try #require(try LockEnvelope.sniff(onDisk))
    #expect(header.kind == kind)
    #expect(onDisk.range(of: Data("secret".utf8)) == nil)
    let plaintext = try LockEnvelope.open(onDisk, contentKey: key ?? session.contentKey)
    #expect(try LockEnvelope.sniff(plaintext) == nil)
    return plaintext
  }

  @MainActor private func decodedWorkspace(_ data: Data) throws -> Workspace {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Workspace.self, from: data)
  }

  @Test("The quit flush of a locked workspace writes an envelope; without its key nothing")
  @MainActor
  func quitFlushSealsWorkspace() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "LockedWorkspaceIOTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let url = directory.appendingPathComponent("ws.sqlws")
    let manager = writingManager(
      Workspace(id: workspaceId, name: "secret", fileURL: url), defaults: defaults)
    manager.lockKeyId = workspaceId
    sessions.hold(session, by: manager.id)
    manager.isDirty = true

    manager.flushToExistingFile()

    let plaintext = try opened(Data(contentsOf: url), kind: .workspace)
    #expect(try decodedWorkspace(plaintext).name == "secret")
    #expect(!manager.isDirty)

    // The key left memory: the file is kept as is, never rewritten as plaintext
    manager.releaseFileAccess()
    let before = Data("previous envelope".utf8)
    try before.write(to: url)
    manager.isDirty = true
    manager.flushToExistingFile()
    #expect(try Data(contentsOf: url) == before)
    #expect(manager.isDirty)
  }

  @Test("Save As of a locked workspace keeps the lock at the new place")
  @MainActor
  func workspaceSaveAsKeepsLock() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "LockedWorkspaceIOTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let url = directory.appendingPathComponent("ws.sqlws")
    let manager = writingManager(
      Workspace(id: workspaceId, name: "ws", fileURL: url), defaults: defaults)
    manager.lockKeyId = workspaceId
    sessions.hold(session, by: manager.id)

    try await manager.saveWorkspace()
    let copy = directory.appendingPathComponent("secret copy.sqlws")
    try await manager.saveWorkspaceAs(url: copy)

    #expect(try decodedWorkspace(opened(Data(contentsOf: url), kind: .workspace)).name == "ws")
    let saved = try decodedWorkspace(opened(Data(contentsOf: copy), kind: .workspace))
    #expect(saved.name == "secret copy")
    #expect(saved.id == workspaceId)
    manager.releaseFileAccess()
  }

  @Test("Each tab save seals a document with a key id: notebook, .sql, MongoDB .js and .md")
  @MainActor
  func tabSavesSealLockedDocuments() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "LockedWorkspaceIOTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let mongo = ConnectionConfig(
      databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    // A plain workspace: each document keeps the key of the workspace that sealed it
    let manager = writingManager(
      Workspace(name: "Plain", connectionConfig: mongo), defaults: defaults)
    sessions.hold(session, by: manager.id)
    let notebookId = manager.newNotebook()
    try #require(manager.viewModel(for: notebookId)).notebook = DbloreNotebook(
      cells: [NotebookCell(cellType: .sql, content: "SELECT secret;")])
    let scriptId = manager.newSQLFile(content: "db.secret.find()")
    let sqlId = manager.newSQLFile(content: "SELECT secret;")
    let markdownId = manager.newMarkdownFile()
    try #require(manager.viewModel(for: markdownId)).editorContent = "# secret note"
    let plainId = manager.newSQLFile(content: "SELECT 1;")
    let rows: [(id: UUID, file: String, kind: LockEnvelope.Kind, text: String)] = [
      (notebookId, "book.dblore", .notebook, "SELECT secret;"),
      (scriptId, "find.js", .script, "db.secret.find()"),
      (sqlId, "query.sql", .script, "SELECT secret;"),
      (markdownId, "note.md", .markdown, "# secret note"),
    ]

    for row in rows {
      manager.notebookDocument(for: row.id)?.lockKeyId = workspaceId
      manager.editorDocument(for: row.id)?.lockKeyId = workspaceId
      let url = directory.appendingPathComponent(row.file)
      try pointTab(manager, row.id, to: url)
      try await manager.saveTab(id: row.id)

      let plaintext = try opened(Data(contentsOf: url), kind: row.kind)
      if row.kind == .notebook {
        #expect(try DocumentCoder.decode(from: plaintext).cells.map(\.content) == [row.text])
      } else {
        #expect(String(decoding: plaintext, as: UTF8.self) == row.text)
      }
      #expect(manager.tabs.first { $0.id == row.id }?.isDirty == false)
    }

    // No key id: plaintext as before
    let plainURL = directory.appendingPathComponent("plain.sql")
    try pointTab(manager, plainId, to: plainURL)
    try await manager.saveTab(id: plainId)
    #expect(try Data(contentsOf: plainURL) == Data("SELECT 1;".utf8))
    manager.releaseFileAccess()
  }

  @Test("A tab save whose key is gone writes nothing and the tab stays dirty")
  @MainActor
  func tabSaveWithoutSessionStaysDirty() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "LockedWorkspaceIOTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let manager = writingManager(Workspace(name: "Plain"), defaults: defaults)
    let id = manager.newSQLFile(content: "SELECT secret;")
    manager.editorDocument(for: id)?.lockKeyId = workspaceId
    let url = directory.appendingPathComponent("query.sql")
    try pointTab(manager, id, to: url)

    await #expect(throws: LockedFileIOError.sessionMissing(workspaceId)) {
      try await manager.saveTab(id: id)
    }

    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(manager.tabs.first { $0.id == id }?.isDirty == true)
  }

  /// Points the tab at `url`, as the save panel does
  @MainActor private func pointTab(_ manager: WorkspaceManager, _ id: UUID, to url: URL) throws {
    let index = try #require(manager.tabs.firstIndex { $0.id == id })
    manager.tabs[index].fileURL = url
  }

  @Test(
    "The Keychain unlock registers the workspace before granting it; no stored key never prompts")
  @MainActor
  func keychainUnlockRegistersBeforeGrant() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "LockedWorkspaceIOTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keychain = OneServiceKeychain()
    let keyStore = LockKeyStore(
      vault: KeychainVault(
        service: LockKeyStore.serviceName, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        modern: keychain, legacy: OneServiceKeychain()),
      modes: defaults, passcodeSet: { true })
    let registry = LockRegistry()
    let owner = CountingOwnerAuthenticator()
    let header = try #require(try LockEnvelope.sniff(sealed(Data("{}".utf8), .workspace)))
    let center = LockCenter(
      registry: registry, lockVault: .lockPassword(store: InMemoryPasswordStore()),
      prompter: RefusingUnlockPrompter(), ownerAuthenticator: owner)
    let unlock = LockedFileIO.keychainUnlock(
      reason: "open a test", center: center, keyStore: keyStore)

    // No key stored on this Mac: refused without a prompt, but the workspace is registered
    #expect(await unlock(header) == nil)
    #expect(owner.prompts == 0)
    #expect(registry.isBlocked(.workspace(workspaceId)))

    _ = try keyStore.store(session.contentKey, for: workspaceId)
    // A relock while the prompt is open voids the grant
    owner.duringPrompt = { registry.relockAll() }
    #expect(await unlock(header) == nil)
    #expect(registry.isBlocked(.workspace(workspaceId)))

    owner.duringPrompt = {}
    let opened = try #require(await unlock(header))
    #expect(owner.prompts == 2)
    #expect(opened.workspaceId == workspaceId)
    #expect(opened.wrapBlock == session.wrapBlock)
    #expect(opened.contentKey == session.contentKey)
    #expect(!registry.isBlocked(.workspace(workspaceId)))
  }

  // MARK: - Lock Workspace and Remove Lock

  private static let lockPassword = "a lock password"

  /// The owner's Remove Lock confirmation (the Debug owner double, no prompt)
  @MainActor private func ownerConfirmation(
    _ manager: WorkspaceManager
  ) async throws -> RemoveLockAuthorization {
    let center = LockCenter(
      registry: LockRegistry(), lockVault: .lockPassword(store: InMemoryPasswordStore()),
      prompter: RefusingUnlockPrompter(), ownerAuthenticator: GrantingOwnerTestAuthenticator())
    return try #require(
      await center.authorizeRemoveLock(
        manager.workspace.id, session: nil, password: nil, reason: "remove the lock"
      ).authorization)
  }

  /// A content-key store over an in-memory Keychain; `passcodeSet: false` is the
  /// Lock-password-only branch (no Keychain item can be made)
  private func keyStore(
    _ defaults: UserDefaults, passcodeSet: Bool = true
  ) -> (store: LockKeyStore, keychain: OneServiceKeychain) {
    let keychain = OneServiceKeychain()
    let store = LockKeyStore(
      vault: KeychainVault(
        service: LockKeyStore.serviceName, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        modern: keychain, legacy: OneServiceKeychain()),
      modes: defaults, passcodeSet: { passcodeSet })
    return (store, keychain)
  }

  /// A saved MongoDB workspace with a notebook, a .js script and a .md tab, all plaintext on disk
  /// (`workspaceFolder`: where the .sqlws goes, default the test's directory)
  @MainActor private func plainWorkspace(
    _ registry: LockRegistry, defaults: UserDefaults, workspaceFolder: URL? = nil
  ) async throws -> (manager: WorkspaceManager, files: [(url: URL, kind: LockEnvelope.Kind)]) {
    let mongo = ConnectionConfig(
      databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    let url = (workspaceFolder ?? directory).appendingPathComponent("ws.sqlws")
    let manager = writingManager(
      Workspace(name: "ws", fileURL: url, connectionConfig: mongo), defaults: defaults)
    manager.lockedIO = LockedFileIO(sessions: sessions, registry: registry)
    let notebookId = manager.newNotebook()
    try #require(manager.viewModel(for: notebookId)).notebook = DbloreNotebook(
      cells: [NotebookCell(cellType: .sql, content: "SELECT secret;")])
    let scriptId = manager.newSQLFile(content: "db.secret.find()")
    let markdownId = manager.newMarkdownFile()
    try #require(manager.viewModel(for: markdownId)).editorContent = "# secret note"
    var files: [(url: URL, kind: LockEnvelope.Kind)] = [(url, .workspace)]
    for (id, file, kind) in [
      (notebookId, "book.dblore", LockEnvelope.Kind.notebook), (scriptId, "find.js", .script),
      (markdownId, "note.md", .markdown),
    ] {
      let tabURL = directory.appendingPathComponent(file)
      try pointTab(manager, id, to: tabURL)
      try await manager.saveTab(id: id)
      files.append((tabURL, kind))
    }
    try await manager.saveWorkspace()
    for file in files {
      #expect(try LockEnvelope.sniff(Data(contentsOf: file.url)) == nil)
    }
    return (manager, files)
  }

  @Test("Lock Workspace seals the .sqlws and every tab file; later writes and new tabs seal too")
  @MainActor
  func lockWorkspaceSealsEveryFile() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "LockedWorkspaceIOTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let registry = LockRegistry()
    let (manager, files) = try await plainWorkspace(registry, defaults: defaults)
    let (store, _) = keyStore(defaults)
    var steps: [Int] = []

    let report = try await manager.lockWorkspace(
      password: Self.lockPassword, keyStore: store, iterations: 100_000
    ) { done, total in
      #expect(total == files.count)
      steps.append(done)
    }

    let id = manager.workspace.id
    #expect(report.failures.isEmpty)
    #expect(report.mode == .presence)
    #expect(steps == Array(1...files.count))
    #expect(manager.lockKeyId == id)
    #expect(store.mode(for: id) == .presence)
    // Registered, then granted: this window keeps working until the next relock
    #expect(registry.isLocked(.workspace(id)))
    #expect(!registry.isBlocked(.workspace(id)))
    #expect(manager.recents.recentWorkspaces.first?.isLocked == true)
    let key = try #require(sessions.session(for: id)).contentKey
    for file in files {
      let onDisk = try Data(contentsOf: file.url)
      _ = try opened(onDisk, kind: file.kind, key: key)
      // The Lock password alone opens every file (the portable path)
      let header = try #require(try LockEnvelope.sniff(onDisk))
      #expect(try LockEnvelope.unwrapKey(header.wrapBlock, password: Self.lockPassword) == key)
    }

    // A tab created after the lock seals on its first save; the quit flush seals the .sqlws
    let newId = manager.newSQLFile(content: "SELECT secret;")
    let newURL = directory.appendingPathComponent("later.js")
    try pointTab(manager, newId, to: newURL)
    try await manager.saveTab(id: newId)
    _ = try opened(Data(contentsOf: newURL), kind: .script, key: key)
    manager.isDirty = true
    manager.flushToExistingFile()
    _ = try opened(Data(contentsOf: files[0].url), kind: .workspace, key: key)
    manager.releaseFileAccess()
  }

  @Test("Without the Keychain, Lock Workspace still seals with the Lock password wrap")
  @MainActor
  func lockWorkspaceWithoutKeychainSealsWithPassword() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "LockedWorkspaceIOTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let url = directory.appendingPathComponent("ws.sqlws")
    let manager = writingManager(Workspace(name: "ws", fileURL: url), defaults: defaults)
    manager.lockedIO = LockedFileIO(sessions: sessions, registry: LockRegistry())
    try await manager.saveWorkspace()
    let (store, keychain) = keyStore(defaults, passcodeSet: false)

    let report = try await manager.lockWorkspace(
      password: Self.lockPassword, keyStore: store, iterations: 100_000)

    #expect(report.mode == .unavailable)
    #expect(report.failures.isEmpty)
    #expect(keychain.isEmpty)
    let onDisk = try Data(contentsOf: url)
    let header = try #require(try LockEnvelope.sniff(onDisk))
    let key = try LockEnvelope.unwrapKey(header.wrapBlock, password: Self.lockPassword)
    #expect(try decodedWorkspace(opened(onDisk, kind: .workspace, key: key)).name == "ws")
    manager.releaseFileAccess()
  }

  @Test("Remove Lock writes plaintext and forgets the key; a file it cannot write keeps the lock")
  @MainActor
  func removeLockWritesPlaintext() async throws {
    let readOnly = directory.appendingPathComponent("read-only", isDirectory: true)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
      try? FileManager.default.removeItem(at: directory)
    }
    let suiteName = "LockedWorkspaceIOTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let registry = LockRegistry()
    let (manager, plainFiles) = try await plainWorkspace(registry, defaults: defaults)
    var files = plainFiles
    // One more tab, in a folder that can be made read-only
    try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
    let stuckId = manager.newSQLFile(content: "SELECT stuck;")
    let stuckURL = readOnly.appendingPathComponent("stuck.js")
    try pointTab(manager, stuckId, to: stuckURL)
    try await manager.saveTab(id: stuckId)
    files.append((stuckURL, .script))
    let (store, keychain) = keyStore(defaults)
    _ = try await manager.lockWorkspace(
      password: Self.lockPassword, keyStore: store, iterations: 100_000)
    let id = manager.workspace.id
    let sealed = try files.map { try Data(contentsOf: $0.url) }

    // A file that cannot be written: nothing is forgotten, the workspace stays locked
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: stuckURL.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
    let confirmation = try await ownerConfirmation(manager)
    let failed = await manager.removeLock(authorization: confirmation, keyStore: store)
    #expect(failed.map(\.url) == [stuckURL])
    #expect(manager.lockKeyId == id)
    #expect(manager.editorDocument(for: stuckId)?.lockKeyId == id)
    #expect(!keychain.isEmpty)
    #expect(registry.isLocked(.workspace(id)))
    #expect(sessions.session(for: id) != nil)
    #expect(try Data(contentsOf: files[0].url) == sealed[0])
    #expect(try Data(contentsOf: stuckURL) == sealed.last)
    // The tab files it had already written are sealed again
    for file in files.dropFirst() {
      #expect(try LockEnvelope.sniff(Data(contentsOf: file.url)) != nil)
    }

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stuckURL.path)
    let retryConfirmation = try await ownerConfirmation(manager)
    #expect(await manager.removeLock(authorization: retryConfirmation, keyStore: store).isEmpty)

    for file in files {
      let onDisk = try Data(contentsOf: file.url)
      #expect(try LockEnvelope.sniff(onDisk) == nil)
    }
    #expect(
      try String(decoding: Data(contentsOf: files[2].url), as: UTF8.self) == "db.secret.find()")
    #expect(try decodedWorkspace(Data(contentsOf: files[0].url)).name == "ws")
    #expect(manager.lockKeyId == nil)
    #expect(manager.editorDocument(for: stuckId)?.lockKeyId == nil)
    #expect(keychain.isEmpty)
    #expect(store.mode(for: id) == nil)
    #expect(!registry.isLocked(.workspace(id)))
    #expect(sessions.session(for: id) == nil)
    #expect(manager.recents.recentWorkspaces.first?.isLocked == false)
    // Later saves stay plaintext
    try await manager.saveTab(id: stuckId)
    #expect(try Data(contentsOf: stuckURL) == Data("SELECT stuck;".utf8))
    manager.releaseFileAccess()
  }

  /// Makes `url` and its folder read-only, so writing it fails, or writable again
  private func setReadOnly(_ readOnly: Bool, _ url: URL) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: readOnly ? 0o555 : 0o755],
      ofItemAtPath: url.deletingLastPathComponent().path)
    try FileManager.default.setAttributes(
      [.posixPermissions: readOnly ? 0o444 : 0o644], ofItemAtPath: url.path)
  }

  @Test("Remove Lock that cannot write the .sqlws seals every tab file again and stays locked")
  @MainActor
  func removeLockWorkspaceFailureResealsTabs() async throws {
    let folder = directory.appendingPathComponent("workspace", isDirectory: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
      try? FileManager.default.removeItem(at: directory)
    }
    let suiteName = "LockedWorkspaceIOTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let registry = LockRegistry()
    let (manager, files) = try await plainWorkspace(
      registry, defaults: defaults, workspaceFolder: folder)
    let (store, keychain) = keyStore(defaults)
    _ = try await manager.lockWorkspace(
      password: Self.lockPassword, keyStore: store, iterations: 100_000)
    let id = manager.workspace.id
    try setReadOnly(true, files[0].url)

    let confirmation = try await ownerConfirmation(manager)
    let failed = await manager.removeLock(authorization: confirmation, keyStore: store)

    #expect(failed.map(\.url) == [files[0].url])
    #expect(manager.lockKeyId == id)
    #expect(!keychain.isEmpty)
    #expect(registry.isLocked(.workspace(id)))
    let key = try #require(sessions.session(for: id)).contentKey
    for file in files {
      _ = try opened(Data(contentsOf: file.url), kind: file.kind, key: key)
    }
    manager.releaseFileAccess()
  }

  @Test("A tab file Remove Lock cannot seal again is reported as unencrypted")
  @MainActor
  func removeLockReportsFailedReseal() async throws {
    let folder = directory.appendingPathComponent("workspace", isDirectory: true)
    let stuckFolder = directory.appendingPathComponent("stuck", isDirectory: true)
    defer {
      for path in [folder.path, stuckFolder.path] {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
      }
      try? FileManager.default.removeItem(at: directory)
    }
    let suiteName = "LockedWorkspaceIOTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    for path in [folder, stuckFolder] {
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    let registry = LockRegistry()
    let (manager, files) = try await plainWorkspace(
      registry, defaults: defaults, workspaceFolder: folder)
    let stuckId = manager.newSQLFile(content: "SELECT stuck;")
    let stuckURL = stuckFolder.appendingPathComponent("stuck.js")
    try pointTab(manager, stuckId, to: stuckURL)
    try await manager.saveTab(id: stuckId)
    let (store, _) = keyStore(defaults)
    _ = try await manager.lockWorkspace(
      password: Self.lockPassword, keyStore: store, iterations: 100_000)
    let id = manager.workspace.id
    try setReadOnly(true, files[0].url)

    // The stuck tab is the last one written as plaintext; then it cannot be written again
    let tabCount = files.count
    let confirmation = try await ownerConfirmation(manager)
    let failed = await manager.removeLock(authorization: confirmation, keyStore: store) { done, _ in
      if done == tabCount { try? setReadOnly(true, stuckURL) }
    }

    #expect(failed.map(\.url) == [files[0].url, stuckURL])
    #expect(failed.last?.reason.contains("unencrypted") == true)
    #expect(try LockEnvelope.sniff(Data(contentsOf: stuckURL)) == nil)
    #expect(manager.lockKeyId == id)
    #expect(manager.editorDocument(for: stuckId)?.lockKeyId == id)
    let key = try #require(sessions.session(for: id)).contentKey
    for file in files {
      _ = try opened(Data(contentsOf: file.url), kind: file.kind, key: key)
    }
    manager.releaseFileAccess()
  }

  @Test("Retry after Lock Workspace seals the tab files it left unencrypted")
  @MainActor
  func lockWorkspaceRetrySealsFailedFiles() async throws {
    let stuckFolder = directory.appendingPathComponent("stuck", isDirectory: true)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: stuckFolder.path)
      try? FileManager.default.removeItem(at: directory)
    }
    let suiteName = "LockedWorkspaceIOTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let registry = LockRegistry()
    let (manager, files) = try await plainWorkspace(registry, defaults: defaults)
    try FileManager.default.createDirectory(at: stuckFolder, withIntermediateDirectories: true)
    let stuckId = manager.newSQLFile(content: "SELECT secret;")
    let stuckURL = stuckFolder.appendingPathComponent("stuck.js")
    try pointTab(manager, stuckId, to: stuckURL)
    try await manager.saveTab(id: stuckId)
    try setReadOnly(true, stuckURL)
    let (store, _) = keyStore(defaults)

    let report = try await manager.lockWorkspace(
      password: Self.lockPassword, keyStore: store, iterations: 100_000)
    #expect(report.failures.map(\.url) == [stuckURL])
    #expect(try LockEnvelope.sniff(Data(contentsOf: stuckURL)) == nil)

    // Still stuck: the retry reports it again
    #expect(await manager.retryLockWrites(report.failures).map(\.url) == [stuckURL])

    try setReadOnly(false, stuckURL)
    // A failed file whose tab is closed stays as it was
    let closed = LockedFileIO.FileFailure(
      url: directory.appendingPathComponent("closed.sql"), reason: "closed")
    var steps: [Int] = []
    let left = await manager.retryLockWrites(report.failures + [closed]) { done, total in
      #expect(total == 1)
      steps.append(done)
    }

    #expect(left == [closed])
    #expect(steps == [1])
    let key = try #require(sessions.session(for: manager.workspace.id)).contentKey
    _ = try opened(Data(contentsOf: stuckURL), kind: .script, key: key)
    for file in files {
      _ = try opened(Data(contentsOf: file.url), kind: file.kind, key: key)
    }
    manager.releaseFileAccess()
  }

  @Test("A launch overlay never writes plaintext over a sealed tab file; a locked one seals")
  @MainActor
  func overlayNeverWritesPlaintextOverEnvelope() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "LockedWorkspaceIOTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let tabURL = directory.appendingPathComponent("query.sql")
    let before = try sealed(Data("SELECT secret;".utf8), .script)
    try before.write(to: tabURL)
    let tab = WorkspaceTabReference(fileURL: tabURL, documentType: .sqlFile, title: "query.sql")
    let overlay = LaunchTextOverlay(tabId: tab.id, text: .script("SELECT edited;"))

    // The restore did not open the tab (its unlock was cancelled): the overlay recreates it
    let plain = writingManager(Workspace(name: "Plain", tabs: [tab]), defaults: defaults)
    plain.restoreOverlayTab(overlay)
    await #expect(throws: LockedFileIOError.sealedTarget) {
      try await plain.saveTab(id: tab.id)
    }
    #expect(try Data(contentsOf: tabURL) == before)

    // In a locked workspace the recreated tab carries its key and seals
    let locked = writingManager(
      Workspace(id: workspaceId, name: "Locked", tabs: [tab]), defaults: defaults)
    locked.lockKeyId = workspaceId
    sessions.hold(session, by: locked.id)
    locked.restoreOverlayTab(overlay)
    try await locked.saveTab(id: tab.id)
    let plaintext = try opened(Data(contentsOf: tabURL), kind: .script)
    #expect(String(decoding: plaintext, as: UTF8.self) == "SELECT edited;")
    locked.releaseFileAccess()
  }

  @Test("A recent entry's lock flag is false when an older entry has none, and survives edits")
  @MainActor
  func historyEntryLockFlag() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = UUID()
    let old = Data(
      """
      {"id":"\(id.uuidString)","fileURL":"file:///tmp/a.sqlws","name":"a",\
      "lastOpenedAt":0,"tabCount":1}
      """.utf8)
    let decoded = try JSONDecoder().decode(WorkspaceHistoryEntry.self, from: old)
    #expect(decoded.id == id)
    #expect(!decoded.isLocked)

    var locked = decoded
    locked.isLocked = true
    let roundTrip = try JSONDecoder().decode(
      WorkspaceHistoryEntry.self, from: JSONEncoder().encode(locked))
    #expect(roundTrip.isLocked)
    #expect(
      locked.edited(name: "b", fileURL: URL(fileURLWithPath: "/tmp/b.sqlws"), bookmark: nil)
        .isLocked)
  }

  // MARK: - Re-seal after a Lock password change

  /// A sealed workspace `id` at `folder` with the given tab files, its key wrapped with `password`
  @MainActor private func sealedWorkspace(
    _ id: UUID, in folder: URL, password: String, tabs: [String]
  ) throws -> (session: WorkspaceLockSession, url: URL, files: [URL]) {
    let key = SymmetricKey(size: .bits256)
    let block = try LockEnvelope.makeWrapBlock(
      contentKey: key, password: password, workspaceId: id, iterations: 100_000)
    let session = WorkspaceLockSession(workspaceId: id, contentKey: key, wrapBlock: block)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var references: [WorkspaceTabReference] = []
    var files: [URL] = []
    for name in tabs {
      let url = folder.appendingPathComponent(name)
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
    return (session, url, files)
  }

  @Test("A Lock password change re-seals every reachable file; a failed file keeps its old block")
  @MainActor
  func resealWithNewPassword() async throws {
    let open = directory.appendingPathComponent("open", isDirectory: true)
    let closed = directory.appendingPathComponent("closed", isDirectory: true)
    let stuckFolder = closed.appendingPathComponent("stuck", isDirectory: true)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: stuckFolder.path)
      try? FileManager.default.removeItem(at: directory)
    }
    // Open window: its key is in memory (its block was made with another password)
    let a = try sealedWorkspace(UUID(), in: open, password: "older password", tabs: ["a.sql"])
    sessions.hold(a.session, by: a.session.workspaceId)
    // Closed, no Keychain item: unwrapped with the current Lock password
    try FileManager.default.createDirectory(at: stuckFolder, withIntermediateDirectories: true)
    let b = try sealedWorkspace(
      UUID(), in: closed, password: Self.lockPassword, tabs: ["b.sql", "stuck/c.sql"])
    let stuck = b.files[1]
    let stuckBefore = try Data(contentsOf: stuck)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: stuck.path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: stuckFolder.path)
    let entries = [a.url, b.url].map {
      WorkspaceHistoryEntry(fileURL: $0, name: "ws")
    }

    let result = await io.reseal(
      entries, currentPassword: Self.lockPassword, newPassword: "a new lock password",
      iterations: 100_000)

    #expect(result.failures.map(\.url) == [stuck])
    for (session, url) in [
      (a.session, a.url), (a.session, a.files[0]), (b.session, b.url),
      (b.session, b.files[0]),
    ] {
      let header = try #require(try LockEnvelope.sniff(Data(contentsOf: url)))
      let key = try LockEnvelope.unwrapKey(header.wrapBlock, password: "a new lock password")
      #expect(key == session.contentKey)
      #expect(try LockEnvelope.open(Data(contentsOf: url), contentKey: key).isEmpty == false)
    }
    // Data-loss guard: the file that failed is untouched and opens with the old password
    #expect(try Data(contentsOf: stuck) == stuckBefore)
    // The open window seals its next writes with the new block
    let newBlock = try #require(try LockEnvelope.sniff(Data(contentsOf: a.url))).wrapBlock
    #expect(sessions.session(for: a.session.workspaceId)?.wrapBlock == newBlock)
    #expect(
      Set(result.sessions.map(\.workspaceId)) == [a.session.workspaceId, b.session.workspaceId])
  }
}

/// Grants owner authentication without a prompt (the Debug double) and counts the asks
@MainActor
private final class CountingOwnerAuthenticator: BiometricAuthenticator {
  var prompts = 0
  var duringPrompt: () -> Void = {}

  var canUseBiometrics: Bool { false }

  func authenticate(reason: String) async -> Bool { false }

  func authenticateOwner(reason: String) async -> OwnerAuthentication? {
    prompts += 1
    duringPrompt()
    return await GrantingOwnerTestAuthenticator().authenticateOwner(reason: reason)
  }
}

/// One in-memory Keychain domain: items by service and account, no access control checks
final class OneServiceKeychain: KeychainBackend, @unchecked Sendable {
  private let items = OSAllocatedUnfairLock(initialState: [String: Data]())

  func copy(service: String, account: String, context: LAContext?) -> KeychainRead {
    items.withLock { $0["\(service)/\(account)"] }.map { .found($0) } ?? .notFound
  }

  func add(
    service: String, account: String, data: Data, accessible: CFString,
    accessControl: KeychainAccessControl?
  ) -> OSStatus {
    items.withLock { items in
      guard items["\(service)/\(account)"] == nil else { return errSecDuplicateItem }
      items["\(service)/\(account)"] = data
      return errSecSuccess
    }
  }

  func upsert(
    service: String, account: String, data: Data, accessible: CFString,
    accessControl: KeychainAccessControl?
  ) -> OSStatus {
    items.withLock { $0["\(service)/\(account)"] = data }
    return errSecSuccess
  }

  func delete(service: String, account: String) -> OSStatus {
    items.withLock { $0.removeValue(forKey: "\(service)/\(account)") } == nil
      ? errSecItemNotFound : errSecSuccess
  }

  func accounts(service: String) -> [String] { [] }

  var isEmpty: Bool { items.withLock { $0.isEmpty } }
}
