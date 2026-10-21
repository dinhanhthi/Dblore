//
//  AggregationBuilderBody.swift
//  Dblore
//
//  The panes of the aggregation builder, shared by the sheet and the collection tab: the stages
//  on the left (drag to reorder, add, remove, switch off), or the pipeline as text in Text mode,
//  and on the right the preview of the selected stage (the pipeline up to it, at most
//  `previewLimit` documents, as a document tree) or the results of the last Run. The host owns
//  the selection, the mode, Run and its own chrome (title, Insert / Copy / Open in Query).
//

import SwiftUI

struct AggregationBuilderBody: View {
  @Bindable var model: AggregationBuilderModel
  /// The stage shown in the preview pane; set to the first stage on appear when nil, and when
  /// the stages change without it (AI replaced them, or it was removed)
  @Binding var selectedStage: AggregationBuilderModel.Stage.ID?
  /// The workspace's autocomplete source, for field names in stage bodies; nil = no completion
  var fieldSource: SQLAutocompleteProvider? = nil

  /// The Text pane's editor and whether it is empty, as `HighlightedTextEditor` reports them
  @State private var textViewRef: SQLTextView?
  @State private var isTextEmpty = false

  /// Stable timestamp of every preview `CellResult`: the tree is rebuilt per preview command
  /// (`.id`), never per render
  private static let previewStamp = Date(timeIntervalSinceReferenceDate: 0)

  var body: some View {
    HStack(spacing: 0) {
      Group {
        if model.editMode == .text {
          textPane
        } else {
          stagesPane
        }
      }
      .frame(width: 440)
      Divider()
      resultsPane
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear {
      if selectedStage.map({ id in !model.stages.contains { $0.id == id } }) ?? true {
        selectedStage = model.stages.first?.id
      }
    }
    .onChange(of: model.stages.map(\.id)) { _, ids in
      if selectedStage.map({ !ids.contains($0) }) ?? true {
        selectedStage = ids.first
      }
    }
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
        // No List selection: its accent highlight is too loud behind the editors, so the selected
        // stage gets a light neutral fill instead
        List {
          ForEach(Array(model.stages.enumerated()), id: \.element.id) { index, stage in
            AggregationStageRow(
              model: model, stage: stage, number: index + 1,
              onSelect: { select(stage.id) }, fieldSource: fieldSource
            )
            .contentShape(Rectangle())
            .onTapGesture { select(stage.id) }
            .listRowBackground(
              RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                .fill(selectedStage == stage.id ? Color.hoverFill : Color.clear)
                .padding(.horizontal, Spacing.sm)
            )
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
          select(model.addStage())
        } label: {
          Label("Add Stage", systemImage: "plus")
        }
        .buttonStyle(GhostButtonStyle())
        Spacer()
      }
      .modalBarPadding(vertical: Spacing.xs)
    }
  }

  /// Selects a stage and shows its preview instead of the run results
  private func select(_ id: AggregationBuilderModel.Stage.ID) {
    selectedStage = id
    model.showsRunResults = false
  }

  // MARK: - Text

  /// The whole pipeline as editable text. Rebuilt per model: the editor keeps the binding it
  /// was made with.
  private var textPane: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // Highlighted as mongosh, like the stage bodies; the editor takes a fixed height, so it
      // gets the pane's
      GeometryReader { geometry in
        HighlightedTextEditor(
          text: $model.pipelineText,
          textViewRef: $textViewRef,
          isEmpty: $isTextEmpty,
          maxHeight: max(geometry.size.height - Spacing.xs * 2, 0),
          dialect: .mongodb,
          mongoQueryEditing: true
        )
        .padding(Spacing.xs)
      }
      .id(ObjectIdentifier(model))
      // Format goes through the editor, so it is undoable as in the SQL editor
      .overlay(alignment: .bottomTrailing) {
        FormatSQLButton(help: "Format the pipeline") {
          guard let text = model.format() else { return }
          if let textViewRef {
            textViewRef.replaceDocument(with: text)
          } else {
            model.pipelineText = text
          }
        }
        .padding(Spacing.sm)
      }
      .background(Color.inputBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
      .overlay(
        HairlineBorder(
          shape: RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)))
      Text("Disabled stages are kept as // lines")
        .font(.small)
        .foregroundColor(.foregroundMuted)
      if let error = model.textError {
        Text(error)
          .font(.small)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
      }
    }
    .padding(Spacing.md)
  }

  // MARK: - Preview

  /// The run results while shown, else the stage preview (none in Text mode)
  @ViewBuilder
  private var resultsPane: some View {
    if model.showsRunResults {
      runPane
    } else if model.editMode == .text {
      placeholder("Run the pipeline to see its results")
    } else {
      previewPane
    }
  }

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
          Button("Preview") {
            model.showsRunResults = false
            model.preview(selected.stage.id)
          }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(model.previewCommand(for: selected.stage.id) == nil)
          .help(
            "Run the pipeline up to this stage, read-only, at most \(model.previewLimit) documents")
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
      Text(Self.countText(result, limit: model.previewLimit))
        .font(.small)
        .foregroundColor(.foregroundMuted)
      documentTree(result, command: command)
    case .failed(let message):
      failure(message)
    case .notRun:
      placeholder("Not previewed yet")
    case .disabled, .writesData, .invalid:
      placeholder(state.message ?? "")
    }
  }

  // MARK: - Run results

  /// The last Run of the whole pipeline; the tree is rebuilt per run, since `.running` replaces
  /// it in between
  private var runPane: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Pipeline results")
        .font(.labelText.weight(.semibold))
        .foregroundColor(.foreground)
      switch model.runState {
      case .running:
        HStack(spacing: Spacing.sm) {
          ProgressView().controlSize(.small)
          Text("Running...")
            .font(.small)
            .foregroundColor(.foregroundMuted)
          Button("Cancel") { model.cancelRun() }
            .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .done(let result, let command):
        // Read once: in Text mode it re-parses the text
        let current = model.commandText
        HStack(spacing: Spacing.sm) {
          Text(Self.runCountText(result))
          if current != command {
            Text("The pipeline changed since this run")
          }
        }
        .font(.small)
        .foregroundColor(.foregroundMuted)
        documentTree(result, command: command)
      case .failed(let message):
        failure(message)
      case .idle:
        placeholder("Run the pipeline to see its results")
      }
    }
    .padding(Spacing.md)
  }

  // MARK: - Shared

  private func documentTree(_ result: QueryResult, command: String?) -> some View {
    DocumentTreeView(
      result: Self.cellResult(result, command: command), fillsAvailableHeight: true
    )
    .id(command)
    .background(Color.cardHeaderBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
    .overlay(
      HairlineBorder(
        shape: RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)))
  }

  private func failure(_ message: String) -> some View {
    Text(message)
      .font(.small)
      .foregroundColor(.destructive)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func placeholder(_ text: String) -> some View {
    Text(text)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// "N documents", noting the preview limit `limit` when it was reached.
  static func countText(_ result: QueryResult, limit: Int) -> String {
    let count = result.rowCount
    let noun = count == 1 ? "document" : "documents"
    return count >= limit
      ? "\(count) \(noun) (preview limit)" : "\(count) \(noun)"
  }

  /// "N documents", noting the run limit when it cut the result.
  private static func runCountText(_ result: QueryResult) -> String {
    let count = result.rowCount
    let noun = count == 1 ? "document" : "documents"
    return result.wasLimited ? "\(count) \(noun) (run limit)" : "\(count) \(noun)"
  }

  private static func cellResult(_ result: QueryResult, command: String?) -> CellResult {
    CellResult(
      columns: result.columns, rows: result.rows, executionTime: result.executionTime,
      rowCount: result.rowCount, timestamp: previewStamp, wasLimited: result.wasLimited,
      sourceQuery: command)
  }
}
