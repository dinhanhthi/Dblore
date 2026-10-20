//
//  TableHighlightContent.swift
//  Dblore
//
//  Highlight rules of the data viewer in the right sidebar: the applied rules (each can be switched
//  off or removed), then the form of a new rule (color and style, then condition rows).
//  Apply (adds the rule) and Clear are in the sidebar footer. Saved highlights live in
//  `SavedHighlightsPopover`.
//

import SwiftUI

struct TableHighlightContent: View {
  @Bindable var viewModel: NotebookViewModel

  private var relation: String {
    "\(viewModel.dataViewer?.schema ?? "").\(viewModel.dataViewer?.name ?? "")"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let state = viewModel.dataViewer, !state.highlights.isEmpty {
        appliedRules(state)
        Divider()
      }

      HStack(spacing: Spacing.sm) {
        Menu {
          ForEach(HighlightColor.allCases, id: \.self) { color in
            Button(action: { viewModel.highlightDraft.color = color }) {
              Label(color.displayName, systemImage: "circle.fill")
                .foregroundStyle(color.color)
            }
          }
        } label: {
          HStack(spacing: Spacing.xs) {
            Circle().fill(viewModel.highlightDraft.color.color).frame(width: 10, height: 10)
            Text(viewModel.highlightDraft.color.displayName).font(.small)
          }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Highlight color")

        Spacer()

        Picker("", selection: $viewModel.highlightDraft.style) {
          Text("Cell").tag(HighlightStyle.cell)
          Text("Row").tag(HighlightStyle.row)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Highlight the matching cell or the whole row")
      }

      Divider()

      ScrollView {
        FilterConditionsEditor(
          conditions: $viewModel.highlightDraft.filter.conditions,
          columns: viewModel.filterColumns,
          onSubmit: viewModel.applyHighlight
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .onAppear { viewModel.prepareHighlightDraft() }
    .onChange(of: relation) { viewModel.prepareHighlightDraft() }
  }

  /// One line per applied rule, in paint order (the first match wins): on/off, color, conditions
  private func appliedRules(_ state: DataViewerState) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      ForEach(state.highlights) { rule in
        HStack(spacing: Spacing.xs) {
          Toggle(
            "",
            isOn: Binding(
              get: { rule.isEnabled },
              set: { viewModel.setHighlightEnabled(id: rule.id, $0) })
          )
          .toggleStyle(.checkbox)
          .labelsHidden()
          .controlSize(.small)
          .help("Paint this rule")
          .accessibilityLabel("Paint \(summary(of: rule, dialect: state.databaseType.dialect))")
          Circle().fill(rule.color.color).frame(width: 10, height: 10)
          Text(summary(of: rule, dialect: state.databaseType.dialect))
            .font(.small)
            .foregroundColor(rule.isEnabled ? .foreground : .foregroundMuted)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: Spacing.xs)
          Button(action: { viewModel.removeHighlight(id: rule.id) }) {
            Image(systemName: "xmark")
          }
          .buttonStyle(GhostButtonStyle(iconOnly: true))
          .controlSize(.small)
          .help("Remove rule")
        }
      }
    }
  }

  /// The rule's conditions as SQL, with " (row)" for a whole-row rule
  private func summary(of rule: TableHighlight, dialect: SQLDialect) -> String {
    let conditions = rule.filter.whereClause(dialect: dialect) ?? ""
    return rule.style == .row ? conditions + " (row)" : conditions
  }
}

// MARK: - Saved highlights

/// Popover of the header Save button: name the current form and save it, load, mark active (applied
/// when the table opens) or delete saved ones
struct SavedHighlightsPopover: View {
  @Bindable var viewModel: NotebookViewModel

  @State private var saveName = ""

  private var trimmedSaveName: String {
    saveName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Saved highlights")
        .font(.small)
        .foregroundColor(.foregroundMuted)

      HStack(spacing: Spacing.xs) {
        TextField("Name", text: $saveName)
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
          .onSubmit(save)
        Button("Save", action: save)
          .buttonStyle(SecondaryButtonStyle())
          .disabled(trimmedSaveName.isEmpty)
      }

      if !viewModel.savedHighlights.isEmpty {
        Divider()
        ForEach(viewModel.savedHighlights) { saved in
          HStack(spacing: Spacing.xs) {
            Text(saved.name)
              .font(.small)
              .foregroundColor(.foreground)
              .lineLimit(1)
            Spacer()
            // Re-applied on open for SQL tables only
            if !viewModel.isMongoDataViewer {
              Toggle(
                "Active",
                isOn: Binding(
                  get: { saved.isActive },
                  set: { viewModel.setSavedHighlightActive(saved, $0) })
              )
              .toggleStyle(.checkbox)
              .controlSize(.small)
              .font(.small)
              .help("Apply this highlight whenever the table opens")
            }
            Button("Load") { viewModel.loadSavedHighlight(saved) }
              .buttonStyle(GhostButtonStyle())
            Button(action: { viewModel.deleteSavedHighlight(saved) }) {
              Image(systemName: "trash")
            }
            .buttonStyle(GhostButtonStyle(iconOnly: true))
            .help("Delete saved highlight")
          }
        }
      }
    }
    .padding(Spacing.md)
    .frame(width: 280)
  }

  private func save() {
    if viewModel.saveCurrentHighlight(named: saveName) { saveName = "" }
  }
}
