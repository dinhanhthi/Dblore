//
//  SidebarFolderRows.swift
//  Dblore
//
//  Folders of tables and views in the Public tab (`SidebarFolderStore`): the collapsible folder
//  section (Rename and Delete in its menu, rows dropped on its header move in), the row menu's
//  Move to Folder and Remove from Folder items, and the folder name sheet.
//

import SwiftUI

// MARK: - Folder Section

/// A folder header and, expanded, its rows. Empty, it shows a hint row (never a zero-height one).
struct SidebarFolderSection<Content: View>: View {
  let folder: SidebarFolder
  /// Rows listed in the folder (members the schema no longer has are not counted)
  let count: Int
  let isExpanded: Bool
  let onToggle: () -> Void
  let onRename: () -> Void
  let onDelete: () -> Void
  /// Gets the dropped `schema.name` strings; true when one moved in
  let onDrop: ([String]) -> Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SidebarFolderRowView(
        folder: folder, count: count, isExpanded: isExpanded, onToggle: onToggle,
        onRename: onRename, onDelete: onDelete, onDrop: onDrop)

      if isExpanded {
        VStack(alignment: .leading, spacing: 0) {
          if count == 0 {
            Text("Drag tables or views here")
              .font(.small)
              .foregroundColor(.foregroundSubtle)
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.xs)
          } else {
            content()
          }
        }
        .padding(.leading, Spacing.lg)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.foregroundSubtle.opacity(0.2))
            .frame(width: 1)
            .padding(.leading, Spacing.md + 6)  // Align with chevron center
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .clipped()
  }
}

/// The folder header: chevron, name and count. A table or view row dropped on it moves in.
struct SidebarFolderRowView: View {
  let folder: SidebarFolder
  let count: Int
  let isExpanded: Bool
  let onToggle: () -> Void
  let onRename: () -> Void
  let onDelete: () -> Void
  let onDrop: ([String]) -> Bool

  @State private var isHovering = false
  @State private var isTargeted = false

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.foregroundMuted)
        .frame(width: 12, height: 12)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))

      Image(systemName: "folder")
        .font(.system(size: 12))
        .foregroundColor(.accent)

      Text(verbatim: folder.name)
        .font(.monoMedium)
        .foregroundColor(.foreground)
        .lineLimit(1)

      Text("(\(count))")
        .font(.monoSmall)
        .foregroundColor(.foregroundSubtle)

      Spacer()
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .contentShape(Rectangle())
    .onTapGesture { onToggle() }
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.sm)
        .fill(
          isTargeted ? Color.selectionFill : (isHovering ? Color.hoverFill : Color.clear))
    )
    .onHover { isHovering = $0 }
    .linkPointer()
    .dropDestination(for: String.self) { items, _ in
      onDrop(items)
    } isTargeted: {
      isTargeted = $0
    }
    .contextMenu {
      Button("Rename…", action: onRename)
      Divider()
      Button("Delete Folder", role: .destructive, action: onDelete)
    }
    .help("Folder \(folder.name)")
  }
}

// MARK: - Row Menu Items

/// What a table or view row offers about folders: the folders of its schema, the one holding
/// it, and the moves
struct SidebarFolderActions {
  /// `schema.name` of the row, also what dragging it carries
  let member: String
  /// Folders of the row's schema
  let folders: [SidebarFolder]
  /// The folder listing the row, nil when ungrouped
  let currentFolderID: UUID?
  let onMove: (UUID) -> Void
  let onNewFolder: () -> Void
  let onRemove: () -> Void
}

/// Move to Folder (the schema's folders, then New Folder…) and, inside a folder, Remove from
/// Folder
struct SidebarFolderMenuItems: View {
  let actions: SidebarFolderActions

  var body: some View {
    Menu("Move to Folder") {
      ForEach(actions.folders) { folder in
        Button {
          actions.onMove(folder.id)
        } label: {
          Text(verbatim: folder.name)
        }
        .disabled(folder.id == actions.currentFolderID)
      }
      if !actions.folders.isEmpty { Divider() }
      Button("New Folder…", action: actions.onNewFolder)
    }
    if actions.currentFolderID != nil {
      Button("Remove from Folder", action: actions.onRemove)
    }
  }
}

extension View {
  /// Lets the row be dragged onto a folder (its `schema.name`); nil leaves the row as it is
  @ViewBuilder
  func sidebarFolderDrag(_ actions: SidebarFolderActions?) -> some View {
    if let member = actions?.member {
      draggable(member)
    } else {
      self
    }
  }
}

// MARK: - Folder Name Sheet

/// What the name sheet is for: a new folder in `schema` that `member` moves into, or a rename
enum SidebarFolderPrompt: Identifiable {
  case create(schema: String, member: String)
  case rename(SidebarFolder)

  var id: String {
    switch self {
    case .create(let schema, let member): "create:\(schema):\(member)"
    case .rename(let folder): "rename:\(folder.id.uuidString)"
    }
  }
}

struct SidebarFolderNameSheet: View {
  let prompt: SidebarFolderPrompt
  /// Gets the trimmed name
  let onSave: (String) -> Void
  let onClose: () -> Void

  @State private var name: String
  @FocusState private var isFieldFocused: Bool

  init(
    prompt: SidebarFolderPrompt, onSave: @escaping (String) -> Void,
    onClose: @escaping () -> Void
  ) {
    self.prompt = prompt
    self.onSave = onSave
    self.onClose = onClose
    if case .rename(let folder) = prompt {
      _name = State(initialValue: folder.name)
    } else {
      _name = State(initialValue: "")
    }
  }

  private var isRename: Bool {
    if case .rename = prompt { return true }
    return false
  }

  private var normalizedName: String? {
    SidebarFolderStore.normalizedName(name)
  }

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: isRename ? "Rename Folder" : "New Folder", titleIcon: "folder",
        titleIconColor: .accent, onClose: onClose)
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Name")
          .font(.small)
          .foregroundColor(.foregroundMuted)
        TextField("Folder name", text: $name)
          .textFieldStyle(.plain)
          .autocorrectionDisabled()
          .inputCapsuleStyle()
          .focused($isFieldFocused)
          .onSubmit(save)
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      GenericModalFooter {
        Spacer()
        Button("Cancel", action: onClose)
          .buttonStyle(FilledSecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
        Button(isRename ? "Rename" : "Create", action: save)
          .buttonStyle(PrimaryButtonStyle())
          .disabled(normalizedName == nil)
      }
    }
    .frame(width: 360)
    .background(Color.cardBackground)
    .onAppear {
      // Deferred: focus set during the first layout pass of a sheet is dropped
      DispatchQueue.main.async { isFieldFocused = true }
    }
  }

  private func save() {
    guard let normalizedName else { return }
    onSave(normalizedName)
  }
}
