//
//  MongoDocumentEditorSheet.swift
//  Dblore
//
//  MongoDB document editor of the data viewer, presented from
//  `DataViewerState.pendingDocumentEditor`: a whole document (+ Row, Insert, Duplicate, which may
//  hold an array of documents, or a staged insert) or one non-primitive field of a stored
//  document, in mongosh notation with mongosh highlighting. Stage hands the text to
//  `applyDocumentEditor`; a parse or staging error keeps the sheet open and shows inline.
//

import AppKit
import SwiftUI

struct MongoDocumentEditorSheet: View {
  @Bindable var viewModel: NotebookViewModel
  let request: DataViewerState.DocumentEditorRequest

  @State private var text: String
  @State private var error: DataViewerState.DocumentEditorError?
  /// `applyDocumentEditor` is running: Stage stays disabled so it runs once
  @State private var isApplying = false
  @State private var textViewRef: SQLTextView?
  @State private var isEmpty = false

  /// Fixed editor height: no measured height drives the sheet's frame
  private static let editorHeight: CGFloat = 300

  init(viewModel: NotebookViewModel, request: DataViewerState.DocumentEditorRequest) {
    self.viewModel = viewModel
    self.request = request
    self._text = State(initialValue: request.text)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      VStack(alignment: .leading, spacing: Spacing.sm) {
        editor
        status
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Divider()
      footer
    }
    .frame(width: 600, height: 460)
    .background(Color.appBackground)
  }

  // MARK: - Header and footer

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Text(title)
        .font(.subheading)
        .foregroundColor(.foreground)
      Text(subtitle)
        .font(.monoMedium)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      Button(action: cancel) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Close")
    }
    .modalBarPadding(vertical: Spacing.sm)
  }

  private var footer: some View {
    HStack(spacing: Spacing.sm) {
      Text(hint)
        .font(.small)
        .foregroundColor(.foregroundSubtle)
        .lineLimit(1)
      Spacer()
      Button("Cancel", action: cancel)
        .buttonStyle(GhostButtonStyle())
        .keyboardShortcut(.cancelAction)
      Button(stageTitle, action: stage)
        .buttonStyle(PrimaryButtonStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(isApplying || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help(stageHelp)
    }
    .modalBarPadding()
  }

  // MARK: - Editor

  private var editor: some View {
    HighlightedTextEditor(
      text: $text,
      textViewRef: $textViewRef,
      isEmpty: $isEmpty,
      maxHeight: Self.editorHeight,
      dialect: .mongodb
    )
    .padding(Spacing.xs)
    .background(Color.inputBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
    .overlay(
      HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)))
  }

  @ViewBuilder
  private var status: some View {
    if let error {
      Text(error.message)
        .font(.small)
        .foregroundColor(.destructive)
        .lineLimit(3)
        .textSelection(.enabled)
    }
  }

  // MARK: - Wording

  private var title: String {
    switch request.kind {
    case .insert: "Insert Document"
    case .replaceInsert: "Edit Staged Document"
    case .value: "Edit Field"
    }
  }

  /// The edited field, else the collection
  private var subtitle: String {
    if case .value(_, let column) = request.kind { return column }
    return viewModel.dataViewer?.name ?? ""
  }

  private var hint: String {
    switch request.kind {
    case .insert: "A document, or an array of documents. mongosh notation."
    case .replaceInsert: "Replaces the staged document. mongosh notation."
    case .value: "The new value of the field. mongosh notation."
    }
  }

  /// A field edit is sent at once (one `$set`); documents are staged until Commit.
  private var stageTitle: String {
    if case .value = request.kind { return "Apply" }
    return "Stage"
  }

  private var stageHelp: String {
    if case .value = request.kind { return "Send this value to the database (⌘↩)" }
    return "Stage until Commit (⌘↩)"
  }

  // MARK: - Actions

  private func cancel() {
    viewModel.dataViewer?.pendingDocumentEditor = nil
  }

  /// Applied: the view model clears `pendingDocumentEditor` and the sheet closes. Refused: the
  /// sheet stays with the error, the caret at the parser's offset when there is one.
  private func stage() {
    guard !isApplying else { return }
    isApplying = true
    error = nil
    let submitted = text
    Task {
      let failure = await viewModel.applyDocumentEditor(submitted)
      isApplying = false
      error = failure
      if let offset = failure?.offset { placeCaret(at: offset) }
    }
  }

  /// `offset` counts UTF-16 units, like `NSRange`
  private func placeCaret(at offset: Int) {
    guard let textView = textViewRef else { return }
    let length = (textView.string as NSString).length
    let range = NSRange(location: min(max(0, offset), length), length: 0)
    textView.window?.makeFirstResponder(textView)
    textView.setSelectedRange(range)
    textView.scrollRangeToVisible(range)
  }
}
