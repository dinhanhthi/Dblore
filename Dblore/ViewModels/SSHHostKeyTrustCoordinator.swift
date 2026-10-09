// SSHHostKeyTrustCoordinator.swift
// The app-wide SSH host-key prompt. Every DatabaseConnectionManager of the app gets it, so
// connect, Test Connection, banner Reconnect and internal reconnects all ask through one
// sheet. Requests for the same key share one sheet and its answer; other hosts wait their turn.
// Time in the sheet does not count against the connection timeout (`SSHHandshakeDeadline`).
// When the server gives up meanwhile (sshd LoginGraceTime), the connect fails, its validator
// task is cancelled, and the sheet closes; the connect error says why.

import Foundation

/// A changed host key, for the blocking alert.
nonisolated struct SSHHostKeyChange: Equatable, Sendable {
  var host: String
  var port: Int
  var expected: String
  var presented: String
}

/// Shows the trust sheet and the changed-key alert. Production: `AppKitSSHHostKeyTrustPresenter`.
@MainActor
protocol SSHHostKeyTrustPresenting: AnyObject {
  /// Shows the sheet. `decide` gets the user's answer, or false when the window hosting the
  /// sheet goes away, and is called at most once. Returns false when nothing can host it.
  func presentTrust(
    _ request: SSHHostKeyTrustRequest, decide: @escaping @MainActor (Bool) -> Void
  ) -> Bool
  /// Closes the sheet without an answer (every waiting connect was cancelled).
  func dismissTrust()
  /// Blocking alert with both fingerprints and the man-in-the-middle warning. No Trust button.
  func presentHostKeyChanged(_ change: SSHHostKeyChange)
}

@MainActor
final class SSHHostKeyTrustCoordinator: SSHHostKeyPrompt {
  /// No presenter in the test host: every unknown host is declined, as before the sheet.
  static let shared = SSHHostKeyTrustCoordinator(
    presenter: SessionManager.isRunningAsTestHost ? nil : AppKitSSHHostKeyTrustPresenter())

  private struct Entry {
    let id = UUID()
    let request: SSHHostKeyTrustRequest
    var waiters: [UUID: CheckedContinuation<Bool, Never>]
  }

  private let presenter: (any SSHHostKeyTrustPresenting)?
  /// Waiting requests in arrival order; the one with `shownID` is in the sheet.
  private var entries: [Entry] = []
  private var shownID: UUID?
  /// Host and fingerprint of keys declined because no window could show the sheet, so
  /// `report` does not call it a Cancel. Dropped once the sheet is shown for that key.
  private var unpresented: Set<String> = []

  init(presenter: (any SSHHostKeyTrustPresenting)?) {
    self.presenter = presenter
  }

  nonisolated func confirmUnknownHost(_ request: SSHHostKeyTrustRequest) async -> Bool {
    await confirm(request)
  }

  /// True once the user trusts the key. A cancelled caller gets false and leaves the queue.
  func confirm(_ request: SSHHostKeyTrustRequest) async -> Bool {
    let waiter = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        enqueue(request, waiter: waiter, continuation: continuation)
      }
    } onCancel: {
      Task { @MainActor in self.withdraw(waiter) }
    }
  }

  /// The text for a failed connect or Test Connection. A changed host key also shows the
  /// blocking alert. A key declined because no window could show the sheet is not a Cancel.
  func report(_ error: any Error) -> String {
    switch error {
    case DatabaseError.sshHostKeyChanged(let host, let port, let expected, let presented):
      presenter?.presentHostKeyChanged(
        SSHHostKeyChange(host: host, port: port, expected: expected, presented: presented))
      return "Connection blocked: the SSH host key of \(host):\(port) changed."
    case DatabaseError.sshHostKeyNotTrusted(let host, let fingerprint)
    where unpresented.contains(Self.key(host: host, fingerprint: fingerprint)):
      return "Connection not opened: the SSH host key prompt could not be shown. Open a window "
        + "and connect again."
    case DatabaseError.sshHostKeyNotTrusted:
      return "Connection cancelled. The SSH host key was not trusted."
    default:
      return error.localizedDescription
    }
  }

  // MARK: - Queue

  /// Same host, port and key: the same question, so it shares the pending answer. A
  /// different key for the same host:port is asked separately.
  private func enqueue(
    _ request: SSHHostKeyTrustRequest, waiter: UUID,
    continuation: CheckedContinuation<Bool, Never>
  ) {
    guard !Task.isCancelled else {
      continuation.resume(returning: false)
      return
    }
    if let index = entries.firstIndex(where: { $0.request == request }) {
      entries[index].waiters[waiter] = continuation
      return
    }
    entries.append(Entry(request: request, waiters: [waiter: continuation]))
    showNext()
  }

  private func showNext() {
    guard shownID == nil, let head = entries.first else { return }
    shownID = head.id
    let shown =
      presenter?.presentTrust(head.request) { [weak self] trusted in
        self?.decide(head.id, trusted)
      } ?? false
    let key = Self.key(host: head.request.host, fingerprint: head.request.fingerprint)
    if shown {
      unpresented.remove(key)
    } else {
      unpresented.insert(key)
      decide(head.id, false)
    }
  }

  private static func key(host: String, fingerprint: String) -> String {
    "\(host)\n\(fingerprint)"
  }

  private func decide(_ id: UUID, _ trusted: Bool) {
    guard shownID == id, let index = entries.firstIndex(where: { $0.id == id }) else { return }
    shownID = nil
    let entry = entries.remove(at: index)
    for continuation in entry.waiters.values {
      continuation.resume(returning: trusted)
    }
    showNext()
  }

  private func withdraw(_ waiter: UUID) {
    guard let index = entries.firstIndex(where: { $0.waiters[waiter] != nil }) else { return }
    entries[index].waiters.removeValue(forKey: waiter)?.resume(returning: false)
    guard entries[index].waiters.isEmpty else { return }
    let entry = entries.remove(at: index)
    guard shownID == entry.id else { return }
    shownID = nil
    presenter?.dismissTrust()
    showNext()
  }
}

extension DatabaseConnectionManager {
  /// A connection manager whose SSH host-key prompt is the app-wide trust sheet.
  @MainActor
  static func withTrustPrompt() -> DatabaseConnectionManager {
    DatabaseConnectionManager(sshHostKeyPrompt: SSHHostKeyTrustCoordinator.shared)
  }
}
