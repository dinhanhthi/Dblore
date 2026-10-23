//
//  FilterConditionsEditor.swift
//  Dblore
//
//  Condition rows (column, operator, value, AND/OR) shared by the Filter and Highlight forms
//  of the data viewer in the right sidebar.
//

import SwiftUI

struct FilterConditionsEditor: View {
  @Binding var conditions: [FilterCondition]
  let columns: [String]
  /// Called when Enter is pressed in a value field
  let onSubmit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      VStack(spacing: Spacing.xs) {
        ForEach($conditions) { $condition in
          let index = conditions.firstIndex { $0.id == condition.id } ?? 0
          if index > 0 { connectorPill($condition) }
          conditionRow($condition)
        }
      }

      Button(action: addCondition) {
        Image(systemName: "plus")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Add condition")
    }
  }

  // MARK: - Condition row

  /// AND/OR joining a condition to the one above; OR is tinted to stand out from AND
  private func connectorPill(_ condition: Binding<FilterCondition>) -> some View {
    let isOr = condition.wrappedValue.connector == .or
    return HStack(spacing: Spacing.xs) {
      Rectangle().fill(Color.border).frame(height: 1)
      Menu {
        Button("AND") { condition.wrappedValue.connector = .and }
        Button("OR") { condition.wrappedValue.connector = .or }
      } label: {
        Text(isOr ? "OR" : "AND")
          .font(.small)
          .foregroundColor(isOr ? .accent : .foregroundMuted)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      Rectangle().fill(Color.border).frame(height: 1)
    }
  }

  /// One condition as a bordered card so rows read as separate units
  private func conditionRow(_ condition: Binding<FilterCondition>) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
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
        .disabled(conditions.count <= 1)
        .help("Remove condition")
      }

      Menu {
        ForEach(FilterOperator.allCases, id: \.self) { op in
          Toggle(
            op.displayName,
            isOn: Binding(
              get: { op == condition.wrappedValue.op },
              set: { _ in
                // A pattern written for the search's escape character means something else
                // outside the LIKE family
                if !(Self.isLike(condition.wrappedValue.op) && Self.isLike(op)) {
                  condition.wrappedValue.likeEscape = nil
                }
                condition.wrappedValue.op = op
              }))
        }
      } label: {
        Text(condition.wrappedValue.op.displayName)
          .font(.small)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()

      if condition.wrappedValue.op.needsValue {
        TextField(
          condition.wrappedValue.op == .in ? "a, b, c" : "value", text: editedValue(condition)
        )
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
        .onSubmit { onSubmit() }
      }
    }
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.cellBackground, in: RoundedRectangle(cornerRadius: CornerRadius.lg))
    .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.lg)))
  }

  /// The operators whose SQL takes the pattern's `ESCAPE` clause
  private static func isLike(_ op: FilterOperator) -> Bool {
    switch op {
    case .like, .notLike, .ilike, .notIlike: true
    default: false
    }
  }

  /// The value field: an edit drops the search's escape character, so a typed `!` stays itself
  private func editedValue(_ condition: Binding<FilterCondition>) -> Binding<String> {
    Binding(
      get: { condition.wrappedValue.value },
      set: {
        guard $0 != condition.wrappedValue.value else { return }
        condition.wrappedValue.value = $0
        condition.wrappedValue.likeEscape = nil
      })
  }

  /// Table columns, plus a column of a loaded saved filter that the table no longer has
  private func columnChoices(including current: String) -> [String] {
    let columns = columns
    return current.isEmpty || columns.contains(current) ? columns : columns + [current]
  }

  private func addCondition() {
    conditions.append(FilterCondition())
  }

  private func removeCondition(_ id: UUID) {
    guard conditions.count > 1 else { return }
    conditions.removeAll { $0.id == id }
  }
}
