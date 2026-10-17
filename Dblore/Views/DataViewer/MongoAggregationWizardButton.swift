//
//  MongoAggregationWizardButton.swift
//  Dblore
//
//  Wand button of the MongoDB Aggregations section opening the template Wizard: a list of the
//  `AggregationTemplate`s; picking one asks for its one to three values, and Add appends the
//  stages it builds to the builder. The host learns the first new stage so it can select it.
//

import SwiftUI

struct MongoAggregationWizardButton: View {
  let builder: AggregationBuilderModel
  /// The first stage Add appended, for the host to select
  let onAdded: (AggregationBuilderModel.Stage.ID) -> Void

  @State private var isPresented = false
  @State private var selected: AggregationTemplate?
  @State private var values: [String] = []

  var body: some View {
    Button(action: { isPresented.toggle() }) {
      Image(systemName: "wand.and.stars")
    }
    .buttonStyle(SecondaryButtonStyle(iconOnly: true))
    .help("Add stages from a template")
    .accessibilityLabel("Wizard")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      MongoAggregationWizardPopover(
        selected: $selected, values: $values, pick: pick, add: add
      )
      // A closed popover opens again on the list, not on a half-filled template
      .onDisappear(perform: reset)
    }
  }

  private func pick(_ template: AggregationTemplate) {
    values = Array(repeating: "", count: template.fields.count)
    selected = template
  }

  /// Appends the template's stages, reports the first, and closes the popover
  private func add() {
    guard let template = selected else { return }
    var first: AggregationBuilderModel.Stage.ID?
    for stage in template.build(values) {
      let id = builder.addStage(operator: stage.operator, body: stage.body)
      if first == nil { first = id }
    }
    if let first { onAdded(first) }
    isPresented = false
  }

  private func reset() {
    selected = nil
    values = []
  }
}

/// Popover body: its own view so the value fields' focus lives in the popover's hierarchy
private struct MongoAggregationWizardPopover: View {
  @Binding var selected: AggregationTemplate?
  @Binding var values: [String]
  let pick: (AggregationTemplate) -> Void
  let add: () -> Void

  @FocusState private var focusedField: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if let template = selected {
        form(template)
      } else {
        list
      }
    }
    .padding(Spacing.md)
    .frame(width: 320, alignment: .leading)
  }

  // MARK: - Template list

  private var list: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Templates")
        .font(.small)
        .foregroundColor(.foregroundMuted)
      ForEach(AggregationTemplate.all) { template in
        Button(action: { pick(template) }) {
          HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: template.systemImage)
              .foregroundColor(.foregroundMuted)
              .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
              Text(template.title)
                .font(.small)
                .foregroundColor(.foreground)
              Text(template.summary)
                .font(.small)
                .foregroundColor(.foregroundMuted)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(GhostButtonStyle(fillsWidth: true, vPadding: Spacing.xs))
        .help(template.summary)
        .accessibilityLabel(template.title)
      }
    }
  }

  // MARK: - Template values

  private func form(_ template: AggregationTemplate) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.xs) {
        Button(action: { selected = nil }) {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .help("Back to the templates")
        .accessibilityLabel("Back")
        Text(template.title)
          .font(.small)
          .foregroundColor(.foreground)
      }
      Text(template.summary)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(Array(template.fields.enumerated()), id: \.offset) { index, field in
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(field.label)
            .font(.small)
            .foregroundColor(.foregroundMuted)
          TextField(field.placeholder, text: value(at: index))
            .textFieldStyle(.plain)
            .inputCapsuleStyle()
            .focused($focusedField, equals: index)
            .onSubmit(submit)
            .accessibilityLabel(field.label)
        }
      }
      HStack(spacing: Spacing.xs) {
        Spacer()
        Button("Add", action: add)
          .buttonStyle(PrimaryButtonStyle())
          .disabled(!isComplete(template))
          .help(isComplete(template) ? "Add the stages to the pipeline" : "Fill in every value")
          .accessibilityLabel("Add")
      }
    }
    .onAppear { focusedField = 0 }
  }

  /// A blank value builds a stage the server refuses: Add waits for every value
  private func isComplete(_ template: AggregationTemplate) -> Bool {
    values.count == template.fields.count
      && values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  private func submit() {
    guard let template = selected, isComplete(template) else { return }
    add()
  }

  /// The value of field `index`; reads past the end are blank, writes past it are dropped
  private func value(at index: Int) -> Binding<String> {
    Binding(
      get: { index < values.count ? values[index] : "" },
      set: { if index < values.count { values[index] = $0 } }
    )
  }
}
