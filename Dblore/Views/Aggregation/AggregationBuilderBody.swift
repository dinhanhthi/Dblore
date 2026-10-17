//
//  AggregationBuilderBody.swift
//  Dblore
//
//  The panes of the aggregation builder, shared by the sheet and the collection tab: the stages
//  on the left (drag to reorder, add, remove, switch off) and the preview of the selected stage
//  on the right (the pipeline up to it, at most 20 documents, as a document tree). The host
//  owns the selection and its own chrome (title, Insert / Copy / Open in Query).
//

import SwiftUI

struct AggregationBuilderBody: View {
  let model: AggregationBuilderModel
  /// The stage shown in the preview pane; set to the first stage on appear when nil, and when
  /// the stages change without it (AI replaced them, or it was removed)
  @Binding var selectedStage: AggregationBuilderModel.Stage.ID?
  /// The workspace's autocomplete source, for field names in stage bodies; nil = no completion
  var fieldSource: SQLAutocompleteProvider? = nil

  /// Stable timestamp of every preview `CellResult`: the tree is rebuilt per preview command
  /// (`.id`), never per render
  private static let previewStamp = Date(timeIntervalSinceReferenceDate: 0)

  var body: some View {
    HStack(spacing: 0) {
      stagesPane
        .frame(width: 440)
      Divider()
      previewPane
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear { selectedStage = selectedStage ?? model.stages.first?.id }
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
              onSelect: { selectedStage = stage.id }, fieldSource: fieldSource
            )
            .contentShape(Rectangle())
            .onTapGesture { selectedStage = stage.id }
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
