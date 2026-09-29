//
//  WorkspaceWindowCloseGuard.swift
//  Dblore
//
//  Routes the window's close button through `resolvePendingTransaction(action: .closeWindow)`
//  while a Protected transaction is pending (Commit / Roll back / Cancel; Cancel keeps the
//  window). Only the button is retargeted: SwiftUI keeps its own window delegate.
//

import AppKit
import SwiftUI

struct WorkspaceWindowCloseGuard: NSViewRepresentable {
  let workspaceManager: WorkspaceManager

  func makeNSView(context: Context) -> GuardView {
    let view = GuardView()
    view.workspaceManager = workspaceManager
    return view
  }

  func updateNSView(_ nsView: GuardView, context: Context) {
    nsView.workspaceManager = workspaceManager
  }

  final class GuardView: NSView {
    weak var workspaceManager: WorkspaceManager?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      super.viewWillMove(toWindow: newWindow)
      // Leaving the window: give the button back its standard action
      if let window, let button = window.standardWindowButton(.closeButton),
        button.target === self
      {
        button.target = window
        button.action = #selector(NSWindow.performClose(_:))
      }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let button = window?.standardWindowButton(.closeButton) else { return }
      button.target = self
      button.action = #selector(closeButtonClicked(_:))
    }

    @objc private func closeButtonClicked(_ sender: Any?) {
      guard let window else { return }
      guard let manager = workspaceManager,
        WorkspaceTransactionRules.requiresResolution(
          state: manager.pendingTransaction, action: .closeWindow, originTabId: nil)
      else {
        closeWindow(window)
        return
      }
      Task { @MainActor in
        if await manager.resolvePendingTransaction(action: .closeWindow) {
          closeWindow(window)
        }
      }
    }

    // Not `performClose`: it clicks the close button, which re-enters `closeButtonClicked`
    private func closeWindow(_ window: NSWindow) {
      if window.delegate?.windowShouldClose?(window) == false { return }
      window.close()
    }
  }
}
