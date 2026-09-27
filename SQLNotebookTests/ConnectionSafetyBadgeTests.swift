// ConnectionSafetyBadgeTests.swift
// Tests for the header safety badge mapping (protection + SSL -> label / level)

import Foundation
import Testing

@testable import SQLNotebook

@MainActor
private func badge(
  _ level: ConnectionProtectionLevel = .none, protectedMode: Bool = false,
  ssl: SSLMode = .verifyFull, type: DatabaseType = .postgresql
) -> ConnectionSafetyBadge {
  ConnectionSafetyBadge(
    config: ConnectionConfig(
      databaseType: type, sslMode: ssl, protectionLevel: level, protectedMode: protectedMode))
}

@MainActor
@Suite("Connection Safety Badge")
struct ConnectionSafetyBadgeTests {

  // MARK: Protection

  @Test func readOnlyLabel() {
    #expect(badge(.readOnly).protectionLabel == "Read-Only")
    #expect(badge(.readOnly).protectionIcon == "lock.fill")
  }

  @Test func schemaOnlyLabel() {
    #expect(badge(.schemaOnly).protectionLabel == "Schema Protected")
    #expect(badge(.schemaOnly).protectionIcon == "tablecells.badge.ellipsis")
  }

  @Test func protectedModeLabel() {
    #expect(badge(.none, protectedMode: true).protectionLabel == "Protected")
    #expect(badge(.none, protectedMode: true).protectionIcon == "shield.lefthalf.filled")
  }

  @Test func unprotectedLabel() {
    #expect(badge(.none, protectedMode: false).protectionLabel == "Unprotected")
    #expect(badge(.none, protectedMode: false).protectionIcon == "lock.open")
  }

  @Test func stricterLevelWinsOverProtectedMode() {
    #expect(badge(.readOnly, protectedMode: true).protectionLabel == "Read-Only")
    #expect(badge(.schemaOnly, protectedMode: true).protectionLabel == "Schema Protected")
  }

  @Test func tooltipMentionsProtectedModeAlongsideLevel() {
    #expect(badge(.schemaOnly, protectedMode: true).tooltip.contains("Protected mode"))
    #expect(!badge(.schemaOnly, protectedMode: false).tooltip.contains("Protected mode"))
  }

  @Test func protectedOnlyTooltipDoesNotSayAllQueriesAllowed() {
    let tooltip = badge(.none, protectedMode: true).tooltip
    #expect(!tooltip.contains("All queries allowed"))
    #expect(tooltip.hasPrefix("Protected mode"))
  }

  // MARK: SSL

  @Test(arguments: [SSLMode.disable, .allow, .prefer])
  func noGuaranteedSSLIsDanger(_ mode: SSLMode) {
    #expect(badge(ssl: mode).ssl?.level == .danger)
    #expect(badge(ssl: mode).ssl?.label == "No SSL")
  }

  @Test func requireIsWarning() {
    #expect(badge(ssl: .require).ssl?.level == .warning)
    #expect(badge(ssl: .require).ssl?.label == "SSL unverified")
  }

  @Test(arguments: [SSLMode.verifyCa, .verifyFull])
  func verifiedSSLIsOK(_ mode: SSLMode) {
    #expect(badge(ssl: mode).ssl?.level == .ok)
    #expect(badge(ssl: mode).ssl?.label == "SSL verified")
  }

  @Test func sqliteHasNoSSLState() {
    #expect(badge(ssl: .disable, type: .sqlite).ssl == nil)
  }

  @Test(arguments: SSLMode.allCases)
  func tooltipNamesSSLMode(_ mode: SSLMode) {
    #expect(badge(ssl: mode).tooltip.contains(mode.displayName))
  }
}
