//
//  MongoBulkWriteSheet.swift
//  Dblore
//
//  Bulk Update / Delete form of the Documents header (a `GenericModal`, hosted by
//  `DataViewerView` with `modalOverlay`): the mode, the filter (prefilled with the applied one)
//  and the update, the count of the matching documents (read on open and on Preview, with
//  Cancel) and the mongosh command Run sends. Run hands it to `MongoBulkWriteModel`, whose
//  confirm sheet (`MongoBulkWriteConfirmSheet`, presented from this form) asks the typed
//  collection name and the Safe Mode panel or the Confirm step; the form stays open under it and
//  shows a refusal, a failure or the counts of the result.
//

import SwiftUI

struct MongoBulkWriteSheet: View {
  @Bindable var model: MongoBulkWriteModel
  /// The workspace's autocomplete source, for field names in the filter; nil = none
  var fieldSource: SQLAutocompleteProvider?
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool
  @Binding var isPresented: Bool

  private static let width: CGFloat = 620
  private static let height: CGFloat = 560
  private static let labelWidth: CGFloat = 60

  /// Counting, confirming or running: Preview and Run wait
  private var isBusy: Bool {
    switch model.state {
    case .previewing, .confirming, .running: true
    case .idle, .ready, .failed, .done: false
    }
  }

  private var canRun: Bool {
    guard !isBusy, case .success = model.commandText else { return false }
    return true
  }

  var body: some View {
    GenericModal(
      title: "Bulk Update / Delete", titleIcon: "square.stack.3d.up",
      titleBadge: model.collection, width: Self.width, height: Self.height,
      isPresented: $isPresented
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          CapsuleTabPicker(
            selection: $model.mode, tabs: [MongoBulkWriteModel.Mode.update, .delete], height: 28
          ) { mode in
            CapsuleTabLabel(text: mode == .update ? "Update" : "Delete", isSelected: model.mode == mode)
          }
          .fitsContent()
          .accessibilityLabel("Write")
          .disabled(isBusy)
          documentsSection
          countSection
          commandSection
          statusSection
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    } footer: {
      GenericModalFooter {
        Spacer()
        Button("Close") { isPresented = false }
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(model.state == .running)
        Button("Run") { Task { await model.run() } }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(!canRun)
      }
    }
    .task { await model.preview() }
    .sheet(isPresented: MongoBulkWriteConfirmSheet.isPresented(model)) {
      MongoBulkWriteConfirmSheet(
        model: model, databasePassword: databasePassword, isConnected: isConnected)
    }
  }

  // MARK: - Sections

  private var documentsSection: some View {
    Grid(alignment: .leading, horizontalSpacing: Spacing.sm, verticalSpacing: Spacing.sm) {
      documentRow(
        "Filter", $model.filterText, "Blank or {} matches every document",
        autocomplete: completion)
      if model.mode == .update {
        documentRow(
          "Update", $model.updateText,
          #"e.g. {$set: {status: "archived"}}, or a pipeline [...]"#, autocomplete: nil)
      }
    }
  }

  private var countSection: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      sectionTitle("Matching documents")
      HStack(spacing: Spacing.sm) {
        if model.state == .previewing {
          ProgressView().controlSize(.small)
          Text("Counting...")
            .font(.small)
            .foregroundColor(.foregroundMuted)
          Spacer(minLength: 0)
          Button("Cancel", action: model.cancel)
            .buttonStyle(FilledSecondaryButtonStyle())
        } else {
          Text(countText)
            .font(.small)
            .foregroundColor(.foreground)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button("Preview") { Task { await model.preview() } }
            .buttonStyle(FilledSecondaryButtonStyle())
            .disabled(isBusy)
            .help("Count the documents matching the filter")
        }
      }
    }
  }

  @ViewBuilder
  private var commandSection: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      sectionTitle("Command")
      if model.mode == .update
        && model.updateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        Text("Type the update: operators such as $set, or a pipeline.")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      } else {
        switch model.commandText {
        case .success(let text):
          Text(verbatim: text)
            .font(.monoMedium)
            .foregroundColor(.foreground)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .inputStyle()
        case .failure(let error):
          Text(error.message)
            .font(.small)
            .foregroundColor(.destructive)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  /// A refusal or a failure (dismissed back to the count), or the counts of the result
  @ViewBuilder
  private var statusSection: some View {
    switch model.state {
    case .failed(let message):
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundColor(.destructive)
        Text(message)
          .font(.bodyText)
          .foregroundColor(.foreground)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Button("Dismiss", action: model.cancel)
          .buttonStyle(FilledSecondaryButtonStyle())
      }
    case .done(let result):
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.success)
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(Self.resultText(result))
            .font(.bodyText)
            .foregroundColor(.foreground)
          if let note = result.note {
            Text(note)
              .font(.small)
              .foregroundColor(.foregroundMuted)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    case .idle, .previewing, .ready, .confirming, .running:
      EmptyView()
    }
  }

  // MARK: - Rows

  /// A label and a mongosh field, the label level with the field's first line
  private func documentRow(
    _ title: String, _ text: Binding<String>, _ placeholder: String,
    autocomplete: SQLAutocompleteProvider?
  ) -> some View {
    GridRow(alignment: .top) {
      Text(title)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .frame(width: Self.labelWidth, alignment: .leading)
        .frame(height: MongoQueryField.styledLineHeight)
      MongoQueryField(text: text, placeholder: placeholder, autocompleteProvider: autocomplete)
        .inputStyle()
        .frame(maxWidth: .infinity)
    }
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .font(.caption)
      .foregroundColor(.foregroundMuted)
  }

  // MARK: - Helpers

  private var countText: String {
    switch model.state {
    case .ready(let count?): Self.documents(count)
    case .ready(nil):
      "Unknown: the count failed or was cancelled. Run asks for the collection name."
    case .confirming(let pending): pending.count.map(Self.documents) ?? "Unknown"
    case .idle, .previewing, .running, .failed, .done: "Not counted"
    }
  }

  /// "Matched 12 documents, modified 10." / "Deleted 12 documents."
  private static func resultText(_ result: MongoBulkWriteModel.BulkWriteResult) -> String {
    guard result.mode == .update else { return "Deleted \(documents(result.matched))." }
    guard let modified = result.modified else { return "Matched \(documents(result.matched))." }
    return "Matched \(documents(result.matched)), modified \(modified.formatted())."
  }

  private static func documents(_ count: Int) -> String {
    "\(count.formatted()) document\(count == 1 ? "" : "s")"
  }

  /// Field names of the collection in the filter, nil for no completion
  private var completion: SQLAutocompleteProvider? {
    fieldSource.map {
      MongoDocumentAutocompleteProvider(collection: model.collection, mode: .filter, source: $0)
    }
  }
}
