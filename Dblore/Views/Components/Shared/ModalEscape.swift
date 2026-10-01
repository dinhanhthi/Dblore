//
//  ModalEscape.swift
//  Dblore
//
//  Escape closes the top custom modal. A focused text field and the workspace
//  key monitor otherwise swallow Escape before the close button can see it.
//

import SwiftUI

// MARK: - Registry

/// Modals currently on screen, per window. The top entry is the one opened last.
@MainActor
final class ModalDismissRegistry {
  static let shared = ModalDismissRegistry(monitorsEvents: true)

  private final class Entry {
    /// `NSWindow` does not support weak references reliably, so identity is stored instead.
    var windowID: ObjectIdentifier?
    var dismiss: () -> Void

    init(windowID: ObjectIdentifier?, dismiss: @escaping () -> Void) {
      self.windowID = windowID
      self.dismiss = dismiss
    }
  }

  private let monitorsEvents: Bool
  private var entries: [UUID: Entry] = [:]
  private var order: [UUID] = []
  /// Ids whose dismiss already ran and whose view has not left the screen yet.
  private var dismissing: Set<UUID> = []
  private var monitor: Any?

  init(monitorsEvents: Bool = false) {
    self.monitorsEvents = monitorsEvents
  }

  func upsert(id: UUID, window: NSWindow?, dismiss: @escaping () -> Void) {
    let windowID = window.map(ObjectIdentifier.init)
    if let entry = entries[id] {
      entry.windowID = windowID
      entry.dismiss = dismiss
      return
    }
    entries[id] = Entry(windowID: windowID, dismiss: dismiss)
    order.append(id)
    installMonitorIfNeeded()
  }

  func unregister(id: UUID) {
    entries[id] = nil
    order.removeAll { $0 == id }
    dismissing.remove(id)
  }

  func hasModal(in window: NSWindow) -> Bool {
    let windowID = ObjectIdentifier(window)
    return order.contains { entries[$0]?.windowID == windowID }
  }

  /// Handles one keyDown. Returns nil when this modal layer consumed the event.
  func handleKeyDown(_ event: NSEvent) -> NSEvent? {
    guard event.keyCode == 53 else { return event }
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard modifiers.isEmpty else { return event }
    guard let window = event.window, window.isKeyWindow else { return event }
    // A sheet or an AppKit alert is in front of the overlay. Let it take Escape.
    guard window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
    // Autocomplete inside a modal (the favorite SQL editor) dismisses first.
    if let editor = window.firstResponder as? SQLTextView,
      !editor.getAutocompleteSuggestions().isEmpty
    {
      return event
    }
    return handleEscape(in: window) ? nil : event
  }

  /// Dismisses the top modal in `window`. A second Escape while that dismiss is
  /// in flight is swallowed so it does not fall through to the editor.
  @discardableResult
  func handleEscape(in window: NSWindow) -> Bool {
    let windowID = ObjectIdentifier(window)
    guard let id = order.last(where: { entries[$0]?.windowID == windowID }) else { return false }
    if !dismissing.contains(id), let dismiss = entries[id]?.dismiss {
      dismissing.insert(id)
      dismiss()
    }
    return true
  }

  private func installMonitorIfNeeded() {
    guard monitorsEvents, monitor == nil else { return }
    // Local monitors are delivered on the main thread, same as the other key monitor.
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      ModalDismissRegistry.shared.handleKeyDown(event)
    }
  }
}

// MARK: - Catcher

/// Invisible view that registers the presented modal for Escape.
struct ModalEscapeCatcher: NSViewRepresentable {
  var dismiss: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(dismiss: dismiss)
  }

  func makeNSView(context: Context) -> ModalEscapeAnchor {
    let view = ModalEscapeAnchor()
    context.coordinator.bind(to: view)
    return view
  }

  func updateNSView(_ nsView: ModalEscapeAnchor, context: Context) {
    context.coordinator.dismiss = dismiss
    context.coordinator.bind(to: nsView)
  }

  static func dismantleNSView(_ nsView: ModalEscapeAnchor, coordinator: Coordinator) {
    coordinator.unbind()
  }

  @MainActor
  final class Coordinator {
    let id = UUID()
    var dismiss: () -> Void

    init(dismiss: @escaping () -> Void) {
      self.dismiss = dismiss
    }

    func bind(to view: ModalEscapeAnchor) {
      view.onWindowChange = { [weak self] window in
        guard let self else { return }
        ModalDismissRegistry.shared.upsert(id: self.id, window: window, dismiss: self.dismiss)
      }
      ModalDismissRegistry.shared.upsert(id: id, window: view.window, dismiss: dismiss)
    }

    func unbind() {
      ModalDismissRegistry.shared.unregister(id: id)
    }
  }
}

@MainActor
final class ModalEscapeAnchor: NSView {
  var onWindowChange: ((NSWindow?) -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onWindowChange?(window)
  }

  override nonisolated func hitTest(_ point: NSPoint) -> NSView? { nil }
}
