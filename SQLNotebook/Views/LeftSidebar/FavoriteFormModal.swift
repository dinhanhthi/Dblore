//
//  FavoriteFormModal.swift
//  SQLNotebook
//
//  Modal form to create or edit a favorite statement (name, folder, SQL)
//

import SwiftUI

// MARK: - Favorite Form Modal

/// Create or edit a favorite. The payload's id decides: present in the workspace favorites = edit,
/// otherwise create (nil payload = create with no folder).
struct FavoriteFormModal: View {
  let workspaceManager: WorkspaceManager
  @Binding var isPresented: Bool
  let favorite: FavoriteStatement?

  @Bindable private var appSettings = AppSettings.shared
  @State private var name: String
  @State private var sql: String
  @State private var folderId: UUID?
  @State private var placeholder: String
  @State private var textViewRef: SQLTextView?
  @State private var isEditing: Bool

  init(
    workspaceManager: WorkspaceManager, isPresented: Binding<Bool>, favorite: FavoriteStatement?
  ) {
    self.workspaceManager = workspaceManager
    self._isPresented = isPresented
    self.favorite = favorite
    let favorites = workspaceManager.workspace.favorites
    _placeholder = State(initialValue: favorites.nextDefaultName())
    _isEditing = State(initialValue: favorite.map { favorites.contains(itemId: $0.id) } ?? false)
    _name = State(initialValue: favorite?.name ?? "")
    _sql = State(initialValue: favorite?.sql ?? "")
    _folderId = State(initialValue: favorites.resolvedFolderId(favorite?.folderId))
  }

  private var folders: [FavoriteFolder] { workspaceManager.workspace.favorites.folders }

  private var canSave: Bool {
    !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    GenericModal(
      title: isEditing ? "Edit Favorite" : "New Favorite",
      titleIcon: "star",
      width: 520,
      height: 470,
      isPresented: $isPresented
    ) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        FormField(label: "Name") {
          TextField(placeholder, text: $name)
            .textFieldStyle(.plain)
            .inputCapsuleStyle()
        }

        FormField(label: "Folder") {
          Picker("Folder", selection: $folderId) {
            Text("None").tag(UUID?.none)
            ForEach(folders) { folder in
              Text(folder.name).tag(UUID?.some(folder.id))
            }
          }
          .labelsHidden()
        }

        FormField(label: "Query") {
          queryEditor
        }
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } footer: {
      GenericModalFooter {
        Spacer()
        Button("Cancel") { isPresented = false }
          .buttonStyle(SecondaryButtonStyle())
        Button("Save", action: save)
          .buttonStyle(PrimaryButtonStyle())
          .disabled(!canSave)
      }
    }
  }

  private var queryEditor: some View {
    ZStack(alignment: .bottomTrailing) {
      SQLEditorView(
        content: $sql,
        isSelected: true,
        isFocused: false,
        textViewRef: $textViewRef,
        autocompleteProvider: workspaceManager.autocompleteProvider,
        maxHeight: 200,
        isEditorMode: false,
        wordWrapEnabled: appSettings.wordWrapEnabled
      )

      HStack(spacing: Spacing.xs) {
        FormatSQLButton(textView: textViewRef)
        SyntaxHighlightToggleButton()
      }
      .padding(.trailing, Spacing.sm)
      .padding(.bottom, Spacing.sm)
    }
    .frame(maxHeight: 200)
  }

  private func save() {
    guard canSave else { return }
    let saved = FavoriteStatement(
      id: isEditing ? (favorite?.id ?? UUID()) : UUID(),
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      sql: sql,
      folderId: folderId)
    workspaceManager.saveFavorite(saved)
    isPresented = false
  }
}
