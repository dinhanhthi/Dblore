// ConnectionSafetyFooterTests.swift
// Footer safety pills: level -> tone mapping and the "No SSL" badge visibility

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Connection Safety Footer")
struct ConnectionSafetyFooterTests {

  // MARK: Tone

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

}
