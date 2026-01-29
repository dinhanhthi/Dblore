//
//  TabBarView.swift
//  SQLNotebook
//

import SwiftUI

/// Tab bar showing all open tabs with support for selection, closing, and reordering
struct TabBarView: View {
  @Bindable var tabManager: TabStateManager

  @State private var showNewTabMenu = false

  var body: some View {
    HStack(spacing: 0) {
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
              // Drag preview
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
        .padding(.vertical, Spacing.xs)
      }

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
    .frame(height: 36)
    .background(Color.appBackground)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}

#Preview {
  let manager = TabStateManager()

  VStack(spacing: 0) {
    TabBarView(tabManager: manager)
    Spacer()
  }
  .frame(width: 600, height: 400)
  .task {
    manager.newNotebook()
    manager.newSQLFile()
    manager.newNotebook()
    if let first = manager.tabs.first {
      manager.markDirty(tabId: first.id)
    }
  }
}
