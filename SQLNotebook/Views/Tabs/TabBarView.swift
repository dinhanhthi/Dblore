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

  /// Space for traffic light buttons (close, minimize, zoom)
  private let trafficLightWidth: CGFloat = 78
  private let tabBarHeight: CGFloat = 33

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      // Left padding for traffic light buttons
      Color.clear
        .frame(width: trafficLightWidth)

      // Scrollable tabs area
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .bottom, spacing: Spacing.xxs) {
          ForEach(tabManager.tabs) { tab in
            TitleBarTabItem(
              tab: tab,
              isActive: tab.id == tabManager.activeTabId,
              onSelect: { tabManager.selectTab(id: tab.id) },
              onClose: { tabManager.requestCloseTab(id: tab.id) }
            )
            .draggable(tab.id.uuidString) {
              TabItemView(
                tab: tab,
                isActive: true,
                onSelect: {},
                onClose: {}
              )
            }
            .dropDestination(for: String.self) { items, _ in
              guard let draggedIdString = items.first,
                let draggedId = UUID(uuidString: draggedIdString),
                let fromIndex = tabManager.tabs.firstIndex(where: { $0.id == draggedId }),
                let toIndex = tabManager.tabs.firstIndex(where: { $0.id == tab.id })
              else { return false }

              withAnimation(.easeInOut(duration: 0.2)) {
                tabManager.moveTab(from: fromIndex, to: toIndex)
              }
              return true
            }
          }
        }
        .padding(.horizontal, Spacing.sm)
        .frame(maxHeight: .infinity, alignment: .bottom)
      }
      .scrollContentBackground(.hidden)

      Divider()
        .frame(height: 16)
        .padding(.horizontal, Spacing.xs)

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
      .padding(.trailing, Spacing.sm)
      .help("New tab")
    }
    .frame(height: tabBarHeight)
    .frame(maxWidth: .infinity)
    .background(Color.cardBackground)
    .background(WindowDragArea())
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

      // Title with dirty indicator
      Text(displayTitle)
        .font(.system(size: 12))
        .lineLimit(1)
        .foregroundColor(isActive ? .foreground : .foregroundMuted)

      // Close button
      closeButton
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .frame(height: 28)
    .background(backgroundColor)
    .clipShape(tabClipShape)
    .overlay(tabBorderOverlay)
    .contentShape(Rectangle())
    .onTapGesture { onSelect() }
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
      TabTopRoundedBorder(radius: CornerRadius.sm)
        .stroke(Color.border, lineWidth: 1)
    } else {
      RoundedRectangle(cornerRadius: CornerRadius.sm)
        .stroke(Color.clear, lineWidth: 1)
    }
  }

  private var displayTitle: String {
    tab.isDirty ? "\(tab.title) •" : tab.title
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

/// Custom NSView that enables window dragging
class WindowDragView: NSView {
  override var mouseDownCanMoveWindow: Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.performDrag(with: event)
  }
}

/// Standard tab bar (non-titlebar version)
struct TabBarView: View {
  @Bindable var tabManager: TabStateManager

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Spacing.xxs) {
          ForEach(tabManager.tabs) { tab in
            TabItemView(
              tab: tab,
              isActive: tab.id == tabManager.activeTabId,
              onSelect: { tabManager.selectTab(id: tab.id) },
              onClose: { tabManager.requestCloseTab(id: tab.id) }
            )
          }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
      }

      Divider()
        .frame(height: 16)
        .padding(.horizontal, Spacing.xs)

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
      .padding(.trailing, Spacing.sm)
      .help("New tab")
    }
    .frame(height: 36)
    .background(Color.appBackground)
    .overlay(alignment: .bottom) {
      Divider()
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
