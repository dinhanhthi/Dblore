// SSHHostKeyTrustCoordinator.swift
// The app-wide SSH host-key prompt. Every DatabaseConnectionManager of the app gets it, so
// connect, Test Connection, banner Reconnect and internal reconnects all ask through one
// sheet. Requests for the same key share one sheet and its answer; other hosts wait their turn.
// Time in the sheet does not count against the connection timeout (`SSHHandshakeDeadline`).
// When the server gives up meanwhile (sshd LoginGraceTime), the connect fails, its validator
// task is cancelled, and the sheet closes; the connect error says why.
// A changed key stays blocked until the user clicks Replace Pin in its alert: that stores the
// presented key and runs the caller's retry, the same connect through the normal path. Only the
// coordinator holds the retry (and the unremembered secrets it captured), and only while its
// alert is open. MCP, the CLI and Shortcuts never reach this alert
// (`MCPConnectionPool.refuseUnattended`).

import Foundation

/// A changed host key, for the blocking alert. `presented` and `presentedAlgorithm` are the
/// server's key: what Replace Pin stores.
nonisolated struct SSHHostKeyChange: Equatable, Sendable {
  var host: String
  var port: Int
  var expected: String
  var presented: String
  var presentedAlgorithm: String
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
  /// Blocking alert with both fingerprints and the man-in-the-middle warning. Cancel (the
  /// default) keeps the pin. `answered` gets true for Replace Pin, false for Cancel or when the
  /// alert goes away (its window closed), at most once. Returns false, and never calls
  /// `answered`, when the alert is not shown (another one is open).
  func presentHostKeyChanged(
    _ change: SSHHostKeyChange, answered: @escaping @MainActor (_ replace: Bool) -> Void
  ) -> Bool
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
  /// Where Replace Pin writes: the store `SSHHostKeyPolicy` reads by default.
  private let store: any SSHKnownHostStore
  /// Waiting requests in arrival order; the one with `shownID` is in the sheet.
  private var entries: [Entry] = []
  private var shownID: UUID?
  /// Host and fingerprint of keys declined because no window could show the sheet, so
  /// `report` does not call it a Cancel. Dropped once the sheet is shown for that key.
  private var unpresented: Set<String> = []
  /// Replace Pin's retry of each open changed-key alert; dropped once the alert ends.
  private var changedRetries: [UUID: @MainActor () -> Void] = [:]

  init(
    presenter: (any SSHHostKeyTrustPresenting)?,
    store: any SSHKnownHostStore = SSHKnownHostStoreFactory.shared
  ) {
    self.presenter = presenter
    self.store = store
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
  /// blocking alert, whose Replace Pin stores the presented key and then calls `retry` (the
  /// caller's same connect). A key declined because no window could show the sheet is not a
  /// Cancel.
  func report(_ error: any Error, retry: @escaping @MainActor () -> Void) -> String {
    switch error {
    case DatabaseError.sshHostKeyChanged(
      let host, let port, let expected, let presented, let algorithm):
      let change = SSHHostKeyChange(
        host: host, port: port, expected: expected, presented: presented,
        presentedAlgorithm: algorithm)
      let id = UUID()
      changedRetries[id] = retry
      let shown =
        presenter?.presentHostKeyChanged(change) { [weak self] replace in
          self?.changedAlertEnded(id, change: change, replace: replace)
        } ?? false
      if !shown { changedRetries[id] = nil }
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

  /// The alert ended: its retry leaves the coordinator, so a Cancel or a closed window drops it
  /// (and its secrets) at once, and Replace Pin holds it only until it runs.
  private func changedAlertEnded(_ id: UUID, change: SSHHostKeyChange, replace: Bool) {
    guard let retry = changedRetries.removeValue(forKey: id), replace else { return }
    replacePin(change, retry: retry)
  }

  private enum PinReplacement {
    case saved, changedMeanwhile, unreadable, failed
  }

  /// Replace Pin: stores exactly the presented key (off the main actor: Keychain I/O), then
  /// retries. Only while the pin is still the alert's expected key: one replaced or removed
  /// meanwhile is kept and nothing retries. A failed read or write keeps the connect blocked and
  /// says so; no retry.
  private func replacePin(_ change: SSHHostKeyChange, retry: @escaping @MainActor () -> Void) {
    let store = store
    Task {
      let outcome = await Task.detached { () -> PinReplacement in
        let stored: SSHKnownHost?
        do {
          stored = try store.lookup(host: change.host, port: change.port)
        } catch {
          return .unreadable
        }
        guard stored?.fingerprint == change.expected else { return .changedMeanwhile }
        let saved = store.replacePin(
          host: change.host, port: change.port, algorithm: change.presentedAlgorithm,
          fingerprint: change.presented)
        return saved ? .saved : .failed
      }.value
      switch outcome {
      case .saved:
        retry()
      case .changedMeanwhile:
        WorkspaceWindowManager.shared.showToast(
          "The SSH host key pin of \(change.host):\(change.port) changed since the warning was "
            + "shown, so it was not replaced. Connect again to review it.", type: .error)
      case .unreadable:
        WorkspaceWindowManager.shared.showToast(
          DatabaseError.sshHostKeyStoreUnreadable(host: change.host, port: change.port)
            .localizedDescription, type: .error)
      case .failed:
        WorkspaceWindowManager.shared.showToast(
          DatabaseError.sshHostKeyPinFailed(host: change.host, port: change.port)
            .localizedDescription, type: .error)
      }
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
