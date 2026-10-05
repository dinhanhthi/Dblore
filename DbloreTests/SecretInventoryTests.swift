// SecretInventoryTests.swift
// In-memory secret inventory: list, delete one, delete a kind. The Keychain is never opened.

import Foundation
import Testing

@testable import Dblore

@Suite("Secret inventory")
struct SecretInventoryTests {
  private func planted() -> [SecretItem] {
    [
      SecretItem(
        service: SessionManager.keychainService,
        account: "db.example:5432:app:ada",
        label: "db.example:5432:app:ada",
        kind: .dbPassword),
      SecretItem(
        service: KeychainAIKeyStore.serviceName,
        account: AIKeyStoreFactory.apiKeyAccount(AIProviderKind.openAI.rawValue),
        label: AIKeyStoreFactory.apiKeyAccount(AIProviderKind.openAI.rawValue),
        kind: .aiKey),
      SecretItem(
        service: KeychainAIKeyStore.serviceName,
        account: AIKeyStoreFactory.apiKeyAccount(AIProviderKind.anthropic.rawValue),
        label: AIKeyStoreFactory.apiKeyAccount(AIProviderKind.anthropic.rawValue),
        kind: .aiKey),
      SecretItem(
        service: KeychainAIKeyStore.serviceName,
        account: ChatGPTTokenStorage.account,
        label: ChatGPTTokenStorage.account,
        kind: .chatGPTToken),
      SecretItem(
        service: KeychainPasswordStore.serviceName,
        account: KeychainPasswordStore.accountName,
        label: KeychainPasswordStore.accountName,
        kind: .safeModePassword),
      SecretItem(
        service: KeychainClientCertificateStore.serviceName,
        account: "db.example:5432:app:ada",
        label: "db.example:5432:app:ada",
        kind: .clientCertificate),
    ]
  }

  @Test("List returns the planted items")
  func listReturnsPlantedItems() async {
    let items = planted()
    let inventory = InMemorySecretInventory(items: items)
    #expect(await inventory.items() == items)
  }

  @Test("Delete one leaves the others")
  func deleteOneLeavesTheOthers() async throws {
    let items = planted()
    let inventory = InMemorySecretInventory(items: items)
    try await inventory.delete(items[4])
    #expect(await inventory.items() == [items[0], items[1], items[2], items[3], items[5]])
  }

  @Test("deleteAll removes only that kind")
  func deleteAllRemovesOnlyThatKind() async throws {
    let items = planted()
    let inventory = InMemorySecretInventory(items: items)
    try await inventory.deleteAll(kind: .aiKey)
    #expect(await inventory.items() == [items[0], items[3], items[4], items[5]])
  }

  @Test("ChatGPT tokens and API keys are different kinds")
  func classifiesAccounts() {
    let chat = SecretItem.listed(
      service: KeychainAIKeyStore.serviceName, account: ChatGPTTokenStorage.account)
    #expect(chat.kind == .chatGPTToken)
    #expect(chat.label == ChatGPTTokenStorage.account)

    let key = SecretItem.listed(
      service: KeychainAIKeyStore.serviceName,
      account: AIKeyStoreFactory.apiKeyAccount(AIProviderKind.openAI.rawValue))
    #expect(key.kind == .aiKey)

    let database = SecretItem.listed(
      service: SessionManager.keychainService, account: "localhost:5432:app:ada")
    #expect(database.kind == .dbPassword)
    #expect(database.label == database.account)

    let safeMode = SecretItem.listed(
      service: KeychainPasswordStore.serviceName, account: KeychainPasswordStore.accountName)
    #expect(safeMode.kind == .safeModePassword)

    let certificate = SecretItem.listed(
      service: KeychainClientCertificateStore.serviceName,
      account: "db.example:5432:app:ada")
    #expect(certificate.kind == .clientCertificate)
    #expect(certificate.label == certificate.account)
  }

  @Test("The default inventory is in-memory under the test host")
  func defaultInventoryIsInMemory() {
    #expect(SecretInventoryFactory.makeDefault() is InMemorySecretInventory)
  }

  @Test("Inventory source does not request secret bytes")
  func sourceOmitsSecretBytes() throws {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Dblore/Utilities/DataManagement/SecretInventory.swift")
    let text = try String(contentsOf: source, encoding: .utf8)
    #expect(!text.contains("kSecReturnData"))
    #expect(!text.contains("kSecReturnPersistentRef"))
    #expect(text.contains("removePassword"))
  }
}
