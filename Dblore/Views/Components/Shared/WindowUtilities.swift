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

// MARK: - Document Type Card

/// Card for each document type in the welcome screen
struct DocumentTypeCard: View {
  let icon: String
  let title: String
  let description: String
  let accentColor: Color
  let onNew: () -> Void
  let onOpen: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: icon)
        .font(.system(size: 20))
        .foregroundColor(accentColor)
        .frame(width: 24)

      // Title and description
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundColor(.foreground)

        Text(description)
          .font(.caption)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.tail)
      }

      Spacer(minLength: Spacing.sm)

      // Buttons
      HStack(spacing: Spacing.sm) {
        Button {
          onNew()
        } label: {
          Label("New", systemImage: "plus")
        }
        .buttonStyle(PrimaryButtonStyle())

        Button {
          onOpen()
        } label: {
          Label("Open", systemImage: "folder")
        }
        .buttonStyle(SecondaryButtonStyle())
      }
      .controlSize(.small)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .frame(width: 460)
    .background(Color.cardBackground)
    .cornerRadius(CornerRadius.lg)
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.lg)
        .stroke(isHovering ? accentColor.opacity(0.5) : Color.border, lineWidth: 1)
    )
    .animation(.easeInOut(duration: 0.15), value: isHovering)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}
