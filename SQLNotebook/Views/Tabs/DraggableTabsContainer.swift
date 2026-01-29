//
//  DraggableTabsContainer.swift
//  SQLNotebook
//
//  Chrome-like tab dragging with real-time reordering animation
//

import SwiftUI

/// Container that handles Chrome-like tab dragging with real-time reorder animation
struct DraggableTabsContainer: View {
  @Bindable var tabManager: TabStateManager

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

  private let tabSpacing: CGFloat = Spacing.xxs

  var body: some View {
    HStack(alignment: .bottom, spacing: tabSpacing) {
      ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
        let isDragging = tab.id == draggingTabId

        DraggableTitleBarTabItem(
          tab: tab,
          isActive: tab.id == tabManager.activeTabId,
          isDragging: isDragging,
          onSelect: { tabManager.selectTab(id: tab.id) },
          onClose: { tabManager.requestCloseTab(id: tab.id) }
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
                key: TabPositionPreferenceKey.self,
                value: [tab.id: geo.frame(in: .named("tabContainer")).minX]
              )
          }
        )
        .offset(x: calculateOffset(for: tab, at: index))
        .animation(draggingTabId != nil ? .easeInOut(duration: 0.2) : nil, value: targetIndex)
        .zIndex(isDragging ? 100 : 0)
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
    .coordinateSpace(name: "tabContainer")
    .onPreferenceChange(TabPositionPreferenceKey.self) { positions in
      tabPositions = positions
    }
    .frame(maxHeight: .infinity, alignment: .bottom)
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

    let tabs = tabManager.tabs

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
    tabManager.moveTab(from: originalIdx, to: targetIdx)
  }
}

/// Preference key to collect tab positions
struct TabPositionPreferenceKey: PreferenceKey {
  static var defaultValue: [UUID: CGFloat] = [:]

  static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
    value.merge(nextValue()) { _, new in new }
  }
}

/// Tab item wrapper for dragging - adds visual feedback during drag
struct DraggableTitleBarTabItem: View {
  let tab: TabItem
  let isActive: Bool
  let isDragging: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: Spacing.xs) {
      // Document type icon
      Image(systemName: tab.documentType.icon)
        .font(.system(size: 11))
        .foregroundColor(isActive ? .foreground : .foregroundMuted)

      // Title with dirty indicator
      Text(displayTitle)
        .font(.system(size: 12))
        .lineLimit(1)
        .foregroundColor(isActive ? .foreground : .foregroundMuted)

      // Close button
      closeButton
    }
    .padding(.leading, Spacing.sm)
    .padding(.trailing, Spacing.xs)
    .padding(.vertical, Spacing.xs)
    .frame(height: 28)
    .background(backgroundColor)
    .clipShape(tabClipShape)
    .overlay(tabBorderOverlay)
    .contentShape(Rectangle())
    .opacity(isDragging ? 0.9 : 1.0)
    .scaleEffect(isDragging ? 1.02 : 1.0)
    .shadow(color: isDragging ? Color.black.opacity(0.2) : Color.clear, radius: 4, y: 2)
    .onTapGesture { onSelect() }
    .onMiddleClick { onClose() }
    .blockDoubleClickZoom()
    .onHover { isHovering = $0 }
    .animation(.easeInOut(duration: 0.15), value: isDragging)
  }

  private var tabClipShape: some Shape {
    if isActive {
      AnyShape(TabTopRoundedShape(radius: CornerRadius.sm))
    } else {
      AnyShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
    }
  }

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

  private var displayTitle: String {
    tab.isDirty ? "\(tab.title) \u{2022}" : tab.title
  }

  private var backgroundColor: Color {
    if isActive {
      return Color.appBackground
    } else if isHovering || isDragging {
      return Color.cellBackgroundHover.opacity(0.5)
    } else {
      return Color.clear
    }
  }

  @ViewBuilder
  private var closeButton: some View {
    if isHovering || isActive || tab.isDirty {
      Button {
        onClose()
      } label: {
        Image(systemName: tab.isDirty ? "circle.fill" : "xmark")
          .font(.system(size: tab.isDirty ? 6 : 8, weight: .medium))
          .foregroundColor(.foregroundMuted)
          .frame(width: 14, height: 14)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(tab.isDirty ? "Unsaved changes" : "Close tab")
    } else {
      Color.clear
        .frame(width: 14, height: 14)
    }
  }
}
