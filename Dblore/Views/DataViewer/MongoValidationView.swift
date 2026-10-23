//
//  MongoValidationView.swift
//  Dblore
//
//  Validation section of a MongoDB collection screen: the collection's validator as mongosh
//  text, its level and action, and the `collMod` that Apply sends, read on first show, on
//  Refresh and after each change. Generate from Sample fills the editor with a `$jsonSchema`
//  built from a random document sample (nothing is sent). Apply goes through
//  `MongoAdminActionModel`, whose confirm sheet shows the Safe Mode panel and failures; a change
//  sent without asking shows its progress here. Views have no rules.
//

import SwiftUI

struct MongoValidationView: View {
  @Bindable var model: MongoCollectionModel
  /// The tab: connection, rules and history of the change
  let viewModel: NotebookViewModel

  /// The change asked, running or done last; nil before the first
  @State private var action: MongoAdminActionModel?
  @State private var textViewRef: SQLTextView?
  @State private var isEditorEmpty = false
  /// The last Apply was refused for a missing privilege
  @State private var showsRoleHint = false

  private typealias Rules = MongoValidationRules

  private static let editorHeight: CGFloat = 260
  /// Our own text for server code 13 (`MongoSession.message(for:)`), not the server's
  private static let unauthorizedText = "Not authorized for this action"

  var body: some View {
    VStack(spacing: 0) {
      header
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color.appBackground)
    .onAppear { model.loadValidationIfNeeded() }
    .onChange(of: action?.state) { _, state in
      if case .failed(let text)? = state, text.contains(Self.unauthorizedText) {
        showsRoleHint = true
      }
    }
    .sheet(isPresented: confirmPresented) {
      if let action {
        MongoAdminConfirmSheet(
          model: action, databasePassword: viewModel.notebook.connectionConfig?.password,
          isConnected: viewModel.connectionState == .connected)
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      if isRunning {
        ProgressView().controlSize(.small)
        Text("Running...")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      } else if isSampling {
        ProgressView().controlSize(.small)
        Text("Sampling documents...")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
      Spacer(minLength: Spacing.sm)
      if isEditable {
        if isSampling {
          Button("Cancel", action: model.cancelValidationSample)
            .buttonStyle(FilledSecondaryButtonStyle())
            .help("Stop the sample")
        } else {
          Button("Generate from Sample", action: model.generateValidatorFromSample)
            .buttonStyle(FilledSecondaryButtonStyle())
            .disabled(isRunning)
            .help("Replace the rules with a $jsonSchema of a document sample (nothing is sent)")
        }
      }
      Button {
        model.refreshValidation()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .buttonStyle(FilledSecondaryButtonStyle())
      .disabled(isLoading || isRunning)
      .help("Read the rules again (edits are dropped)")
      if isEditable {
        Button("Apply", action: apply)
          .buttonStyle(PrimaryButtonStyle())
          .disabled(!canApply)
          .help(
            blocksSchemaChanges
              ? "This connection's protection level blocks schema changes"
              : "Send the collMod below")
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  private var isLoading: Bool {
    if case .loading = model.validationState { return true }
    return false
  }

  private var isRunning: Bool { action?.state == .running }

  private var isSampling: Bool { model.validationSampleState == .sampling }

  /// A collection's rules are shown (not a view, not loading)
  private var isEditable: Bool { loadedRules != nil }

  private var blocksSchemaChanges: Bool {
    viewModel.protectionPolicy.protectionLevel.blocksSchemaChanges
  }

  /// The collection's rules as read; nil unless a collection (not a view) is loaded
  private var loadedRules: Rules? {
    guard case .loaded(let info) = model.validationState, !info.isView else { return nil }
    return Rules(options: info.options)
  }

  /// The draft as rules, or its parse error
  private var draftRules: Result<Rules, MongoRelaxedJSON.ParseError> {
    do {
      return .success(
        try Rules(
          validatorText: model.validatorDraft, level: model.validationLevelDraft,
          action: model.validationActionDraft))
    } catch {
      return .failure(error)
    }
  }

  /// Valid, different from the collection's rules, and nothing else running
  private var canApply: Bool {
    guard let loadedRules, case .success(let rules) = draftRules else { return false }
    let isUnchanged =
      rules == loadedRules
      || (model.validatorDraft == loadedRules.validatorText && rules.level == loadedRules.level
        && rules.action == loadedRules.action)
    return !isUnchanged && !isRunning && !isSampling && !blocksSchemaChanges
  }

  private var confirmPresented: Binding<Bool> {
    action.map(MongoAdminConfirmSheet.isPresented) ?? .constant(false)
  }

  /// Sends the draft's `collMod` through a new admin model (gated by the epoch of the rules
  /// shown)
  private func apply() {
    guard canApply, case .success(let rules) = draftRules,
      let action = viewModel.mongoValidationAdminAction()
    else { return }
    showsRoleHint = false
    self.action = action
    Task { await action.request(rules.command(collection: model.collection)) }
  }

  // MARK: - States

  @ViewBuilder
  private var content: some View {
    switch model.validationState {
    case .idle, .loading:
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        Text("Loading validation rules...")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
    case .loaded(let info) where info.isView:
      Text("Views have no validation rules")
        .font(.small)
        .foregroundColor(.foregroundMuted)
    case .loaded(let info):
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          rulesSection
          settingsSection(Rules(options: info.options))
          previewSection
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    case .failed(let text):
      VStack(spacing: Spacing.sm) {
        Text(text)
          .font(.system(size: 12, design: .monospaced))
          .foregroundColor(.destructive)
          .textSelection(.enabled)
          .multilineTextAlignment(.center)
        Button("Retry") { model.refreshValidation() }
          .buttonStyle(SecondaryButtonStyle())
      }
      .padding(Spacing.md)
    }
  }

  // MARK: - Sections

  private var rulesSection: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Validator")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
      HighlightedTextEditor(
        text: $model.validatorDraft,
        textViewRef: $textViewRef,
        isEmpty: $isEditorEmpty,
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
      Text(
        #"A query document, e.g. { $jsonSchema: { required: ["name"] } }; blank removes the rules"#
      )
      .font(.small)
      .foregroundColor(.foregroundMuted)
      if case .failed(let text) = model.validationSampleState {
        Text(text)
          .font(.small)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
      }
    }
  }

  /// Level and action; `off` and `errorAndLog` are offered only when the collection has them
  private func settingsSection(_ loaded: Rules) -> some View {
    HStack(spacing: Spacing.lg) {
      picker("Level", selection: $model.validationLevelDraft, choices: levelChoices(loaded))
      picker("Action", selection: $model.validationActionDraft, choices: actionChoices(loaded))
      Spacer(minLength: 0)
    }
  }

  private func levelChoices(_ loaded: Rules) -> [Rules.Level] {
    loaded.level == .off ? [.strict, .moderate, .off] : [.strict, .moderate]
  }

  private func actionChoices(_ loaded: Rules) -> [Rules.Action] {
    loaded.action == .errorAndLog ? [.error, .warn, .errorAndLog] : [.error, .warn]
  }

  private func picker<Value: RawRepresentable<String> & Hashable>(
    _ title: String, selection: Binding<Value>, choices: [Value]
  ) -> some View {
    HStack(spacing: Spacing.sm) {
      Text(title)
        .font(.small)
        .foregroundColor(.foregroundMuted)
      CapsulePickerMenu(title: selection.wrappedValue.rawValue) {
        Picker(title, selection: selection) {
          ForEach(choices, id: \.self) { choice in
            Text(verbatim: choice.rawValue).tag(choice)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
      .accessibilityLabel(title)
    }
  }

  @ViewBuilder
  private var previewSection: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Command")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
      switch draftRules {
      case .success(let rules):
        Text(verbatim: rules.command(collection: model.collection).render())
          .font(.monoMedium)
          .foregroundColor(.foreground)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .inputStyle()
      case .failure(let error):
        Text("Validator: \(error.message)")
          .font(.small)
          .foregroundColor(.destructive)
          .fixedSize(horizontal: false, vertical: true)
      }
      if showsRoleHint {
        Text("Changing validation rules needs the dbAdmin role.")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
    }
  }
}
