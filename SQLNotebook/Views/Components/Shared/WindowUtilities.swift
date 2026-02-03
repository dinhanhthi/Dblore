//
//  WindowUtilities.swift
//  SQLNotebook
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

// MARK: - Traffic Light Positioner

/// NSViewRepresentable that adjusts traffic light button positions
struct TrafficLightPositioner: NSViewRepresentable {
  let tabBarHeight: CGFloat

  func makeNSView(context: Context) -> NSView {
    let view = TrafficLightAdjusterView(tabBarHeight: tabBarHeight)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if let adjuster = nsView as? TrafficLightAdjusterView {
      adjuster.adjustTrafficLights()
    }
  }
}

/// Custom NSView that adjusts traffic light positions when added to window
class TrafficLightAdjusterView: NSView {
  let tabBarHeight: CGFloat
  private var layoutObserver: NSObjectProtocol?

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
      // Remove observer when removed from window
      if let observer = layoutObserver {
        NotificationCenter.default.removeObserver(observer)
        layoutObserver = nil
      }
    }
  }

  func adjustTrafficLights() {
    guard let window = window,
      let closeButton = window.standardWindowButton(.closeButton),
      let superview = closeButton.superview
    else { return }

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
    let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    for (index, buttonType) in buttons.enumerated() {
      guard let button = window.standardWindowButton(buttonType) else { continue }
      var frame = button.frame

      // Adjust Y position
      frame.origin.y = newY

      // Adjust X position: add left padding, buttons are 12pt wide with 8pt spacing
      frame.origin.x = horizontalPadding + CGFloat(index) * (frame.width + 8)

      button.setFrameOrigin(frame.origin)
    }
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
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Icon and Title
      HStack(spacing: Spacing.sm) {
        Image(systemName: icon)
          .font(.system(size: 28))
          .foregroundColor(accentColor)

        Text(title)
          .font(.title2)
          .fontWeight(.semibold)
          .foregroundColor(.foreground)
      }

      // Description
      Text(description)
        .font(.subheadline)
        .foregroundColor(.foregroundMuted)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)

      Spacer()

      // Buttons
      HStack(spacing: Spacing.md) {
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
    }
    .padding(Spacing.xl)
    .frame(width: 250, height: 180)
    .background(Color.cardBackground)
    .cornerRadius(CornerRadius.xl)
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.xl)
        .stroke(isHovering ? accentColor.opacity(0.5) : Color.border, lineWidth: 1)
    )
    .shadow(color: .black.opacity(isHovering ? 0.1 : 0.05), radius: isHovering ? 8 : 4, y: 2)
    .scaleEffect(isHovering ? 1.02 : 1.0)
    .animation(.easeInOut(duration: 0.15), value: isHovering)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}
