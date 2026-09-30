// MLXChatClientTests.swift
// Pure tests for the on-device MLX chat client (no model is loaded)

import Foundation
import MLXLMCommon
import Testing

@testable import Dblore

@Suite("MLXChatClient")
struct MLXChatClientTests {
  @Test("sanitizeTemperature rejects NaN and negatives, caps at 1.0")
  func temperature() {
    #expect(MLXChatClient.sanitizeTemperature(.nan) == 0.2)
    #expect(MLXChatClient.sanitizeTemperature(-1) == 0.2)
    #expect(MLXChatClient.sanitizeTemperature(.infinity) == 0.2)
    #expect(MLXChatClient.sanitizeTemperature(0) == 0)
    #expect(MLXChatClient.sanitizeTemperature(0.5) == 0.5)
    #expect(MLXChatClient.sanitizeTemperature(5) == 1.0)
  }

  @Test("maxTokens is clamped to 1...4096")
  func maxTokens() {
    #expect(MLXChatClient.clampMaxTokens(0) == 1)
    #expect(MLXChatClient.clampMaxTokens(-5) == 1)
    #expect(MLXChatClient.clampMaxTokens(2048) == 2048)
    #expect(MLXChatClient.clampMaxTokens(100_000) == 4096)
  }

  @Test("messages put the system prompt first and keep roles")
  func messageMapping() {
    let request = AIChatRequest(
      model: "qwen3-4b-instruct-2507", system: "be brief",
      messages: [
        AIChatMessage(role: .user, text: "hi"),
        AIChatMessage(role: .assistant, text: "hello"),
        AIChatMessage(role: .user, text: "sql?"),
      ])
    let mapped = MLXChatClient.chatMessages(for: request)
    #expect(mapped.map(\.role) == [.system, .user, .assistant, .user])
    #expect(mapped.map(\.content) == ["be brief", "hi", "hello", "sql?"])
  }

  @Test("empty system prompt is omitted")
  func emptySystem() {
    let request = AIChatRequest(
      model: "x", system: "", messages: [AIChatMessage(role: .user, text: "hi")])
    #expect(MLXChatClient.chatMessages(for: request).map(\.role) == [.user])
  }

  @Test("enable_thinking false only for Qwen3 ids")
  func thinkingContext() {
    let qwen = MLXChatClient.additionalContext(forModel: "qwen3-4b-instruct-2507")
    #expect(qwen?["enable_thinking"] as? Bool == false)
    #expect(MLXChatClient.additionalContext(forModel: "qwen2.5-coder-1.5b") == nil)
    #expect(MLXChatClient.additionalContext(forModel: "omnisql-7b") == nil)
  }

  @Test("listModels reflects installed catalog entries")
  func listModels() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("MLXChatClientTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let client = MLXChatClient(root: root)
    #expect(try await client.listModels().isEmpty)

    let dir = root.appendingPathComponent("qwen2.5-coder-1.5b", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
    try Data().write(to: dir.appendingPathComponent("model.safetensors"))
    #expect(try await client.listModels() == ["qwen2.5-coder-1.5b"])
  }
}
