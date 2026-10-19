//
//  AggregationBuilderSheet.swift
//  Dblore
//
//  The aggregation builder of a MongoDB collection: the stages on the left (drag to reorder,
//  add, remove, switch off), the preview of the selected stage on the right (the pipeline up to
//  it, at most `previewLimit` documents, as a document tree), Insert / Copy of the whole
//  `aggregate`, and an AI button that builds the stages from a prompt.
//  Previews run read-only through the gate (`AggregationBuilderModel`); stages that write are
//  never previewed.
//

import SwiftUI

struct AggregationBuilderSheet: View {
  let model: AggregationBuilderModel
  /// The notebook Insert writes into; nil disables Insert
  let insertTarget: NotebookViewModel?
  /// Inserts the command in place of `insertTarget` (a builder opened on a cell), true when it
  /// did
  var onInsert: ((String) -> Bool)? = nil
  let onClose: () -> Void
  /// The workspace's autocomplete source, for field names in stage bodies; nil = no completion
  var fieldSource: SQLAutocompleteProvider? = nil
  /// The workspace's AI assistant behind the pipeline prompt; nil hides the AI button
  var aiAssistant: AIAssistantViewModel? = nil

  @State private var selectedStage: AggregationBuilderModel.Stage.ID?
  /// The last Insert inserted nothing: the sheet stays open with a message
  @State private var insertFailed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      AggregationBuilderBody(model: model, selectedStage: $selectedStage, fieldSource: fieldSource)
      Divider()
      footer
    }
    .frame(width: 860, height: 600)
    .background(Color.appBackground)
  }

  // MARK: - Header and footer

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
        Text("Aggregation")
          .font(.subheading)
          .foregroundColor(.foreground)
        Text(model.collection)
          .font(.monoMedium)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.middle)
          // Lift by half the x-height gap (15pt vs 12pt mono) so both share one optical center.
          .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] + 0.8 }
      }
      if let aiAssistant {
        MongoAIPipelineButton(assistant: aiAssistant, builder: model)
      }
      Spacer()
      Button(action: onClose) {
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
      Button("Copy") { model.copy() }
        .buttonStyle(GhostButtonStyle())
        .disabled(model.commandText == nil)
        .help("Copy the aggregate command")
      if model.commandText == nil {
        Text(
          model.pipeline(verb: "insert or copy").reason ?? "Fix the stage errors to insert or copy"
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
      } else if insertFailed {
        Text("Nothing was inserted: select a cell or open an editor")
          .font(.small)
          .foregroundColor(.destructive)
          .lineLimit(1)
      }
      Spacer()
      Button("Close", action: onClose)
        .buttonStyle(GhostButtonStyle())
        .keyboardShortcut(.cancelAction)
      Button("Insert", action: insert)
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.commandText == nil || !hasInsertTarget)
        .help(insertHelp)
    }
    .modalBarPadding()
  }

  /// A cell-opened builder inserts into its cell; otherwise the tab must have an editor or a
  /// selected cell (`canInsertText`: not a data viewer or markdown tab)
  private var hasInsertTarget: Bool {
    onInsert != nil || insertTarget?.canInsertText == true
  }

  private var insertHelp: String {
    if !hasInsertTarget { return "Open a notebook or editor to insert into" }
    if onInsert != nil {
      return "Replace the cell's aggregate, or add the command below it when the cell has comments"
    }
    return "Insert the aggregate command into the active cell, replacing the selection"
  }

  private func insert() {
    guard let text = model.commandText else { return }
    let inserted =
      if let onInsert { onInsert(text) } else {
        insertTarget.map { model.insert(into: $0) } ?? false
      }
    guard inserted else {
      insertFailed = true
      return
    }
    onClose()
  }
}
