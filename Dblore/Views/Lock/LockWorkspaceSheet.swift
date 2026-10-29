//
//  LockWorkspaceSheet.swift
//  Dblore
//
// File > Lock Workspace... and Remove Lock...: a sheet on the workspace window. The click opens
// it at once (nothing is read before it shows); the Lock password state is read in its task,
// and the password check (PBKDF2), the new key and the file rewrites run off the main actor
// with progress. The spinner fades in after 150 ms. Passwords are never logged.

import SwiftUI

extension View {
  /// The workspace's Lock Workspace / Remove Lock sheet
  func lockWorkspaceSheet(workspaceManager: WorkspaceManager) -> some View {
    sheet(
      item: Binding(
        get: { workspaceManager.lockSheet },
        set: { if $0 == nil { workspaceManager.lockSheet?.close() } })
    ) { model in
      LockWorkspaceSheet(model: model)
    }
  }
}

/// What the sheet shows and does
@MainActor
@Observable
final class LockWorkspaceModel: Identifiable {
  enum Mode: Equatable {
    case lock
    case remove
  }

  enum Stage: Equatable {
    case form
    case working
    case finished
  }

  let mode: Mode
  let workspaceName: String
  /// The .sqlws and the tab files it rewrites (counted when the sheet opens)
  let fileCount: Int
  var password = ""
  var confirmation = ""
  /// Nil until read; `.absent` asks for a new Lock password
  private(set) var passwordState: UnlockPasswordVault.PasswordState?
  private(set) var stage = Stage.form
  private(set) var isWorking = false
  private(set) var showsSpinner = false
  private(set) var done = 0
  private(set) var total = 0
  private(set) var message: String?
  private(set) var notice: String?
  private(set) var failures: [LockedFileIO.FileFailure] = []

  @ObservationIgnored private weak var manager: WorkspaceManager?
  @ObservationIgnored private let center: LockCenter
  @ObservationIgnored private var spinnerTask: Task<Void, Never>?

  init(manager: WorkspaceManager, mode: Mode, center: LockCenter = .shared) {
    self.manager = manager
    self.mode = mode
    self.center = center
    workspaceName = manager.workspace.name
    fileCount = 1 + manager.tabs.filter { $0.fileURL != nil && !$0.isReadOnlySource }.count
  }

  var minimumLength: Int { center.lockVault.minimumLength }

  var canSubmit: Bool {
    guard stage == .form, !isWorking else { return false }
    switch mode {
    case .remove:
      return true
    case .lock:
      switch passwordState {
      case .absent: return password.count >= minimumLength && password == confirmation
      case .present: return !password.isEmpty
      case .unreadable, nil: return false
      }
    }
  }

  func loadPasswordState() async {
    guard mode == .lock, passwordState == nil else { return }
    passwordState = await Self.passwordState(of: center.lockVault)
    if passwordState == .unreadable {
      message = "The Lock password cannot be read right now. Try again later."
    }
  }

  func submit() {
    guard canSubmit, let manager else { return }
    let entry = password
    password = ""
    begin()
    Task {
      switch mode {
      case .lock: await lock(manager, password: entry)
      case .remove: await removeLock(manager, password: entry)
      }
      end()
    }
  }

  /// Lock Workspace left files unencrypted: Retry is offered
  var canRetry: Bool {
    mode == .lock && stage == .finished && !isWorking && !failures.isEmpty
  }

  /// Writes the files Lock Workspace left unencrypted again, with the same progress
  func retry() {
    guard canRetry, let manager else { return }
    begin()
    done = 0
    total = failures.count
    stage = .working
    Task {
      failures = await manager.retryLockWrites(failures) { done, total in
        self.done = done
        self.total = total
      }
      stage = .finished
      end()
    }
  }

  /// Closes the sheet, except while files are being rewritten
  func close() {
    guard !isWorking, let manager, manager.lockSheet === self else { return }
    manager.lockSheet = nil
  }

  // MARK: - Private

  private func lock(_ manager: WorkspaceManager, password entry: String) async {
    // Held from the password check to the last sealed file: a Lock password change waits, and
    // this waits for one (the entry is checked against the record a change replaces)
    guard center.beginWorkspaceLock() else {
      message = WorkspaceLockError.passwordChanging.errorDescription
      return
    }
    defer { center.endWorkspaceLock() }
    guard await acceptLockPassword(entry) else { return }
    confirmation = ""
    stage = .working
    do {
      let report = try await manager.lockWorkspace(password: entry, center: center) {
        [weak self] done, total in
        self?.done = done
        self?.total = total
      }
      failures = report.failures
      notice = Self.notice(for: report.mode)
      stage = .finished
    } catch {
      stage = .form
      message = error.localizedDescription
    }
  }

  /// Sets the first Lock password, or checks the one already set (its throttle applies)
  private func acceptLockPassword(_ entry: String) async -> Bool {
    if passwordState == .absent {
      let result = await center.setLockPassword(entry, reason: "set the Lock password")
      message = result.message
      if result == .set || result == .alreadySet { passwordState = .present }
      return result == .set
    }
    switch await Self.verify(entry, with: center.lockVault) {
    case .accepted:
      return true
    case .rejected:
      message = "Wrong Lock password."
    case .throttled(let until):
      let seconds = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
      message = "Too many wrong entries. Try again in \(seconds) s."
    case .unreadable:
      passwordState = .unreadable
      message = "The Lock password cannot be read right now. Try again later."
    case .noPassword:
      passwordState = .absent
      message = "No Lock password is set. Set one to lock the workspace."
    }
    return false
  }

  /// The owner confirms first: the Lock password when one is typed (checked against the
  /// workspace's own wrap block), else Touch ID or the Mac password
  private func removeLock(_ manager: WorkspaceManager, password entry: String) async {
    let id = manager.lockKeyId ?? manager.workspace.id
    // A relocked window reads its files back only after an unlock
    guard !center.registry.isBlocked(.workspace(id)) else {
      message = "Unlock the workspace first."
      return
    }
    let confirmation = await center.authorizeRemoveLock(
      id, session: manager.lockedIO.sessions.session(for: id), password: entry,
      reason: "remove the lock of \(workspaceName)")
    guard let authorization = confirmation.authorization else {
      if case .refused(let reason) = confirmation { message = reason }
      return
    }
    stage = .working
    failures = await manager.removeLock(authorization: authorization) { [weak self] done, total in
      self?.done = done
      self?.total = total
    }
    stage = .finished
  }

  private static func notice(for mode: LockKeyMode) -> String? {
    switch mode {
    case .presence:
      return nil
    case .appGated:
      return "This Mac's Keychain keeps the workspace key without its own Touch ID check. "
        + "Dblore asks for Touch ID or the Mac password before reading it."
    case .unavailable:
      return "This Mac's Keychain could not keep the workspace key, so the workspace opens "
        + "with the Lock password only."
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
}

struct LockWorkspaceSheet: View {
  @Bindable var model: LockWorkspaceModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(model.mode == .lock ? "Lock Workspace" : "Remove Lock")
        .font(.subheading)
        .foregroundColor(.foreground)
        .modalBarPadding(vertical: Spacing.sm)

      Divider()

      VStack(alignment: .leading, spacing: Spacing.sm) {
        switch model.stage {
        case .form: form
        case .working: working
        case .finished: finished
        }
        if let message = model.message {
          Text(verbatim: message)
            .font(.small)
            .foregroundColor(.destructive)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)

      Divider()

      HStack(spacing: Spacing.md) {
        ProgressView()
          .controlSize(.small)
          .tint(.accent)
          .opacity(model.showsSpinner ? 1 : 0)
          .animation(.easeIn(duration: 0.15), value: model.showsSpinner)
          // Opt out of the app-wide animation kill switch, only for the fade
          .transaction(value: model.showsSpinner) { $0.disablesAnimations = false }
        Spacer()
        buttons
      }
      .modalBarPadding()
    }
    .frame(width: 420)
    .background(Color.appBackground)
    .interactiveDismissDisabled()
    .task { await model.loadPasswordState() }
  }

  private var files: String {
    model.fileCount == 1 ? "its file" : "its \(model.fileCount) files"
  }

  @ViewBuilder private var form: some View {
    switch model.mode {
    case .lock:
      note(
        "Encrypts \(model.workspaceName) and \(files). Opening it asks for Touch ID, "
          + "the Mac password or the Lock password.")
      Text(
        "If the Lock password is forgotten and this Mac's Keychain loses the workspace key, "
          + "the files cannot be recovered. Older Dblore versions cannot open them."
      )
      .font(.small)
      .foregroundColor(.warning)
      .fixedSize(horizontal: false, vertical: true)
      if model.passwordState == .absent {
        note(
          "Set a Lock password (at least \(model.minimumLength) characters). It also unlocks "
            + "locked connections.")
        passwordField("New Lock Password", text: $model.password)
        passwordField("Confirm Lock Password", text: $model.confirmation)
      } else {
        passwordField("Lock Password", text: $model.password)
          .disabled(model.passwordState != .present)
      }
    case .remove:
      note(
        "Writes \(model.workspaceName) and \(files) back as plain files that any app can "
          + "read, and removes the workspace key from this Mac's Keychain.")
      note(
        "Confirm with the Lock password, or leave it empty to use Touch ID or the Mac password.")
      passwordField("Lock Password", text: $model.password)
    }
  }

  @ViewBuilder private var working: some View {
    if model.total > 0 {
      ProgressView(value: Double(model.done), total: Double(model.total))
        .progressViewStyle(.linear)
    }
    Text(progressText)
      .font(.bodyText)
      .foregroundColor(.foregroundSubtle)
      .lineLimit(1)
      .monospacedDigit()
  }

  private var progressText: String {
    guard model.total > 0 else { return "Preparing the workspace key…" }
    let verb = model.mode == .lock ? "Encrypting" : "Writing"
    return "\(verb) files (\(model.done.formatted()) of \(model.total.formatted()))…"
  }

  @ViewBuilder private var finished: some View {
    if model.failures.isEmpty {
      note(model.mode == .lock ? "The workspace is locked." : "The lock is removed.")
    } else {
      note(
        model.mode == .lock
          ? "The workspace is locked, but these files are still unencrypted. Retry, or save "
            + "them again:"
          : "These files could not be written, so the workspace stays locked:")
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          ForEach(model.failures, id: \.url) { failure in
            Text(verbatim: "\(failure.url.lastPathComponent): \(failure.reason)")
              .font(.small)
              .foregroundColor(.foregroundMuted)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 120)
    }
    if let notice = model.notice {
      Text(verbatim: notice)
        .font(.small)
        .foregroundColor(.warning)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private var buttons: some View {
    switch model.stage {
    case .form, .working:
      Button("Cancel") { model.close() }
        .buttonStyle(SecondaryButtonStyle())
        .keyboardShortcut(.cancelAction)
        .disabled(model.isWorking)
      if model.mode == .lock {
        Button("Lock Workspace") { model.submit() }
          .buttonStyle(PrimaryButtonStyle())
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canSubmit)
      } else {
        Button("Remove Lock") { model.submit() }
          .buttonStyle(DangerButtonStyle())
          .disabled(!model.canSubmit)
      }
    case .finished:
      if model.canRetry {
        Button("Retry") { model.retry() }
          .buttonStyle(SecondaryButtonStyle())
      }
      Button("Done") { model.close() }
        .buttonStyle(PrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
    }
  }

  private func note(_ text: String) -> some View {
    Text(verbatim: text)
      .font(.bodyText)
      .foregroundColor(.foreground)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func passwordField(_ title: String, text: Binding<String>) -> some View {
    SecureField(title, text: text)
      .textFieldStyle(.plain)
      .inputStyle()
      .onSubmit { model.submit() }
  }
}
