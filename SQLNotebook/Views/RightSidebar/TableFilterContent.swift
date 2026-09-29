//
//  TableFilterContent.swift
//  SQLNotebook
//
//  Filter form of the data viewer in the right sidebar: condition rows (column, operator,
//  value, AND/OR), Apply/Clear and the filters saved for the table.
//

import SwiftUI

struct TableFilterContent: View {
  @Bindable var viewModel: NotebookViewModel

  @State private var saveName = ""

  private var relation: String {
    "\(viewModel.dataViewer?.schema ?? "").\(viewModel.dataViewer?.name ?? "")"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.md) {
        ForEach($viewModel.filterDraft.conditions) { $condition in
          let index = viewModel.filterDraft.conditions.firstIndex { $0.id == condition.id } ?? 0
          conditionRow($condition, index: index)
        }

        Button(action: addCondition) {
          Image(systemName: "plus")
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .help("Add condition")

        HStack(spacing: Spacing.sm) {
          Button("Apply") { Task { await viewModel.applyFilter() } }
            .buttonStyle(PrimaryButtonStyle())
          Button("Clear") { Task { await viewModel.clearFilter() } }
            .buttonStyle(SecondaryButtonStyle())
        }

        Divider()
        savedFiltersSection
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .onAppear { viewModel.prepareFilterDraft() }
    .onChange(of: relation) { viewModel.prepareFilterDraft() }
  }

  // MARK: - Condition row

  private func conditionRow(_ condition: Binding<FilterCondition>, index: Int) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      if index > 0 {
        Menu {
          Button("AND") { condition.wrappedValue.connector = .and }
          Button("OR") { condition.wrappedValue.connector = .or }
        } label: {
          Text(condition.wrappedValue.connector == .and ? "AND" : "OR")
            .font(.small)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }

      HStack(spacing: Spacing.xs) {
        Picker("", selection: condition.column) {
          Text("Column").tag("")
          ForEach(columnChoices(including: condition.wrappedValue.column), id: \.self) {
            Text($0).tag($0)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()

        Button(action: { removeCondition(condition.wrappedValue.id) }) {
          Image(systemName: "minus")
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .disabled(viewModel.filterDraft.conditions.count <= 1)
        .help("Remove condition")
      }

      Menu {
        ForEach(FilterOperator.allCases, id: \.self) { op in
          Button(action: { condition.wrappedValue.op = op }) {
            if op == condition.wrappedValue.op {
              Label(op.displayName, systemImage: "checkmark")
            } else {
              Text(op.displayName)
            }
          }
        }
      } label: {
        Text(condition.wrappedValue.op.displayName)
          .font(.small)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()

      if condition.wrappedValue.op.needsValue {
        TextField(
          condition.wrappedValue.op == .in ? "a, b, c" : "value", text: condition.value
        )
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
        .onSubmit { Task { await viewModel.applyFilter() } }
      }
    }
  }

  /// Table columns, plus a column of a loaded saved filter that the table no longer has
  private func columnChoices(including current: String) -> [String] {
    let columns = viewModel.filterColumns
    return current.isEmpty || columns.contains(current) ? columns : columns + [current]
  }

  private func addCondition() {
    viewModel.filterDraft.conditions.append(FilterCondition())
  }

  private func removeCondition(_ id: UUID) {
    guard viewModel.filterDraft.conditions.count > 1 else { return }
    viewModel.filterDraft.conditions.removeAll { $0.id == id }
  }

  // MARK: - Saved filters

  private var trimmedSaveName: String {
    saveName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var savedFiltersSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Saved filters")
        .font(.small)
        .foregroundColor(.foregroundMuted)

      HStack(spacing: Spacing.xs) {
        TextField("Name", text: $saveName)
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
        Button("Save") {
          if viewModel.saveCurrentFilter(named: saveName) { saveName = "" }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(trimmedSaveName.isEmpty)
      }

      ForEach(viewModel.savedFilters) { saved in
        HStack(spacing: Spacing.xs) {
          Text(saved.name)
            .font(.small)
            .foregroundColor(.foreground)
            .lineLimit(1)
          Spacer()
          Button("Load") { viewModel.loadSavedFilter(saved) }
            .buttonStyle(GhostButtonStyle())
          Button(action: { viewModel.deleteSavedFilter(saved) }) {
            Image(systemName: "trash")
          }
          .buttonStyle(GhostButtonStyle(iconOnly: true))
          .help("Delete saved filter")
        }
      }
    }
  }
}
