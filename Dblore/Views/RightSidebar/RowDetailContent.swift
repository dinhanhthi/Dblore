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
  /// Why the row's cut text values (`NotebookViewModel.loadRowDetailCells`) did not load
  @State private var lazyLoadError: String?

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
          // A cut text loads first: its prefix is never shown as the value or edited
          if Self.isCutText(field), lazyLoadError == nil {
            NewRowFieldEditor(
              field: .constant(Self.loading(field.field)), error: nil, allowsDefault: false,
              isReadOnly: true
            )
            .overlay(alignment: .bottomTrailing) {
              FieldLoadingSpinner()
                .padding(Spacing.sm)
            }
          } else {
            NewRowFieldEditor(
              field: $field.field,
              error: Self.isCutText(field)
                ? lazyLoadError.map { "The full value could not be loaded: \($0)" }
                : field.validationError,
              allowsDefault: false, isReadOnly: field.isReadOnly,
              isDirty: field.isDirty && !field.isReadOnly)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .task(id: lazyRequest) {
      lazyLoadError = nil
      lazyLoadError = await viewModel.loadRowDetailCells()
    }
    // A staged insert reverted, discarded or committed elsewhere leaves nothing to edit
    .onChange(of: viewModel.dataViewer?.changeSet?.inserts.map(\.tempID)) {
      viewModel.dropRowDetailOfRemovedInsert()
    }
  }

  /// The load of the row's cut text values, again for another row or a new page
  private var lazyRequest: LazyRequest {
    LazyRequest(
      row: viewModel.rowDetail?.originalRow,
      cells: (viewModel.rowDetail?.fields ?? []).filter(Self.isCutText).map(\.name),
      generation: viewModel.lazyCells.generation)
  }

  private struct LazyRequest: Equatable {
    let row: Int?
    let cells: [String]
    let generation: Int
  }

  /// A text value a lazy page cut (a cut binary value stays not loaded)
  private static func isCutText(_ field: RowDetailField) -> Bool {
    guard field.unloadedLength != nil, case .string = field.original else { return false }
    return true
  }

  /// `field` showing "Loading full value…" in its read-only box
  private static func loading(_ field: NewRowField) -> NewRowField {
    var field = field
    field.isNull = false
    field.text = "Loading full value…"
    return field
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

/// Spinner of a field whose full value loads; fades in after 150 ms, so a fast load never
/// flashes it
private struct FieldLoadingSpinner: View {
  @State private var showsSpinner = false

  var body: some View {
    ProgressView()
      .controlSize(.small)
      .tint(.accent)
      .opacity(showsSpinner ? 1 : 0)
      .animation(.easeIn(duration: 0.15), value: showsSpinner)
      // Opt out of the app-wide animation kill switch, only for the fade
      .transaction(value: showsSpinner) { $0.disablesAnimations = false }
      .task {
        try? await Task.sleep(for: .milliseconds(150))
        showsSpinner = true
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
