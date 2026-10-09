// ConnectionSafetyFooterTests.swift
// Footer safety pills: level -> tone mapping and the "No SSL" badge visibility

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Connection Safety Footer")
struct ConnectionSafetyFooterTests {

  // MARK: Tone

  @Test func protectionTones() {
    #expect(SafetyOptionStyle.footerTone(for: ConnectionProtectionLevel.none) == .neutral)
    #expect(SafetyOptionStyle.footerTone(for: ConnectionProtectionLevel.schemaOnly) == .accent)
    #expect(SafetyOptionStyle.footerTone(for: ConnectionProtectionLevel.readOnly) == .warning)
  }

  @Test func commitStyleTones() {
    #expect(SafetyOptionStyle.footerTone(for: CommitStyle.immediate) == .neutral)
    #expect(SafetyOptionStyle.footerTone(for: CommitStyle.confirm) == .warning)
    #expect(SafetyOptionStyle.footerTone(for: CommitStyle.review) == .accent)
    #expect(SafetyOptionStyle.footerTone(for: CommitStyle.password) == .success)
  }

  // MARK: No SSL badge

  @Test(arguments: SSLMode.allCases)
  func postgresShowsNoSSLOnlyForUnverifiedModes(_ mode: SSLMode) {
    let config = ConnectionConfig(databaseType: .postgresql, sslMode: mode)
    let tooltip = FooterView.noSSLTooltip(for: config, isConnected: true)
    switch mode {
    case .disable, .allow, .prefer:
      #expect(tooltip == "SSL mode \(mode.displayName): the connection may be unencrypted")
    case .require, .verifyCa, .verifyFull:
      #expect(tooltip == nil)
    }
  }

  @Test(arguments: [DatabaseType.sqlite, .duckdb])
  func fileEnginesShowNoSSLBadge(_ type: DatabaseType) {
    let config = ConnectionConfig(databaseType: type, sslMode: .disable)
    #expect(FooterView.noSSLTooltip(for: config, isConnected: true) == nil)
  }

  @Test func disconnectedOrMissingConfigShowsNoSSLBadge() {
    let config = ConnectionConfig(databaseType: .postgresql, sslMode: .disable)
    #expect(FooterView.noSSLTooltip(for: config, isConnected: false) == nil)
    #expect(FooterView.noSSLTooltip(for: nil, isConnected: true) == nil)
  }
}
