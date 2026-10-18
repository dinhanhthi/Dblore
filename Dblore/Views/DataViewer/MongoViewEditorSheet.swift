//
//  MongoViewEditorSheet.swift
//  Dblore
//
//  New View, Edit View and Duplicate View form for MongoDB (a `GenericModal`, presented with
//  `modalOverlay`): name, source collection (or view) and the pipeline as mongosh text, with the
//  command it sends (or what is wrong) below. Edit and Duplicate start from the view's `source`
//  and `definition` (its pipeline in mongosh notation, read by the schema introspector). New and
//  Duplicate send `db.createView`; Edit sends `collMod` with `viewOn` and `pipeline` (the name
//  stays: renaming is its own action). Save hands the command to `MongoAdminActionModel`: the
//  presenting view shows `MongoAdminConfirmSheet` for the Safe Mode panel and a failure, this
//  form stays open under it and closes once the server took the command.
//

import SwiftUI

struct MongoViewEditorSheet: View {
  enum Mode {
    case create
    case edit(DatabaseView)
    case duplicate(of: DatabaseView)
  }

  let model: MongoAdminActionModel
  let mode: Mode
  /// Collections and views of the database, for the source picker (a view can be on a view)
  let sources: [String]
  @Binding var isPresented: Bool

  @State private var draft: MongoViewDraft
  @State private var textViewRef: SQLTextView?
  @State private var isPipelineEmpty = false

  private static let width: CGFloat = 600
  private static let height: CGFloat = 560
  private static let labelWidth: CGFloat = 90
  private static let editorHeight: CGFloat = 220

  init(
    model: MongoAdminActionModel, mode: Mode, sources: [String], isPresented: Binding<Bool>
  ) {
    self.model = model
    self.mode = mode
    self.sources = sources
    _isPresented = isPresented
    let draft =
      switch mode {
      case .create:
        MongoViewDraft(editedName: nil, name: "", source: sources.first ?? "", definition: nil)
      case .edit(let view):
        MongoViewDraft(
          editedName: view.name, name: view.name, source: view.source ?? "",
          definition: view.definition)
      case .duplicate(let view):
        MongoViewDraft(
          editedName: nil, name: "\(view.name)_copy", source: view.source ?? "",
          definition: view.definition)
      }
    _draft = State(initialValue: draft)
  }

  /// Confirming or running: Save waits for that command
  private var isBusy: Bool {
    switch model.state {
    case .confirming, .running: true
    case .idle, .failed, .done: false
    }
  }

  private var title: String {
    switch mode {
    case .create: "New View"
    case .edit: "Edit View"
    case .duplicate: "Duplicate View"
    }
  }

  /// The picker's choices: the given sources without the edited view itself, plus the current
  /// source when it is not listed (a view can be on a collection that does not exist yet)
  private var sourceChoices: [String] {
    var choices = sources.filter { $0 != draft.editedName }
    if !draft.source.isEmpty, !choices.contains(draft.source) {
      choices.insert(draft.source, at: 0)
    }
    return choices
  }

  var body: some View {
    GenericModal(
      title: title, titleIcon: "eye", width: Self.width, height: Self.height,
      isPresented: $isPresented
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          fieldsSection
          pipelineSection
          previewSection
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    } footer: {
      GenericModalFooter {
        Spacer()
        Button("Cancel") { isPresented = false }
          .buttonStyle(FilledSecondaryButtonStyle())
        Button(draft.editedName == nil ? "Create" : "Save", action: save)
          .buttonStyle(PrimaryButtonStyle())
          .disabled(isBusy || draft.command() == nil)
      }
    }
    .onChange(of: model.state) { _, state in
      if state == .done { isPresented = false }
    }
  }

  // MARK: - Sections

  private var fieldsSection: some View {
    Grid(alignment: .leading, horizontalSpacing: Spacing.sm, verticalSpacing: Spacing.sm) {
      GridRow(alignment: .center) {
        label("Name")
        if let editedName = draft.editedName {
          Text(verbatim: editedName)
            .font(.monoMedium)
            .foregroundColor(.foreground)
            .textSelection(.enabled)
        } else {
          TextField("e.g. active_users", text: $draft.name)
            .textFieldStyle(.plain)
            .font(.monoMedium)
            .autocorrectionDisabled()
            .inputCapsuleStyle()
        }
      }
      GridRow(alignment: .center) {
        label("Source")
        Picker("", selection: $draft.source) {
          if draft.source.isEmpty {
            Text("Choose a collection").tag("")
          }
          ForEach(sourceChoices, id: \.self) { name in
            Text(verbatim: name).tag(name)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
      }
    }
  }

  private var pipelineSection: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Pipeline")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
      HighlightedTextEditor(
        text: $draft.pipelineText,
        textViewRef: $textViewRef,
        isEmpty: $isPipelineEmpty,
        maxHeight: Self.editorHeight,
        dialect: .mongodb,
        mongoQueryEditing: true
      )
      .padding(Spacing.xs)
      .background(Color.inputBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
      .overlay(
        HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
      )
      Text("An array of stages, e.g. [{ $match: { active: true } }]; blank for none")
        .font(.small)
        .foregroundColor(.foregroundMuted)
    }
  }

  @ViewBuilder
  private var previewSection: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Command")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
      if let command = draft.command() {
        Text(verbatim: command.render())
          .font(.monoMedium)
          .foregroundColor(.foreground)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .inputStyle()
      } else {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          ForEach(draft.validationMessages(), id: \.self) { message in
            Text(message)
              .font(.small)
              .foregroundColor(.destructive)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }

  private func label(_ title: String) -> some View {
    Text(title)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .frame(width: Self.labelWidth, alignment: .leading)
  }

  // MARK: - Actions

  /// Hands the command to the model: it runs at once under the Immediate commit style, else the
  /// presenting view's confirm sheet asks first
  private func save() {
    guard !isBusy, let command = draft.command() else { return }
    Task { await model.request(command) }
  }
}

/// The view form as a value: `command()` is nil while `validationMessages()` lists a problem.
nonisolated struct MongoViewDraft: Equatable, Sendable {
  /// Set when editing: the view keeps this name and `command()` is a `collMod`
  let editedName: String?
  var name: String
  var source: String
  /// An array of stage documents in relaxed JSON; blank is no stage
  var pipelineText: String

  /// `definition` is the view's pipeline as stored (mongosh notation), nil for a new view
  init(editedName: String?, name: String, source: String, definition: String?) {
    self.editedName = editedName
    self.name = name
    self.source = source
    pipelineText = Self.editableText(definition)
  }

  /// Every problem, in form order; empty when the draft can be sent
  func validationMessages() -> [String] {
    var messages: [String] = []
    if editedName == nil, let message = MongoCollectionDraft.nameProblem(name) {
      messages.append(message)
    }
    if Self.trimmed(source).isEmpty { messages.append("Choose a source collection") }
    if case .failure(let message) = stages() { messages.append(message) }
    return messages
  }

  /// `createView` for a new or duplicated view, `collMod` with `viewOn` and `pipeline` for an
  /// edited one; nil while the draft has a problem
  func command() -> MongoAdminCommand? {
    guard validationMessages().isEmpty, case .success(let stages) = stages() else { return nil }
    let source = Self.trimmed(source)
    guard let editedName else {
      return .createView(name: Self.trimmed(name), source: source, pipeline: stages, options: nil)
    }
    return .collMod(
      collection: editedName,
      options: .document([.init("viewOn", .string(source)), .init("pipeline", .array(stages))]))
  }

  // MARK: - Private

  private enum Parsed: Equatable {
    case success([MongoValue])
    case failure(String)
  }

  /// The stages of `pipelineText`. A view only reads, so `$out` and `$merge` are refused here
  /// (the server would refuse them too).
  private func stages() -> Parsed {
    guard !Self.trimmed(pipelineText).isEmpty else { return .success([]) }
    let value: MongoValue
    do {
      value = try MongoRelaxedJSON.parse(pipelineText)
    } catch {
      return .failure("Pipeline: \(error.message)")
    }
    guard case .array(let stages) = value else {
      return .failure("The pipeline must be an array of stages")
    }
    for stage in stages {
      guard case .document(let fields) = stage else {
        return .failure("Each pipeline stage must be a document")
      }
      if let key = fields.first(where: { $0.key == "$out" || $0.key == "$merge" })?.key {
        return .failure("A view pipeline cannot write: remove the \(key) stage")
      }
    }
    return .success(stages)
  }

  /// The stored definition indented for editing; written as is when it does not parse
  private static func editableText(_ definition: String?) -> String {
    guard let definition, !trimmed(definition).isEmpty else { return "" }
    guard let value = try? MongoRelaxedJSON.parse(definition) else { return definition }
    return MongoRelaxedJSON.render(value, as: .mongosh, indented: true)
  }

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
