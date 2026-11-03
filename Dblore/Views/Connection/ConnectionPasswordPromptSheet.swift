// ConnectionPasswordPromptSheet.swift
// The ask-on-connect password prompt: a sheet with a secure field, Cancel and Connect (or Test),
// its AppKit host and the app-wide coordinator. Asked at one point per path:
// `WorkspaceManager.connect(config:)` (after the lock step, before the Safe Mode hold), the
// Welcome form's held connect, and Test Connection (workspace and Welcome). The typed password
// goes to that one connect or test only: nothing writes it to the Keychain, a workspace file or
// the history. One sheet at a time; other requests wait their turn. A cancelled caller (a
// superseded auto-connect) gets Cancel and leaves the queue. MCP, the CLI and Shortcuts never
// ask (`MCPConnectionPool.refuseUnattended`).

import AppKit
import SwiftUI

/// What the prompt shows: the connection, never a password
nonisolated struct ConnectionPasswordRequest: Equatable, Sendable {
  enum Action: Equatable, Sendable {
    case connect, test
  }

  /// The connection's name, else its address
  let title: String
  /// `user@host:port/database`
  let detail: String
  let action: Action

  init(config: ConnectionConfig, action: Action) {
    let name = DropdownTitle.singleLine(config.name)
    title = name.isEmpty ? config.displayString : String(name.prefix(80))
    detail =
      "\(config.username)@\(config.host):\(config.port)"
      + (config.database.isEmpty ? "" : "/\(config.database)")
    self.action = action
  }
}

/// Shows the prompt. Production: `AppKitConnectionPasswordPresenter`.
@MainActor
protocol ConnectionPasswordPrompting: AnyObject {
  /// Shows the sheet on `anchor` (nil: the key window), above a sheet already on it. `answer`
  /// gets the typed password, or nil for Cancel or when its window goes away, at most once.
  /// Returns false when nothing can host it.
  func presentPasswordPrompt(
    _ request: ConnectionPasswordRequest, anchor: NSWindow?,
    answer: @escaping @MainActor (String?) -> Void
  ) -> Bool
  /// Closes the sheet without an answer (its connect was cancelled).
  func dismissPasswordPrompt()
}

@MainActor
final class ConnectionPasswordPromptCoordinator {
  /// No presenter in the test host: nothing is asked, and the connect guard refuses the empty
  /// password (`DatabaseError.passwordRequiredOnConnect`), as before the prompt.
  static let shared = ConnectionPasswordPromptCoordinator(
    presenter: SessionManager.isRunningAsTestHost ? nil : AppKitConnectionPasswordPresenter())

  enum Answer: Equatable {
    case typed(String)
    case cancelled
    /// Nothing could show the prompt
    case unavailable
  }

  private struct Waiter {
    let id: UUID
    let request: ConnectionPasswordRequest
    weak var anchor: NSWindow?
    let continuation: CheckedContinuation<Answer, Never>
  }

  private let presenter: (any ConnectionPasswordPrompting)?
  /// Waiting requests in arrival order; the one with `shownID` is in the sheet
  private var waiters: [Waiter] = []
  private var shownID: UUID?

  init(presenter: (any ConnectionPasswordPrompting)?) {
    self.presenter = presenter
  }

  /// The connect guard's condition (`DatabaseConnectionManager`): an ask-on-connect config of
  /// an engine that uses a password, without its typed password
  nonisolated static func asks(_ config: ConnectionConfig) -> Bool {
    config.askPasswordOnConnect && config.databaseType.capabilities.usesPassword
      && config.password.isEmpty
  }

  /// `config` with the password typed in the prompt when it `asks`, else as is. Unchanged too
  /// when nothing could show the prompt: the connect guard then refuses it.
  /// - Throws: `WorkspaceConnectError.unlockRequired` when the prompt was cancelled (nothing
  ///   connected or tested, no error to show)
  func withTypedPassword(
    _ config: ConnectionConfig, for action: ConnectionPasswordRequest.Action, anchor: NSWindow?
  ) async throws -> ConnectionConfig {
    guard Self.asks(config) else { return config }
    switch await ask(ConnectionPasswordRequest(config: config, action: action), anchor: anchor) {
    case .typed(let password):
      var config = config
      config.password = password
      return config
    case .cancelled:
      throw WorkspaceConnectError.unlockRequired
    case .unavailable:
      return config
    }
  }

  /// The user's answer. A cancelled caller gets `.cancelled` and leaves the queue.
  func ask(_ request: ConnectionPasswordRequest, anchor: NSWindow?) async -> Answer {
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        enqueue(
          Waiter(id: id, request: request, anchor: anchor, continuation: continuation))
      }
    } onCancel: {
      Task { @MainActor in self.withdraw(id) }
    }
  }

  private func enqueue(_ waiter: Waiter) {
    guard !Task.isCancelled else {
      waiter.continuation.resume(returning: .cancelled)
      return
    }
    guard presenter != nil else {
      waiter.continuation.resume(returning: .unavailable)
      return
    }
    waiters.append(waiter)
    showNext()
  }

  private func showNext() {
    guard shownID == nil, let head = waiters.first else { return }
    shownID = head.id
    let shown =
      presenter?.presentPasswordPrompt(head.request, anchor: head.anchor) { [weak self] typed in
        self?.finish(head.id, typed.map(Answer.typed) ?? .cancelled)
      } ?? false
    if !shown { finish(head.id, .unavailable) }
  }

  /// Answers waiter `id` once, then shows the next request
  private func finish(_ id: UUID, _ answer: Answer) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    if shownID == id { shownID = nil }
    waiter.continuation.resume(returning: answer)
    showNext()
  }

  /// The caller's task was cancelled: its sheet closes, or it leaves the queue
  private func withdraw(_ id: UUID) {
    if shownID == id { presenter?.dismissPasswordPrompt() }
    finish(id, .cancelled)
  }
}

// MARK: - Sheet

struct ConnectionPasswordPromptSheet: View {
  let request: ConnectionPasswordRequest
  let onAnswer: (String?) -> Void
  @State private var password = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      HStack(spacing: Spacing.md) {
        Image(systemName: "key.horizontal")
          .font(.system(size: 28))
          .foregroundColor(.accent)
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(verbatim: request.title)
            .font(.heading)
            .foregroundColor(.foreground)
            .lineLimit(2)
          Text(verbatim: request.detail)
            .font(.mono)
            .foregroundColor(.foregroundMuted)
            .lineLimit(2)
            .truncationMode(.middle)
        }
      }

      FormField(label: "Password") {
        SecureField("Required", text: $password)
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
          .focused($isFocused)
          .onSubmit(submit)
      }

      Text("Used for this \(request.action == .test ? "test" : "connection") only, never saved.")
        .font(.caption)
        .foregroundColor(.foregroundMuted)

      HStack(spacing: Spacing.md) {
        Spacer()
        Button("Cancel") { onAnswer(nil) }
          .buttonStyle(SecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
        Button(request.action == .test ? "Test" : "Connect", action: submit)
          .buttonStyle(PrimaryButtonStyle())
          .keyboardShortcut(.defaultAction)
          .disabled(password.isEmpty)
      }
    }
    .padding(Spacing.xl)
    .frame(width: 420)
    .background(Color.appBackground)
    .onAppear { isFocused = true }
  }

  /// An empty password is never sent: the guard would refuse it
  private func submit() {
    guard !password.isEmpty else { return }
    onAnswer(password)
  }
}

// MARK: - AppKit host

/// Presents the prompt as a window sheet, on the next run-loop turn so the connecting state the
/// click set shows first.
@MainActor
final class AppKitConnectionPasswordPresenter: ConnectionPasswordPrompting {
  private var sheet: NSWindow?
  private var answer: (@MainActor (String?) -> Void)?
  private var hostObservers: [any NSObjectProtocol] = []

  func presentPasswordPrompt(
    _ request: ConnectionPasswordRequest, anchor: NSWindow?,
    answer: @escaping @MainActor (String?) -> Void
  ) -> Bool {
    guard sheet == nil, let parent = Self.hostWindow(anchor) else { return false }
    self.answer = answer
    let view = ConnectionPasswordPromptSheet(request: request) { [weak self] typed in
      self?.finish(typed)
    }
    let window = NSWindow(contentViewController: NSHostingController(rootView: view))
    sheet = window
    observeHostGoingAway(parent, sheet: window)
    DispatchQueue.main.async { [weak self, weak window, weak parent] in
      MainActor.assumeIsolated {
        guard let self, let window, self.sheet === window else { return }
        guard let parent else { return self.finish(nil) }
        // Ended from outside (a relocked window's sweep ends every sheet on it): Cancel
        parent.beginSheet(window) { [weak self, weak window] _ in
          DispatchQueue.main.async {
            MainActor.assumeIsolated {
              guard let self, let window, self.sheet === window else { return }
              self.finish(nil)
            }
          }
        }
      }
    }
    return true
  }

  func dismissPasswordPrompt() {
    answer = nil
    closeSheet()
  }

  private func finish(_ typed: String?) {
    let pending = answer
    answer = nil
    closeSheet()
    pending?(typed)
  }

  /// The window hosting the sheet closed, or (itself a sheet, the connection form) ended
  /// without closing: nobody can answer, so Cancel. `finish` answers at most once.
  private func observeHostGoingAway(_ parent: NSWindow, sheet window: NSWindow) {
    let center = NotificationCenter.default
    hostObservers.append(
      center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.finish(nil) }
      })
    // A host that is itself a sheet can leave via endSheet/orderOut, which post no willClose:
    // its parent posts didEndSheet. Checked on the next turn, once AppKit has detached it.
    guard let grandparent = parent.sheetParent else { return }
    hostObservers.append(
      center.addObserver(
        forName: NSWindow.didEndSheetNotification, object: grandparent, queue: .main
      ) { [weak self, weak parent, weak window] _ in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard let self, let window, self.sheet === window else { return }
            let attached = parent?.sheetParent != nil && parent?.isVisible == true
            if !attached { self.finish(nil) }
          }
        }
      })
  }

  private func closeSheet() {
    for observer in hostObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    hostObservers = []
    guard let sheet else { return }
    self.sheet = nil
    if let parent = sheet.sheetParent {
      parent.endSheet(sheet)
    } else {
      sheet.orderOut(nil)
    }
  }

  /// `anchor` (else the frontmost visible window), descending into the sheets already on it
  private static func hostWindow(_ anchor: NSWindow?) -> NSWindow? {
    var window =
      anchor ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible }
    while let attached = window?.attachedSheet {
      window = attached
    }
    return window
  }
}
