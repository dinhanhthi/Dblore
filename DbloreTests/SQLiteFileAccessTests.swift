// SQLiteFileAccessTests.swift
// Sandbox grant for a SQLite file: sidecar presenters, balanced security scope,
// and the read-only fallback when a sidecar is denied.

import Foundation
import Testing
import os

@testable import Dblore

@Suite("SQLite file access")
@MainActor
struct SQLiteFileAccessTests {
  private final class Log: @unchecked Sendable {
    let events = OSAllocatedUnfairLock(initialState: [String]())
    func add(_ event: String) { events.withLock { $0.append(event) } }
    var list: [String] { events.withLock { $0 } }
  }

  @Test("Presenters are registered before the probe and removed on release")
  func presentersRegisterBeforeProbeAndReleaseBalances() async throws {
    let databaseURL = URL(fileURLWithPath: "/tmp/dblore-access-\(UUID().uuidString).sqlite")
    let log = Log()
    let starts = OSAllocatedUnfairLock(initialState: [String]())
    let stops = OSAllocatedUnfairLock(initialState: [String]())
    let added = OSAllocatedUnfairLock(
      initialState: [SQLiteFileAccess.SidecarFilePresenter]())
    let removed = OSAllocatedUnfairLock(
      initialState: [SQLiteFileAccess.SidecarFilePresenter]())
    var folderAsks = 0
    var probedURL: URL?

    var hooks = SQLiteFileAccess.Hooks()
    hooks.resolve = { data in
      #expect(data == Data([1]))
      return (databaseURL, false)
    }
    hooks.makeBookmark = { _ in
      Issue.record("A fresh bookmark is not needed when the stored one is current")
      return nil
    }
    hooks.startAccess = { url in
      log.add("start:\(url.path)")
      starts.withLock { $0.append(url.path) }
      return SecurityScopedAccessToken(
        url: url,
        start: { _ in true },
        stop: { stopped in
          log.add("stop:\(stopped.path)")
          stops.withLock { $0.append(stopped.path) }
        })
    }
    hooks.chooseFolder = { _ in
      folderAsks += 1
      return nil
    }
    hooks.addPresenter = { presenter in
      log.add("add:\(presenter.presentedItemURL?.path ?? "")")
      added.withLock { $0.append(presenter) }
    }
    hooks.removePresenter = { presenter in
      log.add("remove:\(presenter.presentedItemURL?.path ?? "")")
      removed.withLock { $0.append(presenter) }
    }
    hooks.probe = { url in
      probedURL = url
      log.add("probe")
    }

    let grant = try await SQLiteFileAccess.open(config: config(bookmark: Data([1])), hooks: hooks)
    let events = log.list
    let probeIndex = try #require(events.firstIndex(of: "probe"))
    let addEvents = events[..<probeIndex].filter { $0.hasPrefix("add:") }
    #expect(addEvents == SQLiteFileAccess.sidecarSuffixes.map { "add:\(databaseURL.path)\($0)" })
    #expect(events.first == "start:\(databaseURL.path)")
    #expect(probedURL == databaseURL)
    #expect(folderAsks == 0)
    #expect(grant.url == databaseURL)
    #expect(grant.readOnly == false)
    #expect(grant.bannerReason == nil)
    #expect(grant.bookmark == Data([1]))
    #expect(grant.folderBookmark == nil)

    let presenters = added.withLock { $0 }
    #expect(presenters.count == 3)
    for presenter in presenters {
      #expect(presenter.primaryPresentedItemURL?.path == databaseURL.path)
    }

    grant.release()
    grant.release()
    #expect(
      log.list.suffix(4) == SQLiteFileAccess.sidecarSuffixes.map {
        "remove:\(databaseURL.path)\($0)"
      } + ["stop:\(databaseURL.path)"])
    #expect(starts.withLock { $0 } == [databaseURL.path])
    #expect(stops.withLock { $0 } == [databaseURL.path])
    #expect(
      removed.withLock { $0.map(ObjectIdentifier.init) }
        == presenters.map(ObjectIdentifier.init))
  }

  @Test("Sidecar denial asks for the folder once, then opens read-only")
  func sidecarDenialFallsBackToReadOnly() async throws {
    let databaseURL = URL(fileURLWithPath: "/tmp/dblore-access-\(UUID().uuidString).sqlite")
    let log = Log()
    let stops = OSAllocatedUnfairLock(initialState: 0)
    var folderURL: URL?

    var hooks = SQLiteFileAccess.Hooks()
    hooks.resolve = { _ in (databaseURL, false) }
    hooks.startAccess = { url in
      log.add("start")
      return SecurityScopedAccessToken(
        url: url, start: { _ in true },
        stop: { _ in
          stops.withLock { $0 += 1 }
          log.add("stop")
        })
    }
    hooks.chooseFolder = { url in
      folderURL = url
      log.add("folder")
      return nil
    }
    hooks.addPresenter = { presenter in
      log.add("add:\(presenter.presentedItemURL?.path ?? "")")
    }
    hooks.removePresenter = { _ in log.add("remove") }
    hooks.probe = { _ in
      log.add("probe")
      throw SQLiteFileAccess.SidecarDenied()
    }

    let grant = try await SQLiteFileAccess.open(config: config(), hooks: hooks)
    #expect(
      log.list == ["start"]
        + SQLiteFileAccess.sidecarSuffixes.map { "add:\(databaseURL.path)\($0)" }
        + ["probe", "folder"])
    #expect(folderURL == databaseURL)
    #expect(grant.readOnly == true)
    #expect(grant.bannerReason == SQLiteFileAccess.readOnlyBannerReason)
    #expect(grant.folderBookmark == nil)

    grant.release()
    #expect(stops.withLock { $0 } == 1)
    #expect(log.list.filter { $0 == "remove" }.count == 3)
    #expect(log.list.last == "stop")
  }

  @Test("A granted folder is bookmarked and the write probe runs again")
  func folderGrantRetriesProbe() async throws {
    let databaseURL = URL(fileURLWithPath: "/tmp/dblore-access-\(UUID().uuidString).sqlite")
    let folderURL = databaseURL.deletingLastPathComponent()
    let log = Log()
    let starts = OSAllocatedUnfairLock(initialState: [String]())
    let stops = OSAllocatedUnfairLock(initialState: [String]())
    var probes = 0

    var hooks = SQLiteFileAccess.Hooks()
    hooks.resolve = { _ in (databaseURL, false) }
    hooks.makeBookmark = { url in
      #expect(url == folderURL)
      log.add("bookmark")
      return Data([9])
    }
    hooks.startAccess = { url in
      log.add("start:\(url.path)")
      starts.withLock { $0.append(url.path) }
      return SecurityScopedAccessToken(
        url: url, start: { _ in true },
        stop: { stopped in stops.withLock { $0.append(stopped.path) } })
    }
    hooks.chooseFolder = { url in
      #expect(url == databaseURL)
      log.add("folder")
      return folderURL
    }
    hooks.addPresenter = { _ in }
    hooks.removePresenter = { _ in }
    hooks.probe = { _ in
      probes += 1
      log.add("probe")
      if probes == 1 { throw SQLiteFileAccess.SidecarDenied() }
    }

    let grant = try await SQLiteFileAccess.open(config: config(), hooks: hooks)
    #expect(
      log.list == [
        "start:\(databaseURL.path)", "probe", "folder", "start:\(folderURL.path)", "bookmark",
        "probe",
      ])
    #expect(probes == 2)
    #expect(grant.readOnly == false)
    #expect(grant.bannerReason == nil)
    #expect(grant.folderBookmark == Data([9]))
    grant.release()
    grant.release()
    #expect(stops.withLock { $0 } == [databaseURL.path, folderURL.path])
    #expect(starts.withLock { $0 } == stops.withLock { $0 })
  }

  @Test("A folder grant that still cannot write falls back to read-only")
  func folderGrantStillDeniedFallsBack() async throws {
    let databaseURL = URL(fileURLWithPath: "/tmp/dblore-access-\(UUID().uuidString).sqlite")
    let folderURL = databaseURL.deletingLastPathComponent()
    let stops = OSAllocatedUnfairLock(initialState: 0)
    var probes = 0

    var hooks = SQLiteFileAccess.Hooks()
    hooks.resolve = { _ in (databaseURL, false) }
    hooks.makeBookmark = { _ in Data([9]) }
    hooks.startAccess = { url in
      SecurityScopedAccessToken(
        url: url, start: { _ in true },
        stop: { _ in stops.withLock { $0 += 1 } })
    }
    hooks.chooseFolder = { _ in folderURL }
    hooks.addPresenter = { _ in }
    hooks.removePresenter = { _ in }
    hooks.probe = { _ in
      probes += 1
      throw SQLiteFileAccess.SidecarDenied()
    }

    let grant = try await SQLiteFileAccess.open(config: config(), hooks: hooks)
    #expect(probes == 2)
    #expect(grant.readOnly == true)
    #expect(grant.bannerReason == SQLiteFileAccess.readOnlyBannerReason)
    #expect(grant.folderBookmark == Data([9]))
    grant.release()
    #expect(stops.withLock { $0 } == 2)
  }

  @Test("A requested read-only file skips the write probe and has no banner")
  func requestedReadOnlySkipsProbe() async throws {
    let databaseURL = URL(fileURLWithPath: "/tmp/dblore-access-\(UUID().uuidString).sqlite")
    var probed = false
    var folderAsks = 0
    var added = 0
    var hooks = hooks(databaseURL: databaseURL)
    hooks.addPresenter = { _ in added += 1 }
    hooks.probe = { _ in probed = true }
    hooks.chooseFolder = { _ in
      folderAsks += 1
      return nil
    }

    let grant = try await SQLiteFileAccess.open(
      config: config(readOnlyFile: true), hooks: hooks)
    #expect(probed == false)
    #expect(folderAsks == 0)
    #expect(added == SQLiteFileAccess.sidecarSuffixes.count)
    #expect(grant.readOnly == true)
    #expect(grant.bannerReason == nil)
    grant.release()
  }

  @Test("A stale bookmark is replaced and presenters use the resolved file")
  func staleBookmarkIsRefreshed() async throws {
    let databaseURL = URL(fileURLWithPath: "/tmp/dblore-moved-\(UUID().uuidString).sqlite")
    var hooks = hooks(databaseURL: databaseURL, stale: true)
    hooks.makeBookmark = { url in
      #expect(url == databaseURL)
      return Data([7])
    }
    var probed: URL?
    hooks.probe = { probed = $0 }

    let grant = try await SQLiteFileAccess.open(
      config: config(bookmark: Data([1]), path: "/tmp/dblore-old.sqlite"), hooks: hooks)
    #expect(grant.url == databaseURL)
    #expect(grant.bookmark == Data([7]))
    #expect(probed == databaseURL)
    grant.release()
  }

  @Test("Missing or denied access does not register presenters")
  func missingOrDeniedAccessDoesNotRegisterPresenters() async throws {
    var added = 0
    var hooks = SQLiteFileAccess.Hooks()
    hooks.addPresenter = { _ in added += 1 }
    hooks.resolve = { _ in
      Issue.record("No bookmark to resolve")
      return (URL(fileURLWithPath: "/tmp/unused.sqlite"), false)
    }

    await #expect(throws: SQLiteFileAccess.Failure.missingBookmark) {
      try await SQLiteFileAccess.open(
        config: ConnectionConfig(databaseType: .sqlite), hooks: hooks)
    }
    #expect(added == 0)

    let stops = OSAllocatedUnfairLock(initialState: 0)
    hooks.resolve = { _ in (URL(fileURLWithPath: "/tmp/denied.sqlite"), false) }
    hooks.startAccess = { url in
      SecurityScopedAccessToken(
        url: url, start: { _ in false },
        stop: { _ in stops.withLock { $0 += 1 } })
    }
    await #expect(throws: SQLiteFileAccess.Failure.accessNotGranted) {
      try await SQLiteFileAccess.open(config: config(), hooks: hooks)
    }
    #expect(added == 0)
    #expect(stops.withLock { $0 } == 0)
  }

  @Test("The write probe opens a file and rolls BEGIN IMMEDIATE back")
  func writeProbeRollsBack() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-file-access-\(UUID().uuidString).sqlite")
    defer { removeDatabase(at: url) }
    do {
      let created = try SQLiteHandle(url: url)
      try created.execute("CREATE TABLE notes (id INTEGER)")
    }
    try SQLiteFileAccess.probeWritable(url)
    let opened = try SQLiteHandle(url: url)
    try opened.execute("INSERT INTO notes (id) VALUES (1)")
    #expect(opened.changes == 1)
  }

  @Test("Disconnect calls the file-access release hook once")
  func disconnectCallsReleaseHook() async {
    let manager = DatabaseConnectionManager()
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let release: @Sendable () -> Void = { calls.withLock { $0 += 1 } }
    await manager.setSQLiteFileAccessRelease(release)
    _ = await manager.forgetConnection()
    #expect(calls.withLock { $0 } == 0)
    await manager.disconnect()
    await manager.disconnect()
    #expect(calls.withLock { $0 } == 1)
  }

  private func config(
    bookmark: Data = Data([1]), path: String = "/tmp/dblore-access.sqlite",
    readOnlyFile: Bool = false
  ) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite, database: path, fileBookmark: bookmark, readOnlyFile: readOnlyFile)
  }

  private func hooks(databaseURL: URL, stale: Bool = false) -> SQLiteFileAccess.Hooks {
    var hooks = SQLiteFileAccess.Hooks()
    hooks.resolve = { _ in (databaseURL, stale) }
    hooks.startAccess = { url in
      SecurityScopedAccessToken(url: url, start: { _ in true }, stop: { _ in })
    }
    hooks.addPresenter = { _ in }
    hooks.removePresenter = { _ in }
    hooks.probe = { _ in }
    hooks.chooseFolder = { _ in nil }
    return hooks
  }

  private func removeDatabase(at url: URL) {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: url)
    for suffix in ["-wal", "-shm", "-journal"] {
      try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }
}
