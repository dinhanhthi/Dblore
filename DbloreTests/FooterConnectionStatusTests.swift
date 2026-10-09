// FooterConnectionStatusTests.swift
// Tests for the window footer connection status text (workspace connection state -> label)

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Footer Connection Status")
struct FooterConnectionStatusTests {

  @Test func statusTextForEachState() {
    let named = ConnectionConfig(host: "db.local", database: "shop", name: "Prod")
    let unnamed = ConnectionConfig(host: "db.local", database: "shop")

    let multiline = ConnectionConfig(
      host: "localhost", database: "dblore_test",
      name: "dblore-postgres-test\n\ndblore-postgres-test")

    #expect(FooterView.connectionStatusText(for: .disconnected, config: named) == "Not connected")
    #expect(FooterView.connectionStatusText(for: .connecting, config: named) == "Connecting...")
    #expect(FooterView.connectionStatusText(for: .connected, config: named) == "Connected")
    #expect(FooterView.connectionStatusText(for: .connected, config: unnamed) == "Connected")
    #expect(FooterView.connectionStatusText(for: .connected, config: multiline) == "Connected")
    #expect(FooterView.connectionStatusText(for: .connected, config: nil) == "Connected")
    #expect(
      FooterView.connectionStatusText(for: .error("boom"), config: nil) == "Connection failed")
    #expect(
      FooterView.connectionStatusText(
        for: .error("password authentication failed\nFATAL: remaining connection slots"),
        config: multiline) == "Connection failed")
  }

  @Test func footerTextNamesTheConnection() {
    let named = ConnectionConfig(host: "db.local", database: "shop", name: "Prod")
    let unnamed = ConnectionConfig(host: "db.local", database: "shop")
    let multiline = ConnectionConfig(
      host: "localhost", database: "dblore_test",
      name: "dblore-postgres-test\n\ndblore-postgres-test")

    #expect(FooterView.footerStatusText(for: .connected, config: named) == "Connected to Prod")
    #expect(
      FooterView.footerStatusText(for: .connected, config: multiline)
        == "Connected to dblore-postgres-test dblore-postgres-test")
    #expect(FooterView.footerStatusText(for: .connected, config: unnamed) == "Connected")
    #expect(FooterView.footerStatusText(for: .connected, config: nil) == "Connected")
    #expect(FooterView.footerStatusText(for: .connecting, config: named) == "Connecting...")
    #expect(FooterView.footerStatusText(for: .error("boom"), config: named) == "Connection failed")
  }
}
