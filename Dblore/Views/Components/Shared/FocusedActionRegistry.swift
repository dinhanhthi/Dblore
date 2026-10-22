//
//  FocusedActionRegistry.swift
//  Dblore
//
//  Menu commands for workspace windows hosted by AppKit (`NSHostingController`). Those windows
//  are not part of the `WindowGroup` scene, so `focusedSceneValue` never reaches `@FocusedValue`
//  in the commands. Publishers also record their value per hosting window here, and the
//  commands fall back to the key window's record.

import AppKit
import Combine
import SwiftUI

// MARK: - Registry

/// Values each window publishes with `bridgedFocusedSceneValue`, per focused value key.
@MainActor
final class FocusedActionRegistry: ObservableObject {
  static let shared = FocusedActionRegistry()

  private struct Publication {
    let owner: ObjectIdentifier
    var depth: Int
    var value: Any
    /// Publication order: among publishers at the same depth, the latest wins
    let order: Int
  }

  private struct WindowEntry {
    weak var window: NSWindow?
    var publications: [AnyKeyPath: [Publication]] = [:]
  }

  private let keyWindow: () -> NSWindow?
  private var entries: [ObjectIdentifier: WindowEntry] = [:]
  private var nextOrder = 0
  private var isRefreshScheduled = false
  private var tokens: [any NSObjectProtocol] = []

  init(keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }) {
    self.keyWindow = keyWindow
    let center = NotificationCenter.default
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      tokens.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.scheduleRefresh() }
        })
    }
    tokens.append(
      center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
        [weak self] note in
        guard let window = note.object as? NSWindow else { return }
        MainActor.assumeIsolated { self?.windowWillClose(window) }
      })
  }

  /// Records `value` for `key` in `window`. A nil value withdraws this owner's record of the key.
  /// `depth` is the publisher's nesting: the innermost publisher of a key wins, as in SwiftUI.
  func publish<Value>(
    _ value: Value?, for key: WritableKeyPath<FocusedValues, Value?>, owner: ObjectIdentifier,
    depth: Int = 0, in window: NSWindow
  ) {
    store(value.map { $0 as Any }, for: key, owner: owner, depth: depth, in: window)
  }

  func store(
    _ value: Any?, for key: AnyKeyPath, owner: ObjectIdentifier, depth: Int, in window: NSWindow
  ) {
    let id = ObjectIdentifier(window)
    if entries[id]?.window !== window {
      // A new window: forget the ones that went away without a close notification
      entries = entries.filter { $0.value.window != nil }
      entries[id] = WindowEntry(window: window)
    }
    var entry = entries[id] ?? WindowEntry(window: window)
    var publications = entry.publications[key] ?? []
    let index = publications.firstIndex { $0.owner == owner }
    let old = index.map { publications[$0].value }

    if let value {
      if let index {
        publications[index].value = value
        publications[index].depth = depth
      } else {
        publications.append(Publication(owner: owner, depth: depth, value: value, order: nextOrder))
        nextOrder += 1
      }
    } else if let index {
      publications.remove(at: index)
    }
    entry.publications[key] = publications.isEmpty ? nil : publications
    entries[id] = entry

    if !Self.isSameForMenus(old, value) { scheduleRefresh() }
  }

  /// Drops every record of `owner` (its view left the window or the hierarchy).
  func withdraw(owner: ObjectIdentifier) {
    var didRemove = false
    for (id, var entry) in entries {
      for (key, publications) in entry.publications {
        let kept = publications.filter { $0.owner != owner }
        guard kept.count != publications.count else { continue }
        entry.publications[key] = kept.isEmpty ? nil : kept
        didRemove = true
      }
      entries[id] = entry
    }
    if didRemove { scheduleRefresh() }
  }

  /// The key window's value for `key`, or nil. Never another window's value.
  func value<Value>(for key: WritableKeyPath<FocusedValues, Value?>) -> Value? {
    guard let window = keyWindow(),
      let entry = entries[ObjectIdentifier(window)], entry.window === window,
      let winner = entry.publications[key]?.max(by: { ($0.depth, $0.order) < ($1.depth, $1.order) })
    else { return nil }
    return winner.value as? Value
  }

  private func windowWillClose(_ window: NSWindow) {
    guard entries.removeValue(forKey: ObjectIdentifier(window)) != nil else { return }
    scheduleRefresh()
  }

  /// One republish per main queue turn. Publishers write during view updates, where a
  /// synchronous `objectWillChange` is not allowed.
  private func scheduleRefresh() {
    guard !isRefreshScheduled else { return }
    isRefreshScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      isRefreshScheduled = false
      objectWillChange.send()
    }
  }

  /// The menus only change when a value appears or goes, or an equatable value or object
  /// changes. Closures are rebuilt on every view update: the latest is stored, no republish.
  private static func isSameForMenus(_ old: Any?, _ new: Any?) -> Bool {
    guard let old, let new else { return old == nil && new == nil }
    if let old = old as? any Equatable { return old.isEqual(to: new) }
    if type(of: old) is AnyClass { return (old as AnyObject) === (new as AnyObject) }
    return true
  }
}

extension Equatable {
  fileprivate func isEqual(to other: Any) -> Bool {
    (other as? Self) == self
  }
}

// MARK: - Publishing

extension EnvironmentValues {
  /// Nesting of bridged publishers, so the innermost one of a key wins in the registry
  @Entry fileprivate var bridgedFocusDepth = 0
}

extension View {
  /// `focusedSceneValue`, also recorded for the hosting window so the menu commands see it in
  /// AppKit-hosted workspace windows (`BridgedFocusedValue`).
  func bridgedFocusedSceneValue<Value>(
    _ keyPath: WritableKeyPath<FocusedValues, Value?>, _ value: Value?
  ) -> some View {
    modifier(BridgedFocusedSceneValue(keyPath: keyPath, value: value))
  }
}

private struct BridgedFocusedSceneValue<Value>: ViewModifier {
  let keyPath: WritableKeyPath<FocusedValues, Value?>
  let value: Value?
  @Environment(\.bridgedFocusDepth) private var depth

  func body(content: Content) -> some View {
    content
      .environment(\.bridgedFocusDepth, depth + 1)
      .focusedSceneValue(keyPath, value)
      .background(
        BridgedFocusPublisher(key: keyPath, value: value.map { $0 as Any }, depth: depth))
  }
}

/// Records the value for the window it lives in, and withdraws it when it leaves.
private struct BridgedFocusPublisher: NSViewRepresentable {
  let key: AnyKeyPath
  let value: Any?
  let depth: Int

  func makeNSView(context: Context) -> PublisherView { PublisherView() }

  func updateNSView(_ nsView: PublisherView, context: Context) {
    nsView.update(key: key, value: value, depth: depth)
  }

  static func dismantleNSView(_ nsView: PublisherView, coordinator: ()) {
    FocusedActionRegistry.shared.withdraw(owner: ObjectIdentifier(nsView))
  }

  final class PublisherView: NSView {
    private var key: AnyKeyPath?
    private var value: Any?
    private var depth = 0

    /// Never takes clicks or drags from the content it sits behind
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      FocusedActionRegistry.shared.withdraw(owner: ObjectIdentifier(self))
      publish()
    }

    func update(key: AnyKeyPath, value: Any?, depth: Int) {
      self.key = key
      self.value = value
      self.depth = depth
      publish()
    }

    private func publish() {
      guard let window, let key else { return }
      FocusedActionRegistry.shared.store(
        value, for: key, owner: ObjectIdentifier(self), depth: depth, in: window)
    }
  }
}

// MARK: - Reading

/// `@FocusedValue` for menu commands, falling back to what the key window published with
/// `bridgedFocusedSceneValue` (AppKit-hosted windows). Observes the registry, so the commands
/// re-render when the key window changes or a window publishes a new value.
@propertyWrapper
struct BridgedFocusedValue<Value>: DynamicProperty {
  @FocusedValue private var focusedValue: Value?
  @ObservedObject private var registry = FocusedActionRegistry.shared
  private let keyPath: WritableKeyPath<FocusedValues, Value?>

  init(_ keyPath: WritableKeyPath<FocusedValues, Value?>) {
    _focusedValue = FocusedValue(keyPath)
    self.keyPath = keyPath
  }

  var wrappedValue: Value? {
    focusedValue ?? registry.value(for: keyPath)
  }
}
