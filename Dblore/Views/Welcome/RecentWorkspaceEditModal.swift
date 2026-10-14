//
//  RecentWorkspaceEditModal.swift
//  Dblore
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Edits the display name and file location of one recent workspace.
struct RecentWorkspaceEditModal: View {
  let entry: WorkspaceHistoryEntry
  @Binding var isPresented: Bool
  var onSave: (WorkspaceHistoryEntry, String, URL) async throws -> Void

  @State private var name: String
  @State private var fileURL: URL
  @State private var isSaving = false
  @State private var errorMessage: String?

  init(
    entry: WorkspaceHistoryEntry,
    isPresented: Binding<Bool>,
    onSave: @escaping (WorkspaceHistoryEntry, String, URL) async throws -> Void
  ) {
    self.entry = entry
    self._isPresented = isPresented
    self.onSave = onSave
    self._name = State(initialValue: entry.name)
    self._fileURL = State(initialValue: entry.fileURL)
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(title: "Edit Workspace", onClose: { isPresented = false })

      VStack(alignment: .leading, spacing: Spacing.md) {
        FormField(label: "Name") {
          TextField("Workspace name", text: $name)
            .textFieldStyle(.plain)
            .inputCapsuleStyle()
        }

        FormField(label: "Workspace file") {
          HStack(spacing: Spacing.sm) {
            Text(fileURL.path)
              .font(.caption)
              .foregroundColor(.foregroundMuted)
              .lineLimit(1)
              .truncationMode(.middle)
              .frame(maxWidth: .infinity, alignment: .leading)
              .help(fileURL.path)

            Button("Browse", action: browse)
              .buttonStyle(SecondaryButtonStyle())
              .controlSize(.small)
              .disabled(isSaving)
          }
        }

        if let errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundColor(.destructive)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.panelBackground)

      GenericModalFooter {
        Spacer(minLength: Spacing.sm)
        Button("Cancel") { isPresented = false }
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(isSaving)
        Button(action: save) {
          HStack(spacing: Spacing.sm) {
            if isSaving {
              ProgressView()
                .controlSize(.mini)
                .tint(.accent)
                .frame(width: 14, height: 14)
            }
            Text("Save")
          }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isSaving || trimmedName.isEmpty)
      }
    }
    .background(Color.cardBackground)
  }

  /// Width of the right sidebar the form opens in.
  static let panelWidth: CGFloat = 400

  private func browse() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.sqlWorkspace]
    panel.canCreateDirectories = true
    panel.directoryURL = fileURL.deletingLastPathComponent()
    panel.nameFieldStringValue = fileURL.lastPathComponent
    panel.prompt = "Choose"
    panel.message = "Choose a new location for this workspace file"

    Task { @MainActor in
      let response: NSApplication.ModalResponse
      if let window = NSApp.keyWindow {
        response = await panel.beginSheetModal(for: window)
      } else {
        response = panel.runModal()
      }
      guard response == .OK, let url = panel.url else { return }
      fileURL = url
    }
  }

  private func save() {
    guard !trimmedName.isEmpty, !isSaving else { return }
    isSaving = true
    errorMessage = nil
    let savedName = trimmedName
    let destination = fileURL
    Task { @MainActor in
      do {
        try await onSave(entry, savedName, destination)
        isSaving = false
        isPresented = false
      } catch {
        isSaving = false
        errorMessage = error.localizedDescription
      }
    }
  }
}
