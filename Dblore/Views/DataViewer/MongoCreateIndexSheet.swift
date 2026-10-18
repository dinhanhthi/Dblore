//
//  MongoCreateIndexSheet.swift
//  Dblore
//
//  Create Index form of the MongoDB collection screen (a `GenericModal`, presented with
//  `modalOverlay`): key rows, name, unique / sparse / hidden, TTL, partial filter, wildcard
//  projection and collation, with the mongosh command it sends (or what is wrong) below. The
//  server version is read on appear; until it answers every option is shown, then the hidden
//  toggle goes away below MongoDB 4.4. Create hands the command to `MongoAdminActionModel`:
//  the presenting view shows `MongoAdminConfirmSheet` for the Safe Mode panel and a failure,
//  this form stays open under it (the draft survives a Cancel or an error) and closes once the
//  index is created.
//

import SwiftUI

struct MongoCreateIndexSheet: View {
  let collection: String
  let model: MongoAdminActionModel
  /// For the server version
  let manager: DatabaseConnectionManager
  /// The workspace's autocomplete source, for field names in the partial filter; nil = none
  var fieldSource: SQLAutocompleteProvider?
  @Binding var isPresented: Bool

  @State private var draft = MongoIndexDraft()
  /// Nil until the server answers
  @State private var features: MongoServerFeatures?

  private static let width: CGFloat = 620
  private static let height: CGFloat = 640
  private static let labelWidth: CGFloat = 130
  private static let numberWidth: CGFloat = 100

  /// An unknown version shows the option (the server's error explains)
  private var showsHidden: Bool { features?.hiddenIndexes ?? true }

  /// Confirming or running: Create waits for that command
  private var isBusy: Bool {
    switch model.state {
    case .confirming, .running: true
    case .idle, .failed, .done: false
    }
  }

  var body: some View {
    GenericModal(
      title: "Create Index", titleIcon: "list.bullet.rectangle", titleBadge: collection,
      width: Self.width, height: Self.height, isPresented: $isPresented
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          keysSection
          optionsSection
          previewSection
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    } footer: {
      GenericModalFooter {
        if features == nil {
          ProgressView().controlSize(.small)
          Text("Reading the server version...")
            .font(.small)
            .foregroundColor(.foregroundMuted)
        }
        Spacer()
        Button("Cancel") { isPresented = false }
          .buttonStyle(FilledSecondaryButtonStyle())
        Button("Create", action: create)
          .buttonStyle(PrimaryButtonStyle())
          .disabled(isBusy || draft.command(collection: collection) == nil)
      }
    }
    .task {
      let answer = await manager.mongoServerVersion()
      features = answer
      if !answer.hiddenIndexes { draft.hidden = false }
    }
    .onChange(of: model.state) { _, state in
      if state == .done { isPresented = false }
    }
  }

  // MARK: - Sections

  private var keysSection: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      sectionTitle("Keys")
      ForEach($draft.keys) { $key in
        HStack(spacing: Spacing.sm) {
          TextField(
            key.kind == .wildcard
              ? "Path prefix (blank for all fields)" : "Field, e.g. address.city",
            text: $key.field
          )
          .textFieldStyle(.plain)
          .font(.monoMedium)
          .inputCapsuleStyle()
          Picker("", selection: $key.kind) {
            ForEach(MongoIndexDraft.KeyKind.allCases, id: \.self) { kind in
              Text(kind.title).tag(kind)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .fixedSize()
          Button {
            draft.keys.removeAll { $0.id == key.id }
          } label: {
            Image(systemName: "minus")
          }
          .buttonStyle(GhostButtonStyle(iconOnly: true))
          .disabled(draft.keys.count <= 1)
          .help("Remove key")
        }
      }
      Button {
        draft.keys.append(MongoIndexDraft.Key())
      } label: {
        Label("Add Key", systemImage: "plus")
      }
      .buttonStyle(GhostButtonStyle())
    }
  }

  private var optionsSection: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      sectionTitle("Options")
      Grid(alignment: .leading, horizontalSpacing: Spacing.sm, verticalSpacing: Spacing.sm) {
        GridRow(alignment: .center) {
          label("Name")
          TextField("Generated from the keys", text: $draft.name)
            .textFieldStyle(.plain)
            .inputCapsuleStyle()
        }
        GridRow(alignment: .center) {
          Color.clear.frame(width: 1, height: 1)
          HStack(spacing: Spacing.md) {
            toggle("Unique", $draft.unique, help: "Refuse two documents with the same key values")
            toggle("Sparse", $draft.sparse, help: "Skip documents without the indexed fields")
            if showsHidden {
              toggle("Hidden", $draft.hidden, help: "Build the index but keep the planner off it")
            }
            Spacer(minLength: 0)
          }
        }
        GridRow(alignment: .center) {
          label("TTL")
          HStack(spacing: Spacing.sm) {
            TextField("None", text: $draft.ttlSeconds)
              .textFieldStyle(.plain)
              .numberInputCapsuleStyle()
              .frame(width: Self.numberWidth)
            Text("seconds: documents expire this long after the date in the key field")
              .font(.small)
              .foregroundColor(.foregroundMuted)
              .lineLimit(1)
            Spacer(minLength: 0)
          }
        }
        documentRow(
          "Partial filter", $draft.partialFilter, "e.g. {status: \"active\"}",
          autocomplete: completion)
        documentRow(
          "Wildcard projection", $draft.wildcardProjection, "Only with $**, e.g. {name: 1}",
          autocomplete: nil)
        documentRow(
          "Collation", $draft.collation, #"e.g. {locale: "en", strength: 2}"#, autocomplete: nil)
      }
    }
  }

  @ViewBuilder
  private var previewSection: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      sectionTitle("Command")
      if let command = draft.command(collection: collection) {
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

  // MARK: - Rows

  /// A label and a mongosh field, the label level with the field's first line
  private func documentRow(
    _ title: String, _ text: Binding<String>, _ placeholder: String,
    autocomplete: SQLAutocompleteProvider?
  ) -> some View {
    GridRow(alignment: .top) {
      label(title)
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

  private func label(_ title: String) -> some View {
    Text(title)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .frame(width: Self.labelWidth, alignment: .leading)
  }

  private func toggle(_ title: String, _ isOn: Binding<Bool>, help: String) -> some View {
    Toggle(title, isOn: isOn)
      .toggleStyle(.checkbox)
      .font(.small)
      .help(help)
  }

  /// Field names of the collection in the partial filter, nil for no completion
  private var completion: SQLAutocompleteProvider? {
    fieldSource.map {
      MongoDocumentAutocompleteProvider(collection: collection, mode: .filter, source: $0)
    }
  }

  // MARK: - Actions

  /// Hands the command to the model: it runs at once under the Immediate commit style, else the
  /// presenting view's confirm sheet asks first
  private func create() {
    guard !isBusy, let command = draft.command(collection: collection) else { return }
    Task { await model.request(command) }
  }
}

extension MongoIndexDraft.KeyKind {
  fileprivate var title: String {
    switch self {
    case .ascending: "Ascending (1)"
    case .descending: "Descending (-1)"
    case .geo2dsphere: "2dsphere"
    case .text: "Text"
    case .wildcard: "Wildcard ($**)"
    }
  }
}
