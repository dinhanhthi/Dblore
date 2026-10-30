// AppleIntelligenceChatClient.swift
// Chat through Apple Intelligence's system model (FoundationModels, macOS 26 and later): one
// session per request, streamed on this Mac. Also fits requests into the system model's context.

import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

nonisolated extension AppleIntelligencePromptBudget {
  /// Context size of the system model where FoundationModels cannot be read; the factory refuses
  /// Apple Intelligence there, so this only keeps the code total
  private static let fallbackContextSize = 4_096

  /// `fit` against the system model: its context size, and `tokenCount(for:)` on macOS 26.4 and
  /// later, else `estimatedTokens`
  static func fitSystemModel(
    reserve: Int, history: [AIChatMessage], system: @escaping @Sendable (String) -> String,
    renderSchema: @escaping @Sendable (Int) -> String
  ) async throws -> Fitted {
    var contextSize = fallbackContextSize
    var tokenCount: @Sendable (String) async throws -> Int = { estimatedTokens($0) }
    #if canImport(FoundationModels)
      if #available(macOS 26, *) {
        contextSize = SystemLanguageModel.default.contextSize
        if #available(macOS 26.4, *) {
          tokenCount = { try await SystemLanguageModel.default.tokenCount(for: $0) }
        }
      }
    #endif
    return try await fit(
      contextSize: contextSize, reserve: reserve, history: history, system: system,
      renderSchema: renderSchema, tokenCount: tokenCount)
  }
}

#if canImport(FoundationModels)
  /// The system model behind `AIChatClient`. Text only: `request.tools` and tool blocks are never
  /// sent (on-device providers get no tools), so `supportsNativeTools` keeps its default, false.
  /// Callers fit the request first (`AppleIntelligencePromptBudget.fitSystemModel`).
  @available(macOS 26, *)
  nonisolated struct AppleIntelligenceChatClient: AIChatClient {
    /// Instructions are the system prompt, earlier messages the transcript, and the last user
    /// message the prompt; the answer is capped at the chat reserve the budget kept free.
    /// Snapshots are cumulative: each yields only its new text.
    func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
      AsyncThrowingStream { continuation in
        let task = Task {
          do {
            let messages = Self.alternating(request.messages)
            guard let last = messages.last, last.role == .user else {
              throw AIClientError.transport("Apple Intelligence needs a question to answer.")
            }
            let session = LanguageModelSession(
              model: .default, tools: [],
              transcript: Self.transcript(system: request.system, history: messages.dropLast()))
            let options = GenerationOptions(
              maximumResponseTokens: max(
                1, min(request.maxTokens, AppleIntelligencePromptBudget.chatReserve)))
            var sent = ""
            for try await snapshot in session.streamResponse(to: last.text, options: options) {
              try Task.checkCancellation()
              let text = snapshot.content
              // Compared by Unicode scalar: a combining mark may join a character already sent
              guard text.unicodeScalars.starts(with: sent.unicodeScalars) else { continue }
              let delta = String(text.unicodeScalars.dropFirst(sent.unicodeScalars.count))
              guard !delta.isEmpty else { continue }
              sent = text
              continuation.yield(.text(delta))
            }
            continuation.finish()
          } catch is CancellationError {
            continuation.finish()
          } catch let error as AIClientError {
            continuation.finish(throwing: error)
          } catch {
            continuation.finish(throwing: AIClientError.transport(Self.userMessage(error)))
          }
        }
        continuation.onTermination = { termination in
          if case .cancelled = termination { task.cancel() }
        }
      }
    }

    func listModels() async throws -> [String] {
      [AIProviderKind.appleIntelligenceModel]
    }

    /// Text only, consecutive messages of one role joined: a transcript alternates prompts and
    /// responses, while history can hold a query result placeholder right before the question
    static func alternating(_ messages: [AIChatMessage]) -> [AIChatMessage] {
      messages.reduce(into: []) { result, message in
        if let previous = result.last, previous.role == message.role {
          result[result.count - 1] = AIChatMessage(
            role: message.role, text: previous.text + "\n\n" + message.text)
        } else {
          result.append(AIChatMessage(role: message.role, text: message.text))
        }
      }
    }

    private static func transcript(
      system: String, history: ArraySlice<AIChatMessage>
    ) -> Transcript {
      func segments(_ text: String) -> [Transcript.Segment] {
        [.text(Transcript.TextSegment(content: text))]
      }
      let turns: [Transcript.Entry] = history.map { message in
        switch message.role {
        case .user: .prompt(Transcript.Prompt(segments: segments(message.text)))
        case .assistant:
          .response(Transcript.Response(assetIDs: [], segments: segments(message.text)))
        }
      }
      return Transcript(
        entries: [
          .instructions(Transcript.Instructions(segments: segments(system), toolDefinitions: []))
        ]
          + turns)
    }

    /// What the user reads for a generation error; macOS 27 throws `LanguageModelError`, 26
    /// `LanguageModelSession.GenerationError`
    static func userMessage(_ error: any Error) -> String {
      let tooLong = AppleIntelligencePromptBudget.BudgetError.tooLong.localizedDescription
      let declined = "Apple Intelligence declined this request. Rephrase it and try again."
      let busy = "Apple Intelligence is busy. Try again in a moment."
      let language = "Apple Intelligence doesn't support this language yet."
      if #available(macOS 27, *), let error = error as? LanguageModelError {
        switch error {
        case .contextSizeExceeded: return tooLong
        case .guardrailViolation, .refusal: return declined
        case .rateLimited: return busy
        case .unsupportedLanguageOrLocale: return language
        case .timeout: return "Apple Intelligence did not answer in time."
        default: return error.localizedDescription
        }
      }
      if let error = error as? LanguageModelSession.GenerationError {
        switch error {
        case .exceededContextWindowSize: return tooLong
        case .guardrailViolation, .refusal: return declined
        case .rateLimited, .concurrentRequests: return busy
        case .unsupportedLanguageOrLocale: return language
        case .assetsUnavailable:
          return AppleIntelligenceAvailability.modelNotReady.message ?? error.localizedDescription
        default: return error.localizedDescription
        }
      }
      return error.localizedDescription
    }
  }
#endif
