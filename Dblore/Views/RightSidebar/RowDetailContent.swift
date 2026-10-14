//
//  RowDetailContent.swift
//  Dblore
//
//  Row Details in the right sidebar: the table and key of one result row, then one label and
//  value box per column. Edits stay drafts until Apply in the sidebar footer; a dot marks each
//  draft Apply will send.
//

import SwiftUI

struct RowDetailContent: View {
  @Bindable var viewModel: NotebookViewModel

  /// Fields of the open row (empty when there is none)
  private var fields: Binding<[RowDetailField]> {
    Binding(
      get: { viewModel.rowDetail?.fields ?? [] },
      set: { viewModel.rowDetail?.fields = $0 })
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.md) {
        if let state = viewModel.rowDetail {
          header(state)
        }

        Divider()

        ForEach(fields) { $field in
          NewRowFieldEditor(
            field: $field.field, error: field.validationError, allowsDefault: false,
            isReadOnly: field.isReadOnly, isDirty: field.isDirty && !field.isReadOnly)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    // A staged insert reverted, discarded or committed elsewhere leaves nothing to edit
    .onChange(of: viewModel.dataViewer?.changeSet?.inserts.map(\.tempID)) {
      viewModel.dropRowDetailOfRemovedInsert()
    }
  }

  /// Table name, row number and primary key of the row
  private func header(_ state: RowDetailState) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      if let tableName = state.tableName {
        Text(tableName)
          .font(.mono)
          .foregroundColor(.foreground)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Text("Row \(state.rowNumber)")
        .font(.caption)
        .foregroundColor(.foregroundSubtle)

      ForEach(state.keyPairs, id: \.name) { key in
        HStack(spacing: Spacing.xs) {
          Text(key.name)
            .font(.caption)
            .foregroundColor(.foregroundSubtle)

          Text("=")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)

          Text(key.value.fullString)
            .font(.mono)
            .foregroundColor(.foreground)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
      }
    }
  }
}

// MARK: - Previews

#Preview("Row Details") {
  let viewModel = NotebookViewModel()
  let columns = [
    ("id", "int4", CellValue.int(1), true),
    ("nickname", "text", CellValue.null, false),
    ("settings", "jsonb", CellValue.json(#"{"theme":"dark","beta":true}"#), false),
    ("bio", "text", CellValue.string("Writes SQL for fun."), false),
  ]
  var fields = columns.map { name, type, value, isPrimaryKey in
    RowDetailField(
      field: NewRowField(name: name, type: type, isPrimaryKey: isPrimaryKey), original: value,
      isReadOnly: isPrimaryKey)
  }
  fields[3].text = "Writes SQL for a living."
  viewModel.rowDetail = RowDetailState(
    tableName: "public.users", rowNumber: 1, keyPairs: [RowDetailKey(name: "id", value: .int(1))],
    rowData: Dictionary(uniqueKeysWithValues: columns.map { ($0.0, $0.2) }),
    primaryKeyColumns: ["id"], originalRow: 0, stagedInsertID: nil, editTarget: nil,
    fields: fields)
  viewModel.rightSidebarContent = .rowDetail(cellId: nil)

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
