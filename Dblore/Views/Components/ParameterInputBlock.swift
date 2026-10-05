//
//  ParameterInputBlock.swift
//  Dblore
//
//  One :name parameter: its name, a NULL toggle, and the value field. Shared by the
//  editor sidebar and the cell parameter form so the storage rules stay identical.
//

import SwiftUI

/// A detected name stays out of storage until the user types or toggles NULL.
/// `onStore` receives the typed text, nil for NULL, or "" when NULL switches off.
struct ParameterInputBlock<Accessory: View>: View {
  let name: String
  let stored: QueryParameter?
  let onStore: (String?) -> Void
  let trailingAccessory: Accessory

  init(
    name: String,
    stored: QueryParameter?,
    onStore: @escaping (String?) -> Void,
    @ViewBuilder trailingAccessory: () -> Accessory
  ) {
    self.name = name
    self.stored = stored
    self.onStore = onStore
    self.trailingAccessory = trailingAccessory()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.xs) {
        Text(name)
          .font(.small)
          .foregroundColor(.foreground)
          .lineLimit(1)
        Spacer(minLength: Spacing.xs)
        Toggle("NULL", isOn: nullBinding)
          .font(.small)
          .foregroundColor(.foreground)
          .controlSize(.small)
          .fixedSize()
        trailingAccessory
      }

      TextField("", text: textBinding)
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
        .disabled(isStoredNull)
    }
  }

  private var isStoredNull: Bool {
    guard let stored else { return false }
    return stored.value == nil
  }

  private var textBinding: Binding<String> {
    Binding(
      get: { stored?.value ?? "" },
      set: { newValue in
        // Missing until the user types. A disabled NULL field must not write the name back.
        guard let stored else {
          guard !newValue.isEmpty else { return }
          onStore(newValue)
          return
        }
        guard stored.value != nil else { return }
        onStore(newValue)
      }
    )
  }

  private var nullBinding: Binding<Bool> {
    Binding(
      get: { isStoredNull },
      set: { isNull in
        // Off on a name that was never stored is not a user edit.
        if stored == nil && !isNull { return }
        onStore(isNull ? nil : "")
      }
    )
  }
}

extension ParameterInputBlock where Accessory == EmptyView {
  init(name: String, stored: QueryParameter?, onStore: @escaping (String?) -> Void) {
    self.init(name: name, stored: stored, onStore: onStore) { EmptyView() }
  }
}
