// HeaderConnectionConfigTests.swift
// Tests for the header safety badge decision from the connection config passed to HeaderView

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite struct HeaderConnectionConfigTests {

  private func badge(
    _ config: ConnectionConfig?,
    viewMode: ViewMode = .editor,
    isConnected: Bool = true
  ) -> ConnectionSafetyBadge? {
    HeaderView.connectionBadge(
      for: config, viewMode: viewMode, isConnected: isConnected, fallback: .confirm)
  }

  @Test func readOnlyConfigShowsBadge() {
    let item = badge(ConnectionConfig(protectionLevel: .readOnly))
    #expect(item?.protectionLabel == "Read-Only")
  }

  @Test func schemaOnlyConfigShowsBadge() {
    let item = badge(ConnectionConfig(protectionLevel: .schemaOnly))
    #expect(item?.protectionLabel == "Schema Protected")
  }

  @Test func reviewConfigShowsBadge() {
    let item = badge(ConnectionConfig(protectionLevel: .none, protectedMode: true))
    #expect(item?.protectionLabel == "Review")
  }

  @Test func nilConfigShowsNoBadge() {
    #expect(badge(nil) == nil)
  }

  @Test func disconnectedShowsNoBadge() {
    #expect(badge(ConnectionConfig(protectionLevel: .readOnly), isConnected: false) == nil)
  }

  @Test func markdownShowsNoBadge() {
    #expect(badge(ConnectionConfig(protectionLevel: .readOnly), viewMode: .markdown) == nil)
  }

  @Test func notebookShowsBadge() {
    #expect(badge(ConnectionConfig(protectionLevel: .readOnly), viewMode: .notebook) != nil)
  }
}
