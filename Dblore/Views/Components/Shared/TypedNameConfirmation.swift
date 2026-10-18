//
//  TypedNameConfirmation.swift
//  Dblore
//
//  Typed-name step of a destructive action (drop an index, a collection, a table): the
//  destructive button stays disabled until the user types the object's exact name.
//

import SwiftUI

/// Shows the exact name of the object (selectable, to copy it) and a field to type it.
/// Engine-neutral: the caller passes the object kind as display text.
struct TypedNameConfirmation: View {
  /// Display text, e.g. "index", "collection", "table"
  let objectKind: String
  let name: String
  /// Title of the destructive button, e.g. "Drop Index"
  let confirmTitle: String
  let onCancel: () -> Void
  /// Gets the typed text, for the caller to check again before it sends anything
  let onConfirm: (String) -> Void

  @State private var typed = ""
  @FocusState private var isFieldFocused: Bool

  /// Exact and case-sensitive; whitespace around the typed text is ignored. The name is
  /// trimmed too so a name with surrounding spaces can still be confirmed, and an empty
  /// entry never matches.
  nonisolated static func matches(_ typed: String, name: String) -> Bool {
    let entry = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    return !entry.isEmpty && entry == name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isMatching: Bool { Self.matches(typed, name: name) }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundColor(.destructive)
        Text("This cannot be undone")
          .font(.subheading)
          .foregroundColor(.foreground)
      }

      Text("Type the name of the \(objectKind) to confirm:")
        .font(.labelText)
        .foregroundColor(.foregroundMuted)

      Text(name)
        .font(.mono)
        .foregroundColor(.foreground)
        .textSelection(.enabled)
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
        .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))

      TextField("Name", text: $typed)
        .font(.mono)
        .textFieldStyle(.plain)
        .autocorrectionDisabled()
        .inputCapsuleStyle()
        .focused($isFieldFocused)
        .onSubmit(confirm)

      HStack(spacing: Spacing.md) {
        Spacer()
        Button("Cancel", action: onCancel)
          .buttonStyle(FilledSecondaryButtonStyle())
        Button(confirmTitle, action: confirm)
          .buttonStyle(DangerButtonStyle())
          .disabled(!isMatching)
      }
    }
    .padding(Spacing.md)
    .onAppear {
      // Deferred: focus set during the first layout pass of a sheet is dropped
      DispatchQueue.main.async { isFieldFocused = true }
    }
  }

  private func confirm() {
    guard isMatching else { return }
    onConfirm(typed)
  }
}
