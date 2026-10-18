//
//  RenameObjectSheet.swift
//  Dblore
//
//  Rename form for a database object (a `GenericModal`, presented with `modalOverlay`): the
//  current name, a field for the new one and why it cannot be used. Engine-neutral: the caller
//  checks names, sends the command and shows its progress through `isBusy` and `errorText`, and
//  closes the form once the rename is done (this view never closes itself after Rename).
//

import SwiftUI

struct RenameObjectSheet: View {
  /// e.g. "Rename Collection"
  let title: String
  let currentName: String
  /// Why a new name (trimmed) cannot be used, nil when it can
  let validate: (String) -> String?
  /// The rename is being confirmed or sent: Rename waits
  var isBusy = false
  /// The last failure, shown under the field
  var errorText: String?
  /// Gets the trimmed new name
  let onRename: (String) -> Void
  @Binding var isPresented: Bool

  @State private var newName: String
  @FocusState private var isFieldFocused: Bool

  private static let width: CGFloat = 460
  private static let height: CGFloat = 280
  private static let labelWidth: CGFloat = 90

  init(
    title: String, currentName: String, validate: @escaping (String) -> String?,
    isBusy: Bool = false, errorText: String? = nil, onRename: @escaping (String) -> Void,
    isPresented: Binding<Bool>
  ) {
    self.title = title
    self.currentName = currentName
    self.validate = validate
    self.isBusy = isBusy
    self.errorText = errorText
    self.onRename = onRename
    _isPresented = isPresented
    _newName = State(initialValue: currentName)
  }

  private var trimmedName: String {
    newName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Nothing to report while the name is unchanged
  private var problem: String? {
    trimmedName == currentName ? nil : validate(trimmedName)
  }

  private var canRename: Bool {
    !isBusy && trimmedName != currentName && validate(trimmedName) == nil
  }

  var body: some View {
    GenericModal(
      title: title, titleIcon: "pencil", width: Self.width, height: Self.height,
      isPresented: $isPresented
    ) {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        Grid(alignment: .leading, horizontalSpacing: Spacing.sm, verticalSpacing: Spacing.sm) {
          GridRow(alignment: .center) {
            label("Current name")
            Text(verbatim: currentName)
              .font(.monoMedium)
              .foregroundColor(.foreground)
              .textSelection(.enabled)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          GridRow(alignment: .center) {
            label("New name")
            TextField("Name", text: $newName)
              .font(.monoMedium)
              .textFieldStyle(.plain)
              .autocorrectionDisabled()
              .inputCapsuleStyle()
              .focused($isFieldFocused)
              .onSubmit(rename)
          }
        }
        if let message = problem ?? errorText {
          Text(message)
            .font(.small)
            .foregroundColor(.destructive)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } footer: {
      GenericModalFooter {
        if isBusy {
          ProgressView().controlSize(.small)
        }
        Spacer()
        Button("Cancel") { isPresented = false }
          .buttonStyle(FilledSecondaryButtonStyle())
        Button("Rename", action: rename)
          .buttonStyle(PrimaryButtonStyle())
          .disabled(!canRename)
      }
    }
    .onAppear {
      // Deferred: focus set during the first layout pass of a sheet is dropped
      DispatchQueue.main.async { isFieldFocused = true }
    }
  }

  private func label(_ title: String) -> some View {
    Text(title)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .frame(width: Self.labelWidth, alignment: .leading)
  }

  private func rename() {
    guard canRename else { return }
    onRename(trimmedName)
  }
}
