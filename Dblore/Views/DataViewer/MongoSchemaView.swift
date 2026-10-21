//
//  MongoSchemaView.swift
//  Dblore
//
//  Schema section of a MongoDB collection screen: an optional filter, Analyze (Cancel while
//  running), and one card per field of the analyzed document sample. The read and the analysis
//  run in `MongoCollectionModel`, off the main actor. Clicks on a field's types and top values
//  edit the filter; Show Documents applies it to the Documents section; Export Schema copies or
//  saves the report as JSON Schema or as a MongoDB `$jsonSchema` validator.
//

import SwiftUI

struct MongoSchemaView: View {
  @Bindable var model: MongoCollectionModel
  /// The workspace's autocomplete source, for field names of the collection
  let autocompleteSource: SQLAutocompleteProvider
  /// Applies the filter text to the Documents section; returns its parse error (nothing applied)
  let showDocuments: (String) async -> DataViewerState.DocumentFilterError?

  /// A click or Show Documents that failed (the filter text does not parse, ...)
  @State private var actionError: String?
  @State private var isShowingDocuments = false

  var body: some View {
    VStack(spacing: 0) {
      header
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color.appBackground)
    .onChange(of: model.schemaFilter) { actionError = nil }
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
        Button("Show Documents", action: applyToDocuments)
          .buttonStyle(SecondaryButtonStyle())
          .disabled(isFilterBlank || isShowingDocuments)
          .help("Apply this filter in the Documents section")
          .frame(height: MongoQueryField.styledLineHeight)
        if case .done(let report) = model.schemaState {
          exportMenu(report)
            .frame(height: MongoQueryField.styledLineHeight)
        }
      }
      Text(status)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
      if let actionError {
        Text(actionError)
          .font(.small)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  private var isFilterBlank: Bool {
    model.schemaFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func applyToDocuments() {
    isShowingDocuments = true
    Task { @MainActor in
      defer { isShowingDocuments = false }
      if let error = await showDocuments(model.schemaFilter) {
        actionError = error.localizedDescription
      } else {
        model.section = .documents
      }
    }
  }

  /// The clicked condition applied to the filter text
  private func applyFilter(_ condition: MongoSchemaFilter.Condition, adding: Bool) {
    do {
      model.schemaFilter = try MongoSchemaFilter.apply(
        condition, to: model.schemaFilter, adding: adding)
      actionError = nil
    } catch {
      actionError = error.localizedDescription
    }
  }

  // MARK: - Export

  /// Copy or save the report in both formats. A custom ButtonStyle is ignored on a Menu: the
  /// label has `SecondaryButtonStyle`'s size and border, without its hover fill.
  private func exportMenu(_ report: MongoSchemaAnalyzer.Report) -> some View {
    Menu {
      Button("Copy JSON Schema") { copy(MongoSchemaExport.jsonSchema(report)) }
      Button("Copy MongoDB $jsonSchema") { copy(Self.validator(report)) }
      Divider()
      Button("Save JSON Schema…") {
        save(MongoSchemaExport.jsonSchema(report), as: "\(model.collection).schema.json")
      }
      Button("Save MongoDB $jsonSchema…") {
        save(Self.validator(report), as: "\(model.collection).jsonschema.json")
      }
    } label: {
      Label("Export Schema", systemImage: "square.and.arrow.up")
        .font(ButtonMetrics.regularFont)
        .foregroundColor(.foreground)
        .padding(.horizontal, ButtonMetrics.regularHorizontalPadding)
        .padding(.vertical, ButtonMetrics.regularVerticalPadding)
        .overlay(HairlineBorder(shape: Capsule()))
        .contentShape(Capsule())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .linkPointer()
    .fixedSize()
    .help("Copy or save the analyzed schema as JSON Schema or a MongoDB validator")
  }

  /// `{ "$jsonSchema": <body> }`, indented, ready to paste as a collection validator
  private static func validator(_ report: MongoSchemaAnalyzer.Report) -> String {
    let body = MongoSchemaExport.mongoJSONSchema(report)
    return "{\n  \"$jsonSchema\": " + body.replacingOccurrences(of: "\n", with: "\n  ") + "\n}"
  }

  private func copy(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private func save(_ text: String, as filename: String) {
    DataExporter.saveFile(content: text, defaultFilename: filename, allowedFileTypes: ["json"])
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
        + (report.isTruncated
          ? " · first \(MongoSchemaAnalyzer.nodeLimit.formatted()) fields only" : "")
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
            MongoSchemaFieldRow(field: field, onFilter: applyFilter)
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
