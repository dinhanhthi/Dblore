//
//  AggregationBuilderSheet.swift
//  Dblore
//
//  The aggregation builder of a MongoDB collection: the stages on the left (drag to reorder,
//  add, remove, switch off), the preview of the selected stage on the right (the pipeline up to
//  it, at most 20 documents, as a document tree), and Insert / Copy of the whole `aggregate`.
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

  @State private var selectedStage: AggregationBuilderModel.Stage.ID?
  /// The last Insert inserted nothing: the sheet stays open with a message
  @State private var insertFailed = false

  /// Stable timestamp of every preview `CellResult`: the tree is rebuilt per preview command
  /// (`.id`), never per render
  private static let previewStamp = Date(timeIntervalSinceReferenceDate: 0)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      HStack(spacing: 0) {
        stagesPane
          .frame(width: 440)
        Divider()
        previewPane
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      footer
    }
    .frame(width: 860, height: 600)
    .background(Color.appBackground)
    .onAppear { selectedStage = selectedStage ?? model.stages.first?.id }
  }

  // MARK: - Header and footer

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Text("Aggregation")
        .font(.subheading)
        .foregroundColor(.foreground)
      Text(model.collection)
        .font(.monoMedium)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .truncationMode(.middle)
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
        Text("Fix the stage errors to insert or copy")
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

  // MARK: - Stages

  private var stagesPane: some View {
    VStack(spacing: 0) {
      if model.stages.isEmpty {
        Text("No stages. Add one to start the pipeline.")
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(selection: $selectedStage) {
          ForEach(Array(model.stages.enumerated()), id: \.element.id) { index, stage in
            AggregationStageRow(
              model: model, stage: stage, number: index + 1,
              onSelect: { selectedStage = stage.id }
            )
            .tag(stage.id)
          }
          .onMove { source, destination in
            model.move(fromOffsets: source, toOffset: destination)
          }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
      }
      Divider()
      HStack {
        Button {
          selectedStage = model.addStage()
        } label: {
          Label("Add Stage", systemImage: "plus")
        }
        .buttonStyle(GhostButtonStyle())
        Spacer()
      }
      .modalBarPadding(vertical: Spacing.xs)
    }
  }

  // MARK: - Preview

  private var selected: (index: Int, stage: AggregationBuilderModel.Stage)? {
    guard let selectedStage,
      let index = model.stages.firstIndex(where: { $0.id == selectedStage })
    else { return nil }
    return (index, model.stages[index])
  }

  @ViewBuilder
  private var previewPane: some View {
    if let selected {
      let state = model.previewState(for: selected.stage.id)
      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(spacing: Spacing.sm) {
          Text("Stage \(selected.index + 1)")
            .font(.labelText.weight(.semibold))
            .foregroundColor(.foreground)
          Text(selected.stage.operator)
            .font(.monoMedium)
            .foregroundColor(.foregroundMuted)
            .lineLimit(1)
          Spacer()
          Button("Preview") { model.preview(selected.stage.id) }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.previewCommand(for: selected.stage.id) == nil)
            .help("Run the pipeline up to this stage, read-only, at most 20 documents")
        }
        previewBody(state, command: model.previewCommand(for: selected.stage.id))
      }
      .padding(Spacing.md)
    } else {
      placeholder("Select a stage to preview it")
    }
  }

  @ViewBuilder
  private func previewBody(
    _ state: AggregationBuilderModel.PreviewState, command: String?
  ) -> some View {
    switch state {
    case .loading:
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        Text("Previewing...")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let result):
      Text(Self.countText(result))
        .font(.small)
        .foregroundColor(.foregroundMuted)
      DocumentTreeView(
        result: Self.cellResult(result, command: command), fillsAvailableHeight: true
      )
      .id(command)
      .background(Color.cardHeaderBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
      .overlay(
        HairlineBorder(
          shape: RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)))
    case .failed(let message):
      Text(message)
        .font(.small)
        .foregroundColor(.destructive)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    case .notRun:
      placeholder("Not previewed yet")
    case .disabled, .writesData, .invalid:
      placeholder(state.message ?? "")
    }
  }

  private func placeholder(_ text: String) -> some View {
    Text(text)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// "N documents", noting the preview limit when it was reached.
  static func countText(_ result: QueryResult) -> String {
    let count = result.rowCount
    let noun = count == 1 ? "document" : "documents"
    return count >= Int(AggregationBuilderModel.previewLimit)
      ? "\(count) \(noun) (preview limit)" : "\(count) \(noun)"
  }

  private static func cellResult(_ result: QueryResult, command: String?) -> CellResult {
    CellResult(
      columns: result.columns, rows: result.rows, executionTime: result.executionTime,
      rowCount: result.rowCount, timestamp: previewStamp, wasLimited: result.wasLimited,
      sourceQuery: command)
  }
}
