//
//  FavoriteFolderModal.swift
//  Dblore
//
//  Modal to create or rename a favorite folder, and the favorite modals presenter
//

import SwiftUI

// MARK: - Favorite Folder Modal

/// Create (nil folder) or rename a favorite folder
struct FavoriteFolderModal: View {
  let workspaceManager: WorkspaceManager
  @Binding var isPresented: Bool
  let folder: FavoriteFolder?

  @State private var name: String

  init(workspaceManager: WorkspaceManager, isPresented: Binding<Bool>, folder: FavoriteFolder?) {
    self.workspaceManager = workspaceManager
    self._isPresented = isPresented
    self.folder = folder
    self._name = State(initialValue: folder?.name ?? "")
  }

  private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    GenericModal(
      title: folder == nil ? "New Folder" : "Rename Folder",
      titleIcon: "folder",
      width: 360,
      height: 190,
      isPresented: $isPresented
    ) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        FormField(label: "Name") {
          TextField("Folder name", text: $name)
            .textFieldStyle(.plain)
            .inputCapsuleStyle()
            .onSubmit(save)
        }
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } footer: {
      GenericModalFooter {
        Spacer()
        Button("Cancel") { isPresented = false }
          .buttonStyle(FilledSecondaryButtonStyle())
        Button("Save", action: save)
          .buttonStyle(PrimaryButtonStyle())
          .disabled(!canSave)
      }
    }
  }

  private func save() {
    guard canSave else { return }
    if let folder {
      workspaceManager.renameFolder(id: folder.id, name: name)
    } else {
      workspaceManager.createFolder(name: name)
    }
    isPresented = false
  }
}

// MARK: - Favorite Modals Presenter

extension View {
  /// Presents the folder modal driven by `workspaceManager.favoriteModal`
  func favoriteModals(workspaceManager: WorkspaceManager) -> some View {
    let isPresented = Binding(
      get: { workspaceManager.favoriteModal?.isFolder == true },
      set: { if !$0 { workspaceManager.favoriteModal = nil } }
    )
    return modalOverlay(isPresented: isPresented) {
      if case .folder(let folder) = workspaceManager.favoriteModal {
        FavoriteFolderModal(
          workspaceManager: workspaceManager, isPresented: isPresented, folder: folder
        )
        .id(workspaceManager.favoriteModal?.id)
      }
    }
  }

  /// Presents the favorite form driven by `workspaceManager.favoriteModal` in a right sidebar
  /// that slides in from the trailing edge
  func favoriteFormPanel(workspaceManager: WorkspaceManager) -> some View {
    let isPresented = Binding(
      get: { workspaceManager.favoriteModal?.isFolder == false },
      set: { if !$0 { workspaceManager.favoriteModal = nil } }
    )
    return sidePanelOverlay(isPresented: isPresented, width: FavoriteFormModal.panelWidth) {
      if case .favorite(let favorite) = workspaceManager.favoriteModal {
        FavoriteFormModal(
          workspaceManager: workspaceManager, isPresented: isPresented, favorite: favorite
        )
        .id(workspaceManager.favoriteModal?.id)
      }
    }
  }
}
