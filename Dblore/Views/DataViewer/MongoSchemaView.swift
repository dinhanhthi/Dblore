//
//  MongoSchemaView.swift
//  Dblore
//
//  Schema section of a MongoDB collection screen: an optional filter, Analyze (Cancel while
//  running), and one card per field of the analyzed document sample. The read and the analysis
//  run in `MongoCollectionModel`, off the main actor.
//

import SwiftUI

struct MongoSchemaView: View {
  @Bindable var model: MongoCollectionModel
  /// The workspace's autocomplete source, for field names of the collection
  let autocompleteSource: SQLAutocompleteProvider

  var body: some View {
    VStack(spacing: 0) {
      header
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color.appBackground)
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      // Top aligned: the button stays level with the first line as the field grows
      HStack(alignment: .top, spacing: Spacing.sm) {
        MongoQueryField(
          text: $model.schemaFilter,
          placeholder: #"Optional filter, e.g. {status: "active"}"#,
          autocompleteProvider: fieldCompletion,
          onSubmit: model.analyzeSchema
        )
        .inputStyle()
        if isAnalyzing {
          Button("Cancel", action: model.cancelSchemaAnalysis)
            .buttonStyle(SecondaryButtonStyle())
            .help("Stop the analysis")
            .frame(height: MongoQueryField.styledLineHeight)
        } else {
          Button("Analyze", action: model.analyzeSchema)
            .buttonStyle(PrimaryButtonStyle())
            .help("Read a document sample and list its fields")
            .frame(height: MongoQueryField.styledLineHeight)
        }
      }
      Text(status)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  private var fieldCompletion: SQLAutocompleteProvider {
    MongoDocumentAutocompleteProvider(
      collection: model.collection, mode: .filter, source: autocompleteSource)
  }

  private var isAnalyzing: Bool {
    if case .analyzing = model.schemaState { return true }
    return false
  }

  private var status: String {
    switch model.schemaState {
    case .idle, .failed:
      "Analyze a random sample of up to 1,000 documents to see field types and values."
    case .analyzing:
      "Reading a sample of up to 1,000 documents..."
    case .done(let report):
      "Based on a sample of \(report.sampleSize.formatted()) "
        + (report.sampleSize == 1 ? "document" : "documents")
    }
  }

  // MARK: - States

  @ViewBuilder
  private var content: some View {
    switch model.schemaState {
    case .idle:
      VStack(spacing: Spacing.sm) {
        Image(systemName: "chart.bar.doc.horizontal")
          .font(.system(size: 28))
          .foregroundColor(.foregroundSubtle)
        message("Field types, presence and common values of the sampled documents")
      }
    case .analyzing:
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        Text("Analyzing...")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
    case .failed(let text):
      failure(text)
    case .done(let report) where report.fields.isEmpty:
      message("No fields found")
    case .done(let report):
      ScrollView {
        LazyVStack(spacing: Spacing.sm) {
          ForEach(report.fields) { field in
            MongoSchemaFieldRow(field: field)
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.md)
      }
    }
  }

  private func message(_ text: String) -> some View {
    Text(text)
      .font(.small)
      .foregroundColor(.foregroundMuted)
  }

  private func failure(_ text: String) -> some View {
    VStack(spacing: Spacing.sm) {
      Text(text)
        .font(.system(size: 12, design: .monospaced))
        .foregroundColor(.destructive)
        .textSelection(.enabled)
        .multilineTextAlignment(.center)
      Button("Retry", action: model.analyzeSchema)
        .buttonStyle(SecondaryButtonStyle())
    }
    .padding(Spacing.md)
  }
}
