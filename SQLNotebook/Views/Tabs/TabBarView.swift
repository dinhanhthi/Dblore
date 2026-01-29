//
//  TabBarView.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

/// Tab bar that sits in the titlebar area with traffic light buttons
/// Uses NSHostingView to properly integrate with window titlebar
struct TitleBarTabsView: View {
  @Bindable var tabManager: TabStateManager

  /// Space for traffic light buttons (close, minimize, zoom)
  private let trafficLightWidth: CGFloat = 78

  var body: some View {
    HStack(spacing: 0) {
      // Left padding for traffic light buttons
      Color.clear
        .frame(width: trafficLightWidth, height: 38)

      // Scrollable tabs area
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Spacing.xxs) {
          ForEach(tabManager.tabs) { tab in
            TabItemView(
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
      }
      .frame(height: 38)

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
    .frame(height: 38)
    .frame(maxWidth: .infinity)
    .background(WindowDragArea())
    .background(Color.appBackground)
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

#Preview("TitleBar Tabs") {
  let manager = TabStateManager()

  VStack(spacing: 0) {
    TitleBarTabsView(tabManager: manager)
    Divider()
    Spacer()
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
