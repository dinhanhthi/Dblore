//
//  MarkdownNoteView.swift
//  Dblore
//
//  Code mode for a Markdown note tab: plain text editing of the note source.
//

import SwiftUI

struct MarkdownNoteView: View {
  @Bindable var viewModel: NotebookViewModel

  var body: some View {
    PlainTextEditor(text: text)
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.appBackground)
  }

  /// Writes the note text and marks the tab dirty only on a real change, like a .sql tab
  private var text: Binding<String> {
    Binding(
      get: { viewModel.editorContent },
      set: { newValue in
        guard newValue != viewModel.editorContent else { return }
        viewModel.editorContent = newValue
        viewModel.onDocumentChanged?()
      }
    )
  }
}
