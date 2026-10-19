//
//  AggregationStageRow.swift
//  Dblore
//
//  One stage of the aggregation builder: drag grip, operator (free text or a common stage from
//  the menu), enable switch, Preview and Remove, the body in a mongosh-highlighted editor, and
//  a one-line status (the stage's error or its preview state).
//

import AppKit
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
  /// The operator is typed (after a double-click) instead of picked from the menu
  @State private var isEditingOperator = false
  @FocusState private var operatorFocused: Bool

  /// Stages offered by the operator menu; any other `$` operator can be typed.
  static let commonOperators = [
    "$match", "$group", "$sort", "$project", "$limit", "$skip", "$unwind", "$lookup",
    "$addFields", "$set", "$unset", "$count", "$sortByCount", "$sample", "$facet", "$bucket",
    "$replaceRoot", "$replaceWith", "$unionWith", "$out", "$merge",
  ]

  /// Fixed editor height: rows keep one height while typing, so reordering stays stable
  private static let editorHeight: CGFloat = 72
  /// The operator capsule: as tall as the row's icon buttons, not a full input
  private static let operatorHeight: CGFloat = 24

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

  /// A click anywhere opens the common stages; a double-click types any operator
  private var operatorField: some View {
    HStack(spacing: Spacing.xxs) {
      if isEditingOperator {
        TextField("$match", text: operatorBinding)
          .textFieldStyle(.plain)
          .font(.monoMedium)
          .focused($operatorFocused)
          .onSubmit { isEditingOperator = false }
      } else {
        Text(stage.operator.isEmpty ? "$match" : stage.operator)
          .font(.monoMedium)
          .foregroundColor(stage.operator.isEmpty ? .foregroundSubtle : .foreground)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      Image(systemName: "chevron.down")
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(.foregroundMuted)
    }
    .padding(.horizontal, Spacing.sm)
    .frame(width: 136, height: Self.operatorHeight)
    .background(Color.controlBackground, in: Capsule())
    .overlay(HairlineBorder(shape: Capsule()))
    .overlay {
      if !isEditingOperator {
        OperatorMenuClickArea(
          options: Self.commonOperators, selected: stage.operator,
          onSelect: { model.setOperator($0, for: stage.id) },
          onDoubleClick: {
            isEditingOperator = true
            operatorFocused = true
          })
      }
    }
    .onChange(of: operatorFocused) { _, focused in
      if !focused { isEditingOperator = false }
    }
    .help("Click for the common stages; double-click to type any operator")
    .accessibilityLabel("Stage operator")
  }

  private var editor: some View {
    HighlightedTextEditor(
      text: bodyBinding,
      onFocus: onSelect,
      textViewRef: $textViewRef,
      isEmpty: $isBodyEmpty,
      autocompleteProvider: fieldCompletion,
      maxHeight: Self.editorHeight,
      dialect: .mongodb,
      mongoQueryEditing: true
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
      if let text = Self.caption(state, limit: model.previewLimit) {
        Text(text)
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
      }
    }
  }

  /// One-line preview state under the editor (`limit`: the preview size), nil when not
  /// previewed yet.
  static func caption(_ state: AggregationBuilderModel.PreviewState, limit: Int) -> String? {
    switch state {
    case .notRun: nil
    case .loading: "Previewing..."
    case .loaded(let result): AggregationBuilderBody.countText(result, limit: limit)
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

// MARK: - Operator menu

/// Click area over the operator capsule. A SwiftUI `Menu` opens on the first mouse-down, so a
/// double-click could never reach the field: the menu waits out the double-click interval
/// (at most 0.3 s) and a second click types instead.
private struct OperatorMenuClickArea: NSViewRepresentable {
  var options: [String]
  var selected: String
  var onSelect: (String) -> Void
  var onDoubleClick: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> ClickView {
    let view = ClickView()
    view.coordinator = context.coordinator
    return view
  }

  func updateNSView(_ nsView: ClickView, context: Context) {
    context.coordinator.options = options
    context.coordinator.selected = selected
    context.coordinator.onSelect = onSelect
    context.coordinator.onDoubleClick = onDoubleClick
  }

  final class Coordinator: NSObject {
    var options: [String] = []
    var selected = ""
    var onSelect: (String) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    private var pendingMenu: DispatchWorkItem?

    @objc func pick(_ sender: NSMenuItem) {
      guard let name = sender.representedObject as? String else { return }
      onSelect(name)
    }

    func click(_ event: NSEvent, in view: NSView) {
      pendingMenu?.cancel()
      guard event.clickCount == 1 else {
        pendingMenu = nil
        onDoubleClick()
        return
      }
      let work = DispatchWorkItem { [weak self, weak view] in
        guard let self, let view else { return }
        self.pendingMenu = nil
        self.pop(from: view)
      }
      pendingMenu = work
      DispatchQueue.main.asyncAfter(
        deadline: .now() + min(NSEvent.doubleClickInterval, 0.3), execute: work)
    }

    private func pop(from view: NSView) {
      let menu = NSMenu()
      menu.autoenablesItems = false
      for name in options {
        let item = NSMenuItem(title: name, action: #selector(pick(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = name
        item.state = name == selected ? .on : .off
        menu.addItem(item)
      }
      // Top-left just below the capsule
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 2), in: view)
    }
  }

  final class ClickView: NSView {
    weak var coordinator: Coordinator?

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
      discardCursorRects()
      addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
      coordinator?.click(event, in: self)
    }
  }
}
