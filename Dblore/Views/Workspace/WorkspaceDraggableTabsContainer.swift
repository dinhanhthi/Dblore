//
//  WorkspaceDraggableTabsContainer.swift
//  Dblore
//
//  Chrome-like tab dragging with real-time reordering animation for workspaces
//

import SwiftUI

/// Pure helpers for dragging a tab out of its window into a new one
enum TabDragOut {
  /// True when the tab can move and the mouse (screen coordinates) is outside the window frame; edges count as inside
  static func shouldDetach(mouseLocation: NSPoint, windowFrame: NSRect, canMove: Bool) -> Bool {
    guard canMove else { return false }
    let isInside =
      mouseLocation.x >= windowFrame.minX && mouseLocation.x <= windowFrame.maxX
      && mouseLocation.y >= windowFrame.minY && mouseLocation.y <= windowFrame.maxY
    return !isInside
  }

  /// Origin for the new window so the drop point sits over its tab-bar area
  static func detachedWindowOrigin(dropPoint: NSPoint, windowSize: NSSize) -> NSPoint {
    NSPoint(
      x: dropPoint.x - ComponentSize.trafficLightAndToggleWidth,
      y: dropPoint.y + ComponentSize.tabBarHeight / 2 - windowSize.height)
  }

  /// Shift the origin so the window stays inside the visible frame; a larger window pins to its top-left
  static func clampedOrigin(_ origin: NSPoint, windowSize: NSSize, visibleFrame: NSRect) -> NSPoint {
    let x = max(visibleFrame.minX, min(origin.x, visibleFrame.maxX - windowSize.width))
    let y = min(visibleFrame.maxY - windowSize.height, max(origin.y, visibleFrame.minY))
    return NSPoint(x: x, y: y)
  }
}

/// Container that handles Chrome-like tab dragging with real-time reorder animation for workspaces
struct WorkspaceDraggableTabsContainer: View {
  @Bindable var workspaceManager: WorkspaceManager

  /// Currently dragging tab ID
  @State private var draggingTabId: UUID?

  /// Current drag offset for the dragging tab
  @State private var dragOffset: CGFloat = 0

  /// Stored tab widths for position calculation
  @State private var tabWidths: [UUID: CGFloat] = [:]

  /// Stored tab positions (leading edge X) relative to container
  @State private var tabPositions: [UUID: CGFloat] = [:]

  /// The target index where the dragged tab would be inserted
  @State private var targetIndex: Int?

  /// Original index of the dragging tab
  @State private var originalIndex: Int?

  /// True while the pointer is outside the window and releasing would open the tab in a new window
  @State private var isDetaching = false

  /// Tab under the current mouse press, so selection fires once per press
  @State private var pressedTabId: UUID?

  /// Namespace for the active tab capsule that slides between tabs
  @Namespace private var tabCapsuleNamespace

  private let tabSpacing: CGFloat = Spacing.xxs
  private let dragThreshold: CGFloat = 5

  var body: some View {
    tabsRow
      .frame(maxHeight: .infinity, alignment: .center)
      .animation(.spring(response: 0.35, dampingFraction: 0.8), value: workspaceManager.activeTabId)
  }

  private var tabsRow: some View {
    HStack(alignment: .center, spacing: tabSpacing) {
      ForEach(Array(workspaceManager.tabs.enumerated()), id: \.element.id) { index, tab in
        let isDragging = tab.id == draggingTabId
        let isActive = tab.id == workspaceManager.activeTabId

        WorkspaceDraggableTabItem(
          tab: tab,
          isActive: isActive,
          isDragging: isDragging,
          capsuleNamespace: tabCapsuleNamespace,
          canClose: workspaceManager.canClose(tabId: tab.id),
          hasTabsToRight: !workspaceManager.tabsToCloseRight(of: tab.id).isEmpty,
          canRevealFile: workspaceManager.canRevealFile(tabId: tab.id),
          canMoveToNewWindow: workspaceManager.canMoveToNewWindow(tabId: tab.id),
          onClose: { workspaceManager.requestCloseTab(id: tab.id) },
          onTogglePin: { workspaceManager.setPinned(!tab.isPinned, id: tab.id) },
          onCloseToRight: { workspaceManager.closeTabsToTheRight(of: tab.id) },
          onMoveToNewWindow: { Task { await workspaceManager.moveTabToNewWindow(id: tab.id) } },
          onRevealFile: { workspaceManager.revealFile(tabId: tab.id) }
        )
        .id(tab.id)
        .background(
          GeometryReader { geo in
            Color.clear
              .onAppear {
                tabWidths[tab.id] = geo.size.width
              }
              .onChange(of: geo.size.width) { _, newWidth in
                tabWidths[tab.id] = newWidth
              }
              .preference(
                key: WorkspaceTabPositionPreferenceKey.self,
                value: [tab.id: geo.frame(in: .named("workspaceTabContainer")).minX]
              )
          }
        )
        .opacity(isDragging && isDetaching ? 0.5 : 1)
        .offset(x: calculateOffset(for: tab, at: index))
        .animation(draggingTabId != nil ? .easeInOut(duration: 0.2) : nil, value: targetIndex)
        .zIndex(isDragging ? 100 : (isActive ? 50 : 0))
        .gesture(
          // Zero distance so the tab activates on mouse-down (like Chrome); a tap gesture
          // waits for mouse-up. Reordering starts only past `dragThreshold`.
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              if pressedTabId == nil {
                pressedTabId = tab.id
                workspaceManager.selectTab(id: tab.id)
                if NSApp.currentEvent?.clickCount == 2 { workspaceManager.pinTab(id: tab.id) }
              }
              guard draggingTabId != nil || abs(value.translation.width) >= dragThreshold
              else { return }
              isDetaching = shouldDetach(tab: tab)
              handleDragChanged(tab: tab, index: index, translation: value.translation.width)
            }
            .onEnded { _ in
              pressedTabId = nil
              if draggingTabId != nil {
                if isDetaching {
                  handleDetachEnded(tab: tab)
                } else {
                  handleDragEnded()
                }
              }
              isDetaching = false
            }
        )
      }
    }
    .coordinateSpace(name: "workspaceTabContainer")
    .onPreferenceChange(WorkspaceTabPositionPreferenceKey.self) { positions in
      tabPositions = positions
    }
    .onChange(of: draggingTabId) { _, newValue in
      if newValue == nil { isDetaching = false }
    }
  }

  /// Calculate visual offset for a tab based on drag state
  private func calculateOffset(for tab: TabItem, at index: Int) -> CGFloat {
    // If this is the dragging tab, return the drag offset
    if tab.id == draggingTabId {
      return dragOffset
    }

    // If we're dragging and this tab needs to shift
    guard let draggingId = draggingTabId,
      let originalIdx = originalIndex,
      let targetIdx = targetIndex,
      let draggingWidth = tabWidths[draggingId]
    else {
      return 0
    }

    let shiftAmount = draggingWidth + tabSpacing

    // Determine if this tab should shift
    if originalIdx < targetIdx {
      // Dragging right: tabs between original and target shift left
      if index > originalIdx && index <= targetIdx {
        return -shiftAmount
      }
    } else if originalIdx > targetIdx {
      // Dragging left: tabs between target and original shift right
      if index >= targetIdx && index < originalIdx {
        return shiftAmount
      }
    }

    return 0
  }

  /// Handle drag gesture changes
  private func handleDragChanged(tab: TabItem, index: Int, translation: CGFloat) {
    if draggingTabId == nil {
      // Start dragging
      draggingTabId = tab.id
      originalIndex = index
      targetIndex = index
    }

    dragOffset = translation

    // Calculate target index based on current position
    // While detaching, freeze reordering so the other tabs return to place
    let newTargetIndex =
      isDetaching
      ? index
      : calculateTargetIndex(
        originalIndex: index,
        dragOffset: translation
      )

    if newTargetIndex != targetIndex {
      withAnimation(.easeInOut(duration: 0.2)) {
        targetIndex = newTargetIndex
      }
    }
  }

  /// Calculate where the tab would be inserted based on drag offset
  private func calculateTargetIndex(originalIndex: Int, dragOffset: CGFloat) -> Int {
    guard let draggingId = draggingTabId,
      let draggingWidth = tabWidths[draggingId]
    else {
      return originalIndex
    }

    let tabs = workspaceManager.tabs

    // Calculate how far we've moved in terms of tab positions
    var newIndex = originalIndex

    if dragOffset > 0 {
      // Dragging right
      var accumulatedWidth: CGFloat = 0
      for i in (originalIndex + 1)..<tabs.count {
        let tabId = tabs[i].id
        let tabWidth = tabWidths[tabId] ?? draggingWidth
        accumulatedWidth += tabWidth + tabSpacing

        // If we've moved past half of this tab, we should be after it
        if dragOffset > accumulatedWidth - (tabWidth / 2) {
          newIndex = i
        } else {
          break
        }
      }
    } else if dragOffset < 0 {
      // Dragging left
      var accumulatedWidth: CGFloat = 0
      for i in stride(from: originalIndex - 1, through: 0, by: -1) {
        let tabId = tabs[i].id
        let tabWidth = tabWidths[tabId] ?? draggingWidth
        accumulatedWidth += tabWidth + tabSpacing

        // If we've moved past half of this tab, we should be before it
        if -dragOffset > accumulatedWidth - (tabWidth / 2) {
          newIndex = i
        } else {
          break
        }
      }
    }

    return workspaceManager.clampedMoveTarget(
      from: originalIndex, to: max(0, min(newIndex, tabs.count - 1)))
  }

  /// Whether the pointer is outside the window that received the drag and the tab can move
  private func shouldDetach(tab: TabItem) -> Bool {
    guard let window = NSApp.currentEvent?.window ?? NSApp.keyWindow else { return false }
    return TabDragOut.shouldDetach(
      mouseLocation: NSEvent.mouseLocation,
      windowFrame: window.frame,
      canMove: workspaceManager.canMoveToNewWindow(tabId: tab.id))
  }

  /// Handle drag end outside the window: reset without animation, then open the tab in a new window
  private func handleDetachEnded(tab: TabItem) {
    draggingTabId = nil
    dragOffset = 0
    targetIndex = nil
    originalIndex = nil

    let dropPoint = NSEvent.mouseLocation
    Task { await workspaceManager.moveTabToNewWindow(id: tab.id, dropPoint: dropPoint) }
  }

  /// Handle drag gesture end
  private func handleDragEnded() {
    guard let originalIdx = originalIndex,
      let targetIdx = targetIndex,
      originalIdx != targetIdx
    else {
      // Reset without moving - animate back to original position
      withAnimation(.easeOut(duration: 0.2)) {
        dragOffset = 0
      }
      // Clear state after animation
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        draggingTabId = nil
        targetIndex = nil
        originalIndex = nil
      }
      return
    }

    // Reset all state IMMEDIATELY (no animation) before moving
    // This prevents SwiftUI from animating the position change
    draggingTabId = nil
    dragOffset = 0
    targetIndex = nil
    originalIndex = nil

    // Perform the actual move - SwiftUI will render new positions directly
    workspaceManager.moveTab(from: originalIdx, to: targetIdx)
  }
}

/// Preference key to collect tab positions for workspace tabs
struct WorkspaceTabPositionPreferenceKey: PreferenceKey {
  static var defaultValue: [UUID: CGFloat] = [:]

  static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
    value.merge(nextValue()) { _, new in new }
  }
}

/// Tab item wrapper for dragging - adds visual feedback during drag (workspace version)
struct WorkspaceDraggableTabItem: View {
  let tab: TabItem
  let isActive: Bool
  let isDragging: Bool
  let capsuleNamespace: Namespace.ID
  let canClose: Bool
  let hasTabsToRight: Bool
  let canRevealFile: Bool
  let canMoveToNewWindow: Bool
  let onClose: () -> Void
  let onTogglePin: () -> Void
  let onCloseToRight: () -> Void
  let onMoveToNewWindow: () -> Void
  let onRevealFile: () -> Void

  @State private var isHovering = false
  @State private var isHoveringClose = false

  var body: some View {
    HStack(spacing: Spacing.xs) {
      // Document type icon
      Image(systemName: tab.documentType.icon)
        .font(.system(size: 11))
        .foregroundColor(isActive ? .foreground : .foregroundMuted)

      // Title
      Text(tab.title)
        .font(.system(size: 12))
        .italic(tab.isPreview)
        .lineLimit(1)
        .foregroundColor(isActive ? .foreground : .foregroundMuted)

      // Close button slot; shows the dirty dot until the slot itself is hovered
      closeButton
    }
    .padding(.horizontal, Spacing.md)
    .frame(height: 28)
    .background {
      if isActive {
        // Neutral capsule for the active tab - slides between tabs; the label stays above it
        Capsule()
          .fill(Color.foreground.opacity(0.12))
          .overlay(Capsule().strokeBorder(Color.foreground.opacity(0.12), lineWidth: 1))
          .matchedGeometryEffect(id: "activeTab", in: capsuleNamespace)
      } else if isHovering || isDragging {
        // Subtle hover state for inactive tabs
        Capsule()
          .fill(Color.foreground.opacity(0.06))
      }
    }
    .background(WindowDragBlocker())
    .contentShape(Capsule())
    .opacity(isDragging ? 0.9 : 1.0)
    .scaleEffect(isDragging ? 1.02 : 1.0)
    .shadow(color: isDragging ? Color.black.opacity(0.2) : Color.clear, radius: 4, y: 2)
    .onMiddleClick { if !tab.isPinned { onClose() } }
    .blockDoubleClickZoom()
    .contextMenu {
      Button(action: onTogglePin) {
        Label(
          tab.isPinned ? "Unpin Tab" : "Pin Tab", systemImage: tab.isPinned ? "pin.slash" : "pin")
      }
      Button(action: onClose) {
        Label("Close Tab", systemImage: "xmark")
      }
      .disabled(!canClose)
      Button(action: onCloseToRight) {
        Label("Close to the Right", systemImage: "xmark.square")
      }
      .disabled(!hasTabsToRight)
      Button(action: onMoveToNewWindow) {
        Label("Open in New Window", systemImage: "macwindow.badge.plus")
      }
      .disabled(!canMoveToNewWindow)
      if canRevealFile {
        Divider()
        Button(action: onRevealFile) {
          Label("Open File Location", systemImage: "folder")
        }
      }
    }
    .onHover {
      isHovering = $0
      if !$0 { isHoveringClose = false }
    }
    .animation(.easeInOut(duration: 0.15), value: isDragging)
    .animation(.easeInOut(duration: 0.15), value: isHovering)
  }

  @ViewBuilder
  private var closeButton: some View {
    if tab.isPinned {
      // Pinned tabs have no X: the slot shows the pin (or the dirty dot), hover swaps in unpin
      if isHoveringClose {
        Button {
          onTogglePin()
        } label: {
          Image(systemName: "pin.slash")
            .font(.system(size: 8, weight: .medium))
            .foregroundColor(isActive ? .foreground.opacity(0.7) : .foregroundMuted)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkPointer()
        .help("Unpin tab")
        .onHover { isHoveringClose = $0 }
      } else if tab.isDirty {
        Circle()
          .fill(Color.foregroundMuted)
          .frame(width: 8, height: 8)
          .frame(width: 14, height: 14)
          .contentShape(Rectangle())
          .onHover { isHoveringClose = $0 }
      } else {
        Image(systemName: "pin.fill")
          .font(.system(size: 8, weight: .medium))
          .foregroundColor(isActive ? .foreground.opacity(0.7) : .foregroundMuted)
          .frame(width: 14, height: 14)
          .contentShape(Rectangle())
          .onHover { isHoveringClose = $0 }
      }
    } else if (isHovering || isActive) && !(tab.isDirty && !isHoveringClose) {
      Button {
        onClose()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .medium))
          .foregroundColor(isActive ? .foreground.opacity(0.7) : .foregroundMuted)
          .frame(width: 14, height: 14)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .linkPointer()
      .help("Close tab")
      .onHover { isHoveringClose = $0 }
    } else if tab.isDirty {
      // Dot fills the close button slot; hovering it swaps in the X
      Circle()
        .fill(Color.foregroundMuted)
        .frame(width: 8, height: 8)
        .frame(width: 14, height: 14)
        .contentShape(Rectangle())
        .onHover { isHoveringClose = $0 }
    } else {
      Color.clear
        .frame(width: 14, height: 14)
    }
  }
}
