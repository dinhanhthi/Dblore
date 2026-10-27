//
//  LockSettingsSection.swift
//  Dblore
//
// Settings > Security > Lock: the Lock password (set, change, remove), when Dblore locks again,
// and the locked connections and workspaces. Shown with or without an open tab (also from
// Welcome). A click opens its form at once; the owner check, the PBKDF2 work and the re-seal of
// locked workspaces run in LockCenter, off the main actor, with progress. The spinner fades in
// after 150 ms. Passwords are never logged.

import AppKit
import SwiftUI

/// What the Lock settings show and do. The password work goes through `LockCenter`.
@MainActor
@Observable
final class LockSettingsModel {
  enum Form: Equatable {
    case set
    case change
    case remove
  }

  /// Nil until read
  private(set) var passwordState: UnlockPasswordVault.PasswordState?
  /// The open password form, nil when none is open
  private(set) var form: Form?
  var currentPassword = ""
  var newPassword = ""
  var confirmation = ""
  private(set) var isWorking = false
  private(set) var showsSpinner = false
  /// Workspaces re-sealed so far, of `total`, during a change
  private(set) var done = 0
  private(set) var total = 0
  private(set) var message: String?
  private(set) var notice: String?
  /// Files a change did not re-seal: they still open with the old Lock password
  private(set) var failures: [URL] = []
  private(set) var lockedConnections: [ConnectionHistoryEntry] = []
  /// The durable list of locked workspace files, read with the connections
  private(set) var durableWorkspaces: [WorkspaceHistoryEntry] = []

  @ObservationIgnored private let center: LockCenter
  /// Where the saved connections live (the user's defaults in the app)
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var spinnerTask: Task<Void, Never>?
  /// Lock changes and connection-history changes made elsewhere (another window's connection
  /// form, Settings > Data, Lock Workspace and Remove Lock) reload the locked items while the
  /// section is shown
  @ObservationIgnored private let observers = NotificationTokens()

  init(center: LockCenter = .shared, defaults: UserDefaults = .standard) {
    self.center = center
    self.defaults = defaults
    let reload: @Sendable (Notification) -> Void = { [weak self] note in
      guard
        note.name != .localDataChanged
          || LocalDataCategory.notification(note, includes: .connectionHistory)
      else { return }
      MainActor.assumeIsolated { self?.loadItems() }
    }
    observers.tokens = [
      NotificationCenter.default.addObserver(
        forName: LockRegistry.didChangeLocks, object: center.registry, queue: .main,
        using: reload),
      NotificationCenter.default.addObserver(
        forName: .localDataChanged, object: nil, queue: .main, using: reload),
    ]
  }

  /// "Lock again after idle": Never keeps unlocked items open for good, so the owner confirms
  /// first (Touch ID or the Mac password); a refusal keeps the old value
  func setIdleTimeout(_ timeout: LockIdleTimeout, in settings: AppSettings) async {
    guard timeout != settings.lockIdleTimeout else { return }
    if timeout == .never {
      guard await center.authenticateOwner(reason: "never lock again after idle") else { return }
    }
    settings.lockIdleTimeout = timeout
  }

  var minimumLength: Int { center.lockVault.minimumLength }

  /// Locked workspaces from Recents
  var lockedWorkspaces: [WorkspaceHistoryEntry] {
    RecentManager.shared.recentWorkspaces.filter(\.isLocked)
  }

  /// The Locked items list: Recents' locked workspaces, then the locked ones that left Recents
  var listedWorkspaces: [WorkspaceHistoryEntry] {
    let recents = lockedWorkspaces
    let paths = Set(recents.map(\.fileURL.standardizedFileURL.path))
    return recents
      + durableWorkspaces.filter { !paths.contains($0.fileURL.standardizedFileURL.path) }
  }

  /// Listed only by the durable list (not in Recents): it can be forgotten
  func isListedOnly(_ entry: WorkspaceHistoryEntry) -> Bool {
    let path = entry.fileURL.standardizedFileURL.path
    return !lockedWorkspaces.contains { $0.fileURL.standardizedFileURL.path == path }
  }

  var canSubmit: Bool {
    guard let form, !isWorking else { return false }
    switch form {
    case .set, .change:
      return newPassword.count >= minimumLength && newPassword == confirmation
    case .remove:
      return lockedWorkspaces.isEmpty
    }
  }

  func load() async {
    loadItems()
    passwordState = await Self.passwordState(of: center.lockVault)
  }

  private func loadItems() {
    loadConnections()
    durableWorkspaces = center.lockedWorkspaces.entries
  }

  /// The saved connections marked locked (no Keychain read)
  private func loadConnections() {
    lockedConnections = SessionManager.loadHistory(
      defaults: defaults, passwords: NoPasswordStore(), registry: center.registry
    ).filter(\.config.isLocked)
  }

  func open(_ form: Form) {
    guard !isWorking else { return }
    clearFields()
    message = nil
    notice = nil
    failures = []
    self.form = form
  }

  func cancel() {
    guard !isWorking else { return }
    clearFields()
    message = nil
    form = nil
  }

  func submit() {
    guard canSubmit, let form else { return }
    let current = currentPassword
    let new = newPassword
    clearFields()
    begin()
    Task {
      switch form {
      case .set: await set(new)
      case .change: await change(current: current, new: new)
      case .remove: await remove(current: current)
      }
      passwordState = await Self.passwordState(of: center.lockVault)
      end()
    }
  }

  /// Removes the lock of a saved connection: the owner confirms every time (also when it was
  /// unlocked in this session), and every other saved row that reaches it and is still blocked
  /// asks too
  func removeLock(of entry: ConnectionHistoryEntry, anchor: NSWindow?) {
    guard !isWorking else { return }
    isWorking = true
    let config = entry.config
    let identity = LockIdentity(config)
    let defaults = defaults
    let registry = center.registry
    Task {
      defer { isWorking = false }
      let rows = SessionManager.loadHistory(
        defaults: defaults, passwords: NoPasswordStore(), registry: registry
      ).map(\.config)
      guard
        await center.confirmLockRemoval(
          for: config, rows: rows, reason: "remove the lock of \(Self.title(of: config))",
          anchor: anchor),
        SessionManager.setLocked(false, for: identity, defaults: defaults, registry: registry)
      else { return }
      LocalDataNotifications.post(.connectionHistory)
      await load()
    }
  }

  /// Forgets a locked workspace file that only the durable list holds (sealed on another Mac,
  /// or moved): the owner confirms first; its file is untouched
  func forget(_ entry: WorkspaceHistoryEntry, anchor: NSWindow?) {
    guard !isWorking else { return }
    isWorking = true
    Task {
      defer { isWorking = false }
      if await center.forgetLockedWorkspace(
        entry, reason: "forget the locked workspace \(entry.name)", anchor: anchor)
      {
        loadItems()
      }
    }
  }

  /// A locked workspace open in a window: its Remove Lock sheet (which asks) on that window.
  /// A closed one opens first (it asks to unlock); its lock is removed with File > Remove Lock.
  func removeLock(of entry: WorkspaceHistoryEntry) {
    let windows = WorkspaceWindowManager.shared
    if let manager = windows.workspaces.values.first(where: {
      $0.lockKeyId != nil
        && $0.workspace.fileURL?.standardizedFileURL == entry.fileURL.standardizedFileURL
    }) {
      NewWindowStore.shared.findWindow(for: manager.id)?.makeKeyAndOrderFront(nil)
      manager.openLockSheet(.remove)
      return
    }
    Task {
      if let id = await windows.requestWorkspaceReportingError(url: entry.fileURL) {
        windows.pendingWorkspaceId = id
      }
    }
  }

  func isOpen(_ entry: WorkspaceHistoryEntry) -> Bool {
    WorkspaceWindowManager.shared.workspaces.values.contains {
      $0.lockKeyId != nil
        && $0.workspace.fileURL?.standardizedFileURL == entry.fileURL.standardizedFileURL
    }
  }

  static func title(of config: ConnectionConfig) -> String {
    config.name.isEmpty ? config.displayString : config.name
  }

  // MARK: - Private

  private func set(_ new: String) async {
    let result = await center.setLockPassword(new, reason: "set the Lock password")
    guard result == .set else {
      message = result.message
      return
    }
    notice = "The Lock password is set."
    form = nil
  }

  private func change(current: String, new: String) async {
    done = 0
    total = 0
    let result = await center.changeLockPassword(
      current: current, new: new, workspaces: reachableWorkspaces,
      reason: "change the Lock password"
    ) { [weak self] done, total in
      Task { @MainActor in
        self?.done = done
        self?.total = total
      }
    }
    switch result {
    case .changed(let failed):
      failures = failed
      notice = "The Lock password is changed."
      form = nil
    case .notStored(let failed):
      failures = failed
      message = result.message
    default:
      message = result.message
    }
  }

  private func remove(current: String) async {
    let result = await center.removeLockPassword(
      current: current, workspaces: reachableWorkspaces, reason: "remove the Lock password")
    guard result == .removed else {
      message = result.message
      return
    }
    notice = "The Lock password is removed."
    form = nil
  }

  /// Recents plus every locked workspace open in a window (Recents keeps only the latest few)
  private var reachableWorkspaces: [WorkspaceHistoryEntry] {
    var entries = RecentManager.shared.recentWorkspaces
    for manager in WorkspaceWindowManager.shared.workspaces.values where manager.lockKeyId != nil {
      guard var entry = WorkspaceHistoryEntry.from(manager.workspace),
        !entries.contains(where: {
          $0.fileURL.standardizedFileURL == entry.fileURL.standardizedFileURL
        })
      else { continue }
      entry.isLocked = true
      entries.append(entry)
    }
    return entries
  }

  private func clearFields() {
    currentPassword = ""
    newPassword = ""
    confirmation = ""
  }

  /// Disables the actions at once; the spinner fades in only after 150 ms
  private func begin() {
    isWorking = true
    message = nil
    notice = nil
    failures = []
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
}

/// Notification observers removed when their owner goes away
private nonisolated final class NotificationTokens: @unchecked Sendable {
  var tokens: [any NSObjectProtocol] = []

  deinit {
    for token in tokens {
      NotificationCenter.default.removeObserver(token)
    }
  }
}

struct LockSettingsSection: View {
  @Bindable var appSettings: AppSettings
  @State private var model = LockSettingsModel()
  @State private var hostWindow = HostWindowReference()

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsGroupCard(title: "Lock password") {
        passwordCard
      }
      SettingsGroupCard(title: "Relock") {
        relockRow
      }
      SettingsGroupCard(title: "Locked items") {
        lockedItems
      }
    }
    .background(HostWindowReader(reference: hostWindow))
    .task { await model.load() }
  }

  // MARK: - Lock password

  @ViewBuilder private var passwordCard: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: model.passwordState == .absent ? "lock.open.fill" : "lock.fill")
          .font(.system(size: 12))
          .foregroundColor(.accent)
        Text(statusTitle)
          .font(.bodyText)
          .fontWeight(.medium)
          .foregroundColor(.foreground)
      }
      note(
        "Unlocks locked connections and workspaces, like Touch ID or the Mac password. "
          + "Workspaces sealed with it open with it on any Mac.")

      if let form = model.form {
        passwordForm(form)
      } else {
        passwordButtons
      }

      if let message = model.message {
        Text(verbatim: message)
          .font(.small)
          .foregroundColor(.destructive)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let notice = model.notice {
        Text(verbatim: notice)
          .font(.small)
          .foregroundColor(.foregroundSubtle)
      }
      if !model.failures.isEmpty {
        failureList
      }
    }
  }

  private var statusTitle: String {
    switch model.passwordState {
    case nil: return "Lock password"
    case .present: return "A Lock password is set"
    case .absent: return "No Lock password is set"
    case .unreadable: return "The Lock password cannot be read right now"
    }
  }

  @ViewBuilder private var passwordButtons: some View {
    HStack(spacing: Spacing.sm) {
      switch model.passwordState {
      case .absent:
        Button("Set Lock Password...") { model.open(.set) }
          .buttonStyle(FilledSecondaryButtonStyle())
      case .present:
        Button("Change...") { model.open(.change) }
          .buttonStyle(FilledSecondaryButtonStyle())
        Button("Remove...") { model.open(.remove) }
          .buttonStyle(DangerButtonStyle())
      case .unreadable, nil:
        EmptyView()
      }
    }
  }

  @ViewBuilder private func passwordForm(_ form: LockSettingsModel.Form) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      switch form {
      case .set:
        note("At least \(model.minimumLength) characters.")
        passwordField("New Lock Password", text: $model.newPassword)
        passwordField("Confirm Lock Password", text: $model.confirmation)
      case .change:
        note(
          "Re-encrypts the locked workspaces with the new password. Earlier backups and copies "
            + "stay readable with the old password.", color: .warning)
        note("Leave the current password empty to use Touch ID or the Mac password.")
        passwordField("Current Lock Password", text: $model.currentPassword)
        passwordField("New Lock Password", text: $model.newPassword)
        passwordField("Confirm Lock Password", text: $model.confirmation)
      case .remove:
        if model.lockedWorkspaces.isEmpty {
          note(
            "Locked connections then unlock with Touch ID or the Mac password only. Confirm "
              + "with the Lock password, or leave it empty to use Touch ID or the Mac password.")
          passwordField("Current Lock Password", text: $model.currentPassword)
        } else {
          note(
            "Locked workspaces open with the Lock password. Remove their locks first "
              + "(Locked items below).", color: .warning)
        }
      }
      if model.isWorking, form == .change {
        progress
      }
      HStack(spacing: Spacing.sm) {
        ProgressView()
          .controlSize(.small)
          .tint(.accent)
          .opacity(model.showsSpinner ? 1 : 0)
          .animation(.easeIn(duration: 0.15), value: model.showsSpinner)
          // Opt out of the app-wide animation kill switch, only for the fade
          .transaction(value: model.showsSpinner) { $0.disablesAnimations = false }
        Spacer()
        Button("Cancel") { model.cancel() }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(model.isWorking)
        submitButton(form)
      }
    }
  }

  @ViewBuilder private func submitButton(_ form: LockSettingsModel.Form) -> some View {
    switch form {
    case .set:
      Button("Set Lock Password") { model.submit() }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!model.canSubmit)
    case .change:
      Button("Change Lock Password") { model.submit() }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!model.canSubmit)
    case .remove:
      Button("Remove Lock Password") { model.submit() }
        .buttonStyle(DangerButtonStyle())
        .disabled(!model.canSubmit)
    }
  }

  @ViewBuilder private var progress: some View {
    if model.total > 0 {
      ProgressView(value: Double(model.done), total: Double(model.total))
        .progressViewStyle(.linear)
    }
    Text(
      model.total > 0
        ? "Re-encrypting workspaces (\(model.done.formatted()) of \(model.total.formatted()))..."
        : "Checking the password..."
    )
    .font(.small)
    .foregroundColor(.foregroundSubtle)
    .monospacedDigit()
  }

  private var failureList: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(
        "These files could not be re-encrypted and still open with the old Lock password. "
          + "Open their workspace, then save them or change the Lock password again:"
      )
      .font(.small)
      .foregroundColor(.warning)
      .fixedSize(horizontal: false, vertical: true)
      ForEach(model.failures, id: \.self) { url in
        Text(verbatim: url.path)
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(url.path)
      }
    }
  }

  // MARK: - Relock

  private var relockRow: some View {
    HStack(alignment: .center, spacing: Spacing.sm) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Lock again after idle")
          .font(.bodyText)
          .foregroundColor(.foreground)
        Text(
          "Unlocked items lock again when the Mac has no input for this long, and when the "
            + "screen locks or the Mac sleeps."
        )
        .font(.small)
        .foregroundColor(.foregroundSubtle)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: Spacing.sm)
      CapsuleDropdown(
        title: appSettings.lockIdleTimeout.title, accessibilityLabel: "Lock again after idle",
        options: LockIdleTimeout.allCases, optionTitle: \.title,
        isSelected: { $0 == appSettings.lockIdleTimeout },
        onSelect: { timeout in
          Task { await model.setIdleTimeout(timeout, in: appSettings) }
        })
    }
  }

  // MARK: - Locked items

  @ViewBuilder private var lockedItems: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if model.lockedConnections.isEmpty && model.listedWorkspaces.isEmpty {
        note(
          "Nothing is locked. Lock a connection in its connection form, or a workspace with "
            + "File > Lock Workspace.")
      }
      ForEach(model.lockedConnections) { entry in
        itemRow(
          icon: "server.rack", title: LockSettingsModel.title(of: entry.config),
          detail: entry.config.databaseType.displayName, action: "Remove Lock..."
        ) {
          model.removeLock(of: entry, anchor: hostWindow.window)
        }
      }
      ForEach(model.listedWorkspaces, id: \.fileURL) { entry in
        let isOpen = model.isOpen(entry)
        let canForget = !isOpen && model.isListedOnly(entry)
        itemRow(
          icon: "square.stack.3d.up", title: entry.name, detail: entry.fileURL.path,
          hint: isOpen
            ? nil
            : "Open it, then choose File > Remove Lock."
              + (canForget ? " Forget it when it was sealed on another Mac or moved." : ""),
          action: isOpen ? "Remove Lock..." : "Open",
          secondary: canForget
            ? ("Forget...", { model.forget(entry, anchor: hostWindow.window) }) : nil
        ) {
          model.removeLock(of: entry)
        }
      }
    }
  }

  /// `detail` is one middle-truncated line (a path); `hint`, when given, a line of its own
  private func itemRow(
    icon: String, title: String, detail: String, hint: String? = nil, action: String,
    secondary: (title: String, perform: () -> Void)? = nil, perform: @escaping () -> Void
  ) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: 12))
        .foregroundColor(.foregroundMuted)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: title)
          .font(.bodyText)
          .foregroundColor(.foreground)
          .lineLimit(1)
        Text(verbatim: detail)
          .font(.small)
          .foregroundColor(.foregroundSubtle)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(detail)
        if let hint {
          Text(verbatim: hint)
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: Spacing.sm)
      if let secondary {
        Button(secondary.title, action: secondary.perform)
          .buttonStyle(SecondaryButtonStyle())
      }
      Button(action, action: perform)
        .buttonStyle(SecondaryButtonStyle())
    }
    .disabled(model.isWorking)
  }

  // MARK: - Helpers

  private func note(_ text: String, color: Color = .foregroundSubtle) -> some View {
    Text(verbatim: text)
      .font(.bodyText)
      .foregroundColor(color)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func passwordField(_ title: String, text: Binding<String>) -> some View {
    SecureField(title, text: text)
      .textFieldStyle(.plain)
      .inputStyle()
      .disabled(model.isWorking)
      .onSubmit { model.submit() }
  }
}
