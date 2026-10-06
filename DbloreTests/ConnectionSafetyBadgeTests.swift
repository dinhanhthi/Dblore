// ConnectionSafetyBadgeTests.swift
// Tests for the header safety badge mapping (protection + SSL -> label / level)

import Foundation
import Testing

@testable import Dblore

@MainActor
private func badge(
  _ level: ConnectionProtectionLevel = .none,
  protectedMode: Bool = false,
  safeMode: SafeMode? = nil,
  style: CommitStyle? = nil,
  ssl: SSLMode = .verifyFull,
  type: DatabaseType = .postgresql,
  fallback: CommitStyle = .confirm
) -> ConnectionSafetyBadge {
  var config = ConnectionConfig(
    databaseType: type, sslMode: ssl, protectionLevel: level, safeMode: safeMode,
    protectedMode: protectedMode)
  if let style {
    config.applyCommitStyle(style)
  }
  return ConnectionSafetyBadge(
    config: config,
    commitStyle: config.resolvedCommitStyle(fallback: fallback))
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

  @Test func legacyProtectedReadsReview() {
    let item = badge(.none, protectedMode: true)
    #expect(item.protectionLabel == "Review")
    #expect(item.protectionIcon == "shield.lefthalf.filled")
    #expect(item.protectionLabel != "Protected")
  }

  @Test func unprotectedSilentReadsImmediate() {
    let item = badge(.none, protectedMode: false, safeMode: .silent)
    #expect(item.protectionLabel == "Immediate")
    #expect(item.protectionIcon == "lock.open")
    #expect(item.protectionLabel != "Unprotected")
  }

  @Test(arguments: CommitStyle.allCases)
  func noneLevelUsesCommitStyleTitle(_ style: CommitStyle) {
    let item = badge(.none, style: style)
    #expect(item.protectionLabel == style.title)
    #expect(item.protectionLabel != "Protected")
    #expect(item.protectionLabel != "Unprotected")
  }

  @Test func stricterLevelWinsOverProtectedMode() {
    #expect(badge(.readOnly, protectedMode: true).protectionLabel == "Read-Only")
    #expect(badge(.schemaOnly, protectedMode: true).protectionLabel == "Schema Protected")
  }

  @Test func tooltipMentionsReviewAlongsideLevel() {
    let reviewLine = "Review: changes stay pending until you Commit or Roll Back."
    #expect(badge(.schemaOnly, protectedMode: true).tooltip.contains(reviewLine))
    #expect(!badge(.schemaOnly, protectedMode: false).tooltip.contains(reviewLine))
  }

  @Test func reviewOnlyTooltipNamesReview() {
    let tooltip = badge(.none, protectedMode: true).tooltip
    #expect(!tooltip.contains("All queries allowed"))
    #expect(tooltip.contains("Review: changes stay pending until you Commit or Roll Back."))
    #expect(!tooltip.contains("Protected"))
    #expect(!tooltip.contains("Unprotected"))
  }

  // MARK: SSL

  @Test(arguments: [SSLMode.disable, .allow, .prefer])
  func noGuaranteedSSLIsDanger(_ mode: SSLMode) {
    #expect(badge(ssl: mode).ssl?.level == .danger)
    #expect(badge(ssl: mode).ssl?.label == "No SSL")
  }

  @Test(arguments: [SSLMode.require, .verifyCa, .verifyFull])
  func verifiedSSLIsOK(_ mode: SSLMode) {
    #expect(badge(ssl: mode).ssl?.level == .ok)
    #expect(badge(ssl: mode).ssl?.label == "SSL verified")
  }

  @Test func requireTooltipSaysCertificateAlwaysVerified() {
    #expect(badge(ssl: .require).tooltip.contains("always verifies the server certificate"))
  }

  @Test func sqliteHasNoSSLState() {
    #expect(badge(ssl: .disable, type: .sqlite).ssl == nil)
  }

  @Test(arguments: SSLMode.allCases)
  func tooltipNamesSSLMode(_ mode: SSLMode) {
    #expect(badge(ssl: mode).tooltip.contains(mode.displayName))
  }
}
