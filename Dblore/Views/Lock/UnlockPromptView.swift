//
//  UnlockPromptView.swift
//  Dblore
//
// The unlock prompt: a sheet on the window the locked item belongs to (over the sheet already
// open there, e.g. the connection form), never app-modal, so other windows stay usable. Touch
// ID or the Mac password, or the Lock password when one is set. The prompt only answers:
// LockCenter grants. The Lock password check (PBKDF2) and the store read run off the main
// actor; the entry is never logged.

import AppKit
import SwiftUI

/// What the prompt shows and decides
@MainActor
@Observable
final class UnlockPromptModel {
  let title: String
  let reason: String
  var password = ""
  /// Nil until read; `.absent` hides the password path, `.unreadable` keeps it (fail closed)
  private(set) var passwordState: UnlockPasswordVault.PasswordState?
  private(set) var isWorking = false
  private(set) var showsSpinner = false
  private(set) var message: String?

  @ObservationIgnored private let lockVault: UnlockPasswordVault
  @ObservationIgnored private let authenticator: any BiometricAuthenticator
  @ObservationIgnored private let answer: (Bool) -> Void
  @ObservationIgnored private var spinnerTask: Task<Void, Never>?

  init(
    item: LockIdentity, reason: String, lockVault: UnlockPasswordVault,
    authenticator: any BiometricAuthenticator, answer: @escaping (Bool) -> Void
  ) {
    title = Self.title(of: item)
    self.reason = reason
    self.lockVault = lockVault
    self.authenticator = authenticator
    self.answer = answer
  }

  var showsPasswordPath: Bool { passwordState == .present || passwordState == .unreadable }

  /// The system prompt reads "Dblore" is trying to <reason>: the sheet's sentence, lowercased
  /// first letter ("unlock qa to connect")
  private var systemReason: String { reason.prefix(1).lowercased() + reason.dropFirst() }

  func loadPasswordState() async {
    passwordState = await Self.passwordState(of: lockVault)
  }

  /// Touch ID or the Mac password (the system prompt)
  func authenticateOwner() {
    guard !isWorking else { return }
    begin()
    Task {
      let proof = await authenticator.authenticateOwner(reason: systemReason)
      end()
      guard let proof else {
        message = "Touch ID or the Mac password did not unlock."
        return
      }
      // No protected read follows here: end the context's reuse window at once
      proof.invalidate()
      answer(true)
    }
  }

  func unlockWithPassword() {
    guard !isWorking, !password.isEmpty else { return }
    let entry = password
    password = ""
    begin()
    Task {
      let outcome = await Self.verify(entry, with: lockVault)
      end()
      switch outcome {
      case .accepted:
        answer(true)
      case .rejected:
        message = "Wrong Lock password."
      case .throttled(let until):
        let seconds = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
        message = "Too many wrong entries. Try again in \(seconds) s."
      case .unreadable:
        message = "The Lock password cannot be read right now. Use Touch ID or the Mac password."
      case .noPassword:
        passwordState = .absent
        message = "No Lock password is set. Use Touch ID or the Mac password."
      }
    }
  }

  /// Disables the actions at once; the spinner fades in only after 150 ms
  private func begin() {
    isWorking = true
    message = nil
    spinnerTask = Task {
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled, isWorking else { return }
      showsSpinner = true
    }
  }

  private func end() {
    spinnerTask?.cancel()
    spinnerTask = nil
    isWorking = false
    showsSpinner = false
  }

  @concurrent nonisolated private static func passwordState(
    of vault: UnlockPasswordVault
  ) async -> UnlockPasswordVault.PasswordState {
    vault.passwordState
  }

  @concurrent nonisolated private static func verify(
    _ password: String, with vault: UnlockPasswordVault
  ) async -> UnlockPasswordVault.Outcome {
    vault.verify(password)
  }

  /// The locked item in words; a `fileID` is never named (it goes with its file)
  private static func title(of item: LockIdentity) -> String {
    switch item {
    case .server(let engine, let host, let port, let username):
      let login = username.isEmpty ? "\(host):\(port)" : "\(username)@\(host):\(port)"
      return "\(engine.displayName) \(login)"
    case .file(_, let path):
      return (path as NSString).lastPathComponent
    case .fileID:
      return "This file"
    case .workspace:
      return "This workspace"
    }
  }
}

struct UnlockPromptView: View {
  @Bindable var model: UnlockPromptModel
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "lock.fill")
        .font(.system(size: 40))
        .foregroundColor(.accent)

      VStack(spacing: Spacing.xs) {
        Text("Locked")
          .font(.heading)
          .foregroundColor(.foreground)
        Text(verbatim: model.title)
          .font(.mono)
          .foregroundColor(.foreground)
          .lineLimit(2)
          .truncationMode(.middle)
        Text(verbatim: model.reason)
          .font(.bodyText)
          .foregroundColor(.foregroundMuted)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      Button("Use Touch ID or Mac Password") { model.authenticateOwner() }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.isWorking)

      if model.showsPasswordPath {
        SecureField("Lock Password", text: $model.password)
          .textFieldStyle(.plain)
          .inputStyle()
          .onSubmit { model.unlockWithPassword() }
      }

      if let message = model.message {
        Text(verbatim: message)
          .font(.small)
          .foregroundColor(.destructive)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      // Cancel and Unlock centered on the bottom row; the spinner sits apart at the leading edge
      HStack(spacing: Spacing.sm) {
        Button("Cancel") { onCancel() }
          .buttonStyle(SecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
        if model.showsPasswordPath {
          Button("Unlock") { model.unlockWithPassword() }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.password.isEmpty || model.isWorking)
        }
      }
      .frame(maxWidth: .infinity)
      .overlay(alignment: .leading) {
        ProgressView()
          .controlSize(.small)
          .tint(.accent)
          .opacity(model.showsSpinner ? 1 : 0)
          .animation(.easeIn(duration: 0.15), value: model.showsSpinner)
          // Opt out of the app-wide animation kill switch, only for the fade
          .transaction(value: model.showsSpinner) { $0.disablesAnimations = false }
      }
    }
    .padding(Spacing.xl)
    .frame(width: 380)
    .background(Color.appBackground)
    .task { await model.loadPasswordState() }
  }
}

/// The app's unlock prompter: `UnlockPromptView` as a sheet (`beginSheet`) on the anchor
/// window, or on the innermost sheet already attached to it. Without an anchor it refuses:
/// it never picks the key window and never runs app-modal.
@MainActor
final class AppUnlockPrompter: UnlockPrompter {
  private let authenticator: any BiometricAuthenticator
  private var open: [UnlockPromptSheet] = []

  init(authenticator: any BiometricAuthenticator = LAContextBiometricAuthenticator()) {
    self.authenticator = authenticator
  }

  func unlock(
    _ item: LockIdentity, reason: String, anchor: NSWindow?, lockVault: UnlockPasswordVault
  ) async -> Bool {
    guard var host = anchor else { return false }
    while let attached = host.attachedSheet {
      host = attached
    }
    return await withCheckedContinuation { continuation in
      let sheet = UnlockPromptSheet()
      open.append(sheet)
      let model = UnlockPromptModel(
        item: item, reason: reason, lockVault: lockVault, authenticator: authenticator
      ) { [weak sheet] unlocked in sheet?.finish(unlocked) }
      sheet.present(
        UnlockPromptView(model: model) { [weak sheet] in sheet?.finish(false) }, on: host
      ) { [weak self, weak sheet] unlocked in
        self?.open.removeAll { $0 === sheet }
        continuation.resume(returning: unlocked)
      }
    }
  }
}

/// One open prompt: its sheet window and the answer, given exactly once
@MainActor
final class UnlockPromptSheet {
  private var window: NSWindow?
  private var answer: ((Bool) -> Void)?
  private var hostObservers: [any NSObjectProtocol] = []

  /// Marks the prompt's sheet window: a relock's sweep (`endSheets(on:)`) leaves it open
  static let identifier = NSUserInterfaceItemIdentifier("DbloreUnlockPrompt")

  func present(_ view: some View, on host: NSWindow, answer: @escaping (Bool) -> Void) {
    self.answer = answer
    let window = NSWindow(contentViewController: NSHostingController(rootView: view))
    window.identifier = Self.identifier
    self.window = window
    observeHostGoingAway(host)
    host.beginSheet(window)
  }

  /// Ends every sheet on `window` (innermost first) as cancelled, except unlock prompts and
  /// the sheets on them: a relocked window shows nothing of its workspace
  static func endSheets(on window: NSWindow) {
    for sheet in window.sheets.reversed() where sheet.identifier != identifier {
      endSheets(on: sheet)
      window.endSheet(sheet, returnCode: .cancel)
    }
  }

  func finish(_ unlocked: Bool) {
    guard let answer else { return }
    self.answer = nil
    close()
    answer(unlocked)
  }

  /// The window under the prompt (or one it sits on) closed, or the host sheet ended without
  /// closing: nobody can answer, so it does not unlock
  private func observeHostGoingAway(_ host: NSWindow) {
    let center = NotificationCenter.default
    var window: NSWindow? = host
    while let closing = window {
      hostObservers.append(
        center.addObserver(
          forName: NSWindow.willCloseNotification, object: closing, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.finish(false) }
        })
      window = closing.sheetParent
    }
    // A host sheet can leave via endSheet/orderOut, which post no willClose: its parent posts
    // didEndSheet. Checked on the next turn, once AppKit has detached it.
    guard let parent = host.sheetParent else { return }
    hostObservers.append(
      center.addObserver(forName: NSWindow.didEndSheetNotification, object: parent, queue: .main) {
        [weak self, weak host] _ in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard let self, self.window != nil else { return }
            if host?.sheetParent == nil || host?.isVisible != true { self.finish(false) }
          }
        }
      })
  }

  private func close() {
    for observer in hostObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    hostObservers = []
    guard let window else { return }
    self.window = nil
    if let parent = window.sheetParent {
      parent.endSheet(window)
    } else {
      window.orderOut(nil)
    }
  }
}
