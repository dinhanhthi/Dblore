//
//  MongoImportSheet.swift
//  Dblore
//
//  Import form of a MongoDB collection (a `GenericModal`, presented with `modalOverlay`): the
//  file and its detected format, the target (an existing collection or a new one), for CSV the
//  columns with their inferred type and an override menu, the first converted documents as
//  relaxed Extended JSON, then the progress with Cancel and the result line. `MongoImportModel`
//  reads the file and sends the documents; the Safe Mode panel shows in a sheet over the form.
//  The presenters refuse to close the form while an import runs (Cancel stops it after the batch
//  in flight).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MongoImportSheet: View {
  @Bindable var model: MongoImportModel
  /// Collections of the database, for the existing target picker
  let collections: [String]
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool
  @Binding var isPresented: Bool

  private enum TargetKind: Hashable {
    case existing, new
  }

  @State private var targetKind: TargetKind
  @State private var existingName: String
  @State private var newName = ""
  /// The open panel is open: the form waits for it
  @State private var choosingFile = false
  /// The preview documents as text, rendered off the main actor
  @State private var previewTexts: [String] = []

  private static let width: CGFloat = 640
  private static let height: CGFloat = 640
  private static let labelWidth: CGFloat = 110
  /// Characters of one preview document shown; the rest is cut
  nonisolated private static let previewLimit = 4_000

  /// `collection`: the collection the form was opened for, picked first; nil picks the first
  /// one (no collection at all starts on a new collection)
  init(
    model: MongoImportModel, collection: String?, collections: [String],
    databasePassword: String?, isConnected: Bool, isPresented: Binding<Bool>
  ) {
    self.model = model
    self.collections = collections
    self.databasePassword = databasePassword
    self.isConnected = isConnected
    _isPresented = isPresented
    let initial = collection ?? collections.first
    _existingName = State(initialValue: initial ?? "")
    _targetKind = State(initialValue: initial == nil ? .new : .existing)
  }

  private var target: MongoImportModel.Target? {
    switch targetKind {
    case .existing: existingName.isEmpty ? nil : .existing(existingName)
    case .new: .new(newName)
    }
  }

  private var isConfirming: Bool {
    if case .confirming = model.state { true } else { false }
  }

  private var canImport: Bool {
    model.documentCount > 0 && target != nil && !model.isBusy && !isConfirming && !choosingFile
      && !model.importStarted
  }

  var body: some View {
    GenericModal(
      title: "Import Documents", titleIcon: "square.and.arrow.down",
      width: Self.width, height: Self.height, isPresented: $isPresented
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          optionsSection
          if model.format == .csv, !model.columns.isEmpty { columnsSection }
          if !previewTexts.isEmpty { previewSection }
          statusSection
          if model.importStarted, !model.isBusy {
            Text("Choose a file to import again.")
              .font(.small)
              .foregroundColor(.foregroundMuted)
          }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    } footer: {
      GenericModalFooter {
        Spacer()
        Button("Close") { isPresented = false }
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(model.isRunning || choosingFile)
        Button("Import") {
          guard let target else { return }
          Task { await model.request(target: target) }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!canImport)
      }
    }
    .task(id: model.preview) {
      let documents = model.preview
      let texts = await Task.detached(priority: .userInitiated) {
        documents.map { Self.previewText($0) }
      }.value
      // A newer preview replaced this one meanwhile
      guard !Task.isCancelled else { return }
      previewTexts = texts
    }
    .sheet(isPresented: MongoImportConfirmSheet.isPresented(model)) {
      MongoImportConfirmSheet(
        model: model, databasePassword: databasePassword, isConnected: isConnected)
    }
  }

  // MARK: - Sections

  private var optionsSection: some View {
    Grid(alignment: .leading, horizontalSpacing: Spacing.sm, verticalSpacing: Spacing.sm) {
      GridRow(alignment: .center) {
        label("File")
        HStack(spacing: Spacing.sm) {
          Button("Choose File...", action: chooseFile)
            .buttonStyle(FilledSecondaryButtonStyle())
          if let url = model.fileURL {
            Text(url.lastPathComponent)
              .font(.small)
              .foregroundColor(.foreground)
              .lineLimit(1)
              .truncationMode(.middle)
              .help(url.path)
          }
        }
      }
      if let format = model.format {
        GridRow(alignment: .center) {
          label("Format")
          Text(Self.title(format))
            .font(.small)
            .foregroundColor(.foreground)
        }
        GridRow(alignment: .center) {
          label("Documents")
          Text(model.documentCount.formatted())
            .font(.small)
            .foregroundColor(.foreground)
            .monospacedDigit()
        }
      }
      GridRow(alignment: .center) {
        label("Target")
        CapsuleTabPicker(selection: $targetKind, tabs: [TargetKind.existing, .new], height: 28) {
          kind in
          CapsuleTabLabel(
            text: kind == .existing ? "Existing collection" : "New collection",
            isSelected: targetKind == kind)
        }
        .fitsContent()
        .accessibilityLabel("Target")
        .disabled(collections.isEmpty && targetKind == .new)
      }
      GridRow(alignment: .center) {
        label("Collection")
        switch targetKind {
        case .existing:
          if collections.isEmpty {
            Text("The database has no collection")
              .font(.small)
              .foregroundColor(.foregroundMuted)
          } else {
            CapsulePickerMenu(title: existingName) {
              Picker("", selection: $existingName) {
                ForEach(collections, id: \.self) { name in
                  Text(name).tag(name)
                }
              }
              .pickerStyle(.inline)
              .labelsHidden()
            }
            .accessibilityLabel("Collection")
          }
        case .new:
          TextField("e.g. events", text: $newName)
            .textFieldStyle(.plain)
            .font(.monoMedium)
            .autocorrectionDisabled()
            .inputCapsuleStyle()
        }
      }
    }
    .disabled(model.isBusy || isConfirming || choosingFile)
  }

  private var columnsSection: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      sectionTitle("Columns")
      Grid(alignment: .leading, horizontalSpacing: Spacing.md, verticalSpacing: Spacing.xs) {
        GridRow {
          sectionTitle("Field")
          sectionTitle("Inferred")
          sectionTitle("Import as")
        }
        // Elements, not subscripts: a stale row of a longer column list must not index the new one
        ForEach(Array(model.columns.enumerated()), id: \.offset) { index, column in
          GridRow(alignment: .center) {
            Text(column.path)
              .font(.monoMedium)
              .foregroundColor(.foreground)
              .lineLimit(1)
              .truncationMode(.middle)
            Text(Self.title(column.inferred))
              .font(.small)
              .foregroundColor(.foregroundMuted)
            CapsulePickerMenu(
              title: override(at: index).wrappedValue.map { Self.title($0) } ?? "Inferred"
            ) {
              Picker("", selection: override(at: index)) {
                Text("Inferred").tag(MongoImportReader.FieldType?.none)
                ForEach(MongoImportReader.FieldType.allCases, id: \.self) { type in
                  Text(Self.title(type)).tag(MongoImportReader.FieldType?.some(type))
                }
              }
              .pickerStyle(.inline)
              .labelsHidden()
            }
            .accessibilityLabel("Type")
          }
        }
      }
      // An import ran: a change would load the file again and re-arm Import for it
      .disabled(model.isBusy || isConfirming || choosingFile || model.importStarted)
      Text("Empty cells are null. Dotted headers (a.b) build nested documents.")
        .font(.small)
        .foregroundColor(.foregroundMuted)
    }
  }

  private var previewSection: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      sectionTitle("Preview (first \(previewTexts.count) documents)")
      VStack(alignment: .leading, spacing: Spacing.sm) {
        ForEach(Array(previewTexts.enumerated()), id: \.offset) { index, text in
          Text(verbatim: text)
            .font(.mono)
            .foregroundColor(.foreground)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          if index < previewTexts.count - 1 { Divider() }
        }
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.controlBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))
    }
  }

  @ViewBuilder
  private var statusSection: some View {
    switch model.state {
    case .loading:
      progressLine("Reading the file...")
    case .preparing:
      progressLine("Checking the documents...")
    case .running(let inserted, let total):
      VStack(alignment: .leading, spacing: Spacing.xs) {
        ProgressView(value: Double(inserted), total: Double(max(total, 1)))
        HStack(spacing: Spacing.sm) {
          Text(
            model.cancelRequested
              ? "Stopping after the current batch..."
              : "\(inserted.formatted()) of \(total.formatted()) documents imported"
          )
          .font(.bodyText)
          .foregroundColor(.foreground)
          .monospacedDigit()
          Spacer(minLength: 0)
          Button("Cancel", action: model.cancel)
            .buttonStyle(FilledSecondaryButtonStyle())
            .disabled(model.cancelRequested)
        }
      }
    case .done(let message):
      resultLine(message, icon: "checkmark.circle.fill", color: .success)
    case .failed(let message):
      resultLine(message, icon: "exclamationmark.triangle.fill", color: .destructive)
    case .cancelled(let message):
      Text(message)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
    case .idle, .confirming:
      EmptyView()
    }
  }

  // MARK: - Rows

  private func label(_ title: String) -> some View {
    Text(title)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .frame(width: Self.labelWidth, alignment: .leading)
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .font(.caption)
      .foregroundColor(.foregroundMuted)
  }

  /// A spinner with a Cancel that stops the read or the check
  private func progressLine(_ text: String) -> some View {
    HStack(spacing: Spacing.sm) {
      ProgressView().controlSize(.small)
      Text(text)
        .font(.small)
        .foregroundColor(.foregroundMuted)
      Spacer(minLength: 0)
      Button("Cancel", action: model.cancel)
        .buttonStyle(FilledSecondaryButtonStyle())
    }
  }

  private func resultLine(_ message: String, icon: String, color: Color) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: icon)
        .foregroundColor(color)
      Text(message)
        .font(.bodyText)
        .foregroundColor(.foreground)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The override of column `index`; a change reads the file again with it
  private func override(at index: Int) -> Binding<MongoImportReader.FieldType?> {
    Binding(
      get: { index < model.columns.count ? model.columns[index].override : nil },
      set: { type in
        guard index < model.columns.count, let url = model.fileURL, !model.isBusy,
          !model.importStarted
        else { return }
        var columns = model.columns
        columns[index].override = type
        Task { await model.load(url: url, format: .csv, columns: columns) }
      })
  }

  // MARK: - File

  /// Non-modal open panel: the form is disabled until it returns, and the model drops the file
  /// when the form was closed meanwhile
  private func chooseFile() {
    guard !choosingFile, !model.isBusy else { return }
    choosingFile = true
    Task {
      let url = await Self.showOpenPanel()
      choosingFile = false
      if let url { await model.load(url: url) }
    }
  }

  private static func showOpenPanel() async -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = allowedTypes
    return await withCheckedContinuation { continuation in
      panel.begin { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
    }
  }

  private static let allowedTypes: [UTType] =
    [.json, .commaSeparatedText, .tabSeparatedText, .plainText]
    + ["ndjson", "jsonl"].map { UTType(filenameExtension: $0, conformingTo: .data) }
    .compactMap { $0 }

  // MARK: - Helpers

  nonisolated private static func previewText(_ document: MongoValue) -> String {
    let text = MongoRelaxedJSON.render(document, as: .relaxedExtendedJSON, indented: true)
    guard text.count > previewLimit else { return text }
    return String(text.prefix(previewLimit)) + "\n..."
  }

  private static func title(_ format: MongoImportReader.Format) -> String {
    switch format {
    case .jsonArray: "JSON array"
    case .ndjson: "NDJSON (one document per line)"
    case .csv: "CSV"
    }
  }

  private static func title(_ type: MongoImportReader.FieldType) -> String {
    switch type {
    case .int32: "Int32"
    case .int64: "Int64"
    case .double: "Double"
    case .bool: "Boolean"
    case .date: "Date"
    case .null: "Null"
    case .string: "String"
    case .objectId: "ObjectId"
    case .skip: "Skip column"
    }
  }
}

/// The Safe Mode panel of an import (`MongoImportModel`) with its summary: file, target and
/// document count. Presented while the model asks only: once confirmed the form shows the
/// progress and the result, and closing the sheet then must not stop the import.
struct MongoImportConfirmSheet: View {
  let model: MongoImportModel
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool

  @Environment(\.dismiss) private var dismiss

  private static let width: CGFloat = 520
  private static let title = "Import Documents"

  /// Presents the sheet while `model` asks. Closing it leaves the confirmation.
  static func isPresented(_ model: MongoImportModel) -> Binding<Bool> {
    Binding(
      get: {
        if case .confirming = model.state { true } else { false }
      },
      set: { if !$0, case .confirming = model.state { model.cancel() } })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      if case .confirming(let pending) = model.state {
        SafeModeConfirmationPanel(
          requiresPassword: pending.requiresPassword, confirmTitle: "Import",
          biometricReason: "Authorize the MongoDB import in Safe Mode",
          databasePassword: databasePassword, isConnected: isConnected,
          isPending: { [model] in model.isPending(pending) },
          onCancel: close,
          onConfirm: { [model] in await model.confirm(pending) }
        ) {
          summary(pending)
        }
        .padding(.top, Spacing.md)
      }
    }
    .frame(width: Self.width)
    .background(Color.appBackground)
    // A late Touch ID answer after the sheet closed must not send (the panel checks
    // `isPending`); a running import is left alone
    .onDisappear {
      if case .confirming = model.state { model.cancel() }
    }
  }

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Text(Self.title)
        .font(.subheading)
        .foregroundColor(.foreground)
      Spacer()
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .keyboardShortcut(.cancelAction)
      .help("Close")
    }
    .modalBarPadding(vertical: Spacing.sm)
  }

  private func summary(_ pending: MongoImportModel.Confirmation) -> some View {
    let into: String
    switch pending.target {
    case .existing(let name): into = "Into collection \(name)"
    case .new(let name): into = "Into new collection \(name) (created first)"
    }
    let count = pending.documentCount
    return VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Inserts \(count.formatted()) document\(count == 1 ? "" : "s")")
        .font(.bodyText)
        .foregroundColor(.foreground)
      Text(verbatim: into)
        .font(.small)
        .foregroundColor(.foreground)
      Text(verbatim: "From \(pending.fileName)")
        .font(.small)
        .foregroundColor(.foregroundMuted)
    }
    .textSelection(.enabled)
  }

  /// Leaves without sending anything
  private func close() {
    if case .confirming = model.state { model.cancel() }
    dismiss()
  }
}
