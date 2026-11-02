//
//  WorkspaceWindowCloseGuard.swift
//  Dblore
//
//  Routes the window's close button through `closeWorkspace`: the workspace closes with its
//  window (Protected transaction and unsaved-changes prompts first; Cancel keeps the window), so
//  no connection stays open behind a closed window and a locked workspace asks again at its next
//  open. Only the button is retargeted: SwiftUI keeps its own window delegate.
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
    /// The close button's own target and action, given back when this view leaves the window
    private weak var originalTarget: AnyObject?
    private var originalAction: Selector?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      super.viewWillMove(toWindow: newWindow)
      // Leaving the window: give the button back its own action. Never `performClose`: it
      // clicks the button, which would call `performClose` again until the stack overflows.
      if let button = window?.standardWindowButton(.closeButton), button.target === self {
        button.target = originalTarget
        button.action = originalAction
      }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let button = window?.standardWindowButton(.closeButton) else { return }
      // A guard about to leave (the next content can arrive first) holds the button's own
      if let other = button.target as? GuardView {
        if other !== self {
          originalTarget = other.originalTarget
          originalAction = other.originalAction
        }
      } else {
        originalTarget = button.target
        originalAction = button.action
      }
      button.target = self
      button.action = #selector(closeButtonClicked(_:))
    }

    @objc private func closeButtonClicked(_ sender: Any?) {
      guard let window else { return }
      guard let manager = workspaceManager else {
        closeWindow(window)
        return
      }
      Task { @MainActor in
        if await WorkspaceWindowManager.shared.closeWorkspace(id: manager.id) {
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
