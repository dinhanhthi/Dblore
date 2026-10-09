// SSHHostKeyTrustSheet.swift
// The first-connection fingerprint sheet and its AppKit host. The sheet attaches to the
// frontmost window (or the sheet already on it, e.g. the connection form), so it shows above
// any SwiftUI sheet. The changed-key alert attaches to the top-level window instead: a sheet
// it could sit on (the Safe Mode unlock) may be closing, and AppKit queues the alert behind it.
// Host-key data is external input: shown as plain text.

import AppKit
import SwiftUI

struct SSHHostKeyTrustSheet: View {
  let request: SSHHostKeyTrustRequest
  let onDecide: (Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      HStack(spacing: Spacing.md) {
        Image(systemName: "key.horizontal")
          .font(.system(size: 28))
          .foregroundColor(.accent)
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Trust this SSH server?")
            .font(.heading)
            .foregroundColor(.foreground)
          Text(
            "First connection to this SSH server. Verify the fingerprint with your server "
              + "administrator before trusting."
          )
          .font(.bodyText)
          .foregroundColor(.foregroundMuted)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      VStack(alignment: .leading, spacing: Spacing.sm) {
        row("Server", verbatim: "\(request.host):\(request.port)")
        row("Key type", verbatim: request.algorithm)
        row("Fingerprint", verbatim: request.fingerprint)
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.lg).fill(Color.cardHeaderBackground))

      HStack(spacing: Spacing.md) {
        Spacer()
        Button("Cancel") { onDecide(false) }
          .buttonStyle(SecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
        Button("Trust and Connect") { onDecide(true) }
          .buttonStyle(PrimaryButtonStyle())
      }
    }
    .padding(Spacing.xl)
    .frame(width: 460)
    .background(Color.appBackground)
  }

  private func row(_ label: String, verbatim value: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(label)
        .font(.small)
        .foregroundColor(.foregroundMuted)
      Text(verbatim: value)
        .font(.mono)
        .foregroundColor(.foreground)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Presents the trust sheet as a window sheet and the changed-key alert as an `NSAlert`.
@MainActor
final class AppKitSSHHostKeyTrustPresenter: SSHHostKeyTrustPresenting {
  private var sheet: NSWindow?
  private var decide: (@MainActor (Bool) -> Void)?
  private var hostObservers: [any NSObjectProtocol] = []
  private var showsChangedAlert = false
  private var changedAlertObserver: (any NSObjectProtocol)?

  func presentTrust(
    _ request: SSHHostKeyTrustRequest, decide: @escaping @MainActor (Bool) -> Void
  ) -> Bool {
    guard sheet == nil, let parent = Self.hostWindow() else { return false }
    self.decide = decide
    let view = SSHHostKeyTrustSheet(request: request) { [weak self] trusted in
      self?.finish(trusted)
    }
    let window = NSWindow(contentViewController: NSHostingController(rootView: view))
    sheet = window
    observeHostGoingAway(parent, sheet: window)
    parent.beginSheet(window)
    return true
  }

  func dismissTrust() {
    decide = nil
    closeSheet()
  }

  func presentHostKeyChanged(_ change: SSHHostKeyChange) {
    guard !showsChangedAlert else { return }
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "SSH host key changed"
    alert.informativeText =
      DatabaseError.sshHostKeyChanged(
        host: change.host, port: change.port, expected: change.expected,
        presented: change.presented
      ).localizedDescription
    let fingerprints = NSTextField(
      wrappingLabelWithString: "Expected:  \(change.expected)\nPresented: \(change.presented)")
    fingerprints.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    fingerprints.isSelectable = true
    fingerprints.preferredMaxLayoutWidth = 360
    fingerprints.frame.size = fingerprints.fittingSize
    alert.accessoryView = fingerprints
    alert.addButton(withTitle: "OK")
    guard let root = Self.rootWindow() else {
      alert.runModal()
      return
    }
    showsChangedAlert = true
    // Closing the window drops its queued or shown alert, possibly without the completion
    // handler: reopen the gate then too, so a later changed key still alerts.
    changedAlertObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: root, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.changedAlertEnded() }
    }
    alert.beginSheetModal(for: root) { [weak self] _ in
      self?.changedAlertEnded()
    }
  }

  private func changedAlertEnded() {
    showsChangedAlert = false
    if let changedAlertObserver {
      NotificationCenter.default.removeObserver(changedAlertObserver)
    }
    changedAlertObserver = nil
  }

  private func finish(_ trusted: Bool) {
    let pending = decide
    decide = nil
    closeSheet()
    pending?(trusted)
  }

  /// The window hosting the sheet closed, or (itself a sheet) ended without closing: nobody
  /// can answer, so the key is not trusted. `finish` runs `decide` at most once.
  private func observeHostGoingAway(_ parent: NSWindow, sheet window: NSWindow) {
    let center = NotificationCenter.default
    hostObservers.append(
      center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.finish(false) }
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
            if !attached { self.finish(false) }
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

  /// The top-level window under the frontmost one (never a sheet).
  private static func rootWindow() -> NSWindow? {
    var window =
      NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible }
    while let parent = window?.sheetParent {
      window = parent
    }
    return window
  }

  /// The frontmost visible window, descending into the sheets already attached to it.
  private static func hostWindow() -> NSWindow? {
    var window =
      NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible }
    while let attached = window?.attachedSheet {
      window = attached
    }
    return window
  }
}
