// AIEndpointTests.swift
// Unit tests for AI endpoint normalization and URL joining

import Foundation
import Testing

@testable import Dblore

@Suite("AI Endpoint Tests")
struct AIEndpointTests {

  @Test(
    "normalize accepts and canonicalizes base URLs",
    arguments: [
      ("http://localhost:11434", "http://localhost:11434/v1"),
      ("  https://api.openai.com/v1  ", "https://api.openai.com/v1"),
      ("https://x.com/v1/chat/completions", "https://x.com/v1"),
      ("https://x.com/v1/chat/completions/", "https://x.com/v1"),
      ("https://x.com/v1/messages", "https://x.com/v1"),
      ("https://x.com/v1/responses", "https://x.com/v1"),
      ("https://x.com/v1/models", "https://x.com/v1"),
      ("https://openrouter.ai/api/v1/", "https://openrouter.ai/api/v1"),
      ("https://x.com", "https://x.com/v1"),
      ("https://x.com/", "https://x.com/v1"),
      ("https://x.com/v2beta", "https://x.com/v2beta"),
      ("https://x.com/api", "https://x.com/api/v1"),
      ("http://192.168.1.5:8080", "http://192.168.1.5:8080/v1"),
      ("http://mac.local:1234", "http://mac.local:1234/v1"),
      ("http://127.0.0.1:1234/v1", "http://127.0.0.1:1234/v1"),
      ("http://[::1]:8080", "http://[::1]:8080/v1"),
      ("http://10.0.0.5:8080", "http://10.0.0.5:8080/v1"),
      ("http://172.16.0.1", "http://172.16.0.1/v1"),
      ("http://100.64.0.1", "http://100.64.0.1/v1"),
      ("http://169.254.1.1", "http://169.254.1.1/v1"),
      ("http://[fd00::1]", "http://[fd00::1]/v1"),
      ("http://[fe80::1]", "http://[fe80::1]/v1"),
    ])
  func normalizeAccepts(raw: String, expected: String) throws {
    #expect(try AIEndpoint.normalize(raw).absoluteString == expected)
  }

  @Test(
    "normalize rejects unsafe or malformed input",
    arguments: [
      "",
      "   ",
      "http://example.com",
      "http://203.0.113.5",
      "http://8.8.8.8",
      "http://999.1.1.1",
      "http://010.0.0.1",
      "http://172.016.0.1",
      "http://0100.64.0.1",
      "http://192.168.01.1",
      "http://172.32.0.1",
      "http://100.128.0.1",
      "http://[2001:db8::1]",
      "ftp://example.com",
      "https://u:p@x.com",
      "https://u@x.com",
      "https://",
      "not a url",
    ])
  func normalizeRejects(raw: String) {
    #expect(throws: AIEndpointError.self) { try AIEndpoint.normalize(raw) }
  }

  @Test("chatURL and modelsURL join onto the base")
  func joins() throws {
    let base = try AIEndpoint.normalize("https://x.com")
    #expect(
      AIEndpoint.chatURL(base: base, wire: .chatCompletions).absoluteString
        == "https://x.com/v1/chat/completions")
    #expect(
      AIEndpoint.chatURL(base: base, wire: .anthropicMessages).absoluteString
        == "https://x.com/v1/messages")
    #expect(AIEndpoint.modelsURL(base: base).absoluteString == "https://x.com/v1/models")
  }

  @Test("the Gemini base URL normalizes unchanged and builds the per-model stream URL")
  func geminiURLs() throws {
    let base = try AIEndpoint.normalize(AIProviderKind.gemini.defaultBaseURL)
    #expect(base.absoluteString == "https://generativelanguage.googleapis.com/v1beta")
    #expect(
      try AIEndpoint.normalize("https://generativelanguage.googleapis.com/v1beta/models/")
        == base)
    #expect(AIEndpoint.chatURL(base: base, wire: .geminiGenerateContent) == base)
    #expect(
      try AIEndpoint.geminiStreamURL(base: base, model: "models/gemini-2.5-flash").absoluteString
        == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
    )
    #expect(
      AIEndpoint.modelsURL(base: base).absoluteString
        == "https://generativelanguage.googleapis.com/v1beta/models")
  }

  @Test(
    "Gemini model ids that could add a path, query or fragment are refused",
    arguments: ["", "models/", "a/b", "..", "../a", ".a", "-a", "a?x", "a#x", "a b", "a\n", "é"])
  func geminiModelRefused(model: String) throws {
    let base = try AIEndpoint.normalize(AIProviderKind.gemini.defaultBaseURL)
    #expect(AIEndpoint.geminiModelID(model) == nil)
    #expect(throws: AIEndpointError.invalidModel) {
      try AIEndpoint.geminiStreamURL(base: base, model: model)
    }
  }

  @Test("Gemini model ids keep dots, dashes and underscores")
  func geminiModelAccepted() {
    #expect(AIEndpoint.geminiModelID("gemini-2.5-flash-lite") == "gemini-2.5-flash-lite")
    #expect(AIEndpoint.geminiModelID("models/gemini_exp.1") == "gemini_exp.1")
  }
}
