// NonisolatedDefaultsTests.swift
// Default members of the nonisolated AIChatClient and DatabaseSessionFactory protocols must not
// hop to the main actor when called from a background task.

import Foundation
import Testing

@testable import Dblore

/// Records whether `listModels` ran on the main thread. Nonisolated async members run on the
/// caller's executor, so this reports where the default `listModelsResult` ran.
nonisolated private final class ThreadRecordingClient: AIChatClient, @unchecked Sendable {
  private let lock = NSLock()
  private var ranOnMain: Bool?

  var recordedMain: Bool? { lock.withLock { ranOnMain } }

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    AsyncThrowingStream { $0.finish() }
  }

  func listModels() async throws -> [String] {
    let onMain = pthread_main_np() != 0
    lock.withLock { ranOnMain = onMain }
    return []
  }
}

/// Records whether `makeSession(config:)` ran on the main thread, then throws (no session needed).
nonisolated private final class ThreadRecordingFactory: DatabaseSessionFactory, @unchecked Sendable
{
  struct Done: Error {}

  private let lock = NSLock()
  private var ranOnMain: Bool?

  var recordedMain: Bool? { lock.withLock { ranOnMain } }

  func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
    let onMain = pthread_main_np() != 0
    lock.withLock { ranOnMain = onMain }
    throw Done()
  }
}

struct NonisolatedDefaultsTests {
  @Test func aiChatClientDefaultRunsOffMainActor() async throws {
    let client = ThreadRecordingClient()
    _ = try await Task.detached { try await client.listModelsResult() }.value
    #expect(client.recordedMain == false)
  }

  @Test func sessionFactoryDefaultRunsOffMainActor() async throws {
    let factory = ThreadRecordingFactory()
    let config = ConnectionConfig()
    _ = try? await Task.detached {
      try await factory.makeSession(config: config, extraAllowedPaths: [])
    }.value
    #expect(factory.recordedMain == false)
  }
}
