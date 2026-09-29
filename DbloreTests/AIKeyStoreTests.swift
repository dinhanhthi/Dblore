// AIKeyStoreTests.swift
// Unit tests for the AI API key store (in-memory store, factory, account naming)

import Foundation
import Testing

@testable import Dblore

@Suite("AI Key Store Tests")
struct AIKeyStoreTests {

  @Test("In-memory store saves, loads, overwrites and deletes per account")
  func inMemoryRoundTrip() {
    let store = InMemoryAIKeyStore()
    #expect(store.load(account: "a") == nil)

    #expect(store.save("one", account: "a"))
    #expect(store.save("other", account: "b"))
    #expect(store.load(account: "a") == "one")

    #expect(store.save("two", account: "a"))
    #expect(store.load(account: "a") == "two")
    #expect(store.load(account: "b") == "other")

    store.delete(account: "a")
    #expect(store.load(account: "a") == nil)
    #expect(store.load(account: "b") == "other")
  }

  @Test("makeDefault returns the in-memory store under the test host")
  func factoryUsesInMemoryUnderTestHost() {
    #expect(AIKeyStoreFactory.makeDefault() is InMemoryAIKeyStore)
  }

  @Test("apiKeyAccount prefixes the provider raw value")
  func accountNaming() {
    #expect(AIKeyStoreFactory.apiKeyAccount("openAI") == "apikey.openAI")
  }
}
