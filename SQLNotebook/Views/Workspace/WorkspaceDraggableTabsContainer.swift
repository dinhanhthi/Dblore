//
//  WorkspaceDraggableTabsContainer.swift
//  SQLNotebook
//
//  Chrome-like tab dragging with real-time reordering animation for workspaces
//

import SwiftUI

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

  /// Namespace for the active tab capsule that slides between tabs
  @Namespace private var tabCapsuleNamespace

  private let tabSpacing: CGFloat = Spacing.xxs

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
          onSelect: { workspaceManager.selectTab(id: tab.id) },
          onClose: { workspaceManager.requestCloseTab(id: tab.id) }
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
        .offset(x: calculateOffset(for: tab, at: index))
        .animation(draggingTabId != nil ? .easeInOut(duration: 0.2) : nil, value: targetIndex)
        .zIndex(isDragging ? 100 : (isActive ? 50 : 0))
        .gesture(
          DragGesture(minimumDistance: 5)
            .onChanged { value in
              handleDragChanged(tab: tab, index: index, translation: value.translation.width)
            }
            .onEnded { _ in
              handleDragEnded()
            }
        )
      }
    }
    .coordinateSpace(name: "workspaceTabContainer")
    .onPreferenceChange(WorkspaceTabPositionPreferenceKey.self) { positions in
      tabPositions = positions
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
    let newTargetIndex = calculateTargetIndex(
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

    return max(0, min(newIndex, tabs.count - 1))
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
  let onSelect: () -> Void
  let onClose: () -> Void

  @State private var isHovering = false

  var body: some View {
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
          .fill(Color.cellBackgroundHover.opacity(0.4))
      }
    }
    .contentShape(Capsule())
    .opacity(isDragging ? 0.9 : 1.0)
    .scaleEffect(isDragging ? 1.02 : 1.0)
    .shadow(color: isDragging ? Color.black.opacity(0.2) : Color.clear, radius: 4, y: 2)
    .onTapGesture { onSelect() }
    .onMiddleClick { onClose() }
    .blockDoubleClickZoom()
    .onHover { isHovering = $0 }
    .animation(.easeInOut(duration: 0.15), value: isDragging)
    .animation(.easeInOut(duration: 0.15), value: isHovering)
  }

  @ViewBuilder
  private var closeButton: some View {
    if isHovering || isActive {
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
      .pointerStyle(.link)
      .help("Close tab")
    } else {
      Color.clear
        .frame(width: 14, height: 14)
    }
  }
}
