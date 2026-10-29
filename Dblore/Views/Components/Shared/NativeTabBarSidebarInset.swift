//
//  NativeTabBarSidebarInset.swift
//  Dblore
//

import AppKit
import SwiftUI

/// Makes the native window tab bar start after the left sidebar (full width at 0).
///
/// AppKit insets the window tab bar to the sidebar split item of the window's content, so this
/// adds a hidden `NSSplitViewController` inside this view's anchor and moves its divider
/// to `width`. The split view stays hidden, so every click still reaches SwiftUI (a visible one
/// would take them). `width` is animatable: SwiftUI interpolates it in the same transaction as
/// the sidebar, so the bar follows the sidebar while it slides.
struct NativeTabBarSidebarInset: View, Animatable {
  var width: CGFloat

  var animatableData: CGFloat {
    get { width }
    set { width = newValue }
  }

  // SwiftUI interpolates an animatable view, not a representable: this view gets every frame's
  // width and hands it on
  var body: some View {
    SidebarInsetAnchor(width: width)
  }
}

/// Places the anchor view that keeps the window's sidebar probe at `width`
private struct SidebarInsetAnchor: NSViewRepresentable {
  let width: CGFloat

  func makeNSView(context: Context) -> NativeTabBarSidebarInsetView {
    let view = NativeTabBarSidebarInsetView()
    view.width = width
    return view
  }

  func updateNSView(_ nsView: NativeTabBarSidebarInsetView, context: Context) {
    nsView.width = width
  }
}

/// Full-size, hit-test-transparent anchor that owns the window's sidebar probe while it is in a
/// window
final class NativeTabBarSidebarInsetView: NSView {
  var width: CGFloat = 0 {
    didSet {
      guard width != oldValue else { return }
      probe?.apply(width: width)
    }
  }
  private var probe: SidebarInsetProbe?

  override nonisolated func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow !== window { releaseProbe() }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    let probe = SidebarInsetProbe.probe(for: window)
    probe.owner = self
    self.probe = probe
    probe.apply(width: width)
  }

  private func releaseProbe() {
    guard let probe else { return }
    self.probe = nil
    // A view SwiftUI created for the same window may own the probe already
    if probe.owner === self || probe.owner == nil { probe.detach() }
  }
}

/// The hidden split view controller of one window, attached to its hosting controller.
///
/// When a window becomes the selected tab, AppKit gives its sidebar split item the thickness the
/// previous tab had. The probe then moves its divider back to its own width.
@MainActor
private final class SidebarInsetProbe {
  /// One probe per window, so a recreated representable reuses it
  private static var probes: [ObjectIdentifier: SidebarInsetProbe] = [:]

  weak var owner: NativeTabBarSidebarInsetView?
  private weak var window: NSWindow?
  private let split = NSSplitViewController()
  private let sidebarItem: NSSplitViewItem
  /// Width the divider should stay at
  private var width: CGFloat = 0
  private var isMovingDivider = false
  private var isRestorePending = false
  private var resizeObserver: NSObjectProtocol?

  static func probe(for window: NSWindow) -> SidebarInsetProbe {
    // A closed window's identifier can be reused: after this, an entry is this window's
    dropClosedWindows()
    if let probe = probes[ObjectIdentifier(window)] {
      probe.attachIfNeeded()
      return probe
    }
    let probe = SidebarInsetProbe(window: window)
    probes[ObjectIdentifier(window)] = probe
    return probe
  }

  private init(window: NSWindow) {
    self.window = window
    let sidebarController = NSViewController()
    sidebarController.view = NSView()
    sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
    sidebarItem.minimumThickness = 0
    sidebarItem.canCollapseFromWindowResize = false
    split.addSplitViewItem(sidebarItem)
    let contentController = NSViewController()
    contentController.view = NSView()
    let contentItem = NSSplitViewItem(viewController: contentController)
    contentItem.minimumThickness = 0
    contentItem.canCollapseFromWindowResize = false
    split.addSplitViewItem(contentItem)
    resizeObserver = NotificationCenter.default.addObserver(
      forName: NSSplitView.didResizeSubviewsNotification, object: split.splitView, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.splitViewDidResize() }
    }
    attachIfNeeded()
  }

  /// Puts the split view in the owner anchor, sized to it (a zero-size split view clamps the
  /// divider to 0); SwiftUI does not support a subview of the hosting view itself. It stays
  /// hidden: the tab bar follows its sidebar item anyway.
  private func attachIfNeeded() {
    guard let window, let container = owner else { return }
    if split.view.superview === container { return }
    split.view.removeFromSuperview()
    split.removeFromParent()
    window.contentViewController?.addChild(split)
    split.view.isHidden = true
    split.view.frame = container.bounds
    split.view.autoresizingMask = [.width, .height]
    container.addSubview(split.view, positioned: .below, relativeTo: nil)
  }

  /// Where the window tab bar starts: 0 while the sidebar item is collapsed
  private var dividerPosition: CGFloat {
    sidebarItem.isCollapsed ? 0 : sidebarItem.viewController.view.frame.width
  }

  /// Moves the sidebar divider to `width`; the window tab bar starts there
  func apply(width: CGFloat) {
    attachIfNeeded()
    self.width = max(0, width)
    moveDivider()
  }

  private func moveDivider() {
    guard abs(dividerPosition - width) > 0.5 else { return }
    isMovingDivider = true
    defer { isMovingDivider = false }
    // Expanded first: a collapsed item only follows the divider again past half its last
    // thickness, so the tab bar would stay at 0 while the sidebar slides in
    if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
    split.splitView.setPosition(width, ofDividerAt: 0)
    split.view.layoutSubtreeIfNeeded()
    // Narrower than AppKit lets a sidebar item get (about 10pt): collapsed, the bar starts at 0
    if dividerPosition > width + 0.5 {
      sidebarItem.isCollapsed = true
      split.view.layoutSubtreeIfNeeded()
    }
  }

  /// Something else moved the divider (a tab selection): put it back on the next turn
  private func splitViewDidResize() {
    guard !isMovingDivider, !isRestorePending, abs(dividerPosition - width) > 0.5 else { return }
    isRestorePending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      isRestorePending = false
      moveDivider()
    }
  }

  func detach() {
    tearDown()
    Self.probes = Self.probes.filter { $0.value !== self }
    Self.dropClosedWindows()
  }

  private func tearDown() {
    if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    resizeObserver = nil
    split.view.removeFromSuperview()
    split.removeFromParent()
  }

  /// Every probe leaves the registry through `tearDown`, so its resize observer goes with it
  private static func dropClosedWindows() {
    for (key, probe) in probes where probe.window == nil {
      probe.tearDown()
      probes[key] = nil
    }
  }
}
