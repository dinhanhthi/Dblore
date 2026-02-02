//
//  FileOpenChooserView.swift
//  SQLNotebook
//
//  Dialog shown when opening files from Finder while workspaces are already open.
//  Allows user to choose which workspace to open files in.

import AppKit
import SwiftUI

// MARK: - Window Resizer

/// Helper view to resize the window to a specific size
struct WindowResizer: NSViewRepresentable {
  let size: NSSize

  func makeNSView(context: Context) -> NSView {
    let view = WindowResizerView(targetSize: size)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Custom NSView that resizes window when added to window
class WindowResizerView: NSView {
  let targetSize: NSSize

  init(targetSize: NSSize) {
    self.targetSize = targetSize
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window = self.window else { return }

    window.setContentSize(targetSize)
    window.minSize = targetSize
    window.maxSize = targetSize
    window.center()
  }
}

/// View shown when files are opened from Finder and workspaces already exist
/// Allows user to choose destination workspace or create a new one
struct FileOpenChooserView: View {
  let onWorkspaceSelected: (WorkspaceManager) -> Void
  let onNewWorkspace: () -> Void
  let onCancel: () -> Void

  @Bindable private var windowManager = WorkspaceWindowManager.shared
  @Bindable private var pendingFileOpen = PendingFileOpen.shared

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: Spacing.xl) {
          // Header - similar to WelcomeHeader
          FileOpenHeader(fileNames: fileNamesText)

          // Workspace list in a card with scroll
          OpenWorkspacesColumn(
            workspaces: windowManager.allWorkspaces,
            onSelect: onWorkspaceSelected,
            onNewWorkspace: onNewWorkspace,
            columnWidth: 450
          )

          // Cancel button
          Button("Cancel") {
            onCancel()
          }
          .buttonStyle(.plain)
          .foregroundColor(.foregroundMuted)
          .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.vertical, Spacing.xxl)
        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.appBackground)
    .ignoresSafeArea(.all, edges: .top)
    .background(
      TrafficLightPositioner(tabBarHeight: ComponentSize.tabBarHeight)
    )
    .background(WindowResizer(size: NSSize(width: 700, height: 500)))
  }

  private var fileNamesText: String {
    let files = pendingFileOpen.pendingFiles
    if files.isEmpty {
      return ""
    } else if files.count == 1 {
      return files[0].lastPathComponent
    } else {
      return
        "\(files[0].lastPathComponent) and \(files.count - 1) more file\(files.count > 2 ? "s" : "")"
    }
  }
}

// MARK: - File Open Header

struct FileOpenHeader: View {
  let fileNames: String

  var body: some View {
    VStack(spacing: Spacing.xs) {
      Image(systemName: "doc.badge.arrow.up")
        .font(.system(size: 36))
        .foregroundColor(.accent)

      Text("Open File")
        .font(.title)
        .fontWeight(.bold)
        .foregroundColor(.foreground)

      Text(fileNames)
        .font(.body)
        .foregroundColor(.foregroundMuted)
        .lineLimit(2)
        .multilineTextAlignment(.center)
    }
    .padding(.bottom, Spacing.lg)
  }
}

// MARK: - Open Workspaces Column

struct OpenWorkspacesColumn: View {
  let workspaces: [WorkspaceManager]
  let onSelect: (WorkspaceManager) -> Void
  let onNewWorkspace: () -> Void
  let columnWidth: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Header
      Label("Choose a workspace", systemImage: "folder.badge.gearshape")
        .font(.headline)
        .foregroundColor(.foreground)

      // Workspace list - scrollable when content exceeds max height
      ScrollView {
        VStack(spacing: 0) {
          ForEach(workspaces, id: \.id) { manager in
            OpenWorkspaceRow(manager: manager, onSelect: { onSelect(manager) })
          }

          // New workspace option
          NewWorkspaceRow(onSelect: onNewWorkspace)
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: 300)
      .fixedSize(horizontal: false, vertical: true)
      .background(Color.cardBackground)
      .cornerRadius(CornerRadius.md)
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .stroke(Color.border, lineWidth: 1)
      )
    }
    .frame(width: columnWidth)
  }
}

// MARK: - Open Workspace Row

struct OpenWorkspaceRow: View {
  let manager: WorkspaceManager
  let onSelect: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button {
      onSelect()
    } label: {
      HStack(alignment: .center, spacing: Spacing.sm) {
        // Workspace icon
        Image(systemName: "folder.badge.gearshape")
          .font(.system(size: 16))
          .foregroundColor(.accent)
          .frame(width: 24)

        VStack(alignment: .leading, spacing: 2) {
          // Workspace name
          HStack(spacing: Spacing.xs) {
            Text(manager.workspace.name)
              .font(.callout)
              .fontWeight(.medium)
              .foregroundColor(.foreground)
              .lineLimit(1)
              .truncationMode(.tail)

            Spacer(minLength: Spacing.xs)

            // Tab count badge
            if manager.tabs.count > 0 {
              Text("\(manager.tabs.count)")
                .font(.caption2)
                .foregroundColor(.foregroundMuted)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, 2)
                .background(Color.inputBackground)
                .cornerRadius(CornerRadius.sm)
                .layoutPriority(1)
            }
          }

          // Connection info
          if manager.connectionState == .connected,
            let config = manager.workspace.connectionConfig
          {
            Text(config.displayString)
              .font(.caption)
              .foregroundColor(.foregroundMuted)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }

        Spacer(minLength: 0)
      }
      .padding(Spacing.sm)
      .background(isHovering ? Color.cellBackgroundHover : Color.clear)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}

// MARK: - New Workspace Row

struct NewWorkspaceRow: View {
  let onSelect: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button {
      onSelect()
    } label: {
      HStack(alignment: .center, spacing: Spacing.sm) {
        // Plus icon
        Image(systemName: "plus.circle.fill")
          .font(.system(size: 16))
          .foregroundColor(.syntaxFunction)
          .frame(width: 24)

        Text("New Workspace")
          .font(.callout)
          .fontWeight(.medium)
          .foregroundColor(.foreground)

        Spacer()
      }
      .padding(Spacing.sm)
      .background(isHovering ? Color.cellBackgroundHover : Color.clear)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}

// MARK: - Preview

#Preview("File Open Chooser") {
  FileOpenChooserView(
    onWorkspaceSelected: { _ in },
    onNewWorkspace: {},
    onCancel: {}
  )
  .frame(width: 700, height: 500)
}
