//
//  WorkspaceManager+RedisKeys.swift
//  Dblore
//
//  Redis key tabs (`TabDocumentType.redisKey`): a click on a key in the sidebar shows it in one
//  reused preview tab, a double click keeps that tab. Both act in the click's frame: the tab is
//  made and selected before anything is read. Key tabs live only in this session.
//  Edits (`RedisKeyEditor`) go through the gate under the connection's protection (a key tab has
//  no notebook view model, so no tab write unlock) and its commit style; each sent write is
//  stored in History as a data edit (`.dataViewerEdit`, the Redis render of its arguments), and
//  tells the sidebar to read the db's keys again (`redisKeysChanged`).
//

import Foundation

extension WorkspaceManager {
  /// Longest key label a tab title shows (the label is escaped first)
  nonisolated static let redisKeyTitleLength = 48

  /// The key of the active tab, nil when it is not a key tab
  var activeRedisKey: RedisKeyRef? {
    activeTab?.redisKey
  }

  /// A click on a key: selects the tab already showing it, else shows it in the key preview tab,
  /// else opens a new preview tab. Synchronous, so the tab switches in the click's frame. Nil
  /// (nothing opened) outside a Redis workspace.
  @discardableResult
  func openRedisKey(_ key: RedisKeyRef) -> UUID? {
    guard isRedisWorkspace else { return nil }
    // By the key's bytes and db, never its title: two keys can share a label
    if let id = tabs.first(where: { $0.redisKey == key })?.id {
      selectTab(id: id)
      return id
    }
    let title = Self.redisKeyTitle(key)
    if let index = tabs.firstIndex(where: { $0.documentType == .redisKey && $0.isPreview }) {
      tabs[index].redisKey = key
      tabs[index].title = title
      selectTab(id: tabs[index].id)
      return tabs[index].id
    }
    let tab = TabItem(documentType: .redisKey, title: title, isPreview: true, redisKey: key)
    tabs.append(tab)
    selectTab(id: tab.id)
    return tab.id
  }

  /// A double click on a key: its tab (the preview the click opened, or a kept one) is kept, so
  /// the next click opens another preview
  @discardableResult
  func pinRedisKey(_ key: RedisKeyRef) -> UUID? {
    guard let id = openRedisKey(key) else { return nil }
    pinTab(id: id)
    return id
  }

  /// A connection to another server, db or engine: the key tabs show keys it does not have
  func closeRedisKeyTabs() {
    for id in tabs.filter({ $0.documentType == .redisKey }).map(\.id) {
      closeTabImmediately(id: id)
    }
  }

  /// The connection's protection for key reads and edits (key tabs have no tab policy)
  var redisKeyPolicy: ProtectionPolicy {
    ProtectionPolicy(config: workspace.connectionConfig)
  }

  /// A read-only connection: key tabs and the sidebar offer no edit (the gate refuses anyway)
  var isRedisReadOnly: Bool {
    redisKeyPolicy.protectionLevel == .readOnly
  }

  /// The write path of key edits: the gate under `redisKeyPolicy` (read at each command), the
  /// connection's commit style (read when a write is asked and when it is confirmed), History
  func redisKeyWriteContext(
    staleMessage: String = "The connection changed; reload the key."
  ) -> RedisKeyWriteContext {
    var context = RedisKeyWriteContext.gated(
      manager: connectionManager,
      policy: { [weak self] in
        // Gone with its window: the strictest level, so nothing is written
        self?.redisKeyPolicy ?? ProtectionPolicy(protectionLevel: .readOnly)
      },
      commitStyle: { [weak self] in
        self?.workspace.connectionConfig.map(RedisCommandContext.commitStyle(of:))
          ?? AppSettings.shared.commitStyle
      },
      recordHistory: { [weak self] outcomes in await self?.recordRedisKeyEdits(outcomes) })
    context.staleMessage = staleMessage
    return context
  }

  /// Stores key edits in History (with History on): the Redis render of each sent command as
  /// a data edit (`.dataViewerEdit`, kind write) of this workspace's connection, never a reply.
  /// The editor already skipped commands holding a password.
  func recordRedisKeyEdits(_ outcomes: [QueryHistoryOutcome]) async {
    guard AppSettings.shared.historyEnabled, let config = workspace.connectionConfig,
      config.databaseType == .redis, !outcomes.isEmpty
    else { return }
    let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let recorder = NotebookViewModel.defaultHistoryRecorder()
    for outcome in outcomes {
      await recorder.record(
        QueryHistoryEntry(
          id: 0, sql: outcome.sql, executedAt: Date(),
          durationMs: Int((outcome.duration * 1_000).rounded()), rowCount: nil,
          status: outcome.status, errorMessage: outcome.errorMessage,
          connectionKey: QueryHistoryIdentity.connectionKey(for: config),
          connectionLabel: name.isEmpty ? "\(config.host)/\(config.database)" : name,
          workspaceID: workspace.id, workspaceName: workspace.name, source: .dataViewerEdit,
          kind: .write))
    }
    await refreshHistory()
  }

  /// A write changed the keys of `db`: the sidebar reads its key counts and keys again
  func noteRedisKeysChanged(db: Int) {
    NotificationCenter.default.post(
      name: .redisKeysChanged, object: self, userInfo: [Self.redisKeysChangedDatabase: db])
  }

  /// The `userInfo` key of `redisKeysChanged`: the db index
  nonisolated static let redisKeysChangedDatabase = "db"

  /// The key was deleted: its tabs close
  func closeRedisKeyTabs(showing key: RedisKeyRef) {
    for id in tabs.filter({ $0.redisKey == key }).map(\.id) {
      closeTabImmediately(id: id)
    }
  }

  /// The key was renamed: its tabs show the new name (and read it again); a tab already showing
  /// the new name closes first, so one tab shows it
  func retargetRedisKeyTabs(from key: RedisKeyRef, to newKey: RedisKeyRef) {
    guard tabs.contains(where: { $0.redisKey == key }) else { return }
    closeRedisKeyTabs(showing: newKey)
    let title = Self.redisKeyTitle(newKey)
    for index in tabs.indices where tabs[index].redisKey == key {
      tabs[index].redisKey = newKey
      tabs[index].title = title
    }
  }

  /// The key's escaped label (`RedisKeyBrowserModel.label`), cut after `redisKeyTitleLength`
  /// characters with "…"
  nonisolated static func redisKeyTitle(_ key: RedisKeyRef) -> String {
    let label = RedisKeyBrowserModel.label(key.bytes)
    guard !label.isEmpty else { return "(empty)" }
    guard label.count > redisKeyTitleLength else { return label }
    return String(label.prefix(redisKeyTitleLength)) + "…"
  }
}

extension Notification.Name {
  /// A key edit changed the keys of a db (`object`: the `WorkspaceManager`, `userInfo`: its
  /// `redisKeysChangedDatabase`)
  static let redisKeysChanged = Notification.Name("ace.thi.Dblore.redisKeysChanged")
}
