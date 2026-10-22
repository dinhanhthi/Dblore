//
//  SQLSnippetsSettings.swift
//  Dblore
//
//  Settings > Editor: the SQL snippets of the editor, with add, edit, delete and a preview.
//

import SwiftUI

struct SQLSnippetsCard: View {
  private let store = SQLSnippetStore.shared

  /// The snippet in the editor: a new one (id not in the list) or a copy of a saved one
  @State private var editing: SQLSnippet?
  @State private var pendingDelete: SQLSnippet?

  private var snippets: [SQLSnippet] { store.snippets }
  private var isFull: Bool { snippets.count >= SQLSnippet.maxSnippets }

  var body: some View {
    SettingsGroupCard(title: "Snippets") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        helpText(
          "Type a trigger in a SQL editor and accept it from autocomplete to insert the snippet. Tab and Shift-Tab move between its tab stops."
        )
        helpText(
          "In the body: ${1:default} is tab stop 1 with its default text, ${1} an empty tab stop, $0 where the caret ends, \\$ a literal dollar sign."
        )
        if !snippets.isEmpty {
          Divider()
          ForEach(snippets) { snippet in
            row(snippet)
          }
        }
        Divider()
        if let editing {
          SQLSnippetEditor(
            snippet: editing, snippets: snippets,
            onSave: { snippet throws(SQLSnippet.ValidationError) in try store.save(snippet) },
            onDone: { self.editing = nil })
        } else {
          HStack(spacing: Spacing.md) {
            Button("Add snippet") { editing = SQLSnippet(name: "", trigger: "", body: "") }
              .buttonStyle(FilledSecondaryButtonStyle())
              .disabled(isFull)
              .linkPointer()
            if isFull {
              helpText(SQLSnippet.ValidationError.tooManySnippets.message)
            }
          }
        }
      }
    }
    .confirmationDialog(
      "Delete \(pendingDelete?.name ?? "")?",
      isPresented: Binding(
        get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      titleVisibility: .visible,
      presenting: pendingDelete
    ) { snippet in
      Button("Delete", role: .destructive) { store.delete(id: snippet.id) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("The snippet and its body are removed.")
    }
  }

  private func row(_ snippet: SQLSnippet) -> some View {
    HStack(alignment: .center, spacing: Spacing.sm) {
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(verbatim: snippet.name)
          .font(.bodyText)
          .foregroundColor(.foreground)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(verbatim: snippet.trigger)
          .font(.mono)
          .foregroundColor(.foregroundSubtle)
          .lineLimit(1)
      }
      Spacer(minLength: Spacing.sm)
      Button("Edit") { editing = snippet }
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(editing != nil)
        .linkPointer()
      Button("Delete") { pendingDelete = snippet }
        .buttonStyle(DangerButtonStyle())
        .disabled(editing != nil)
        .linkPointer()
    }
  }

  private func helpText(_ text: String) -> some View {
    Text(verbatim: text)
      .font(.bodyText)
      .foregroundColor(.foregroundSubtle)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Name, trigger and body fields of one snippet, with its validation message, a preview and Save
private struct SQLSnippetEditor: View {
  let snippets: [SQLSnippet]
  let onSave: (SQLSnippet) throws(SQLSnippet.ValidationError) -> Void
  let onDone: () -> Void

  @State private var snippet: SQLSnippet
  /// Why the last Save was refused, cleared on the next edit
  @State private var saveError: SQLSnippet.ValidationError?

  init(
    snippet: SQLSnippet, snippets: [SQLSnippet],
    onSave: @escaping (SQLSnippet) throws(SQLSnippet.ValidationError) -> Void,
    onDone: @escaping () -> Void
  ) {
    self.snippets = snippets
    self.onSave = onSave
    self.onDone = onDone
    _snippet = State(initialValue: snippet)
  }

  private var error: SQLSnippet.ValidationError? {
    SQLSnippet.validate(snippet, among: snippets)
  }

  /// An untouched new snippet shows no error yet
  private var shownError: SQLSnippet.ValidationError? {
    if let saveError { return saveError }
    return snippet.name.isEmpty && snippet.trigger.isEmpty && snippet.body.isEmpty ? nil : error
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      label("Name")
      TextField("Select with filter", text: $snippet.name)
        .textFieldStyle(.plain)
        .font(.bodyText)
        .inputStyle()
      label("Trigger")
      TextField("sel", text: $snippet.trigger)
        .textFieldStyle(.plain)
        .font(.mono)
        .autocorrectionDisabled()
        .inputStyle()
      label("Body")
      // Plain: smart quotes and dashes would corrupt the SQL
      PlainTextEditor(text: $snippet.body)
        .frame(height: 96)
        .textAreaCapsuleStyle()
      Text(verbatim: counterText)
        .font(.small)
        .monospacedDigit()
        .foregroundColor(
          snippet.body.count > SQLSnippet.maxBodyChars ? .destructive : .foregroundMuted
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
      if !snippet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        label("Preview")
        Text(verbatim: Self.preview(of: snippet.body))
          .font(.mono)
          .foregroundColor(.foreground)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textAreaCapsuleStyle()
        Text(verbatim: "[1], [2], … mark the tab stops in order; [0] is where the caret ends.")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
      if let shownError {
        Text(verbatim: shownError.message)
          .font(.bodyText)
          .foregroundColor(.destructive)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: Spacing.sm) {
        Spacer()
        Button("Cancel", action: onDone)
          .buttonStyle(FilledSecondaryButtonStyle())
          .linkPointer()
        Button("Save", action: save)
          .buttonStyle(PrimaryButtonStyle())
          .disabled(error != nil)
          .linkPointer()
      }
    }
    .onChange(of: snippet) { saveError = nil }
  }

  private func save() {
    do {
      try onSave(snippet)
      onDone()
    } catch {
      saveError = error
    }
  }

  /// The expanded body with `[n]` before each tab stop, in visiting order, and `[0]` at the caret
  static func preview(of body: String) -> String {
    let expansion = SQLSnippet.expand(body)
    let count = expansion.stops.count
    let marks = expansion.stops.enumerated().map { order, range in
      (location: range.location, order: order, label: order == count - 1 ? "[0]" : "[\(order + 1)]")
    }
    // Last offset first, so an insertion never shifts one still to come; at one offset the later
    // stop goes in first, so `${1}${2}` reads [1][2]
    let text = NSMutableString(string: expansion.text)
    for mark in marks.sorted(by: {
      $0.location != $1.location ? $0.location > $1.location : $0.order > $1.order
    }) {
      text.insert(mark.label, at: mark.location)
    }
    return text as String
  }

  /// "n / 4,000"
  private var counterText: String {
    let locale = Locale(identifier: "en_US")
    return "\(snippet.body.count.formatted(.number.locale(locale))) / "
      + SQLSnippet.maxBodyChars.formatted(.number.locale(locale))
  }

  private func label(_ text: String) -> some View {
    Text(verbatim: text)
      .font(.bodyText)
      .foregroundColor(.foregroundMuted)
  }
}
