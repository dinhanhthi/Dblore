// FooterConnectionStatusTests.swift
// Tests for the window footer connection status text (workspace connection state -> label)

import Foundation
import Testing

@testable import SQLNotebook

@MainActor
@Suite("Footer Connection Status")
struct FooterConnectionStatusTests {

  @Test func statusTextForEachState() {
    let named = ConnectionConfig(host: "db.local", database: "shop", name: "Prod")
    let unnamed = ConnectionConfig(host: "db.local", database: "shop")

    #expect(FooterView.connectionStatusText(for: .disconnected, config: named) == "Not connected")
    #expect(FooterView.connectionStatusText(for: .connecting, config: named) == "Connecting...")
    #expect(FooterView.connectionStatusText(for: .connected, config: named) == "Connected to Prod")
    #expect(
      FooterView.connectionStatusText(for: .connected, config: unnamed)
        == "Connected to shop@db.local")
    #expect(FooterView.connectionStatusText(for: .connected, config: nil) == "Connected")
    #expect(FooterView.connectionStatusText(for: .error("boom"), config: nil) == "Error: boom")
  }
}
