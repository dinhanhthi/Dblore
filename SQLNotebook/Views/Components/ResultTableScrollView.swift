//
//  ResultTableScrollView.swift
//  SQLNotebook
//
//  Extracted from ResultTableView.swift for better maintainability (10.3.1)
//

import SwiftUI

// MARK: - Horizontal Scrollable Content

/// A custom NSScrollView wrapper that:
/// - Always scrolls horizontally (for wide result tables)
/// - Optionally scrolls vertically (controlled by enableVerticalScrolling parameter)
/// - When vertical scrolling disabled: passes ALL vertical scroll events through to parent
/// - Supports shift+scroll for horizontal scrolling with mouse
/// - Syncs horizontal scroll position with header
struct HorizontalScrollableContent<Content: View>: NSViewRepresentable {
  let totalWidth: CGFloat
  @Binding var headerScrollPosition: ScrollPosition
  let enableVerticalScrolling: Bool
  @ViewBuilder let content: () -> Content

  func makeNSView(context: Context) -> ResultTableNSScrollView {
    let scrollView = ResultTableNSScrollView()
    scrollView.enableVerticalScrolling = enableVerticalScrolling
    scrollView.hasVerticalScroller = enableVerticalScrolling
    scrollView.hasHorizontalScroller = true

    // Always use legacy scrollbar style to show scrollbar when content overflows
    // Overlay style auto-hides which makes it hard to discover horizontal scrolling
    scrollView.scrollerStyle = .legacy
    scrollView.autohidesScrollers = false

    scrollView.drawsBackground = false
    scrollView.backgroundColor = .clear

    // Configure vertical scroll elasticity based on mode
    scrollView.verticalScrollElasticity = enableVerticalScrolling ? .automatic : .none
    scrollView.horizontalScrollElasticity = .automatic

    // Create hosting view for SwiftUI content
    let hostingView = NSHostingView(rootView: content())
    scrollView.documentView = hostingView

    // Set up notification for scroll position sync
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.scrollViewDidScroll(_:)),
      name: NSScrollView.didLiveScrollNotification,
      object: scrollView
    )

    return scrollView
  }

  func updateNSView(_ scrollView: ResultTableNSScrollView, context: Context) {
    // Update scrolling mode if changed
    scrollView.enableVerticalScrolling = enableVerticalScrolling
    scrollView.hasVerticalScroller = enableVerticalScrolling
    scrollView.verticalScrollElasticity = enableVerticalScrolling ? .automatic : .none

    // Scrollbar appearance is consistent (legacy style, always visible when overflow)
    scrollView.scrollerStyle = .legacy
    scrollView.autohidesScrollers = false

    // Update content
    if let hostingView = scrollView.documentView as? NSHostingView<Content> {
      hostingView.rootView = content()
      // Let hosting view calculate its intrinsic size
      let fittingSize = hostingView.fittingSize
      hostingView.frame = NSRect(origin: .zero, size: fittingSize)
    }

    // Update coordinator reference
    context.coordinator.headerScrollPosition = $headerScrollPosition
  }

  static func dismantleNSView(_ scrollView: ResultTableNSScrollView, coordinator: Coordinator) {
    NotificationCenter.default.removeObserver(coordinator)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(headerScrollPosition: $headerScrollPosition)
  }

  // Tell SwiftUI the size we need based on content
  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView scrollView: ResultTableNSScrollView,
    context: Context
  ) -> CGSize? {
    // When vertical scrolling is enabled, don't provide custom sizing
    // Let SwiftUI handle the layout based on frame modifiers
    if enableVerticalScrolling {
      return nil
    }

    // Passthrough mode: tell SwiftUI we need full content height
    guard let hostingView = scrollView.documentView as? NSHostingView<Content> else {
      return nil
    }
    let fittingSize = hostingView.fittingSize
    let width = proposal.width ?? fittingSize.width
    return CGSize(width: width, height: fittingSize.height)
  }

  class Coordinator: NSObject {
    var headerScrollPosition: Binding<ScrollPosition>

    init(headerScrollPosition: Binding<ScrollPosition>) {
      self.headerScrollPosition = headerScrollPosition
    }

    @objc func scrollViewDidScroll(_ notification: Notification) {
      guard let scrollView = notification.object as? NSScrollView else { return }
      let xOffset = scrollView.contentView.bounds.origin.x
      headerScrollPosition.wrappedValue.scrollTo(x: xOffset)
    }
  }
}

// MARK: - Result Table NS Scroll View

/// Custom NSScrollView for result tables that:
/// - Handles horizontal scrolling normally (including shift+scroll for mouse)
/// - Conditionally handles vertical scrolling based on enableVerticalScrolling property
/// - When vertical scrolling disabled: passes ALL vertical scroll events to parent scroll view
/// This allows the parent notebook list to scroll when hovering over result tables.
///
/// Based on Apple's responder chain pattern:
/// https://developer.apple.com/documentation/appkit/nsscrollview/1403494-scrollwheel
class ResultTableNSScrollView: NSScrollView {

  var enableVerticalScrolling: Bool = false

  override func scrollWheel(with event: NSEvent) {
    // Detect scroll type
    let isShiftScroll = event.modifierFlags.contains(.shift)
    let deltaX = event.scrollingDeltaX
    let deltaY = event.scrollingDeltaY

    // Shift+scroll: convert vertical to horizontal
    if isShiftScroll && deltaY != 0 && deltaX == 0 {
      // Handle as horizontal scroll
      scrollHorizontally(by: deltaY)
      return  // Consume - don't pass to parent
    }

    // Pure horizontal scroll (trackpad swipe)
    if deltaX != 0 && deltaY == 0 {
      scrollHorizontally(by: deltaX)
      return  // Consume - don't pass to parent
    }

    // Diagonal scroll: handle horizontal component, decide vertical based on mode
    if deltaX != 0 && deltaY != 0 {
      scrollHorizontally(by: deltaX)
      if enableVerticalScrolling {
        // Handle vertical scrolling internally - scroll vertically by deltaY
        scrollVertically(by: deltaY)
      } else {
        // Forward to parent for vertical scrolling
        nextResponder?.scrollWheel(with: event)
      }
      return
    }

    // Pure vertical scroll: handle based on mode
    if enableVerticalScrolling {
      // Handle vertical scrolling internally
      scrollVertically(by: deltaY)
    } else {
      // Pass entirely to parent
      // This is the key - we forward the event up the responder chain
      // so the parent notebook List can scroll
      nextResponder?.scrollWheel(with: event)
    }
  }

  /// Manually scroll vertically by the given delta
  private func scrollVertically(by delta: CGFloat) {
    guard let docView = documentView else { return }

    var origin = contentView.bounds.origin
    origin.y -= delta

    // Clamp to valid scroll bounds
    let maxY = max(0, docView.frame.height - contentView.frame.height)
    origin.y = max(0, min(origin.y, maxY))

    contentView.scroll(to: origin)
    reflectScrolledClipView(contentView)
  }

  /// Manually scroll horizontally by the given delta
  private func scrollHorizontally(by delta: CGFloat) {
    guard let docView = documentView else { return }

    var origin = contentView.bounds.origin
    origin.x -= delta

    // Clamp to valid scroll bounds
    let maxX = max(0, docView.frame.width - contentView.frame.width)
    origin.x = max(0, min(origin.x, maxX))

    contentView.scroll(to: origin)
    reflectScrolledClipView(contentView)

    // Manually post notification to sync header
    // reflectScrolledClipView doesn't trigger didLiveScrollNotification
    NotificationCenter.default.post(
      name: NSScrollView.didLiveScrollNotification,
      object: self
    )
  }
}
