//
//  MongoCreateCollectionSheet.swift
//  Dblore
//
//  New Collection form for MongoDB (a `GenericModal`, presented with `modalOverlay`): name, kind
//  (plain, capped, clustered or time series) with its options, and collation, with the mongosh
//  command it sends (or what is wrong) below. The server version is read on appear; until it
//  answers every kind is shown, then time series goes away below MongoDB 5.0 and clustered below
//  5.3. Create hands the command to `MongoAdminActionModel`: the presenting view shows
//  `MongoAdminConfirmSheet` for the Safe Mode panel and a failure, this form stays open under it
//  (the draft survives a Cancel or an error) and closes once the collection is created.
//

import SwiftUI

struct MongoCreateCollectionSheet: View {
  let model: MongoAdminActionModel
  /// For the server version
  let manager: DatabaseConnectionManager
  @Binding var isPresented: Bool

  @State private var draft = MongoCollectionDraft()
  /// Nil until the server answers
  @State private var features: MongoServerFeatures?

  private static let width: CGFloat = 560
  private static let height: CGFloat = 520
  private static let labelWidth: CGFloat = 130
  private static let numberWidth: CGFloat = 140

  /// The kinds this server can create; an unknown version shows them all (the server's error
  /// explains)
  private var kinds: [MongoCollectionDraft.Kind] {
    MongoCollectionDraft.Kind.allCases.filter { Self.supports($0, features) }
  }

  /// Confirming or running: Create waits for that command
  private var isBusy: Bool {
    switch model.state {
    case .confirming, .running: true
    case .idle, .failed, .done: false
    }
  }

  var body: some View {
    GenericModal(
      title: "New Collection", titleIcon: "tablecells", width: Self.width, height: Self.height,
      isPresented: $isPresented
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
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
          .disabled(isBusy || draft.command() == nil)
      }
    }
    .task {
      let answer = await manager.mongoServerVersion()
      features = answer
      if !Self.supports(draft.kind, answer) { draft.kind = .standard }
    }
    .onChange(of: model.state) { _, state in
      if state == .done { isPresented = false }
    }
  }

  // MARK: - Sections

  private var optionsSection: some View {
    Grid(alignment: .leading, horizontalSpacing: Spacing.sm, verticalSpacing: Spacing.sm) {
      GridRow(alignment: .center) {
        label("Name")
        TextField("e.g. events", text: $draft.name)
          .textFieldStyle(.plain)
          .font(.monoMedium)
          .autocorrectionDisabled()
          .inputCapsuleStyle()
      }
      GridRow(alignment: .center) {
        label("Kind")
        CapsulePickerMenu(title: draft.kind.title) {
          Picker("", selection: $draft.kind) {
            ForEach(kinds, id: \.self) { kind in
              Text(kind.title).tag(kind)
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        }
      }
      switch draft.kind {
      case .standard:
        EmptyView()
      case .capped:
        numberRow("Size", $draft.cappedSize, "Required", unit: "bytes")
        numberRow(
          "Max documents", $draft.cappedMax, "No limit", unit: "the oldest are removed first")
      case .clustered:
        GridRow(alignment: .center) {
          Color.clear.frame(width: 1, height: 1)
          note("Documents are stored in _id order; _id must be unique")
        }
      case .timeSeries:
        textRow("Time field", $draft.timeField, "Required, e.g. timestamp")
        textRow("Meta field", $draft.metaField, "Optional, e.g. sensor")
        GridRow(alignment: .center) {
          label("Granularity")
          CapsulePickerMenu(title: draft.granularity?.rawValue.capitalized ?? "Server default") {
            Picker("", selection: $draft.granularity) {
              Text("Server default").tag(MongoCollectionDraft.Granularity?.none)
              ForEach(MongoCollectionDraft.Granularity.allCases, id: \.self) { granularity in
                Text(granularity.rawValue.capitalized).tag(Optional(granularity))
              }
            }
            .pickerStyle(.inline)
            .labelsHidden()
          }
        }
        numberRow(
          "Expire after", $draft.expireAfterSeconds, "Never",
          unit: "seconds after the time field")
      }
      GridRow(alignment: .top) {
        label("Collation")
          .frame(height: MongoQueryField.styledLineHeight)
        MongoQueryField(
          text: $draft.collation, placeholder: #"e.g. {locale: "en", strength: 2}"#,
          autocompleteProvider: nil
        )
        .inputStyle()
        .frame(maxWidth: .infinity)
      }
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

  // MARK: - Rows

  private func textRow(
    _ title: String, _ text: Binding<String>, _ placeholder: String
  )
    -> some View
  {
    GridRow(alignment: .center) {
      label(title)
      TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.monoMedium)
        .autocorrectionDisabled()
        .inputCapsuleStyle()
    }
  }

  private func numberRow(
    _ title: String, _ text: Binding<String>, _ placeholder: String, unit: String
  ) -> some View {
    GridRow(alignment: .center) {
      label(title)
      HStack(spacing: Spacing.sm) {
        TextField(placeholder, text: text)
          .textFieldStyle(.plain)
          .numberInputCapsuleStyle()
          .frame(width: Self.numberWidth)
        note(unit)
        Spacer(minLength: 0)
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

  private func note(_ text: String) -> some View {
    Text(text)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
  }

  // MARK: - Actions

  /// Whether the server answered `features` can create `kind`; nil (not answered yet) shows all
  private static func supports(
    _ kind: MongoCollectionDraft.Kind, _ features: MongoServerFeatures?
  ) -> Bool {
    switch kind {
    case .standard, .capped: true
    case .clustered: features?.clusteredCollections ?? true
    case .timeSeries: features?.timeSeries ?? true
    }
  }

  /// Hands the command to the model: it runs at once under the Immediate commit style, else the
  /// presenting view's confirm sheet asks first
  private func create() {
    guard !isBusy, let command = draft.command() else { return }
    Task { await model.request(command) }
  }
}

extension MongoCollectionDraft.Kind {
  fileprivate var title: String {
    switch self {
    case .standard: "Standard"
    case .capped: "Capped"
    case .clustered: "Clustered on _id"
    case .timeSeries: "Time series"
    }
  }
}
