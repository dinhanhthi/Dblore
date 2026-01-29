//
//  TabContainerView.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

/// Main container view that holds the tab bar and active tab content
struct TabContainerView: View {
  @Bindable var tabManager: TabStateManager

  /// Height of the tab bar - must match TitleBarTabsView.tabBarHeight
  private let tabBarHeight: CGFloat = 33

  var body: some View {
    VStack(spacing: 0) {
      // Tab bar in titlebar area
      TitleBarTabsView(tabManager: tabManager)

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
    .ignoresSafeArea(.all, edges: .top)
    .background(TrafficLightPositioner(tabBarHeight: tabBarHeight))
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
  /// Optional override for recent files (used in previews)
  var overrideRecentFiles: [URL]?

  /// Recent files filtered to only .sqlnb and .sql
  private var recentFiles: [URL] {
    if let override = overrideRecentFiles {
      return override
    }
    return NSDocumentController.shared.recentDocumentURLs.filter { url in
      let ext = url.pathExtension.lowercased()
      return ext == "sqlnb" || ext == "sql"
    }
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: Spacing.lg) {
          // Header
          VStack(spacing: Spacing.xs) {
            Image(systemName: "tablecells.badge.ellipsis")
              .font(.system(size: 36))
              .foregroundColor(.accent)

            Text("Welcome to SQLNotebook")
              .font(.title2)
              .fontWeight(.semibold)
              .foregroundColor(.foreground)

            Text("Create a new document or open an existing one")
              .font(.caption)
              .foregroundColor(.foregroundMuted)
          }

          // Cards
          HStack(spacing: Spacing.lg) {
            // Notebook Card
            DocumentTypeCard(
              icon: "doc.text.fill",
              title: "Notebook",
              description: "Interactive SQL with multiple cells and inline results",
              accentColor: .accent,
              onNew: { tabManager.newNotebook() },
              onOpen: { openFile(type: .notebook) }
            )

            // SQL File Card
            DocumentTypeCard(
              icon: "doc.fill",
              title: "SQL File",
              description: "Simple SQL script editor for queries",
              accentColor: .syntaxFunction,
              onNew: { tabManager.newSQLFile() },
              onOpen: { openFile(type: .sqlFile) }
            )
          }
          .padding(.top, Spacing.sm)

          // Recent Files Section (only show if there are recent files)
          if !recentFiles.isEmpty {
            RecentFilesSection(
              recentFiles: recentFiles,
              tabManager: tabManager
            )
            .padding(.top, Spacing.lg)
          }
        }
        .padding(.vertical, Spacing.xl)
        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
      }
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

/// Section showing recent files
struct RecentFilesSection: View {
  let recentFiles: [URL]
  let tabManager: TabStateManager

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // Section header
      Text("Recent")
        .font(.subheadline)
        .fontWeight(.medium)
        .foregroundColor(.foregroundMuted)
        .padding(.horizontal, Spacing.xs)

      // File list - compact, no spacing between items
      VStack(spacing: 0) {
        ForEach(recentFiles.prefix(10), id: \.self) { url in
          RecentFileRow(url: url) {
            Task {
              try? await tabManager.openFile(url: url)
            }
          }
        }
      }
    }
    .frame(width: 480)
  }
}

/// Single row for a recent file - compact design
struct RecentFileRow: View {
  let url: URL
  let onOpen: () -> Void

  @State private var isHovering = false

  private var fileType: TabDocumentType? {
    TabDocumentType.from(url: url)
  }

  private var icon: String {
    fileType?.icon ?? "doc"
  }

  private var iconColor: Color {
    switch fileType {
    case .notebook: return .accent
    case .sqlFile: return .syntaxFunction
    case nil: return .foregroundMuted
    }
  }

  var body: some View {
    Button {
      onOpen()
    } label: {
      HStack(spacing: Spacing.sm) {
        Image(systemName: icon)
          .font(.system(size: 12))
          .foregroundColor(iconColor)
          .frame(width: 16)

        Text(url.lastPathComponent)
          .font(.callout)
          .foregroundColor(.foreground)
          .lineLimit(1)

        Text(url.deletingLastPathComponent().path)
          .font(.caption)
          .foregroundColor(.foregroundSubtle)
          .lineLimit(1)
          .truncationMode(.middle)

        Spacer()
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(isHovering ? Color.cellBackgroundHover : Color.clear)
      .cornerRadius(CornerRadius.sm)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}

/// Card for each document type in the welcome screen - compact design
struct DocumentTypeCard: View {
  let icon: String
  let title: String
  let description: String
  let accentColor: Color
  let onNew: () -> Void
  let onOpen: () -> Void

  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // Icon and Title
      HStack(spacing: Spacing.sm) {
        Image(systemName: icon)
          .font(.system(size: 20))
          .foregroundColor(accentColor)

        Text(title)
          .font(.headline)
          .foregroundColor(.foreground)
      }

      // Description
      Text(description)
        .font(.caption)
        .foregroundColor(.foregroundMuted)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)

      // Buttons - compact
      HStack(spacing: Spacing.sm) {
        Button {
          onNew()
        } label: {
          Label("New", systemImage: "plus")
            .font(.callout)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(accentColor)
        .controlSize(.small)

        Button {
          onOpen()
        } label: {
          Label("Open", systemImage: "folder")
            .font(.callout)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      .padding(.top, Spacing.xs)
    }
    .padding(Spacing.lg)
    .frame(width: 220, height: 140)
    .background(Color.cardBackground)
    .cornerRadius(CornerRadius.lg)
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.lg)
        .stroke(isHovering ? accentColor.opacity(0.5) : Color.border, lineWidth: 1)
    )
    .shadow(color: .black.opacity(isHovering ? 0.08 : 0.04), radius: isHovering ? 6 : 3, y: 1)
    .scaleEffect(isHovering ? 1.02 : 1.0)
    .animation(.easeInOut(duration: 0.15), value: isHovering)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}

#Preview("With Recent Files") {
  EmptyTabView(
    tabManager: TabStateManager(),
    overrideRecentFiles: [
      URL(fileURLWithPath: "/Users/demo/Documents/projects/analytics.sqlnb"),
      URL(fileURLWithPath: "/Users/demo/Documents/queries/report.sql"),
      URL(fileURLWithPath: "/Users/demo/Desktop/test.sqlnb"),
      URL(fileURLWithPath: "/Users/demo/Documents/backup/migration.sql"),
    ]
  )
  .frame(width: 800, height: 500)
}

#Preview("Without Recent Files") {
  EmptyTabView(
    tabManager: TabStateManager(),
    overrideRecentFiles: []
  )
  .frame(width: 800, height: 500)
}

// MARK: - Traffic Light Positioner

/// Adjusts traffic light button positions to vertically center them with the tab bar
struct TrafficLightPositioner: NSViewRepresentable {
  let tabBarHeight: CGFloat

  func makeNSView(context: Context) -> NSView {
    let view = TrafficLightAdjusterView(tabBarHeight: tabBarHeight)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if let adjuster = nsView as? TrafficLightAdjusterView {
      adjuster.adjustTrafficLights()
    }
  }
}

/// Custom NSView that adjusts traffic light positions when added to window
class TrafficLightAdjusterView: NSView {
  let tabBarHeight: CGFloat
  private var layoutObserver: NSObjectProtocol?

  init(tabBarHeight: CGFloat) {
    self.tabBarHeight = tabBarHeight
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    if let window = window {
      adjustTrafficLights()

      // Observe window layout changes to re-adjust buttons
      if layoutObserver == nil {
        layoutObserver = NotificationCenter.default.addObserver(
          forName: NSWindow.didResizeNotification,
          object: window,
          queue: .main
        ) { [weak self] _ in
          Task { @MainActor in
            self?.adjustTrafficLights()
          }
        }
      }
    } else {
      // Remove observer when removed from window
      if let observer = layoutObserver {
        NotificationCenter.default.removeObserver(observer)
        layoutObserver = nil
      }
    }
  }

  func adjustTrafficLights() {
    guard let window = window,
      let closeButton = window.standardWindowButton(.closeButton),
      let superview = closeButton.superview
    else { return }

    // Traffic light buttons are 12pt tall
    let buttonHeight: CGFloat = 12

    // Fine-tune vertical offset (negative = move down in screen coords)
    let verticalAdjustment: CGFloat = -3

    // Horizontal padding from left edge of window
    let horizontalPadding: CGFloat = 13

    // The superview contains all three buttons in a container
    // We need to center this container vertically in the tab bar area
    // In macOS coordinates, Y=0 is at the bottom of the superview

    // Calculate where the center of buttons should be (from top of window content)
    // tabBarHeight / 2 = center of tab bar from top
    let centerFromTop = tabBarHeight / 2

    // In the titlebar container, we want buttons centered
    // The container's coordinate system has Y increasing upward
    // So we need to position relative to the container's height
    let containerHeight = superview.bounds.height
    let newY = containerHeight - centerFromTop - (buttonHeight / 2) + verticalAdjustment

    // Adjust each button's position
    let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    for (index, buttonType) in buttons.enumerated() {
      guard let button = window.standardWindowButton(buttonType) else { continue }
      var frame = button.frame

      // Adjust Y position
      frame.origin.y = newY

      // Adjust X position: add left padding, buttons are 12pt wide with 8pt spacing
      frame.origin.x = horizontalPadding + CGFloat(index) * (frame.width + 8)

      button.setFrameOrigin(frame.origin)
    }
  }
}
