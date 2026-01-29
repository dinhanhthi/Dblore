//
//  TabContainerView.swift
//  SQLNotebook
//

import SwiftUI

/// Main container view that holds the tab bar and active tab content
struct TabContainerView: View {
  @Bindable var tabManager: TabStateManager

  var body: some View {
    VStack(spacing: 0) {
      // Tab bar
      TabBarView(tabManager: tabManager)

      // Content area
      if let activeTabId = tabManager.activeTabId,
        let viewModel = tabManager.viewModel(for: activeTabId)
      {
        TabContentView(
          tabId: activeTabId,
          tabManager: tabManager,
          viewModel: viewModel
        )
      } else {
        EmptyTabView(onNewNotebook: { tabManager.newNotebook() })
      }
    }
    .frame(minWidth: 800, minHeight: 600)
    .background(Color.appBackground)
    .confirmationDialog(
      "Save changes?",
      isPresented: $tabManager.showingCloseConfirmation,
      titleVisibility: .visible
    ) {
      Button("Save") {
        Task {
          await tabManager.saveAndCloseTab()
        }
      }
      Button("Don't Save", role: .destructive) {
        tabManager.closeTabWithoutSaving()
      }
      Button("Cancel", role: .cancel) {
        tabManager.cancelClose()
      }
    } message: {
      if let tabId = tabManager.tabToClose,
        let tab = tabManager.tabs.first(where: { $0.id == tabId })
      {
        Text("Do you want to save changes to \"\(tab.title)\"?")
      }
    }
    .onOpenURL { url in
      Task {
        try? await tabManager.openFile(url: url)
      }
    }
  }
}

/// View shown when no tabs are open
struct EmptyTabView: View {
  let onNewNotebook: () -> Void

  var body: some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "doc.text.magnifyingglass")
        .font(.system(size: 48))
        .foregroundColor(.foregroundMuted)

      Text("No documents open")
        .font(.title2)
        .foregroundColor(.foregroundMuted)

      Text("Create a new document or open an existing one")
        .font(.subheadline)
        .foregroundColor(.foregroundSubtle)

      HStack(spacing: Spacing.md) {
        Button {
          onNewNotebook()
        } label: {
          Label("New Notebook", systemImage: "doc.badge.plus")
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.appBackground)
  }
}

#Preview {
  let manager = TabStateManager()

  TabContainerView(tabManager: manager)
    .frame(width: 1200, height: 800)
}
