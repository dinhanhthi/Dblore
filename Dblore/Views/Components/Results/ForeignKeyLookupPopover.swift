//
//  ForeignKeyLookupPopover.swift
//  Dblore
//
//  Referenced-row popover for one result cell. The lookup and the jump are the view model's.
//  A NULL component is not looked up and does not open the data viewer.
//

import SwiftUI

/// One cell's foreign key, the row values, and whether those values can be followed.
struct ReferencedRowRequest {
  var column: String
  var schema: String
  var table: String
  var rowColumns: [String]
  var values: [String: CellValue]
  var foreignKey: ForeignKey
  /// False when a component is missing or NULL. Nothing is sent, and the jump stays disabled.
  var followsReference: Bool
}

/// Constraint, target, lookup state, and the data-viewer jump for one referenced row.
struct ForeignKeyLookupPopover: View {
  let request: ReferencedRowRequest
  let lookup: () async throws -> QueryResult?
  let jump: () -> Void

  @State private var phase: Phase

  private enum Phase {
    case loading
    case notLookedUp
    case empty
    case rows(QueryResult)
    case failed(String)
  }

  init(
    request: ReferencedRowRequest, lookup: @escaping () async throws -> QueryResult?,
    jump: @escaping () -> Void
  ) {
    self.request = request
    self.lookup = lookup
    self.jump = jump
    _phase = State(initialValue: request.followsReference ? .loading : .notLookedUp)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      labeled("Constraint", request.foreignKey.constraintName)
      labeled("Target", targetText)
      Divider()
      content
      Button("Open in Data Viewer", action: open)
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!request.followsReference)
    }
    .padding(Spacing.md)
    .frame(width: 280)
    .task { await load() }
  }

  private var targetText: String {
    let key = request.foreignKey
    let relation =
      key.targetSchema.isEmpty ? key.targetTable : key.targetQualifiedName
    let columns = key.targetColumns.joined(separator: ", ")
    return "\(relation) (\(columns))"
  }

  @ViewBuilder
  private var content: some View {
    switch phase {
    case .loading:
      HStack(spacing: Spacing.sm) {
        ProgressView()
          .controlSize(.small)
        Text("Loading")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
    case .notLookedUp:
      Text("No lookup")
        .font(.small)
        .foregroundColor(.foregroundMuted)
    case .empty:
      Text("No matching row")
        .font(.small)
        .foregroundColor(.foregroundMuted)
    case .rows(let result):
      rowValues(result)
    case .failed(let message):
      Text(message)
        .font(.small)
        .foregroundColor(.destructive)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func rowValues(_ result: QueryResult) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if result.rows.count > 1 {
        Text("At least two rows match")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          ForEach(Array(result.rows.enumerated()), id: \.offset) { index, row in
            if index > 0 { Divider() }
            columnValues(result.columns, row)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 220)
    }
  }

  private func columnValues(_ columns: [ColumnInfo], _ row: [CellValue]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
        let value = row.indices.contains(index) ? row[index] : nil
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
          Text(column.name)
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .lineLimit(1)
          Spacer(minLength: Spacing.sm)
          Text(value?.fullString ?? "")
            .font(.monoSmall)
            .foregroundColor(value?.isNull == true ? .foregroundSubtle : .foreground)
            .lineLimit(3)
            .textSelection(.enabled)
        }
      }
    }
  }

  private func labeled(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(title)
        .font(.smallest)
        .foregroundColor(.foregroundSubtle)
      Text(value)
        .font(.small)
        .foregroundColor(.foreground)
        .textSelection(.enabled)
        .lineLimit(2)
    }
  }

  /// Sends nothing when a component is NULL. The view model records no history.
  private func load() async {
    guard request.followsReference else { return }
    do {
      let result = try await lookup()
      guard !Task.isCancelled else { return }
      if let result, !result.rows.isEmpty {
        phase = .rows(result)
      } else if result != nil {
        phase = .empty
      } else {
        phase = .notLookedUp
      }
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      phase = .failed(error.localizedDescription)
    }
  }

  private func open() {
    guard request.followsReference else { return }
    jump()
  }
}
