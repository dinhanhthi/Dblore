//
//  RedisKeyViewerView.swift
//  Dblore
//
//  A Redis key tab: a header card with the key's escaped name and db (known at once), then its
//  type, TTL (a live countdown) and size once read (`RedisKeyViewerModel`). Until then the card
//  keeps its shape with placeholder values, and a spinner fades in after 150 ms, so a click shows
//  the new key in the frame it lands and a fast read never flashes the spinner. A key that no
//  longer exists shows its own state. A new key in the same preview tab, or a reconnect, reads
//  the header again. Server text is shown as plain, escaped text only.
//

import SwiftUI

struct RedisKeyViewerView: View {
  let key: RedisKeyRef
  let workspaceManager: WorkspaceManager

  /// One per tab (the container gives each tab its own view); dropped with the tab
  @State private var model = RedisKeyViewerModel()

  /// What reads the header again when it changes
  private struct LoadTrigger: Equatable {
    let key: RedisKeyRef
    let isConnected: Bool
  }

  private var isConnected: Bool { workspaceManager.connectionState.isConnected }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      RedisKeyHeaderCard(
        key: key, state: model.state(for: key), loadID: model.loadID,
        connection: workspaceManager.connectionState, onReload: load)
      // The value area
      Spacer(minLength: 0)
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.appBackground)
    // On every appear too (a view shown again after `stop()`). `load()` returns at once; the
    // reads run in their own task, which this one's cancellation never stops half way.
    .task(id: LoadTrigger(key: key, isConnected: isConnected)) { load() }
    .onDisappear { model.stop() }
  }

  /// Reads the header of `key` (nothing while not connected). Returns at once: the reads run
  /// off the main thread.
  private func load() {
    guard isConnected else {
      model.stop()
      return
    }
    // The command tabs' policy (none is active here), else the connection's: reads pass it
    let policy =
      workspaceManager.activeViewModel?.protectionPolicy
      ?? ProtectionPolicy(config: workspaceManager.workspace.connectionConfig)
    model.load(key, manager: workspaceManager.connectionManager, policy: policy)
  }
}

// MARK: - Header card

/// The key's name and db, then its facts, a placeholder of the same shape, or why there are none
private struct RedisKeyHeaderCard: View {
  let key: RedisKeyRef
  let state: RedisKeyViewerModel.State
  let loadID: UUID
  let connection: ConnectionState
  let onReload: () -> Void

  private typealias Model = RedisKeyViewerModel

  var body: some View {
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
    }
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

/// A small spinner that fades in after 150 ms, so a fast read never flashes it
private struct DelayedSpinner: View {
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
