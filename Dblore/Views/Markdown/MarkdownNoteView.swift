//
//  MarkdownNoteView.swift
//  Dblore
//
//  A Markdown note tab: plain text editing of the note source (code mode) or the
//  editable Milkdown preview, toggled from the header.
//

import SwiftUI

struct MarkdownNoteView: View {
  @Bindable var viewModel: NotebookViewModel
  /// Created the first time preview turns on, so code-only notes never start a web view
  @State private var preview: MarkdownPreviewController?
  /// Mode on screen. Lags `isMarkdownPreview` when leaving preview until its text is flushed.
  @State private var isShowingPreview = false

  var body: some View {
    ZStack {
      if isShowingPreview, let preview {
        MarkdownPreviewView(controller: preview)
          .overlay {
            if preview.didFail {
              Text("Preview unavailable")
                .font(.small)
                .foregroundStyle(Color.foregroundMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)
            } else if !preview.isReady {
              ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)
            }
          }
      } else {
        PlainTextEditor(text: text)
          .padding(Spacing.md)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.appBackground)
    .task(id: viewModel.isMarkdownPreview) {
      await switchMode()
    }
    .onDisappear {
      viewModel.flushMarkdownPreview = nil
      preview?.detach()
    }
  }

  /// Writes the note text and marks the tab dirty only on a real change, like a .sql tab
  private var text: Binding<String> {
    Binding(
      get: { viewModel.editorContent },
      set: { [viewModel] in Self.apply($0, to: viewModel) }
    )
  }

  private static func apply(_ newValue: String, to viewModel: NotebookViewModel) {
    guard newValue != viewModel.editorContent else { return }
    viewModel.editorContent = newValue
    viewModel.onDocumentChanged?()
  }

  /// Shows the note in the preview, or flushes the preview's last edits before showing code.
  /// Closures handed to the controller and view model capture the view model and a weak
  /// controller, never this view, so neither keeps the other (and the web view) alive.
  private func switchMode() async {
    if viewModel.isMarkdownPreview {
      let controller = preview ?? MarkdownPreviewController()
      preview = controller
      controller.show(source: viewModel.editorContent) { [viewModel] text in
        Self.apply(text, to: viewModel)
      }
      viewModel.flushMarkdownPreview = { [weak viewModel, weak controller] in
        guard let viewModel, let text = await controller?.currentText() else { return }
        Self.apply(text, to: viewModel)
      }
      isShowingPreview = true
    } else if isShowingPreview {
      await viewModel.flushMarkdownPreview?()
      guard !Task.isCancelled else { return }
      viewModel.flushMarkdownPreview = nil
      isShowingPreview = false
    }
  }
}
