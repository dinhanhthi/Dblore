// SessionRowSource.swift
// Rows from `DatabaseSession.query` and `DatabaseSession.fetch`.
// Columns and cell values only, so this file does not import a driver module.

import Foundation

/// Column list plus a stream of rows. The stream throws if a row cannot be read, then finishes.
/// `columns` is known before the first row; an empty result still carries its column list.
nonisolated struct SessionRowSource: Sendable {
  let columns: [ColumnInfo]
  let rows: AsyncThrowingStream<[CellValue], Error>
}
