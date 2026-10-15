//
//  DataViewerState.swift
//  Dblore
//

import Foundation

/// State of a table/view data viewer tab: the relation, the current page and the SQL that
/// loads it (server-side LIMIT/OFFSET pagination plus an exact COUNT(*)).
struct DataViewerState: Equatable {
  /// Rows-per-page choices (all within the session row cap)
  static let pageSizes = [50, 100, 250, 500, 1000]

  var schema: String
  var name: String
  /// Columns of the ORDER BY (e.g. the primary key), empty for heap order
  var orderColumns: [String]
  /// 1-based page number
  var page: Int = 1
  var pageSize: Int = 100
  /// Exact row count, nil until COUNT(*) returned
  var totalRows: Int? = nil
  /// Result column names hidden in the grid
  var hiddenColumns: Set<String> = []
  /// Dialect of the connection, for literal escaping in the WHERE clause
  var databaseType: DatabaseType = .postgresql
  /// The applied filter (SQL engines only)
  var filter = TableFilter(conditions: [])
  /// MongoDB: the applied filter document as typed (relaxed JSON / mongosh notation), "" for none
  var documentFilter = ""
  /// MongoDB: the header sort, nil for the default `{_id: 1}`
  var documentSort: DocumentSort? = nil
  /// The applied highlight: painted client-side, so not part of `LoadKey`
  var highlight = TableHighlight(filter: TableFilter(conditions: []))
  /// Staged inserts, deletes, and cell edits. Nil when nothing is staged.
  /// Session-only: a saved tab stores the relation, not this set.
  var changeSet: RowChangeSet? = nil
  /// MongoDB: staged document inserts and deletes, nil when nothing is staged. Same lifetime as
  /// `changeSet` (session-only; dropped by Discard, the leave prompt, or a new relation).
  var documentChangeSet: MongoDocumentChangeSet? = nil
  /// MongoDB: the document or value the editor sheet shows, nil when it is closed
  var pendingDocumentEditor: DocumentEditorRequest? = nil
  /// MongoDB: the editor's field edit armed a Safe Mode dialog, shown once the sheet has
  /// dismissed (`NotebookViewModel.documentEditorDismissed`)
  var confirmationAwaitsEditorDismissal = false

  /// What a page load depends on; loads are coalesced while it is unchanged
  struct LoadKey: Hashable {
    let schema: String
    let name: String
    let page: Int
    let pageSize: Int
    let filter: TableFilter
    let documentFilter: String
    let documentSort: DocumentSort?
  }

  var loadKey: LoadKey {
    LoadKey(
      schema: schema, name: name, page: page, pageSize: pageSize, filter: filter,
      documentFilter: documentFilter, documentSort: documentSort)
  }

  /// Tab title: `name` for the default (or no) schema or an engine that never names it
  /// (MySQL), else `schema.name`
  var title: String {
    !databaseType.namesSchema || schema.isEmpty || schema == databaseType.dialect.defaultSchema
      ? name : "\(schema).\(name)"
  }

  /// Quoted `"schema"."name"` when `schema` is non-empty, including the default schema.
  /// An empty schema is `"name"` alone. `SQLDialect.qualified` would drop the default schema.
  private var relation: String {
    let table = quotedIdentifier(name)
    return schema.isEmpty ? table : quotedIdentifier(schema) + "." + table
  }

  /// Dialect quoting, or the historical non-throwing quote when the name contains NUL.
  private func quotedIdentifier(_ name: String) -> String {
    do {
      return try databaseType.dialect.quoteIdentifier(name)
    } catch {
      return CellUpdateStatement.quoteIdentifier(name)
    }
  }

  /// ` WHERE <clause>` for the applied filter, empty without a complete condition
  private var whereSQL: String {
    filter.whereClause(dialect: databaseType.dialect).map { " WHERE " + $0 } ?? ""
  }

  /// `SELECT * FROM rel [WHERE ...] [ORDER BY ...] LIMIT n [OFFSET m]` (OFFSET only after page 1)
  var pageSQL: String {
    assert(databaseType != .mongodb, "MongoDB pages are mongoQueries()")
    var sql = "SELECT * FROM \(relation)\(whereSQL)"
    if !orderColumns.isEmpty {
      sql += " ORDER BY " + orderColumns.map { quotedIdentifier($0) }.joined(separator: ", ")
    }
    if page > 1 {
      let offset = (page - 1) * pageSize
      sql += " " + databaseType.dialect.limitOffset(limit: pageSize, offset: offset)
    } else {
      sql += " LIMIT \(pageSize)"
    }
    return sql
  }

  var countSQL: String {
    assert(databaseType != .mongodb, "MongoDB counts are mongoQueries()")
    return "SELECT count(*) FROM \(relation)\(whereSQL)"
  }

  /// Number of pages (at least 1), nil while the total is unknown
  var pageCount: Int? {
    guard let totalRows else { return nil }
    return max(1, (totalRows + pageSize - 1) / pageSize)
  }

  var canGoPrevious: Bool { page > 1 }

  /// Next is allowed while the total is unknown
  var canGoNext: Bool {
    guard let pageCount else { return true }
    return page < pageCount
  }

  /// 1-based row numbers shown on this page, nil when no row was loaded
  func rowRange(loadedRows: Int) -> ClosedRange<Int>? {
    guard loadedRows > 0 else { return nil }
    let first = (page - 1) * pageSize + 1
    return first...(first + loadedRows - 1)
  }

  /// The count of a COUNT(*) result: first cell as an integer or numeric string
  static func total(from result: QueryResult) -> Int? {
    switch result.rows.first?.first {
    case .int(let value): return value
    case .string(let value): return Int(value)
    default: return nil
    }
  }
}

// MARK: - MongoDB

extension DataViewerState {
  /// A header sort: one field, ascending (1) or descending (-1)
  struct DocumentSort: Hashable {
    var field: String
    var ascending: Bool
  }

  /// A filter text that is not a document. `offset` (UTF-16 units) is the parser's, nil when the
  /// text parsed but is not a document.
  struct DocumentFilterError: Error, Equatable, LocalizedError {
    let message: String
    let offset: Int?

    var errorDescription: String? {
      offset.map { "\(message) (offset \($0))" } ?? message
    }
  }

  /// What the MongoDB document editor sheet edits, in mongosh notation.
  struct DocumentEditorRequest: Equatable, Identifiable {
    enum Kind: Equatable {
      /// + Row, Insert, Duplicate: one document, or an array of documents, staged as inserts
      case insert
      /// A staged insert, replaced by the edited document in place
      case replaceInsert(localID: UUID)
      /// One top-level field of a stored document (its `_id` cell), committed as one `$set`
      case value(id: CellValue, column: String)
    }

    let id = UUID()
    let kind: Kind
    /// The data viewer's edit target when the sheet opened: applying refuses any other
    let target: EditTarget
    /// Initial text of the sheet
    let text: String
  }

  /// Why the document editor's text was not applied. `offset` (UTF-16 units) is the parser's,
  /// nil when the text parsed but could not be staged.
  struct DocumentEditorError: Error, Equatable {
    let message: String
    let offset: Int?
  }

  /// The filter document of `text`: nil for blank text or `{}` (no filter), else a document.
  /// Arrays and scalars are refused.
  static func documentFilterValue(_ text: String) -> Result<MongoValue?, DocumentFilterError> {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .success(nil)
    }
    do {
      switch try MongoRelaxedJSON.parse(text) {
      case .document(let fields): return .success(fields.isEmpty ? nil : .document(fields))
      default:
        return .failure(
          DocumentFilterError(
            message: "The filter must be a document, e.g. {status: \"active\"}", offset: nil))
      }
    } catch {
      return .failure(DocumentFilterError(message: error.message, offset: error.offset))
    }
  }

  /// `find(<filter>).sort(<sort>).skip(<offset>).limit(<pageSize>)` (skip only after page 1) and
  /// `countDocuments(<filter>)` on the collection `name`. The sort is `{_id: 1}`, or the header
  /// field with `_id` as the tiebreak so skip/limit pages never repeat or miss a document.
  func mongoQueries() throws(DocumentFilterError) -> (page: MongoCommand, count: MongoCommand) {
    let filter = try Self.documentFilterValue(documentFilter).get()
    let id = MongoValue.Field("_id", .int32(1))
    var sort = [id]
    if let documentSort {
      let field = MongoValue.Field(documentSort.field, .int32(documentSort.ascending ? 1 : -1))
      sort = documentSort.field == "_id" ? [field] : [field, id]
    }
    let page = MongoCommand.find(
      collection: name, filter: filter, projection: nil, sort: .document(sort),
      skip: page > 1 ? (page - 1) * pageSize : nil, limit: pageSize)
    return (page, .countDocuments(collection: name, filter: filter))
  }
}
