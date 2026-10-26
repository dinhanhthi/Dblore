//
//  LockedOverlayView.swift
//  Dblore
//
// The cover of a relocked workspace window: its own locked workspace, or the locked connection
// it works on, was relocked (screen lock, sleep, idle). The workspace's layout is not built
// while covered, so nothing of it shows through or takes input; the content keys and documents
// stay in memory, so Unlock brings the window back without a reload. The cover goes only once
// `LockCenter` granted the unlock.

import AppKit
import SwiftUI

extension WorkspaceManager {
  /// What covers this workspace's windows now (`LockCenter.coverage`): its own workspace when
  /// relocked, else the connection it works on. A connection whose auto-connect stopped on its
  /// lock (`isConnectLocked`: never unlocked here, nothing of it loaded) keeps its banner.
  var lockCoverage: LockCoverage? {
    lockCenter.coverage(
      lockKeyId: lockKeyId, connection: isConnectLocked ? nil : workspace.connectionConfig)
  }
}

/// Same-shape cover with a lock, the workspace or connection name and Unlock. Unlock asks on
/// this window: a locked workspace through the workspace unlock (Touch ID or the Mac password
/// when this Mac's Keychain keeps its key, else the Lock password against its own wrap block),
/// a locked connection through `LockCenter.requestUnlock(for:)`.
struct LockedOverlayView: View {
  let coverage: LockCoverage
  let workspaceManager: WorkspaceManager
  /// The window the cover is on: the unlock asks there
  let window: () -> NSWindow?

  @State private var isUnlocking = false
  /// The cover's own window: read from the cover itself, so the unlock always has its sheet's
  /// window
  @State private var ownWindow = HostWindowReference()

  private var name: String {
    switch coverage {
    case .workspace:
      return LockedWorkspaceOpen.displayName(workspaceManager.workspace.name)
    case .connection(let config):
      return LockedWorkspaceOpen.displayName(
        config.name.isEmpty ? config.displayString : config.name)
    }
  }

  var body: some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "lock.fill")
        .font(.system(size: 40))
        .foregroundColor(.foregroundSubtle)
        .accessibilityHidden(true)
      VStack(spacing: Spacing.xs) {
        Text(isWorkspace ? "Locked Workspace" : "Locked Connection")
          .font(.heading)
          .foregroundColor(.foreground)
        Text(verbatim: name)
          .font(.mono)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Button("Unlock") { unlock() }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isUnlocking)
    }
    .padding(Spacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.appBackground)
    // Clicks and scrolls stop here: nothing below takes them
    .contentShape(Rectangle())
    .onTapGesture {}
    .ignoresSafeArea()
    .accessibilityElement(children: .contain)
    .background(HostWindowReader(reference: ownWindow))
  }

  private var isWorkspace: Bool {
    if case .workspace = coverage { return true }
    return false
  }

  /// Asks at once on this window (its sheet, never a windowless prompt); the cover stays until
  /// the grant. Unlock is enabled again whatever the answer.
  private func unlock() {
    guard !isUnlocking, let anchor = ownWindow.window ?? window() else { return }
    let center = workspaceManager.lockCenter
    let name = name
    switch coverage {
    case .workspace(let id):
      // Open here: its session holds the key, so the unlock checks against its own wrap block
      // (the Keychain path when this Mac keeps its key, else the Lock password field)
      guard let session = workspaceManager.lockedIO.sessions.session(for: id) else { return }
      isUnlocking = true
      Task {
        defer { isUnlocking = false }
        _ = await WorkspaceUnlockPrompt.present(
          session.header, title: name, reason: "unlock \(name)", anchor: anchor, center: center)
      }
    case .connection(let config):
      isUnlocking = true
      Task {
        defer { isUnlocking = false }
        _ = await center.requestUnlock(for: config, reason: "unlock \(name)", anchor: anchor)
      }
    }
  }
}
