//
//  WorkspaceManager+RedisKeys.swift
//  Dblore
//
//  Redis key tabs (`TabDocumentType.redisKey`): a click on a key in the sidebar shows it in one
//  reused preview tab, a double click keeps that tab. Both act in the click's frame: the tab is
//  made and selected before anything is read. Key tabs live only in this session.
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

  /// The key's escaped label (`RedisKeyBrowserModel.label`), cut after `redisKeyTitleLength`
  /// characters with "…"
  nonisolated static func redisKeyTitle(_ key: RedisKeyRef) -> String {
    let label = RedisKeyBrowserModel.label(key.bytes)
    guard !label.isEmpty else { return "(empty)" }
    guard label.count > redisKeyTitleLength else { return label }
    return String(label.prefix(redisKeyTitleLength)) + "…"
  }
}
