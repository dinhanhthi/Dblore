//
//  WindowUtilities.swift
//  Dblore
//
//  Utilities for window management: drag area, double-click blocking, document windows
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

// MARK: - Document Window Configurator

extension EnvironmentValues {
  /// Height of the native tab bar band below the titlebar row, 0 while it is hidden
  @Entry var nativeTabBarHeight: CGFloat = 0
  /// Width the traffic lights take at the leading edge of the titlebar row, trailing gap included
  @Entry var trafficLightsWidth: CGFloat = ComponentSize.trafficLightWidth
  /// Whether the window is in (or entering) full screen, where it has no titlebar row
  @Entry var isWindowFullScreen = false
}

/// Window and tab labels for a workspace, VSCode style: "Name (Workspace)" on the native tab and
/// "file.ext - Name (Workspace)" as the window title. The titlebar row never draws the title (it
/// hosts the Dblore header), but `window.title` is still set: the Window menu and Mission Control
/// show it.
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

/// Joins the window to the shared native tab group, gives it an empty compact toolbar so the
/// titlebar row is as tall as the Dblore header that fills it, and reports the native tab bar:
/// whether it is visible and the height of its band below the row. The title is never drawn (a
/// visible title would also take the clicks meant for the header); `windowTitle` is still set for
/// the Window menu and Mission Control. Optionally reports the width the traffic lights take and
/// whether the window is in full screen. In full screen the window has no toolbar: AppKit would
/// pin the empty row (and the tab bar) above the content, over the Dblore header.
struct DocumentWindowConfigurator: NSViewRepresentable {
  let tabTitle: String
  var windowTitle: String? = nil
  @Binding var isTabBarVisible: Bool
  var tabBarHeight: Binding<CGFloat>? = nil
  var trafficLightsWidth: Binding<CGFloat>? = nil
  var isFullScreen: Binding<Bool>? = nil

  func makeNSView(context: Context) -> NSView {
    let view = DocumentWindowConfiguratorView()
    view.tabTitle = tabTitle
    view.windowTitle = windowTitle ?? tabTitle
    connect(view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard let view = nsView as? DocumentWindowConfiguratorView else { return }
    view.tabTitle = tabTitle
    view.windowTitle = windowTitle ?? tabTitle
    view.window?.tab.title = tabTitle
    view.window?.title = view.windowTitle
    connect(view)
  }

  /// Each value is written only when it changes: a measured value that drives a frame must not
  /// loop during a live resize.
  private func connect(_ view: DocumentWindowConfiguratorView) {
    view.onTabBarVisibilityChange = { isVisible in
      if isTabBarVisible != isVisible { isTabBarVisible = isVisible }
    }
    view.onTabBarHeightChange = tabBarHeight.map { binding in
      { height in if binding.wrappedValue != height { binding.wrappedValue = height } }
    }
    view.onTrafficLightsWidthChange = trafficLightsWidth.map { binding in
      { width in if binding.wrappedValue != width { binding.wrappedValue = width } }
    }
    view.onFullScreenChange = isFullScreen.map { binding in
      { value in if binding.wrappedValue != value { binding.wrappedValue = value } }
    }
  }
}

@MainActor
class DocumentWindowConfiguratorView: NSView {
  var tabTitle = ""
  var windowTitle = ""
  var onTabBarVisibilityChange: ((Bool) -> Void)?
  var onTabBarHeightChange: ((CGFloat) -> Void)?
  var onTrafficLightsWidthChange: ((CGFloat) -> Void)?
  var onFullScreenChange: ((Bool) -> Void)?
  private var lastReported: Bool?
  private var lastTabBarHeight: CGFloat?
  private var lastTrafficLightsWidth: CGFloat?
  private var lastFullScreen: Bool?
  /// Set from `willEnterFullScreen` until `didEnterFullScreen`, while the style mask may not
  /// contain `.fullScreen` yet
  private var isEnteringFullScreen = false
  private var observations: [NSKeyValueObservation] = []
  private var tabBarObservation: NSKeyValueObservation?
  private var toolbarObservation: NSKeyValueObservation?
  private weak var observedToolbar: NSToolbar?
  private var notificationObservers: [NSObjectProtocol] = []

  /// Gap between the zoom button and the first header control; with the zoom button's maxX at
  /// 72 (macOS 27) the width is 88, `ComponentSize.trafficLightWidth`, the strip's width before
  private static let trafficLightsTrailingGap: CGFloat = 16

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopObserving()
    guard let window else { return }

    window.tabbingIdentifier = .dbloreDocument
    window.tabbingMode = .automatic
    window.tab.title = tabTitle
    window.title = windowTitle
    installToolbar()

    observations = [
      window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.reportTabBar() }
      },
      // Changes when a native tab is dragged out or moved to a new window
      window.observe(\.tabGroup, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in
          self?.installToolbar()
          self?.observeTabBar()
          self?.reportTabBar()
          LaunchSessionCapture.schedule()
        }
      },
      // The window's scene can drop the toolbar when it updates its titlebar style
      window.observe(\.toolbar, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.installToolbar() }
      },
    ]
    observeTabBar()

    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification] {
      notificationObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
          [weak self] _ in
          Task { @MainActor in
            if name == NSWindow.didBecomeKeyNotification { self?.installToolbar() }
            self?.reportTabBar()
          }
        })
    }
    observeFullScreen(of: window)
    observeTrafficLights(in: window)
    reportTabBar()
  }

  /// In full screen, or on the way in
  private var isFullScreen: Bool {
    isEnteringFullScreen || window?.styleMask.contains(.fullScreen) == true
  }

  /// The toolbar goes at `willEnter`, before the transition starts, so the empty row never shows
  /// pinned at the top of the screen; it comes back at `didExit`, once the style mask has lost
  /// `.fullScreen`. Run synchronously on the posting (main) thread: a queued block would run after
  /// the transition has started.
  private func observeFullScreen(of window: NSWindow) {
    for name in [
      NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
    ] {
      notificationObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) {
          [weak self] _ in
          MainActor.assumeIsolated {
            guard let self else { return }
            // After `didEnter` the style mask holds `.fullScreen`
            self.isEnteringFullScreen = name == NSWindow.willEnterFullScreenNotification
            self.installToolbar()
            self.reportTabBar()
          }
        })
    }
  }

  /// An empty compact toolbar turns the titlebar into one row as tall as the Dblore header, with
  /// the native tab bar below it. Re-applied whenever something resets it; every setter is guarded
  /// so the observers cannot loop. In full screen the window has no toolbar, whatever resets it.
  private func installToolbar() {
    guard let window else { return }
    if isFullScreen {
      if window.toolbar != nil { window.toolbar = nil }
      return
    }
    if window.toolbar == nil {
      let toolbar = NSToolbar(identifier: "app.dblore.document")
      toolbar.allowsUserCustomization = false
      toolbar.displayMode = .iconOnly
      window.toolbar = toolbar
    }
    // A hidden toolbar would shrink the row back to a plain titlebar
    if window.toolbar?.isVisible == false { window.toolbar?.isVisible = true }
    if window.toolbarStyle != .unifiedCompact { window.toolbarStyle = .unifiedCompact }
    if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
    if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
    if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
    observeToolbarVisibility()
  }

  private func observeToolbarVisibility() {
    guard let toolbar = window?.toolbar, toolbar !== observedToolbar else { return }
    observedToolbar = toolbar
    toolbarObservation = toolbar.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
      Task { @MainActor in self?.installToolbar() }
    }
  }

  private func observeTabBar() {
    tabBarObservation = window?.tabGroup?.observe(\.isTabBarVisible, options: [.new]) {
      [weak self] _, _ in
      Task { @MainActor in self?.reportTabBar() }
    }
  }

  /// AppKit moves the traffic lights without resizing the window (tab bar shown or hidden)
  private func observeTrafficLights(in window: NSWindow) {
    guard let zoom = window.standardWindowButton(.zoomButton) else { return }
    for view in [zoom, zoom.superview].compactMap({ $0 }) {
      view.postsFrameChangedNotifications = true
      notificationObservers.append(
        NotificationCenter.default.addObserver(
          forName: NSView.frameDidChangeNotification, object: view, queue: .main
        ) { [weak self] _ in
          Task { @MainActor in self?.reportTabBar() }
        })
    }
  }

  private func reportTabBar() {
    guard let window else { return }
    let isVisible = window.tabGroup?.isTabBarVisible ?? false
    if lastReported != isVisible {
      lastReported = isVisible
      onTabBarVisibilityChange?(isVisible)
    }

    let isFullScreen = isFullScreen
    if lastFullScreen != isFullScreen {
      lastFullScreen = isFullScreen
      onFullScreenChange?(isFullScreen)
    }

    // The band below the titlebar row. In full screen the tab bar is pinned above the content,
    // which then needs no room for it.
    let topInset = window.frame.height - window.contentLayoutRect.maxY
    let height = isVisible && !isFullScreen ? max(0, topInset - ComponentSize.tabBarHeight) : 0
    if lastTabBarHeight != height {
      lastTabBarHeight = height
      onTabBarHeightChange?(height)
    }

    let width =
      window.standardWindowButton(.zoomButton).map {
        $0.convert($0.bounds, to: nil).maxX + Self.trafficLightsTrailingGap
      } ?? ComponentSize.trafficLightWidth
    if lastTrafficLightsWidth != width {
      lastTrafficLightsWidth = width
      onTrafficLightsWidthChange?(width)
    }
  }

  private func stopObserving() {
    observations.removeAll()
    tabBarObservation = nil
    toolbarObservation = nil
    observedToolbar = nil
    notificationObservers.forEach(NotificationCenter.default.removeObserver)
    notificationObservers.removeAll()
    lastReported = nil
    lastTabBarHeight = nil
    lastTrafficLightsWidth = nil
    lastFullScreen = nil
    isEnteringFullScreen = false
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
