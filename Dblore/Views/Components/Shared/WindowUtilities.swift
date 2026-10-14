//
//  WindowUtilities.swift
//  Dblore
//
//  Utilities for window management: drag area, double-click blocking, traffic lights
//

import AppKit
import SwiftUI

// MARK: - Window Drag Area

/// Invisible view that allows window dragging (like native titlebar)
struct WindowDragArea: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = WindowDragView()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Custom NSView that enables window dragging
class WindowDragView: NSView {
  override var mouseDownCanMoveWindow: Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.performDrag(with: event)
  }
}

/// Transparent backing view that makes the window unmovable while the pointer is over it, so a
/// drag in the transparent titlebar reaches the SwiftUI gesture instead of moving the window
/// (AppKit asks the NSHostingView, not this background view, whether a mouse-down moves the window)
struct WindowDragBlocker: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { WindowDragBlockerView() }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
class WindowDragBlockerView: NSView {
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self))
  }

  override func mouseEntered(with event: NSEvent) { window?.isMovable = false }

  override func mouseExited(with event: NSEvent) { window?.isMovable = true }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    // A tab closed under the pointer never gets mouseExited
    if newWindow == nil { window?.isMovable = true }
    super.viewWillMove(toWindow: newWindow)
  }

  override nonisolated func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Traffic Light Positioner

/// NSViewRepresentable that adjusts traffic light button positions
struct TrafficLightPositioner: NSViewRepresentable {
  let tabBarHeight: CGFloat
  /// While the native tab bar is visible AppKit positions the traffic lights itself
  let isTabBarVisible: Bool

  func makeNSView(context: Context) -> NSView {
    let view = TrafficLightAdjusterView(tabBarHeight: tabBarHeight)
    view.isTabBarVisible = isTabBarVisible
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if let adjuster = nsView as? TrafficLightAdjusterView {
      adjuster.isTabBarVisible = isTabBarVisible
      adjuster.adjustTrafficLights()
    }
  }
}

/// Custom NSView that adjusts traffic light positions when added to window
class TrafficLightAdjusterView: NSView {
  let tabBarHeight: CGFloat
  var isTabBarVisible = false
  private var layoutObserver: NSObjectProtocol?
  private var buttonObservers: [NSObjectProtocol] = []
  private var wasTabBarVisible = false

  init(tabBarHeight: CGFloat) {
    self.tabBarHeight = tabBarHeight
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    if let window = window {
      adjustTrafficLights()

      // The titlebar is laid out after the window is attached and AppKit then puts the buttons
      // back at their default origin, so re-apply once that layout has settled
      DispatchQueue.main.async { [weak self] in
        guard let self, self.window != nil, !self.isTabBarVisible else { return }
        self.window?.standardWindowButton(.closeButton)?.superview?.layoutSubtreeIfNeeded()
        self.adjustTrafficLights()
      }
      observeButtonFrames(in: window)

      // Observe window layout changes to re-adjust buttons
      if layoutObserver == nil {
        layoutObserver = NotificationCenter.default.addObserver(
          forName: NSWindow.didResizeNotification,
          object: window,
          queue: .main
        ) { [weak self] _ in
          Task { @MainActor in
            self?.adjustTrafficLights()
          }
        }
      }
    } else {
      // Remove observers when removed from window
      if let observer = layoutObserver {
        NotificationCenter.default.removeObserver(observer)
        layoutObserver = nil
      }
      buttonObservers.forEach(NotificationCenter.default.removeObserver)
      buttonObservers.removeAll()
    }
  }

  /// Re-adjusts whenever AppKit moves the buttons or resizes their container behind our back
  private func observeButtonFrames(in window: NSWindow) {
    buttonObservers.forEach(NotificationCenter.default.removeObserver)
    buttonObservers.removeAll()

    let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    var watched: [NSView] = types.compactMap { window.standardWindowButton($0) }
    if let container = watched.first?.superview { watched.append(container) }

    for view in watched {
      view.postsFrameChangedNotifications = true
      buttonObservers.append(
        NotificationCenter.default.addObserver(
          forName: NSView.frameDidChangeNotification, object: view, queue: .main
        ) { [weak self] _ in
          Task { @MainActor in self?.adjustTrafficLights() }
        })
    }
  }

  func adjustTrafficLights() {
    guard let window = window,
      let closeButton = window.standardWindowButton(.closeButton),
      let superview = closeButton.superview
    else { return }

    let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    // AppKit lays the buttons out itself while the native tab bar is visible
    if isTabBarVisible {
      wasTabBarVisible = true
      return
    }

    // The tab bar just hid: buttons still sit at the tabbed origin, so make AppKit lay them out
    // again before re-applying the custom position from the fresh layout
    if wasTabBarVisible {
      wasTabBarVisible = false
      superview.needsLayout = true
      superview.layoutSubtreeIfNeeded()
    }

    // Traffic light buttons are 12pt tall
    let buttonHeight: CGFloat = 12

    // Fine-tune vertical offset (negative = move down in screen coords)
    let verticalAdjustment: CGFloat = -1.5

    // Horizontal padding from left edge of window
    let horizontalPadding: CGFloat = 13

    // The superview contains all three buttons in a container
    // We need to center this container vertically in the tab bar area
    // In macOS coordinates, Y=0 is at the bottom of the superview

    // Calculate where the center of buttons should be (from top of window content)
    // tabBarHeight / 2 = center of tab bar from top
    let centerFromTop = tabBarHeight / 2

    // In the titlebar container, we want buttons centered
    // The container's coordinate system has Y increasing upward
    // So we need to position relative to the container's height
    let containerHeight = superview.bounds.height
    let newY = containerHeight - centerFromTop - (buttonHeight / 2) + verticalAdjustment

    // Adjust each button's position
    for (index, buttonType) in buttons.enumerated() {
      guard let button = window.standardWindowButton(buttonType) else { continue }
      var frame = button.frame

      // Adjust Y position
      frame.origin.y = newY

      // Adjust X position: add left padding, buttons are 12pt wide with 8pt spacing
      frame.origin.x = horizontalPadding + CGFloat(index) * (frame.width + 8)

      // Only move when AppKit put it elsewhere, so the frame observers cannot loop
      guard
        abs(button.frame.origin.x - frame.origin.x) > 0.01
          || abs(button.frame.origin.y - frame.origin.y) > 0.01
      else { continue }
      button.setFrameOrigin(frame.origin)
    }
  }
}

// MARK: - Document Window Configurator

extension EnvironmentValues {
  /// True while the native macOS tab bar is shown below the titlebar of this window
  @Entry var isNativeTabBarVisible = false
}

/// Window and tab labels for a workspace, VSCode style: "Name (Workspace)" on the native tab and
/// "file.ext - Name (Workspace)" in the titlebar row.
enum WorkspaceWindowTitle {
  static func tab(workspaceName: String) -> String {
    "\(workspaceName) (Workspace)"
  }

  static func window(fileName: String?, workspaceName: String) -> String {
    let workspace = tab(workspaceName: workspaceName)
    guard let fileName, !fileName.isEmpty else { return workspace }
    return "\(fileName) - \(workspace)"
  }
}

/// Joins the window to the shared native tab group and reports whether the native tab bar is visible.
/// While the tab bar is shown the titlebar row shows `windowTitle`, otherwise the title stays hidden.
struct DocumentWindowConfigurator: NSViewRepresentable {
  let tabTitle: String
  var windowTitle: String? = nil
  @Binding var isTabBarVisible: Bool

  func makeNSView(context: Context) -> NSView {
    let view = DocumentWindowConfiguratorView()
    view.tabTitle = tabTitle
    view.windowTitle = windowTitle ?? tabTitle
    view.onTabBarVisibilityChange = { isVisible in
      if isTabBarVisible != isVisible { isTabBarVisible = isVisible }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard let view = nsView as? DocumentWindowConfiguratorView else { return }
    view.tabTitle = tabTitle
    view.windowTitle = windowTitle ?? tabTitle
    view.window?.tab.title = tabTitle
    view.window?.title = view.windowTitle
    view.onTabBarVisibilityChange = { isVisible in
      if isTabBarVisible != isVisible { isTabBarVisible = isVisible }
    }
  }
}

@MainActor
class DocumentWindowConfiguratorView: NSView {
  var tabTitle = ""
  var windowTitle = ""
  var onTabBarVisibilityChange: ((Bool) -> Void)?
  private var lastReported: Bool?
  private var observations: [NSKeyValueObservation] = []
  private var tabBarObservation: NSKeyValueObservation?
  private var notificationObservers: [NSObjectProtocol] = []

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopObserving()
    guard let window else { return }

    window.tabbingIdentifier = .dbloreDocument
    window.tabbingMode = .automatic
    window.tab.title = tabTitle
    window.title = windowTitle

    observations = [
      window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.reportTabBarVisibility() }
      },
      // Changes when a native tab is dragged out or moved to a new window
      window.observe(\.tabGroup, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in
          self?.observeTabBar()
          self?.reportTabBarVisibility()
          LaunchSessionCapture.schedule()
        }
      },
    ]
    observeTabBar()

    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification] {
      notificationObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
          [weak self] _ in
          Task { @MainActor in self?.reportTabBarVisibility() }
        })
    }
    reportTabBarVisibility()
  }

  private func observeTabBar() {
    tabBarObservation = window?.tabGroup?.observe(\.isTabBarVisible, options: [.new]) {
      [weak self] _, _ in
      Task { @MainActor in self?.reportTabBarVisibility() }
    }
  }

  private func reportTabBarVisibility() {
    let isVisible = window?.tabGroup?.isTabBarVisible ?? false
    guard lastReported != isVisible else { return }
    lastReported = isVisible
    window?.titleVisibility = isVisible ? .visible : .hidden
    onTabBarVisibilityChange?(isVisible)
  }

  private func stopObserving() {
    observations.removeAll()
    tabBarObservation = nil
    notificationObservers.forEach(NotificationCenter.default.removeObserver)
    notificationObservers.removeAll()
    lastReported = nil
  }
}

// MARK: - Middle Click Handler

extension View {
  /// Add middle mouse click handler (like Chrome/VSCode tab closing)
  func onMiddleClick(perform action: @escaping () -> Void) -> some View {
    modifier(MiddleClickModifier(action: action))
  }

  /// Block double-click from triggering window zoom (for tabs)
  func blockDoubleClickZoom() -> some View {
    modifier(BlockDoubleClickZoomModifier())
  }
}

/// View modifier to detect middle mouse click (for closing tabs like Chrome/VSCode)
/// Uses an invisible overlay to avoid layout issues with NSHostingView
struct MiddleClickModifier: ViewModifier {
  let action: () -> Void

  func body(content: Content) -> some View {
    content.overlay(
      MiddleClickDetector(action: action)
    )
  }
}

/// NSViewRepresentable to detect middle mouse button click
/// Uses a transparent NSView overlay that doesn't affect layout
struct MiddleClickDetector: NSViewRepresentable {
  let action: () -> Void

  func makeNSView(context: Context) -> MiddleClickNSView {
    let view = MiddleClickNSView()
    view.action = action
    return view
  }

  func updateNSView(_ nsView: MiddleClickNSView, context: Context) {
    nsView.action = action
  }
}

/// Custom NSView that detects middle mouse button clicks
/// Uses local event monitor to capture middle clicks without blocking other events
@MainActor
class MiddleClickNSView: NSView {
  var action: (() -> Void)?
  // nonisolated(unsafe) allows access from deinit
  nonisolated(unsafe) private var monitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil {
      setupMonitor()
    } else {
      removeMonitor()
    }
  }

  private func setupMonitor() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
      guard let self,
        event.buttonNumber == 2,
        let window = self.window,
        event.window == window
      else {
        return event
      }

      // Check if click is within this view's bounds
      let locationInWindow = event.locationInWindow
      let locationInView = self.convert(locationInWindow, from: nil)
      if self.bounds.contains(locationInView) {
        self.action?()
      }
      return event
    }
  }

  private func removeMonitor() {
    if let monitor = monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
  }

  deinit {
    if let monitor = monitor {
      NSEvent.removeMonitor(monitor)
    }
  }

  // Allow all mouse events to pass through - this view is transparent to clicks
  override nonisolated func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

// MARK: - Double Click Blocker

/// View modifier to block double-click from zooming the window
/// Used on tabs to prevent double-click on tab from maximizing window
struct BlockDoubleClickZoomModifier: ViewModifier {
  func body(content: Content) -> some View {
    content.overlay(
      DoubleClickBlocker()
    )
  }
}

/// NSViewRepresentable that blocks double-click from propagating to window
struct DoubleClickBlocker: NSViewRepresentable {
  func makeNSView(context: Context) -> DoubleClickBlockerNSView {
    DoubleClickBlockerNSView()
  }

  func updateNSView(_ nsView: DoubleClickBlockerNSView, context: Context) {}
}

/// Custom NSView that marks its area as "double-click should not zoom"
/// Used as an overlay on tabs to signal to WindowDragView to skip zoom
@MainActor
class DoubleClickBlockerNSView: NSView {
  // Return nil to allow all clicks to pass through
  // This view is just a marker that WindowDragView checks for
  override nonisolated func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

// MARK: - Document Window Sizing

/// How big a document window's content wants it.
enum DocumentWindowMode: Equatable {
  /// Welcome screens: one small size, not resizable.
  case compact
  /// Tabs: resizable from 1000×600.
  case regular
}

/// SwiftUI sizes the window from the content frame set by `documentWindowMode` (windows use
/// `.contentSize` resizability). This moves the frame when the mode changes: compact centers the
/// small size, regular goes back to the window's last regular frame (1200×800 the first time).
/// Tabs share one frame, so a window in a tab group, or in full screen, is never resized.
@MainActor
enum DocumentWindowSizing {
  /// Content size below the title bar of a compact window.
  static let compactSize = NSSize(width: 820, height: 540)
  /// 1000 wide: the structure editor panel (80% of the window) then keeps the 800 its columns
  /// table needs
  static let regularMinSize = NSSize(width: 1000, height: 600)
  static let regularDefaultSize = NSSize(width: 1200, height: 800)

  /// Mode last applied to each window (true for compact).
  private static let modes = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()
  /// Last regular frame of each window, restored when it leaves compact mode.
  private static let regularFrames = NSMapTable<NSWindow, NSValue>.weakToStrongObjects()
  private static var frameObservers: [NSObjectProtocol] = []

  /// `onSettled` runs once the window has animated to the mode's size, so the content can apply
  /// the mode's limits: applying them first would let SwiftUI snap the window without animation.
  static func apply(
    _ mode: DocumentWindowMode, isTabbed: Bool, to window: NSWindow,
    onSettled: @escaping () -> Void = {}
  ) {
    observeFramesOnce()
    let wasCompact = modes.object(forKey: window)?.boolValue
    modes.setObject(NSNumber(value: mode == .compact), forKey: window)
    guard isLone(window, isTabbed: isTabbed) else {
      unlock(window)
      onSettled()
      return
    }
    switch mode {
    case .compact:
      // Same limits SwiftUI derives from the content frame, set here too: SwiftUI does not
      // always refresh them after a programmatic resize
      let size = withTitleBar(compactSize, of: window)
      window.contentMinSize = size
      setFullScreenAndZoom(enabled: false, on: window)
      setFrame(centered(size, on: window.frame), of: window) {
        window.contentMaxSize = size
        onSettled()
      }
    case .regular:
      window.contentMaxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      setFullScreenAndZoom(enabled: true, on: window)
      var target = window.frame
      if wasCompact == true {
        target =
          regularFrames.object(forKey: window)?.rectValue
          ?? centered(regularDefaultSize, on: window.frame)
      } else if isSmallerThanRegular(window) {
        target = centered(regularDefaultSize, on: window.frame)
      }
      setFrame(target, of: window) {
        unlock(window)
        onSettled()
      }
    }
  }

  /// Frame of a new compact window opened over `frame` (the closed or key window's frame).
  static func compactFrame(centeredOn frame: NSRect) -> NSRect {
    centered(compactSize, on: frame)
  }

  private static func unlock(_ window: NSWindow) {
    window.contentMinSize = withTitleBar(regularMinSize, of: window)
    window.contentMaxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    setFullScreenAndZoom(enabled: true, on: window)
  }

  /// The content frame sits below the title bar, so the window is that much taller.
  private static func withTitleBar(_ size: NSSize, of window: NSWindow) -> NSSize {
    NSSize(
      width: size.width,
      height: size.height + max(0, window.frame.height - window.contentLayoutRect.height))
  }

  private static func isLone(_ window: NSWindow, isTabbed: Bool) -> Bool {
    !isTabbed && (window.tabbedWindows?.count ?? 1) <= 1
      && !window.styleMask.contains(.fullScreen)
  }

  private static func isSmallerThanRegular(_ window: NSWindow) -> Bool {
    window.frame.width < regularMinSize.width || window.frame.height < regularMinSize.height
  }

  /// Remembers a regular window's frame on every move and resize, before a switch to compact
  /// shrinks it.
  private static func observeFramesOnce() {
    guard frameObservers.isEmpty else { return }
    for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
      frameObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          notification in
          guard let window = notification.object as? NSWindow else { return }
          MainActor.assumeIsolated {
            guard modes.object(forKey: window)?.boolValue == false,
              isLone(window, isTabbed: false), !isSmallerThanRegular(window)
            else { return }
            regularFrames.setObject(NSValue(rect: window.frame), forKey: window)
          }
        })
    }
  }

  private static func setFullScreenAndZoom(enabled: Bool, on window: NSWindow) {
    if enabled {
      window.collectionBehavior.remove(.fullScreenNone)
      window.collectionBehavior.insert(.fullScreenPrimary)
    } else {
      window.collectionBehavior.remove(.fullScreenPrimary)
      window.collectionBehavior.insert(.fullScreenNone)
    }
    window.standardWindowButton(.zoomButton)?.isEnabled = enabled
  }

  private static func setFrame(
    _ frame: NSRect, of window: NSWindow, completion: @escaping @MainActor () -> Void = {}
  ) {
    let frame = onScreen(frame, of: window)
    guard frame != window.frame, window.isVisible, !SidebarAnimation.reduceMotion else {
      window.setFrame(frame, display: true)
      completion()
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      window.animator().setFrame(frame, display: true)
    } completionHandler: {
      MainActor.assumeIsolated { completion() }
    }
  }

  private static func centered(_ size: NSSize, on frame: NSRect) -> NSRect {
    NSRect(
      x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
      width: size.width, height: size.height)
  }

  /// Moves `frame` inside the visible frame of the window's screen.
  private static func onScreen(_ frame: NSRect, of window: NSWindow) -> NSRect {
    guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return frame }
    var frame = frame
    frame.size.width = min(frame.width, visible.width)
    frame.size.height = min(frame.height, visible.height)
    frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
    frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
    return frame
  }
}

extension View {
  /// Sizes the hosting document window for `mode`. A compact window in a tab group stays
  /// resizable: tabs share the group's frame.
  func documentWindowMode(_ mode: DocumentWindowMode, isTabbed: Bool) -> some View {
    modifier(DocumentWindowModeModifier(mode: mode, isTabbed: isTabbed))
  }
}

private struct DocumentWindowModeModifier: ViewModifier {
  let mode: DocumentWindowMode
  let isTabbed: Bool

  /// The mode whose size the window has animated to (see `onSettled`). Until then the limits
  /// let the window pass between both sizes, so SwiftUI does not snap it.
  @State private var settledMode: DocumentWindowMode?

  func body(content: Content) -> some View {
    let compact = DocumentWindowSizing.compactSize
    let regular = DocumentWindowSizing.regularMinSize
    let locked = mode == .compact && !isTabbed
    let minSize = locked || (settledMode != .regular && !isTabbed) ? compact : regular
    let maxSize = locked && settledMode == .compact ? compact : nil
    content
      // Measured below the title bar: the window is that much taller (`withTitleBar`)
      .frame(
        minWidth: minSize.width, maxWidth: maxSize?.width ?? .infinity,
        minHeight: minSize.height, maxHeight: maxSize?.height ?? .infinity
      )
      .background(
        DocumentWindowModeApplier(mode: mode, isTabbed: isTabbed) { settledMode = $0 }
      )
  }
}

private struct DocumentWindowModeApplier: NSViewRepresentable {
  let mode: DocumentWindowMode
  let isTabbed: Bool
  let onSettled: (DocumentWindowMode) -> Void

  func makeNSView(context: Context) -> ApplierView {
    let view = ApplierView()
    view.onSettled = onSettled
    view.update(mode: mode, isTabbed: isTabbed)
    return view
  }

  func updateNSView(_ nsView: ApplierView, context: Context) {
    nsView.onSettled = onSettled
    nsView.update(mode: mode, isTabbed: isTabbed)
  }

  final class ApplierView: NSView {
    var onSettled: (DocumentWindowMode) -> Void = { _ in }
    private var mode: DocumentWindowMode = .regular
    private var isTabbed = false

    func update(mode: DocumentWindowMode, isTabbed: Bool) {
      guard mode != self.mode || isTabbed != self.isTabbed else { return }
      self.mode = mode
      self.isTabbed = isTabbed
      scheduleApply()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      scheduleApply()
    }

    /// Next turn, outside the SwiftUI update. Session restore places its windows itself, so
    /// the mode waits until it is done.
    private func scheduleApply() {
      guard window != nil else { return }
      let delay: TimeInterval = LaunchRestorer.isRestoring ? 0.5 : 0
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, let window = self.window else { return }
        if LaunchRestorer.isRestoring {
          self.scheduleApply()
        } else {
          let mode = self.mode
          DocumentWindowSizing.apply(mode, isTabbed: self.isTabbed, to: window) {
            [weak self] in
            // A later mode switch wins over an animation that ends after it
            guard let self, self.mode == mode else { return }
            self.onSettled(mode)
          }
        }
      }
    }
  }
}
