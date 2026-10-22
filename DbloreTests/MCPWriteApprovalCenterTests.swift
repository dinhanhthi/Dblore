// MCPWriteApprovalCenterTests.swift
// The MCP write approval broker: an unanswered request is denied after the timeout (counted
// from when it is shown), a cancelled one is denied, an approval covers one call only (the next
// call asks again), Approve is ignored just after a request shows, and at most
// `maxWaiting` requests wait.

import Foundation
import Testing

@testable import Dblore

/// Counts the requests put on screen, and when each was first shown.
@MainActor
private final class RecordingPresenter: MCPWriteApprovalPresenting {
  private(set) var shown: [UUID] = []
  private(set) var shownAt: [UUID: ContinuousClock.Instant] = [:]

  func update(_ center: MCPWriteApprovalCenter) {
    guard let id = center.current?.id, shown.last != id else { return }
    shown.append(id)
    shownAt[id] = .now
  }
}

@MainActor
@Suite("MCP write approval center", .timeLimit(.minutes(1)))
struct MCPWriteApprovalCenterTests {
  private func request(connection: UUID = UUID()) -> MCPWriteApprovalRequest {
    MCPWriteApprovalRequest(
      connectionID: connection, clientName: "agent", connectionName: "Orders",
      engine: "postgresql",
      statement: "DELETE FROM t WHERE id = 1", classification: "Data modification", warnings: [])
  }

  /// Waits until `center` has `count` requests waiting.
  private func waitFor(_ center: MCPWriteApprovalCenter, count: Int = 1) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while center.queue.count < count, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(center.queue.count == count)
  }

  /// Waits until `center` shows a request, then answers it.
  private func answer(_ center: MCPWriteApprovalCenter, approved: Bool) async throws {
    try await waitFor(center)
    let current = try #require(center.current)
    center.decide(current.id, approved: approved)
  }

  @Test("An unanswered request is denied after the timeout and leaves the queue")
  func timeoutDenies() async throws {
    let presenter = RecordingPresenter()
    let center = MCPWriteApprovalCenter(timeout: .milliseconds(50), presenter: presenter)
    let approved = try await center.request(request())
    #expect(!approved)
    #expect(center.queue.isEmpty)
    #expect(presenter.shown.count == 1)
  }

  @Test("An approval covers one call: the next call asks again")
  func secondCallAsksAgain() async throws {
    let presenter = RecordingPresenter()
    let center = MCPWriteApprovalCenter(
      timeout: .seconds(3600), approveDelay: .zero, presenter: presenter)
    async let first = center.request(request())
    try await answer(center, approved: true)
    #expect(try await first)

    async let second = center.request(request())
    try await answer(center, approved: false)
    #expect(try await !second)
    #expect(presenter.shown.count == 2)
    #expect(center.queue.isEmpty)
  }

  @Test("A request's timeout starts when it is shown, not when it is queued")
  func timeoutStartsWhenShown() async throws {
    let presenter = RecordingPresenter()
    let timeout = Duration.milliseconds(150)
    let center = MCPWriteApprovalCenter(timeout: timeout, presenter: presenter)
    let firstRequest = request()
    let secondRequest = request()
    async let first = center.request(firstRequest)
    try await waitFor(center)
    async let second = center.request(secondRequest)
    try await waitFor(center, count: 2)
    #expect(try await !first)
    #expect(try await !second)
    let ended = ContinuousClock.now
    // Queued with the first; shown only once the first timed out, then a whole timeout again
    let shown = try #require(presenter.shownAt[secondRequest.id])
    #expect(ended - shown >= timeout)
    #expect(presenter.shown == [firstRequest.id, secondRequest.id])
  }

  @Test("Cancelling the calling task denies its request")
  func cancelDenies() async throws {
    let center = MCPWriteApprovalCenter(timeout: .seconds(3600), approveDelay: .zero)
    let task = Task { try await center.request(request()) }
    try await waitFor(center)
    task.cancel()
    #expect(try await !task.value)
    #expect(center.queue.isEmpty)
  }

  @Test("Approve is ignored while the enable delay runs; Deny is not")
  func approveIgnoredDuringDelay() async throws {
    let center = MCPWriteApprovalCenter(timeout: .seconds(3600), approveDelay: .seconds(3600))
    async let result = center.request(request())
    try await waitFor(center)
    let current = try #require(center.current)
    #expect(!center.approveEnabled)
    center.decide(current.id, approved: true)
    #expect(center.current?.id == current.id)
    center.decide(current.id, approved: false)
    #expect(try await !result)
  }

  @Test("At most three requests wait: a fourth is refused at once; Deny all answers the rest")
  func fourthRequestRefused() async throws {
    let center = MCPWriteApprovalCenter(timeout: .seconds(3600), approveDelay: .zero)
    let connection = UUID()
    let waiting = (0..<MCPWriteApprovalCenter.maxWaiting).map { index in
      Task { try await center.request(request(connection: index == 0 ? connection : UUID())) }
    }
    try await waitFor(center, count: MCPWriteApprovalCenter.maxWaiting)
    await #expect(throws: MCPToolError.writeTooManyWaiting) {
      _ = try await center.request(request())
    }
    #expect(center.queue.count == MCPWriteApprovalCenter.maxWaiting)
    center.deny(connections: [connection])
    #expect(try await !waiting[0].value)
    #expect(center.queue.count == MCPWriteApprovalCenter.maxWaiting - 1)
    center.denyAll()
    for task in waiting { #expect(try await !task.value) }
    #expect(center.queue.isEmpty)
  }
}
