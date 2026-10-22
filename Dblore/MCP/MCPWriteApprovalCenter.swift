// MCPWriteApprovalCenter.swift
// The broker for MCP write approvals. An execute_write call waits here until the user approves
// or denies that one request; one not answered within `timeout` (120 s, counted from when it is
// shown), or whose HTTP request was cancelled, is denied. Requests queue in arrival order and are
// shown one at a time; at most `maxWaiting` wait, a further one is refused at once
// (`MCPToolError.writeTooManyWaiting`). Approve is ignored for `approveDelay` (1 s) from when
// the panel is put on screen with a request, so a click or key meant for the previous one never
// approves it. Nothing is
// remembered after an answer, so every call asks again (no standing grants). The server denies
// the waiting requests of a connection that loses its write scope or leaves the allowlist, and
// all of them when write tools or MCP are turned off and when the server stops or restarts
// (a new token, a new port) (`denyWaiting`, `denyAllWaiting`). The panel is
// app-level (`MCPWriteApprovalPanel`, an NSPanel owned here, not a workspace view), so it shows
// even when only the Welcome window is open. Separate from AI access: MCP never approves that.

import Foundation
import Observation

/// One write an MCP client asked for, as the panel shows it.
nonisolated struct MCPWriteApprovalRequest: Sendable, Equatable, Identifiable {
  let id = UUID()
  /// The saved connection it would change
  let connectionID: UUID
  /// What the client calls itself (its User-Agent): reported by the client, not verified
  let clientName: String
  let connectionName: String
  let engine: String
  /// Exactly what runs on Approve
  let statement: String
  /// What the classifier found ("Data modification", "Schema change")
  let classification: String
  /// Classifier warnings: no WHERE, removes data for good
  let warnings: [String]
}

/// How the tool service asks for approval; `MCPWriteApprovalCenter` in the app.
nonisolated protocol MCPWriteApproving: Sendable {
  /// True only when the user approved this request. Throws `MCPToolError.writeTooManyWaiting`
  /// when too many requests already wait.
  func approve(_ request: MCPWriteApprovalRequest) async throws -> Bool
  /// Denies every waiting request for one of `connections`.
  func denyWaiting(connections: Set<UUID>) async
  /// Denies every waiting request.
  func denyAllWaiting() async
}

/// Shows the center's current request, or hides when there is none.
@MainActor
protocol MCPWriteApprovalPresenting: AnyObject {
  func update(_ center: MCPWriteApprovalCenter)
}

@MainActor
@Observable
final class MCPWriteApprovalCenter {
  static let shared = MCPWriteApprovalCenter()
  nonisolated static let defaultTimeout = Duration.seconds(120)
  nonisolated static let defaultApproveDelay = Duration.seconds(1)
  /// Most requests waiting at once, the shown one included
  nonisolated static let maxWaiting = 3

  /// Waiting requests, oldest first; the first is shown
  private(set) var queue: [MCPWriteApprovalRequest] = []
  /// False for `approveDelay` after the current request shows: Approve is ignored
  private(set) var approveEnabled = false

  var current: MCPWriteApprovalRequest? { queue.first }

  @ObservationIgnored private var continuations: [UUID: CheckedContinuation<Bool, any Error>] =
    [:]
  @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var enabling: Task<Void, Never>?
  @ObservationIgnored private let timeout: Duration
  @ObservationIgnored private let approveDelay: Duration
  @ObservationIgnored private var presenter: (any MCPWriteApprovalPresenting)?

  /// `presenter` nil: the app's panel, none under the test host.
  init(
    timeout: Duration = defaultTimeout, approveDelay: Duration = defaultApproveDelay,
    presenter: (any MCPWriteApprovalPresenting)? = nil
  ) {
    self.timeout = timeout
    self.approveDelay = approveDelay
    self.presenter =
      presenter ?? (SessionManager.isRunningAsTestHost ? nil : MCPWriteApprovalPanel())
  }

  /// Waits for the user's answer to `request`: true on Approve; false on Deny, `timeout` after
  /// it shows, or when the calling task is cancelled. Throws `writeTooManyWaiting` at once when
  /// `maxWaiting` requests already wait.
  func request(_ request: MCPWriteApprovalRequest) async throws -> Bool {
    let id = request.id
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        guard queue.count < Self.maxWaiting else {
          continuation.resume(throwing: MCPToolError.writeTooManyWaiting)
          return
        }
        continuations[id] = continuation
        queue.append(request)
        showCurrent()
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.decide(id, approved: false) }
    }
  }

  /// The user's answer to one request; an answered or unknown id is ignored, and so is an
  /// approval of a request not shown or still in its `approveDelay`.
  func decide(_ id: UUID, approved: Bool) {
    if approved, id != current?.id || !approveEnabled { return }
    guard let continuation = continuations.removeValue(forKey: id) else { return }
    timers.removeValue(forKey: id)?.cancel()
    queue.removeAll { $0.id == id }
    continuation.resume(returning: approved)
    showCurrent()
  }

  /// Denies every waiting request (Deny all, write tools turned off).
  func denyAll() {
    for request in queue { decide(request.id, approved: false) }
  }

  /// Denies the waiting requests for `connections` (write scope or allowlist removed).
  func deny(connections: Set<UUID>) {
    for request in queue where connections.contains(request.connectionID) {
      decide(request.id, approved: false)
    }
  }

  /// Updates the panel. A request shown for the first time starts its timeout, with Approve
  /// off; the Approve delay starts once the presenter has put it on screen.
  private func showCurrent() {
    let shown = current.flatMap { timers[$0.id] == nil ? $0.id : nil }
    if let id = shown {
      let timeout = timeout
      timers[id] = Task { [weak self] in
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled else { return }
        self?.decide(id, approved: false)
      }
      enabling?.cancel()
      approveEnabled = approveDelay <= .zero
    }
    presenter?.update(self)
    guard let id = shown, !approveEnabled else { return }
    let delay = approveDelay
    enabling = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self, self.current?.id == id else { return }
      self.approveEnabled = true
    }
  }
}

extension MCPWriteApprovalCenter: MCPWriteApproving {
  nonisolated func approve(_ request: MCPWriteApprovalRequest) async throws -> Bool {
    try await self.request(request)
  }

  nonisolated func denyWaiting(connections: Set<UUID>) async {
    await deny(connections: connections)
  }

  nonisolated func denyAllWaiting() async {
    await denyAll()
  }
}
