//
//  RedisKeyViewerView.swift
//  Dblore
//
//  A Redis key tab: a header card with the key's escaped name and db (known at once), then its
//  type, TTL (a live countdown) and size once read (`RedisKeyViewerModel`). Until then the card
//  keeps its shape with placeholder values, and a spinner fades in after 150 ms, so a click shows
//  the new key in the frame it lands and a fast read never flashes the spinner. A key that no
//  longer exists shows its own state. A new key in the same preview tab, or a reconnect, reads
//  the header again. The value (`RedisValueView`) fills the rest once the header is read, with
//  its own placeholder meanwhile. Server text is shown as plain, escaped text only.
//  Unless the connection is read-only, the loaded key offers its edits (TTL, Rename, Delete, the
//  value's own): each is sent under the epoch the key was loaded with (a reconnect since refuses
//  it: "reload the key"), asked per the commit style (`RedisKeyEditor`), then the key is read
//  again and the sidebar told. A deleted key's tab closes; a renamed key's tab shows the new name.
//

import SwiftUI

struct RedisKeyViewerView: View {
  let key: RedisKeyRef
  let workspaceManager: WorkspaceManager

  /// One per tab (the container gives each tab its own view); dropped with the tab, so
  /// switching back to a tab reads its key (and its first page) again
  @State private var model = RedisKeyViewerModel()
  /// Removals started here (a row's trash icon, Delete): their confirmation shows on this view
  @State private var editor: RedisKeyEditor
  /// The edit sheet on screen
  @State private var editTarget: RedisKeyEditTarget?
  /// The plain confirmation on screen (Immediate commit style); the editor's own stays pending
  /// until a button answers it
  @State private var dialogConfirmation: RedisKeyEditor.Confirmation?

  init(key: RedisKeyRef, workspaceManager: WorkspaceManager) {
    self.key = key
    self.workspaceManager = workspaceManager
    _editor = State(initialValue: RedisKeyEditor(context: workspaceManager.redisKeyWriteContext()))
  }

  /// What reads the header again when it changes
  private struct LoadTrigger: Equatable {
    let key: RedisKeyRef
    let isConnected: Bool
  }

  private var isConnected: Bool { workspaceManager.connectionState.isConnected }

  /// Edits are offered: connected, not read-only, the header read
  private func canEdit(_ state: RedisKeyViewerModel.State) -> Bool {
    guard isConnected, !workspaceManager.isRedisReadOnly, case .loaded = state else { return false }
    return true
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      let state = model.state(for: key)
      RedisKeyHeaderCard(
        key: key, state: state, loadID: model.loadID,
        connection: workspaceManager.connectionState, onReload: load,
        actions: canEdit(state) ? headerActions(state) : nil, isBusy: editor.isBusy)
      if case .failed(let message) = editor.phase {
        RedisEditMessage(message: message, onClose: { editor.cancel() })
      }
      if showsValue(state) {
        RedisValueView(
          values: model.values(for: key), loadID: model.loadID,
          onLoadMore: { model.loadMore() },
          actions: canEdit(state) ? valueActions(model.values(for: key)) : nil)
      } else {
        Spacer(minLength: 0)
      }
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.appBackground)
    // On every appear too (a view shown again after `stop()`). `load()` returns at once; the
    // reads run in their own task, which this one's cancellation never stops half way.
    .task(id: LoadTrigger(key: key, isConnected: isConnected)) { load() }
    .onDisappear {
      model.stop()
      editor.cancel()
    }
    // Another key in this tab (a preview retargeted): an edit asked for the old one is dropped
    .onChange(of: key) { editor.cancel() }
    .sheet(item: $editTarget) { target in
      RedisKeyEditSheet(
        request: target.request, context: workspaceManager.redisKeyWriteContext(),
        epoch: target.epoch, databasePassword: databasePassword, isConnected: isConnected,
        onDone: handle)
    }
    .onChange(of: editor.pending?.id, initial: true) {
      dialogConfirmation = editor.pending.flatMap { $0.needsSafeModePanel ? nil : $0 }
    }
    .confirmationDialog(
      dialogConfirmation?.write.title ?? "",
      isPresented: Binding(
        get: { dialogConfirmation != nil },
        set: { if !$0 { dialogConfirmation = nil } }),
      titleVisibility: .visible,
      presenting: dialogConfirmation
    ) { pending in
      Button(pending.write.confirmTitle, role: .destructive) {
        Task { if let outcome = await editor.confirm(pending) { handle(pending.write, outcome) } }
      }
      Button("Cancel", role: .cancel) { editor.cancel() }
    } message: { pending in
      Text(verbatim: pending.write.details.joined(separator: "\n"))
    }
    .sheet(
      isPresented: Binding(
        get: { editor.pending?.needsSafeModePanel == true },
        set: { if !$0 { editor.cancel() } })
    ) {
      if let pending = editor.pending, pending.needsSafeModePanel {
        RedisWriteConfirmSheet(
          editor: editor, confirmation: pending, databasePassword: databasePassword,
          isConnected: isConnected, onDone: handle)
      }
    }
  }

  private var databasePassword: String? { workspaceManager.workspace.connectionConfig?.password }

  // MARK: - Edits

  private func headerActions(_ state: RedisKeyViewerModel.State) -> RedisKeyHeaderActions {
    var hasExpiry = false
    if case .loaded(let header) = state, header.expiry != .never { hasExpiry = true }
    return RedisKeyHeaderActions(
      setTTL: {
        editTarget = RedisKeyEditTarget(
          request: .ttl(key, hasExpiry: hasExpiry), epoch: model.loadEpoch)
      },
      rename: { editTarget = RedisKeyEditTarget(request: .rename(key), epoch: model.loadEpoch) },
      delete: { remove(.delete(key)) })
  }

  /// The value's edits for its type; the string only when fully read, at most 1 MiB and text
  private func valueActions(_ values: RedisKeyViewerModel.Values) -> RedisValueActions? {
    switch values {
    case .string(let value):
      var note: String?
      if !value.isComplete || value.bytes.count > RedisKeyWrite.maxInputBytes {
        note = "Only a value read whole (up to 256 KiB here) can be edited. Use a command tab."
      } else if !value.isText {
        note = "This value is binary; it cannot be edited as text. Use a command tab."
      }
      let open = {
        editTarget = RedisKeyEditTarget(
          request: .stringValue(key, old: value.bytes), epoch: model.loadEpoch)
      }
      return RedisValueActions(
        editString: note == nil ? open : nil, editStringNote: note, add: {}, edit: { _ in },
        remove: { _ in })
    case .rows(let list):
      return RedisValueActions(
        add: {
          editTarget = RedisKeyEditTarget(request: addRequest(list.kind), epoch: model.loadEpoch)
        },
        edit: { row in
          if let request = editRequest(row) {
            editTarget = RedisKeyEditTarget(request: request, epoch: model.loadEpoch)
          }
        },
        remove: { row in
          if let write = removal(row) { remove(write) }
        })
    case .loading, .unsupported, .failed:
      return nil
    }
  }

  private func addRequest(_ kind: RedisKeyViewerModel.KeyType) -> RedisKeyEditRequest {
    switch kind {
    case .hash: .hashField(key, field: nil)
    case .list: .pushElement(key)
    case .sortedSet: .sortedSetMember(key, member: nil)
    case .stream: .streamEntry(key)
    default: .setMember(key)
    }
  }

  /// By the row's exact bytes (or index), never its shown text
  private func editRequest(_ row: RedisKeyViewerModel.ValueRow) -> RedisKeyEditRequest? {
    switch (row.identity, model.values(for: key)) {
    case (.field(let field), _): .hashField(key, field: field)
    case (.index(let index), _): .listElement(key, index: index)
    case (.member(let member), .rows(let list)) where list.kind == .sortedSet:
      .sortedSetMember(key, member: member)
    default: nil
    }
  }

  /// By the row's exact bytes, never its shown text; a list element is never removed
  private func removal(_ row: RedisKeyViewerModel.ValueRow) -> RedisKeyWrite? {
    guard case .rows(let list) = model.values(for: key) else { return nil }
    switch (row.identity, list.kind) {
    case (.field(let field), _): return .removeHashField(key, field: field)
    case (.member(let member), .set): return .removeSetMember(key, member: member)
    case (.member(let member), .sortedSet): return .removeSortedSetMember(key, member: member)
    case (.entry(let id), _): return .deleteStreamEntry(key, id: id)
    default: return nil
    }
  }

  /// A removal: asked first under every commit style (the dialog, or the Safe Mode sheet)
  private func remove(_ write: RedisKeyWrite) {
    let epoch = model.loadEpoch
    Task { if let outcome = await editor.request(write, epoch: epoch) { handle(write, outcome) } }
  }

  /// After a write reached the server: the sidebar reads the db's keys again; the key is read
  /// again, shown missing, closed (deleted) or shown under its new name (renamed). By the live
  /// model, never this view copy's `key`: the preview may show another key by now, or the tab be
  /// closed (its model stopped), and then the written key is not read again here.
  private func handle(_ write: RedisKeyWrite, _ outcome: RedisKeyEditor.Outcome) {
    workspaceManager.noteRedisKeysChanged(db: write.key.db)
    switch outcome {
    case .keyGone:
      model.markMissing(write.key)
    case .written:
      switch write.effect {
      case .changed, .created:
        if model.isShowing(write.key) { load(write.key) }
      case .deleted:
        workspaceManager.closeRedisKeyTabs(showing: write.key)
      case .renamed(let newKey):
        workspaceManager.retargetRedisKeyTabs(from: write.key, to: newKey)
      }
    }
  }

  /// The value shows under a header being read (as a placeholder) or read, while connected
  private func showsValue(_ state: RedisKeyViewerModel.State) -> Bool {
    let connection = workspaceManager.connectionState
    guard connection.isConnected || connection.isConnecting else { return false }
    switch state {
    case .loading, .loaded: return true
    case .missing, .failed: return false
    }
  }

  /// Reads the header and value of the tab's key
  private func load() { load(key) }

  /// Reads the header and value of `key`; while not connected, drops what was read, so a
  /// reconnect shows the placeholder, never the old header first. Returns at once: the reads
  /// run off the main thread.
  private func load(_ key: RedisKeyRef) {
    guard isConnected else {
      model.reset()
      return
    }
    // A key tab has no notebook view model (no tab policy): the connection's policy
    let policy = ProtectionPolicy(config: workspaceManager.workspace.connectionConfig)
    model.load(key, manager: workspaceManager.connectionManager, policy: policy)
  }
}

// MARK: - Header card

/// The key's own edits in its header
struct RedisKeyHeaderActions {
  let setTTL: () -> Void
  let rename: () -> Void
  let delete: () -> Void
}

/// Why the last edit was not written, under the header, until closed
private struct RedisEditMessage: View {
  let message: String
  let onClose: () -> Void

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundColor(.warning)
        .accessibilityHidden(true)
      Text(verbatim: message)
        .font(.small)
        .foregroundColor(.foreground)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Dismiss")
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.controlBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }
}

/// The key's name and db, then its facts, a placeholder of the same shape, or why there are none
private struct RedisKeyHeaderCard: View {
  let key: RedisKeyRef
  let state: RedisKeyViewerModel.State
  let loadID: UUID
  let connection: ConnectionState
  let onReload: () -> Void
  /// nil: read-only, or nothing loaded
  let actions: RedisKeyHeaderActions?
  /// An edit is being checked or sent
  let isBusy: Bool

  private typealias Model = RedisKeyViewerModel

  var body: some View {
    // Escapes a bounded prefix (1,024 bytes) and cuts to 256 characters, like the sidebar
    let label = RedisKeyBrowserModel.label(key.bytes)
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "key")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(.foregroundMuted)
          .accessibilityHidden(true)
        Text(verbatim: label.isEmpty ? "(empty)" : label)
          .font(.monoMedium)
          .foregroundColor(.foreground)
          .lineLimit(2)
          .truncationMode(.tail)
          .textSelection(.enabled)
          .help(label)
        Spacer(minLength: Spacing.sm)
        Text(verbatim: "db \(key.db)")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .background(Color.controlBackground)
      Rectangle().fill(Color.border).frame(height: 1)
      details
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }
    .background(Color.appBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))
  }

  @ViewBuilder
  private var details: some View {
    if connection.isConnecting {
      // Read again once connected: never the previous connection's header meanwhile
      placeholder
    } else if !connection.isConnected {
      note(
        icon: "bolt.horizontal.circle", color: .foregroundMuted, title: "Not connected",
        text: "Connect to read this key.", reload: false)
    } else {
      switch state {
      case .loading:
        placeholder
      case .loaded(let header):
        facts(header)
      case .missing:
        note(
          icon: "exclamationmark.circle", color: .warning, title: "Key no longer exists",
          text: "It was deleted or has expired.", reload: true)
      case .failed(let message):
        note(
          icon: "exclamationmark.triangle", color: .destructive, title: "Could not read this key",
          text: message, reload: true)
      }
    }
  }

  private func facts(_ header: Model.Header) -> some View {
    HStack(alignment: .top, spacing: Spacing.xl) {
      fact("Type") { Text(verbatim: header.type.title) }
      fact("TTL") {
        switch header.expiry {
        case .never: Text("No expiry")
        case .at(let deadline): RedisTTLCountdown(deadline: deadline)
        }
      }
      fact("Memory") { Text(verbatim: Model.memoryText(header.memoryBytes)) }
        .help("MEMORY USAGE: the bytes the key and its value take in the server's memory")
      if let length = header.stringLength {
        fact("Length") { Text(verbatim: Model.lengthText(length)) }
      }
      Spacer(minLength: 0)
      HStack(spacing: Spacing.xs) {
        // Also on read-only connections: after "the connection changed; reload the key"
        Button(action: onReload) {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .help("Read this key again")
        .accessibilityLabel("Reload")
        if let actions {
          editButtons(actions)
        }
      }
    }
  }

  private func editButtons(_ actions: RedisKeyHeaderActions) -> some View {
    HStack(spacing: Spacing.xs) {
      if isBusy {
        DelayedSpinner()
      }
      Button(action: actions.setTTL) {
        Image(systemName: "timer")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Set or remove the TTL")
      .accessibilityLabel("Set TTL")
      Button(action: actions.rename) {
        Image(systemName: "pencil")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Rename the key (RENAMENX: never over another key)")
      .accessibilityLabel("Rename")
      Button("Delete", action: actions.delete)
        .buttonStyle(DangerButtonStyle(vPadding: Spacing.xs))
        .help("Delete the key (UNLINK), after you confirm")
    }
    .disabled(isBusy)
  }

  /// The facts' shape with bars for their values, and a spinner after 150 ms
  private var placeholder: some View {
    HStack(alignment: .top, spacing: Spacing.xl) {
      ForEach(["Type", "TTL", "Memory"], id: \.self) { title in
        fact(title) {
          RoundedRectangle(cornerRadius: CornerRadius.sm)
            .fill(Color.foregroundMuted.opacity(0.15))
            .frame(width: 56, height: 11)
            .padding(.vertical, 2)
        }
      }
      Spacer(minLength: 0)
      // Restarts its delay with each load (a new key in the same tab)
      DelayedSpinner().id(loadID)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading key details")
  }

  private func fact<Value: View>(
    _ title: String, @ViewBuilder value: () -> Value
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(title)
        .font(.smallest)
        .foregroundColor(.foregroundMuted)
      value()
        .font(.small.weight(.medium))
        .foregroundColor(.foreground)
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
  }

  private func note(
    icon: String, color: Color, title: String, text: String, reload: Bool
  ) -> some View {
    HStack(alignment: .center, spacing: Spacing.sm) {
      Image(systemName: icon)
        .foregroundColor(color)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(title)
          .font(.small.weight(.semibold))
          .foregroundColor(.foreground)
        Text(verbatim: text)
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: Spacing.sm)
      if reload {
        Button("Reload", action: onReload)
          .buttonStyle(SecondaryButtonStyle(vPadding: Spacing.xs))
          .help("Read this key again")
      }
    }
  }
}

// MARK: - TTL countdown

/// The time left before `deadline`, redrawn only when its whole second changes; only this text
/// is redrawn, never the card
private struct RedisTTLCountdown: View {
  let deadline: ContinuousClock.Instant
  @State private var now = ContinuousClock.now

  private typealias Model = RedisKeyViewerModel

  var body: some View {
    Text(
      verbatim: Model.ttlText(
        remainingMilliseconds: Model.remainingMilliseconds(until: deadline, now: now))
    )
    .monospacedDigit()
    .task(id: deadline) {
      now = .now
      while true {
        let remaining = Model.remainingMilliseconds(until: deadline, now: .now)
        guard remaining > 0 else { return }
        let wait = Model.nextTickDelay(remainingMilliseconds: remaining)
        guard (try? await Task.sleep(for: .milliseconds(wait))) != nil else { return }
        now = .now
      }
    }
  }
}

// MARK: - Spinner

/// A small spinner that fades in after 150 ms, so a fast read never flashes it (also the value
/// views')
struct DelayedSpinner: View {
  @State private var isShown = false

  var body: some View {
    ProgressView()
      .controlSize(.small)
      .tint(.accent)
      .opacity(isShown ? 1 : 0)
      .animation(.easeIn(duration: 0.15), value: isShown)
      // Opt out of the app-wide animation kill switch, only for the fade
      .transaction(value: isShown) { $0.disablesAnimations = false }
      .task {
        // A cancelled sleep must not show it after it disappeared
        guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return }
        isShown = true
      }
  }
}
