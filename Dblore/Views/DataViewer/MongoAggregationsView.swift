//
//  MongoAggregationsView.swift
//  Dblore
//
//  Aggregations section of a MongoDB collection screen: the aggregation builder of the
//  collection (stages, Add Stage and per-stage previews from `AggregationBuilderBody`), with
//  Copy, Explain, Export Code and Open in Query of the whole `aggregate`, and an AI button that
//  builds the stages from a prompt. Previews run read-only through the gate
//  (`AggregationBuilderModel`), as in the builder sheet.
//

import SwiftUI

struct MongoAggregationsView: View {
  let model: MongoCollectionModel
  /// Opens a new query tab holding the command; nil disables Open in Query
  var openQuery: ((String) -> Void)? = nil
  /// The workspace's autocomplete source, for field names in stage bodies; nil = no completion
  var fieldSource: SQLAutocompleteProvider? = nil
  /// Database the exported driver code connects to
  var database: String = MongoSession.defaultDatabase
  var aiAssistant: AIAssistantViewModel? = nil

  @State private var selectedStage: AggregationBuilderModel.Stage.ID?
  @State private var exportRequest: MongoExportCodeSheet.Request?

  var body: some View {
    VStack(spacing: 0) {
      if let builder = model.aggregationModel {
        header(builder)
        Divider()
        AggregationBuilderBody(
          model: builder, selectedStage: $selectedStage, fieldSource: fieldSource
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.appBackground)
    .sheet(item: $exportRequest) { request in
      MongoExportCodeSheet(request: request)
    }
  }

  // MARK: - Header

  private func header(_ builder: AggregationBuilderModel) -> some View {
    HStack(spacing: Spacing.sm) {
      Text(stageCount(builder))
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
      if builder.commandText == nil {
        Text("Fix the stage errors to copy or open in a query")
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
      }
      Spacer(minLength: Spacing.sm)
      // Tighter than the row: the buttons carry their own padding
      HStack(spacing: Spacing.xs) {
        if let aiAssistant {
          MongoAIPipelineButton(
            assistant: aiAssistant, builder: builder, database: model.database)
        }
        Button("Copy") { builder.copy() }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(builder.commandText == nil)
          .help("Copy the aggregate command")
        explainButton(builder)
        exportButton(builder)
        Button("Open in Query") {
          guard let text = builder.commandText else { return }
          openQuery?(text)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(builder.commandText == nil || openQuery == nil)
        .help(
          builder.commandText == nil
            ? "Fix the stage errors to open the aggregate in a query"
            : "Open the aggregate command in a new query tab")
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  // MARK: - Explain

  /// Explains the enabled stages as one `aggregate` (the sheet is in `DataViewerView`)
  private func explainButton(_ builder: AggregationBuilderModel) -> some View {
    let target = builder.explainTarget
    return Button("Explain") {
      guard case .success(let command) = target else { return }
      model.explain(command)
    }
    .buttonStyle(SecondaryButtonStyle())
    .disabled(target.command == nil || model.explainState == .running)
    .help(target.reason ?? "Explain the pipeline with execution statistics")
  }

  // MARK: - Export Code

  /// Opens the driver code of the enabled stages as one `aggregate`; `$out` and `$merge` export
  /// too, since nothing runs
  private func exportButton(_ builder: AggregationBuilderModel) -> some View {
    let target = builder.pipeline(verb: "export")
    return Button("Export Code") {
      guard case .success(let command) = target else { return }
      exportRequest = MongoExportCodeSheet.Request(command: command, database: database)
    }
    .buttonStyle(SecondaryButtonStyle())
    .disabled(target.command == nil)
    .help(target.reason ?? "Export the pipeline as driver code")
  }

  private func stageCount(_ builder: AggregationBuilderModel) -> String {
    let count = builder.stages.count
    return count == 1 ? "1 stage" : "\(count) stages"
  }
}
