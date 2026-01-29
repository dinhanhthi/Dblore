//
//  TabContainerView.swift
//  SQLNotebook
//

import AppKit
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
        EmptyTabView(tabManager: tabManager)
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
    .task {
      // Restore previous session on launch
      await tabManager.restoreState()
    }
  }
}

/// View shown when no tabs are open
struct EmptyTabView: View {
  let tabManager: TabStateManager

  var body: some View {
    VStack(spacing: Spacing.xl) {
      // Header
      VStack(spacing: Spacing.sm) {
        Image(systemName: "tablecells.badge.ellipsis")
          .font(.system(size: 56))
          .foregroundColor(.accent)

        Text("Welcome to SQLNotebook")
          .font(.title)
          .fontWeight(.semibold)
          .foregroundColor(.foreground)

        Text("Create a new document or open an existing one")
          .font(.subheadline)
          .foregroundColor(.foregroundMuted)
      }

      // Cards
      HStack(spacing: Spacing.xl) {
        // Notebook Card
        DocumentTypeCard(
          icon: "doc.text.fill",
          title: "Notebook",
          description:
            "Interactive SQL notebook with multiple cells, markdown support, and inline results",
          accentColor: .accent,
          onNew: { tabManager.newNotebook() },
          onOpen: { openFile(type: .notebook) }
        )

        // SQL File Card
        DocumentTypeCard(
          icon: "doc.fill",
          title: "SQL File",
          description: "Simple SQL script editor for writing and executing queries",
          accentColor: .syntaxFunction,
          onNew: { tabManager.newSQLFile() },
          onOpen: { openFile(type: .sqlFile) }
        )
      }
      .padding(.top, Spacing.lg)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.appBackground)
  }

  private func openFile(type: TabDocumentType) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false

    switch type {
    case .notebook:
      panel.allowedContentTypes = [.sqlNotebook]
    case .sqlFile:
      panel.allowedContentTypes = [.sql]
    }

    panel.begin { response in
      guard response == .OK else { return }
      Task { @MainActor in
        for url in panel.urls {
          try? await tabManager.openFile(url: url)
        }
      }
    }
  }
}

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
    VStack(alignment: .leading, spacing: Spacing.lg) {
      // Icon and Title
      HStack(spacing: Spacing.md) {
        Image(systemName: icon)
          .font(.system(size: 32))
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
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(accentColor)

        Button {
          onOpen()
        } label: {
          Label("Open", systemImage: "folder")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(Spacing.xl)
    .frame(width: 280, height: 220)
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

#Preview {
  let manager = TabStateManager()

  TabContainerView(tabManager: manager)
    .frame(width: 1200, height: 800)
}
