//
//  LockedWorkspaceOpenView.swift
//  Dblore
//
// Opening a locked workspace. The click only sniffs the file's first bytes; its window opens at
// once with a locked placeholder (no workspace content), then the unlock asks through a sheet on
// that window: Touch ID or the Mac password when this Mac's Keychain keeps the workspace key, or
// the Lock password, which unwraps the file's own wrap block (no Lock password record needed).
// Unwrapping (PBKDF2) and decrypting the .sqlws and its tabs run off the main actor; the content
// shows only once loaded. The spinner fades in after 150 ms. The entry is never logged.

import AppKit
import SwiftUI

/// One locked workspace being opened in a window: from the placeholder to its content, or back
/// (Cancel). Nothing is decrypted or registered in `WorkspaceWindowManager.workspaces` before
/// the owner unlocks.
@MainActor
@Observable
final class LockedWorkspaceOpen: Identifiable {
  /// What the window does once the open ends
  enum Ending: Equatable {
    /// The workspace is open in the window
    case opened
    /// The window was the Welcome window: it shows Welcome again
    case returnToWelcome
    /// The window was made for this open (Finder, File > Open Workspace, Open Recent): it closes
    case closeWindow
  }

  /// The envelope's workspace id: the id the window shows
  let id: UUID
  let url: URL
  let header: LockEnvelope.Header
  let bookmark: Data?
  let folderBookmark: Data?
  /// After the unlock, while the files are decrypted and loaded
  private(set) var isLoading = false
  private(set) var showsSpinner = false
  /// Why the workspace did not open after the unlock (the placeholder shows it with Close)
  private(set) var failure: String?
  private(set) var ending: Ending?
  /// Launch restore's sealed text (`LockEnvelope.Kind.launchOverlays`), opened only after the
  /// unlock; a quit while it asks stores these again as they are
  @ObservationIgnored private(set) var sealedLaunchOverlays: [Data] = []
  /// Sessions of other workspaces' keys its load was given (taken back when it ends without
  /// content)
  @ObservationIgnored private(set) var loadGrants: [WorkspaceLockSession] = []
  /// The window it was asked on (the sheet and later file unlocks anchor there)
  @ObservationIgnored private(set) weak var anchor: NSWindow?
  @ObservationIgnored private var replacesWelcome = false
  @ObservationIgnored private var started = false
  @ObservationIgnored private var waiters: [CheckedContinuation<Ending, Never>] = []
  /// Windows showing its placeholder (launch restore can show one workspace in two)
  @ObservationIgnored private var windowCount = 0
  @ObservationIgnored private unowned let windows: WorkspaceWindowManager

  init(
    url: URL, header: LockEnvelope.Header, bookmark: Data?, folderBookmark: Data?,
    windows: WorkspaceWindowManager
  ) {
    id = header.workspaceId
    self.url = url
    self.header = header
    self.bookmark = bookmark
    self.folderBookmark = folderBookmark
    self.windows = windows
  }

  /// The file's name (the workspace's own name is inside the encrypted file), as one short line
  var name: String { Self.displayName(url.deletingPathExtension().lastPathComponent) }

  /// An untrusted name as one line of at most `limit` characters (control, format and line
  /// characters become spaces; a long name keeps its start and end) for the sheet's title and the
  /// system prompt's reason
  nonisolated static func displayName(_ raw: String, limit: Int = 60) -> String {
    let line = String(
      String.UnicodeScalarView(
        raw.unicodeScalars.map {
          CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
            ? " " : $0
        }))
    guard line.count > limit else { return line }
    let head = (limit - 1) / 2
    return "\(line.prefix(head))\u{2026}\(line.suffix(limit - 1 - head))"
  }

  /// The window shows the placeholder: asks on it, then loads. `replacesWelcome`: the window
  /// showed Welcome before (Cancel goes back to it). Nil when already started.
  func start(anchor: NSWindow?, replacesWelcome: Bool) async -> Ending? {
    guard !started, ending == nil else { return nil }
    started = true
    self.anchor = anchor
    self.replacesWelcome = replacesWelcome
    guard let session = await windows.promptUnlock(header, name, anchor) else { return cancel() }
    guard ending == nil else {
      // Its window closed while the unlock ran: nothing keeps that grant
      windows.revokeUnusedGrant(of: id)
      return nil
    }
    isLoading = true
    let spinner = Task {
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled, isLoading else { return }
      showsSpinner = true
    }
    defer {
      spinner.cancel()
      isLoading = false
      showsSpinner = false
    }
    do {
      try await windows.finishLockedOpen(self, session: session)
      // A cancel while loading was already answered by whoever cancelled
      return ending == .opened ? .opened : nil
    } catch {
      failure = error.localizedDescription
      return nil
    }
  }

  /// Ends the open without content: nothing is kept, the Recents entry stays. Nil when it had
  /// already ended.
  @discardableResult
  func cancel() -> Ending? {
    guard ending == nil else { return nil }
    let ending: Ending = replacesWelcome ? .returnToWelcome : .closeWindow
    windows.dropLockedOpen(self)
    end(ending)
    return ending
  }

  /// A window shows its placeholder
  func attach() {
    windowCount += 1
  }

  /// A window stopped showing it; when none is left, it is cancelled (nothing opens later
  /// without a window)
  func detach() {
    windowCount -= 1
    if windowCount <= 0 { cancel() }
  }

  /// Launch restore: each window of the workspace adds its sealed text (only envelopes not
  /// given yet; their tabs are known once opened). Plaintext snapshot text is never taken: it
  /// could be planted in a locked workspace.
  func addSealedLaunchOverlays(_ sealed: [Data]) {
    for item in sealed where !sealedLaunchOverlays.contains(item) {
      sealedLaunchOverlays.append(item)
    }
  }

  /// Its load was given `session` for a file of another workspace
  func noteLoadGrant(_ session: WorkspaceLockSession) {
    loadGrants.append(session)
  }

  /// The workspace is open (`WorkspaceWindowManager.finishLockedOpen`)
  func markOpened() {
    end(.opened)
  }

  /// How the open ended, once it has. Every window showing it acts on this (a second window of
  /// the same workspace never asks: it joins the first window's ask).
  func outcome() async -> Ending {
    if let ending { return ending }
    return await withCheckedContinuation { waiters.append($0) }
  }

  private func end(_ ending: Ending) {
    self.ending = ending
    let waiting = waiters
    waiters = []
    for waiter in waiting { waiter.resume(returning: ending) }
  }
}

// MARK: - Unlock sheet

/// What the unlock sheet of a sealed file's workspace shows and decides. The Lock password path
/// never needs a Lock password record: it unwraps the file's own wrap block.
@MainActor
@Observable
final class WorkspaceUnlockModel {
  let title: String
  /// This Mac's Keychain keeps the workspace key (recorded at Lock), so Touch ID or the Mac
  /// password can unlock
  let canUseKeychain: Bool
  var password = ""
  private(set) var isWorking = false
  private(set) var showsSpinner = false
  private(set) var message: String?
  /// The unlocked workspace's session (granted)
  private(set) var session: WorkspaceLockSession?

  @ObservationIgnored private let header: LockEnvelope.Header
  @ObservationIgnored private let center: LockCenter
  @ObservationIgnored private let keyStore: LockKeyStore
  @ObservationIgnored private let reason: String
  @ObservationIgnored var answer: (Bool) -> Void
  @ObservationIgnored private var spinnerTask: Task<Void, Never>?
  /// The sheet ended (its window closed) before the unlock answered
  @ObservationIgnored private var isAbandoned = false

  init(
    header: LockEnvelope.Header, title: String, reason: String = "open a locked workspace",
    center: LockCenter, keyStore: LockKeyStore, answer: @escaping (Bool) -> Void = { _ in }
  ) {
    self.header = header
    self.title = title
    self.reason = reason
    self.center = center
    self.keyStore = keyStore
    self.answer = answer
    canUseKeychain = keyStore.mode(for: header.workspaceId).map { $0 != .unavailable } ?? false
  }

  /// Touch ID or the Mac password (the system prompt), then one Keychain read
  func unlockWithKeychain() async {
    guard !isWorking else { return }
    begin()
    let unlocked = await center.unlockWorkspace(header, reason: reason, keyStore: keyStore)
    end()
    if isAbandoned {
      if let unlocked { center.abandonUnlock(unlocked) }
      return
    }
    guard let unlocked else {
      message = "Touch ID or the Mac password did not unlock. Use the Lock password."
      return
    }
    session = unlocked
    answer(true)
  }

  func unlockWithPassword() async {
    guard !isWorking, !password.isEmpty else { return }
    let entry = password
    password = ""
    begin()
    let outcome = await center.unlockWorkspace(header, password: entry)
    end()
    if isAbandoned {
      if case .unlocked(let unlocked) = outcome { center.abandonUnlock(unlocked) }
      return
    }
    guard case .unlocked(let unlocked) = outcome else {
      message = outcome.message
      return
    }
    session = unlocked
    answer(true)
  }

  /// The sheet ended without an answer: an unlock still running keeps no grant once it ends
  func abandon() {
    isAbandoned = true
    if let session { center.abandonUnlock(session) }
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
}

struct WorkspaceUnlockView: View {
  @Bindable var model: WorkspaceUnlockModel
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "lock.fill")
        .font(.system(size: 40))
        .foregroundColor(.accent)

      VStack(spacing: Spacing.xs) {
        Text("Locked Workspace")
          .font(.heading)
          .foregroundColor(.foreground)
        Text(verbatim: model.title)
          .font(.mono)
          .foregroundColor(.foreground)
          .lineLimit(2)
          .truncationMode(.middle)
        Text(
          model.canUseKeychain
            ? "Unlock with Touch ID, the Mac password or the Lock password."
            : "Enter the Lock password to open it."
        )
        .font(.bodyText)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      }

      if model.canUseKeychain {
        Button("Use Touch ID or Mac Password") { Task { await model.unlockWithKeychain() } }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(model.isWorking)
      }

      HStack(spacing: Spacing.sm) {
        SecureField("Lock Password", text: $model.password)
          .textFieldStyle(.plain)
          .inputStyle()
          .onSubmit { Task { await model.unlockWithPassword() } }
        if model.canUseKeychain {
          Button("Unlock") { Task { await model.unlockWithPassword() } }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.password.isEmpty || model.isWorking)
        } else {
          Button("Unlock") { Task { await model.unlockWithPassword() } }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.password.isEmpty || model.isWorking)
        }
      }

      if let message = model.message {
        Text(verbatim: message)
          .font(.small)
          .foregroundColor(.destructive)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: Spacing.md) {
        ProgressView()
          .controlSize(.small)
          .tint(.accent)
          .opacity(model.showsSpinner ? 1 : 0)
          .animation(.easeIn(duration: 0.15), value: model.showsSpinner)
          // Opt out of the app-wide animation kill switch, only for the fade
          .transaction(value: model.showsSpinner) { $0.disablesAnimations = false }
        Spacer()
        Button("Cancel") { onCancel() }
          .buttonStyle(SecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
          .disabled(model.isWorking)
      }
    }
    .padding(Spacing.xl)
    .frame(width: 380)
    .background(Color.appBackground)
  }
}

/// The unlock of a sealed file's workspace as a sheet on a window (never app-modal)
@MainActor
enum WorkspaceUnlockPrompt {
  /// Asks on `anchor` (or the innermost sheet on it) and returns the granted session; nil when
  /// cancelled or the window closed. Without a window, only the Keychain path (the system
  /// prompt; refused without a prompt when this Mac keeps no key). Under the test host it never
  /// shows anything.
  static func present(
    _ header: LockEnvelope.Header, title: String, reason: String, anchor: NSWindow?,
    center: LockCenter = .shared, keyStore: LockKeyStore = LockKeyStore()
  ) async -> WorkspaceLockSession? {
    guard !SessionManager.isRunningAsTestHost, var host = anchor else {
      return await center.unlockWorkspace(header, reason: reason, keyStore: keyStore)
    }
    while let attached = host.attachedSheet {
      host = attached
    }
    let model = WorkspaceUnlockModel(
      header: header, title: title, reason: reason, center: center, keyStore: keyStore)
    let unlocked = await withCheckedContinuation { continuation in
      let sheet = UnlockPromptSheet()
      model.answer = { [weak sheet] unlocked in sheet?.finish(unlocked) }
      sheet.present(
        WorkspaceUnlockView(model: model) { [weak sheet] in sheet?.finish(false) }, on: host
      ) { unlocked in
        // Keeps the sheet alive until it answers
        withExtendedLifetime(sheet) { continuation.resume(returning: unlocked) }
      }
    }
    guard unlocked else {
      model.abandon()
      return nil
    }
    return model.session
  }

  /// `LockedFileIO.Unlock` asking on the window `anchor` returns when the unlock runs. A window
  /// that is still opening (a file opened into a new workspace) is waited for briefly, so the
  /// window exists before the ask. Without an open window (gone, closed, or never there), or
  /// once its task is cancelled, nothing asks: no windowless system prompt, no sheet on a closed
  /// window. `title` names what is unlocked in the sheet.
  static func unlock(
    title: String = "A file of a locked workspace", reason: String,
    anchor: @escaping @MainActor () -> NSWindow?
  ) -> LockedFileIO.Unlock {
    { @MainActor header in
      var window = anchor()
      for _ in 0..<40
      where window == nil && !Task.isCancelled && !SessionManager.isRunningAsTestHost {
        try? await Task.sleep(for: .milliseconds(50))
        window = anchor()
      }
      guard !Task.isCancelled, let window, window.isOpenDbloreDocumentWindow else { return nil }
      return await present(header, title: title, reason: reason, anchor: window)
    }
  }
}

// MARK: - Placeholder

/// The window of a locked workspace before its content: the Welcome card's shape, a lock, the
/// file's name. It asks once it has its window; a spinner fades in after 150 ms while the files
/// are decrypted.
struct LockedWorkspacePlaceholder: View {
  let open: LockedWorkspaceOpen
  /// The window showed Welcome before: Cancel goes back to it (else the window closes)
  let replacesWelcome: Bool
  /// Shows Welcome again
  var onReturnToWelcome: () -> Void = {}

  @State private var hostWindow = HostWindowReference()

  var body: some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "lock.fill")
        .font(.system(size: 40))
        .foregroundColor(.foregroundSubtle)
      VStack(spacing: Spacing.xs) {
        Text("Locked Workspace")
          .font(.heading)
          .foregroundColor(.foreground)
        Text(verbatim: open.name)
          .font(.mono)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      if let failure = open.failure {
        Text(verbatim: failure)
          .font(.small)
          .foregroundColor(.destructive)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        Button("Close") { open.cancel() }
          .buttonStyle(SecondaryButtonStyle())
      } else {
        ProgressView()
          .controlSize(.small)
          .tint(.accent)
          .opacity(open.showsSpinner ? 1 : 0)
          .animation(.easeIn(duration: 0.15), value: open.showsSpinner)
          // Opt out of the app-wide animation kill switch, only for the fade
          .transaction(value: open.showsSpinner) { $0.disablesAnimations = false }
      }
    }
    .padding(Spacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.appBackground)
    .background(HostWindowReader(reference: hostWindow) { start() })
    .documentWindowMode(.compact, isTabbed: false)
    .onAppear { open.attach() }
    // Closed while it asked or loaded: once no window shows it, nothing opens later
    .onDisappear { open.detach() }
  }

  /// Once the window exists: ask on it (a second window of the same open joins the first ask),
  /// then act on how the open ended
  private func start() {
    guard let window = hostWindow.window else { return }
    let open = open
    let replacesWelcome = replacesWelcome
    Task {
      _ = await open.start(anchor: window, replacesWelcome: replacesWelcome)
      finish(await open.outcome())
    }
  }

  /// Without content, each window does what fits its own origin: Welcome's window shows Welcome
  /// again, a window made for the open closes
  private func finish(_ ending: LockedWorkspaceOpen.Ending) {
    guard ending != .opened else { return }
    if replacesWelcome {
      onReturnToWelcome()
    } else if let window = hostWindow.window, window.isOpenDbloreDocumentWindow {
      // A background tab or a minimized window too, but not one already closing (the user
      // closed it while the sheet was open)
      window.close()
    }
  }
}
