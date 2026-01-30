//
//  TabBarView.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

/// Tab bar that sits in the titlebar area with traffic light buttons
/// Active tab is seamless with content area below
struct TitleBarTabsView: View {
  @Bindable var tabManager: TabStateManager

  /// Whether the left sidebar is visible (affects traffic light padding)
  var hasLeftSidebar: Bool = false

  /// Whether can navigate to previous/next tab
  private var canGoToPreviousTab: Bool {
    guard let activeId = tabManager.activeTabId,
      let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == activeId })
    else { return false }
    return currentIndex > 0
  }

  private var canGoToNextTab: Bool {
    guard let activeId = tabManager.activeTabId,
      let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == activeId })
    else { return false }
    return currentIndex < tabManager.tabs.count - 1
  }

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      // Space for traffic light buttons + sidebar toggle button (when sidebar is hidden)
      // The sidebar toggle button is rendered in TabContainerView at fixed position
      if !hasLeftSidebar {
        Color.clear
          .frame(width: ComponentSize.trafficLightAndToggleWidth)
      }

      // Fixed navigation arrows
      HStack(spacing: 2) {
        TabNavigationArrowButton(
          direction: .left,
          isEnabled: canGoToPreviousTab,
          action: goToPreviousTab
        )
        TabNavigationArrowButton(
          direction: .right,
          isEnabled: canGoToNextTab,
          action: goToNextTab
        )
      }
      .padding(.horizontal, Spacing.sm)

      // Scrollable tabs area with Chrome-like drag reordering
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          DraggableTabsContainer(tabManager: tabManager)
        }
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .onChange(of: tabManager.activeTabId) { _, newTabId in
          if let newTabId {
            withAnimation(.easeInOut(duration: 0.2)) {
              proxy.scrollTo(newTabId, anchor: .center)
            }
          }
        }
      }

      // New tab button
      Menu {
        Button {
          tabManager.newNotebook()
        } label: {
          Label("New Notebook", systemImage: "doc.text")
        }

        Button {
          tabManager.newSQLFile()
        } label: {
          Label("New SQL File", systemImage: "doc")
        }

        Divider()

        Button {
          Task {
            await tabManager.openNotebookWithPanel()
          }
        } label: {
          Label("Open Notebook...", systemImage: "folder")
        }

        Button {
          Task {
            await tabManager.openSQLFileWithPanel()
          }
        } label: {
          Label("Open SQL File...", systemImage: "folder")
        }
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.foregroundMuted)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .blockDoubleClickZoom()
      .padding(.horizontal, Spacing.md)
      .help("New tab")
    }
    .frame(height: ComponentSize.tabBarHeight)
    .frame(maxWidth: .infinity)
    .background(Color.cardBackground)
    .background(WindowDragArea())
  }

  /// Navigate to previous tab
  private func goToPreviousTab() {
    guard let activeId = tabManager.activeTabId,
      let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == activeId }),
      currentIndex > 0
    else { return }

    let previousTab = tabManager.tabs[currentIndex - 1]
    tabManager.selectTab(id: previousTab.id)
  }

  /// Navigate to next tab
  private func goToNextTab() {
    guard let activeId = tabManager.activeTabId,
      let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == activeId }),
      currentIndex < tabManager.tabs.count - 1
    else { return }

    let nextTab = tabManager.tabs[currentIndex + 1]
    tabManager.selectTab(id: nextTab.id)
  }
}

/// Direction for tab navigation arrows
enum TabNavigationDirection {
  case left, right
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

/// Fixed arrow button for navigating between tabs
struct TabNavigationArrowButton: View {
  let direction: TabNavigationDirection
  let isEnabled: Bool
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(isEnabled ? .foregroundMuted : .foregroundMuted.opacity(0.3))
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .blockDoubleClickZoom()
    .onHover { isHovering = $0 }
    .help(direction == .left ? "Previous tab" : "Next tab")
  }
}

/// Tab item specifically for titlebar - active tab has no bottom border and covers the divider line
struct TitleBarTabItem: View {
  let tab: TabItem
  let isActive: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  @State private var isHovering = false

  var body: some View {
    // Main tab content with shape and border
    HStack(spacing: Spacing.xs) {
      // Document type icon
      Image(systemName: tab.documentType.icon)
        .font(.system(size: 11))
        .foregroundColor(isActive ? .foreground : .foregroundMuted)

      // Title
      Text(tab.title)
        .font(.system(size: 12))
        .lineLimit(1)
        .foregroundColor(isActive ? .foreground : .foregroundMuted)

      // Dirty indicator dot (separate from close button)
      if tab.isDirty {
        Circle()
          .fill(Color.foregroundMuted)
          .frame(width: 6, height: 6)
      }

      // Close button (always X)
      closeButton
    }
    //    .frame(height: 42)
    .background(backgroundColor)
    .clipShape(tabClipShape)
    .overlay(tabBorderOverlay)
    .contentShape(Rectangle())
    .onTapGesture { onSelect() }
    .onMiddleClick { onClose() }
    .onHover { isHovering = $0 }
  }

  /// Clip shape for the tab background
  private var tabClipShape: some Shape {
    if isActive {
      AnyShape(TabTopRoundedShape(radius: CornerRadius.sm))
    } else {
      AnyShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
    }
  }

  /// Border overlay - active tab only has top and side borders (no bottom)
  @ViewBuilder
  private var tabBorderOverlay: some View {
    if isActive {
      TabTopRoundedBorder(radius: CornerRadius.md)
        .stroke(Color.border, lineWidth: 1)
    } else {
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .stroke(Color.clear, lineWidth: 1)
    }
  }

  private var backgroundColor: Color {
    if isActive {
      return Color.appBackground
    } else if isHovering {
      return Color.cellBackgroundHover.opacity(0.5)
    } else {
      return Color.clear
    }
  }

  @ViewBuilder
  private var closeButton: some View {
    if isHovering || isActive {
      Button {
        onClose()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .medium))
          .foregroundColor(.foregroundMuted)
          .frame(width: 14, height: 14)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Close tab")
    } else {
      Color.clear
        .frame(width: 14, height: 14)
    }
  }
}

/// Custom shape with rounded top corners and flat bottom (for seamless tab)
struct TabTopRoundedShape: Shape {
  let radius: CGFloat

  func path(in rect: CGRect) -> Path {
    var path = Path()

    // Start from bottom-left
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))

    // Line up to top-left corner start
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))

    // Top-left corner
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + radius, y: rect.minY),
      control: CGPoint(x: rect.minX, y: rect.minY)
    )

    // Line to top-right corner start
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))

    // Top-right corner
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY + radius),
      control: CGPoint(x: rect.maxX, y: rect.minY)
    )

    // Line down to bottom-right
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

    // Flat bottom (no corner rounding)
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))

    path.closeSubpath()
    return path
  }
}

/// Type-erased shape wrapper for conditional shapes
struct AnyShape: Shape, @unchecked Sendable {
  private let pathBuilder: @Sendable (CGRect) -> Path

  init<S: Shape>(_ shape: S) {
    let shapeCopy = shape
    pathBuilder = { rect in
      shapeCopy.path(in: rect)
    }
  }

  func path(in rect: CGRect) -> Path {
    pathBuilder(rect)
  }
}

/// Border shape with rounded top corners and NO bottom edge (U-shape inverted)
struct TabTopRoundedBorder: Shape {
  let radius: CGFloat

  func path(in rect: CGRect) -> Path {
    var path = Path()

    // Start from bottom-left, go up
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))

    // Line up to top-left corner start
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))

    // Top-left corner
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + radius, y: rect.minY),
      control: CGPoint(x: rect.minX, y: rect.minY)
    )

    // Line across top to top-right corner start
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))

    // Top-right corner
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY + radius),
      control: CGPoint(x: rect.maxX, y: rect.minY)
    )

    // Line down to bottom-right (no bottom line - open at bottom)
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

    // Don't close the path - leave bottom open
    return path
  }
}

/// Invisible view that allows window dragging (like native titlebar)
struct WindowDragArea: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = WindowDragView()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Custom NSView that enables window dragging and double-click to zoom
@MainActor
class WindowDragView: NSView {
  override nonisolated var mouseDownCanMoveWindow: Bool { true }

  // nonisolated(unsafe) allows access from deinit
  nonisolated(unsafe) private var doubleClickMonitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil {
      setupDoubleClickMonitor()
    } else {
      removeDoubleClickMonitor()
    }
  }

  private func setupDoubleClickMonitor() {
    guard doubleClickMonitor == nil else { return }
    doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) {
      [weak self] event in
      guard let self,
        event.clickCount == 2,
        let window = self.window,
        event.window == window
      else {
        return event
      }

      // Check if click is within the tab bar area (this view's window)
      // and not on interactive elements (tabs, buttons)
      let locationInWindow = event.locationInWindow
      let locationInView = self.convert(locationInWindow, from: nil)

      // Only zoom if click is within our bounds
      if self.bounds.contains(locationInView) {
        // Check if click is on a tab (marked by DoubleClickBlockerNSView)
        // Walk up the view hierarchy from the hit view to check for blocker
        if let contentView = window.contentView {
          if self.isClickOnBlockedArea(point: locationInWindow, in: contentView) {
            return event
          }
        }
        window.zoom(nil)
      }
      return event
    }
  }

  /// Check if the point is within any DoubleClickBlockerNSView
  private func isClickOnBlockedArea(point: NSPoint, in view: NSView) -> Bool {
    // Recursively check all subviews
    for subview in view.subviews {
      let pointInSubview = subview.convert(point, from: nil)
      if subview.bounds.contains(pointInSubview) {
        if subview is DoubleClickBlockerNSView {
          return true
        }
        if isClickOnBlockedArea(point: point, in: subview) {
          return true
        }
      }
    }
    return false
  }

  private func removeDoubleClickMonitor() {
    if let monitor = doubleClickMonitor {
      NSEvent.removeMonitor(monitor)
      doubleClickMonitor = nil
    }
  }

  deinit {
    if let monitor = doubleClickMonitor {
      NSEvent.removeMonitor(monitor)
    }
  }
}

/// Preview helper: Simulated traffic light buttons
struct TrafficLightButtons: View {
  var body: some View {
    HStack(spacing: 8) {
      Circle().fill(Color.red).frame(width: 12, height: 12)
      Circle().fill(Color.yellow).frame(width: 12, height: 12)
      Circle().fill(Color.green).frame(width: 12, height: 12)
    }
    .padding(.leading, 13)
    .padding(.top, 3)
  }
}

#Preview("TitleBar Tabs with Traffic Lights") {
  let manager = TabStateManager()

  ZStack(alignment: .topLeading) {
    VStack(spacing: 0) {
      TitleBarTabsView(tabManager: manager)

      // Content area
      Color.appBackground
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Simulated traffic light buttons (for preview only)
    TrafficLightButtons()
  }
  .frame(width: 800, height: 400)
  .task {
    manager.newNotebook()
    manager.newSQLFile()
    manager.newNotebook()
    if let first = manager.tabs.first {
      manager.markDirty(tabId: first.id)
    }
  }
}

#Preview("TitleBar Tabs - Empty") {
  let manager = TabStateManager()

  ZStack(alignment: .topLeading) {
    VStack(spacing: 0) {
      TitleBarTabsView(tabManager: manager)

      // Content area
      Color.appBackground
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    TrafficLightButtons()
  }
  .frame(width: 800, height: 400)
}
