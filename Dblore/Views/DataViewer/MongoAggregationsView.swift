//
//  MongoAggregationsView.swift
//  Dblore
//
//  Aggregations section of a MongoDB collection screen: the aggregation builder of the
//  collection (stages, Add Stage and per-stage previews from `AggregationBuilderBody`), with
//  Copy and Open in Query of the whole `aggregate`, and an AI button that builds the stages from a
//  prompt. Previews run read-only through the gate (`AggregationBuilderModel`), as in the builder
//  sheet.
//

import SwiftUI

struct MongoAggregationsView: View {
  let model: MongoCollectionModel
  /// Opens a new query tab holding the command; nil disables Open in Query
  var openQuery: ((String) -> Void)? = nil
  /// The workspace's autocomplete source, for field names in stage bodies; nil = no completion
  var fieldSource: SQLAutocompleteProvider? = nil
  var aiAssistant: AIAssistantViewModel? = nil

  @State private var selectedStage: AggregationBuilderModel.Stage.ID?

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
  }

  // MARK: - Header

  private func header(_ builder: AggregationBuilderModel) -> some View {
    HStack(spacing: Spacing.sm) {
      if let aiAssistant {
        MongoAIPipelineButton(assistant: aiAssistant, builder: builder, database: model.database)
      }
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
      Button("Copy") { builder.copy() }
        .buttonStyle(GhostButtonStyle())
        .disabled(builder.commandText == nil)
        .help("Copy the aggregate command")
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
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  private func stageCount(_ builder: AggregationBuilderModel) -> String {
    let count = builder.stages.count
    return count == 1 ? "1 stage" : "\(count) stages"
  }
}
