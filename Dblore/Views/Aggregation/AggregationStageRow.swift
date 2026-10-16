//
//  AggregationStageRow.swift
//  Dblore
//
//  One stage of the aggregation builder: drag grip, operator (free text or a common stage from
//  the menu), enable switch, Preview and Remove, the body in a mongosh-highlighted editor, and
//  a one-line status (the stage's error or its preview state).
//

import SwiftUI

struct AggregationStageRow: View {
  let model: AggregationBuilderModel
  let stage: AggregationBuilderModel.Stage
  /// 1-based position in the pipeline
  let number: Int
  /// Shows this stage in the preview pane
  let onSelect: () -> Void
  /// The workspace's autocomplete source, for field names of the collection; nil = no completion
  var fieldSource: SQLAutocompleteProvider? = nil

  @State private var textViewRef: SQLTextView?
  @State private var isBodyEmpty = false

  /// Stages offered by the operator menu; any other `$` operator can be typed.
  static let commonOperators = [
    "$match", "$group", "$sort", "$project", "$limit", "$skip", "$unwind", "$lookup",
    "$addFields", "$set", "$unset", "$count", "$sortByCount", "$sample", "$facet", "$bucket",
    "$replaceRoot", "$replaceWith", "$unionWith", "$out", "$merge",
  ]

  /// Fixed editor height: rows keep one height while typing, so reordering stays stable
  private static let editorHeight: CGFloat = 72

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      header
      editor
      status
    }
    .padding(.vertical, Spacing.xs)
    .opacity(stage.isEnabled ? 1 : 0.6)
  }

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 11))
        .foregroundColor(.foregroundSubtle)
        .help("Drag to reorder")
      Text("\(number)")
        .font(.monoSmall)
        .foregroundColor(.foregroundMuted)
        .monospacedDigit()
      operatorField
      Spacer(minLength: Spacing.sm)
      Toggle("Enabled", isOn: enabledBinding)
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .help(stage.isEnabled ? "Turn off this stage" : "Turn on this stage")
      Button {
        onSelect()
        model.preview(stage.id)
      } label: {
        Image(systemName: "play")
          .font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .disabled(model.previewCommand(for: stage.id) == nil)
      .help("Preview the pipeline up to this stage")
      Button {
        model.removeStage(stage.id)
      } label: {
        Image(systemName: "trash")
          .font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Remove Stage")
    }
  }

  private var operatorField: some View {
    HStack(spacing: Spacing.xxs) {
      TextField("$match", text: operatorBinding)
        .textFieldStyle(.plain)
        .font(.monoMedium)
        .frame(width: 120)
      Menu {
        ForEach(Self.commonOperators, id: \.self) { name in
          Button(name) { model.setOperator(name, for: stage.id) }
        }
      } label: {
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Common stages")
    }
    .inputCapsuleStyle()
  }

  private var editor: some View {
    HighlightedTextEditor(
      text: bodyBinding,
      onFocus: onSelect,
      textViewRef: $textViewRef,
      isEmpty: $isBodyEmpty,
      autocompleteProvider: fieldCompletion,
      maxHeight: Self.editorHeight,
      dialect: .mongodb
    )
    .padding(Spacing.xs)
    .background(Color.inputBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
    .overlay(
      HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)))
  }

  /// Field names of the collection in the body. Only an operator from `commonOperators` is
  /// passed on: it is interpolated unescaped into the completion prefix, so typed text never is.
  private var fieldCompletion: SQLAutocompleteProvider? {
    let name = stage.operator.trimmingCharacters(in: .whitespaces)
    guard let fieldSource, Self.commonOperators.contains(name) else { return nil }
    return MongoDocumentAutocompleteProvider(
      collection: model.collection, mode: .stage(name), source: fieldSource)
  }

  @ViewBuilder
  private var status: some View {
    if let error = model.error(for: stage.id) {
      Text(error.localizedDescription)
        .font(.small)
        .foregroundColor(.destructive)
        .lineLimit(2)
        .textSelection(.enabled)
    } else {
      let state = model.previewState(for: stage.id)
      if let text = Self.caption(state) {
        Text(text)
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
      }
    }
  }

  /// One-line preview state under the editor, nil when not previewed yet.
  static func caption(_ state: AggregationBuilderModel.PreviewState) -> String? {
    switch state {
    case .notRun: nil
    case .loading: "Previewing..."
    case .loaded(let result): AggregationBuilderBody.countText(result)
    case .failed: "Preview failed"
    case .disabled, .writesData, .invalid: state.message
    }
  }

  // MARK: - Bindings

  private var operatorBinding: Binding<String> {
    Binding(
      get: { stage.operator },
      set: { model.setOperator($0, for: stage.id) })
  }

  private var bodyBinding: Binding<String> {
    Binding(
      get: { stage.body },
      set: { model.setBody($0, for: stage.id) })
  }

  private var enabledBinding: Binding<Bool> {
    Binding(
      get: { stage.isEnabled },
      set: { model.setEnabled($0, for: stage.id) })
  }
}
