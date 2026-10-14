// MCPTokenStoreTests.swift
// The MCP bearer token: 32 random bytes as unpadded base64url, created once, replaced on
// regenerate. The test host gets the in-memory store, never the Keychain.

import Foundation
import Testing

@testable import Dblore

@Suite("MCP token store")
struct MCPTokenStoreTests {
  private static func isToken(_ token: String) -> Bool {
    token.count == 43
      && token.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
      }
  }

  @Test("loadOrCreate makes a 43-character base64url token once, then returns it")
  func loadOrCreate() {
    let store = InMemoryMCPTokenStore()
    let token = store.loadOrCreate()
    #expect(Self.isToken(token))
    #expect(store.loadOrCreate() == token)
  }

  @Test("regenerate replaces the token")
  func regenerate() {
    let store = InMemoryMCPTokenStore()
    let first = store.loadOrCreate()
    let second = store.regenerate()
    #expect(Self.isToken(second))
    #expect(second != first)
    #expect(store.loadOrCreate() == second)
  }

  @Test("The test host uses the in-memory store")
  func testHostDouble() {
    #expect(MCPTokenStoreFactory.shared is InMemoryMCPTokenStore)
  }
}
