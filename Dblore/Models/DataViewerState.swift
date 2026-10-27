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
  /// Leading result columns are frozen through this column name, nil for none. Stored per
  /// table in `GridColumnPrefsStore`; resolve with `GridColumnPrefsStore.resolvedFrozenThrough`.
  var frozenThroughColumn: String? = nil
  /// "Display As" of binary columns by column name, stored per table in `GridColumnPrefsStore`;
  /// a column left out shows its size
  var binaryFormats: [String: BinaryDisplayFormat] = [:]
  /// Dialect of the connection, for literal escaping in the WHERE clause
  var databaseType: DatabaseType = .postgresql
  /// The applied filter (SQL engines only)
  var filter = TableFilter(conditions: [])
  /// MongoDB: the applied filter document as typed (relaxed JSON / mongosh notation), "" for none
  var documentFilter = ""
  /// MongoDB: the header sort, nil for the default `{_id: 1}`
  var documentSort: DocumentSort? = nil
  /// MongoDB: the applied query options (projection, sort, collation, hint, skip, limit, ...)
  var documentOptions = MongoQueryOptions()
  /// The applied highlight rules, first match wins: painted client-side, so not part of `LoadKey`
  var highlights: [TableHighlight] = []
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
  /// Every column of the table in order when the page reads large binary values lazily
  /// (`lazyColumns(_:databaseType:orderColumns:binaryValueColumns:)`), nil for `SELECT *`.
  /// Set from what is cached before each page read, never from a catalog query.
  var lazyColumns: [LazyColumn]? = nil

  /// What a page load depends on; loads are coalesced while it is unchanged
  struct LoadKey: Hashable {
    let schema: String
    let name: String
    let page: Int
    let pageSize: Int
    let filter: TableFilter
    let documentFilter: String
    let documentSort: DocumentSort?
    let documentOptions: MongoQueryOptions
  }

  var loadKey: LoadKey {
    LoadKey(
      schema: schema, name: name, page: page, pageSize: pageSize, filter: filter,
      documentFilter: documentFilter, documentSort: documentSort,
      documentOptions: documentOptions)
  }

  /// Rules that paint: enabled and with a complete condition
  var activeHighlights: [TableHighlight] {
    highlights.filter { $0.isEnabled && $0.hasCompleteCondition }
  }

  /// Tab title: `name` for the default (or no) schema or an engine that never names it
  /// (MySQL), else `schema.name`
  var title: String {
    !databaseType.namesSchema || schema.isEmpty || schema == databaseType.dialect.defaultSchema
      ? name : "\(schema).\(name)"
  }

  /// Quoted `"schema"."name"` when `schema` is non-empty, including the default schema.
  /// An empty schema is `"name"` alone. `SQLDialect.qualified` would drop the default schema.
  /// Every page reads it, and so does the full read of a lazy binary cell (`LazyCellLoader`).
  var relation: String {
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

  /// `SELECT * FROM rel [WHERE ...] [ORDER BY ...] LIMIT n [OFFSET m]` (OFFSET only after page 1).
  /// A lazy page lists `lazyColumns` instead of `*`, then its `lengthColumns`.
  var pageSQL: String {
    assert(databaseType != .mongodb, "MongoDB pages are mongoQueries()")
    var sql = "SELECT \(selectList) FROM \(relation)\(whereSQL)"
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

// MARK: - Lazy binary columns

extension DataViewerState {
  /// Bytes a lazy page reads of each prefixed binary value
  static let lazyPrefixBytes = 65536

  /// A column of a lazy page
  struct LazyColumn: Equatable {
    let name: String
    /// Cached type, given back to a prefixed column whose result has no type (SQLite)
    let type: String
    let isPrimaryKey: Bool
    /// Read as its first `lazyPrefixBytes` bytes, with its byte length in a length column
    let isPrefixed: Bool
  }

  /// Binary values a lazy page cut to `lazyPrefixBytes`, carried by its result
  /// (`CellResult.truncation`) with what reads their full values
  nonisolated struct Truncation: Equatable, Sendable {
    /// Primary key columns whose values, in this order, make a row key
    var keyColumns: [String] = []
    /// Full byte length by row key and column name, only for values longer than the prefix
    var lengths: [RowChangeSet.RowKey: [String: Int]] = [:]
    /// Connection the page was read on (`DatabaseConnectionManager.connectionEpoch`): full
    /// values are read only on it. Nil: none was captured, no full value is read.
    var connectionEpoch: UInt64? = nil
    /// The quoted relation the page read (`DataViewerState.relation`); empty reads nothing
    var relation = ""
    var dialect = SQLDialect.postgresql
  }

  /// Aliases of the byte-length columns a lazy page appends, one per prefixed column in order.
  /// Moved out of the result as soon as the page is read; never part of `hiddenColumns`.
  var lengthColumns: [String] {
    Self.lengthColumns(lazyColumns ?? [])
  }

  private static func lengthColumns(_ columns: [LazyColumn]) -> [String] {
    columns.filter(\.isPrefixed).indices.map { "dblore_byte_length_\($0 + 1)" }
  }

  /// The lazy columns of a table with `columns` (in order), or nil for `SELECT *`: an engine
  /// other than PostgreSQL, MySQL and SQLite, no primary key, or no binary column. Binary:
  /// PostgreSQL `bytea`, a MySQL or SQLite type naming BLOB or BINARY, and a SQLite column in
  /// `binaryValueColumns` (its loaded values were blobs: SQLite columns have no fixed type).
  /// Primary key and ORDER BY columns are never prefixed: the alias would shadow them.
  static func lazyColumns(
    _ columns: [(name: String, type: String, isPrimaryKey: Bool)], databaseType: DatabaseType,
    orderColumns: [String], binaryValueColumns: Set<String> = []
  ) -> [LazyColumn]? {
    guard [.postgresql, .mysql, .sqlite].contains(databaseType),
      columns.contains(where: \.isPrimaryKey)
    else { return nil }
    let lazy = columns.map { column in
      let type = column.type.lowercased()
      let isBinary =
        databaseType == .postgresql
        ? type == "bytea"
        : type.contains("blob") || type.contains("binary")
          || (databaseType == .sqlite && binaryValueColumns.contains(column.name))
      return LazyColumn(
        name: column.name, type: column.type, isPrimaryKey: column.isPrimaryKey,
        isPrefixed: isBinary && !column.isPrimaryKey && !orderColumns.contains(column.name))
    }
    // A table column named like a length alias would make the names ambiguous (MySQL and
    // SQLite names ignore case)
    let names = Set(columns.map { $0.name.lowercased() })
    guard lazy.contains(where: \.isPrefixed),
      !lengthColumns(lazy).contains(where: { names.contains($0.lowercased()) })
    else { return nil }
    return lazy
  }

  /// `*`, or the lazy columns in order (prefixed ones aliased to their name) then the length
  /// columns
  private var selectList: String {
    guard let lazyColumns else { return "*" }
    let prefixed = lazyColumns.filter(\.isPrefixed).map { quotedIdentifier($0.name) }
    let columns = lazyColumns.map { column in
      let name = quotedIdentifier(column.name)
      return column.isPrefixed ? "\(prefixExpression(name)) AS \(name)" : name
    }
    let lengths = zip(prefixed, lengthColumns).map { name, alias in
      "\(lengthExpression(name)) AS \(quotedIdentifier(alias))"
    }
    return (columns + lengths).joined(separator: ", ")
  }

  /// The first `lazyPrefixBytes` bytes of `column`, still a binary value: PostgreSQL
  /// `substring(bytea ...)` is bytea, MySQL `LEFT` of a binary string is a binary string, and
  /// SQLite `substr` of a blob counts bytes and is a blob. SQLite stores any type in any
  /// column, so only its blobs are cut; other values are read whole.
  private func prefixExpression(_ column: String) -> String {
    let bytes = Self.lazyPrefixBytes
    switch databaseType {
    case .mysql: return "LEFT(\(column), \(bytes))"
    case .sqlite:
      return "CASE WHEN typeof(\(column)) = 'blob' THEN substr(\(column), 1, \(bytes))"
        + " ELSE \(column) END"
    default: return "substring(\(column) from 1 for \(bytes))"
    }
  }

  /// Byte length of `column`, NULL for NULL (and for a SQLite value that is not a blob)
  private func lengthExpression(_ column: String) -> String {
    switch databaseType {
    case .mysql: return "LENGTH(\(column))"
    case .sqlite: return "CASE WHEN typeof(\(column)) = 'blob' THEN length(\(column)) END"
    default: return "octet_length(\(column))"
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
  nonisolated struct DocumentFilterError: Error, Equatable, LocalizedError {
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
      /// One field (key path from the top level) of a stored document (its `_id` cell),
      /// committed as one `$set`
      case value(id: CellValue, path: [String])
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
  /// Arrays and scalars are refused. Also the schema sample's filter rule (`MongoSchemaAnalyzer`).
  nonisolated static func documentFilterValue(
    _ text: String
  ) -> Result<MongoValue?, DocumentFilterError> {
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

  /// The page `find` and the `countDocuments` on the collection `name`, with the applied filter
  /// and options. The page skips the user skip plus the earlier pages (no skip when 0) and
  /// stops at the user limit: nil for a page past it (a limit of 0 would mean no limit). The sort
  /// is the header sort, else the Sort option, then `_id` as the tiebreak unless it is a key, so
  /// skip/limit pages never repeat or miss a document. The count carries the user window.
  func mongoQueries() throws(DocumentFilterError) -> (page: MongoCommand?, count: MongoCommand) {
    let filter = try Self.documentFilterValue(documentFilter).get()
    let options = try documentOptions.parsed()
    var sort = options.sort ?? []
    if let documentSort {
      sort = [MongoValue.Field(documentSort.field, .int32(documentSort.ascending ? 1 : -1))]
    }
    if !sort.contains(where: { $0.key == "_id" }) {
      sort.append(MongoValue.Field("_id", .int32(1)))
    }
    let offset = (page - 1) * pageSize
    // Saturates: a huge user skip must not trap
    let (sum, overflow) = (options.skip ?? 0).addingReportingOverflow(offset)
    let skip = overflow ? Int.max : sum
    var limit = pageSize
    if let userLimit = options.limit { limit = min(pageSize, userLimit - offset) }
    let pageCommand: MongoCommand? =
      limit > 0
      ? .find(
        collection: name, filter: filter, projection: options.projection,
        sort: .document(sort), skip: skip > 0 ? skip : nil, limit: limit,
        options: options.cursor)
      : nil
    return (
      pageCommand,
      .countDocuments(collection: name, filter: filter, options: countOptions(options))
    )
  }

  /// The find the user wrote: filter and options, the Sort option as typed (no header sort, no
  /// `_id` tiebreak) and the user skip and limit, without paging. For Explain, Export and
  /// favorites.
  func userQuery() throws(DocumentFilterError) -> MongoCommand {
    let filter = try Self.documentFilterValue(documentFilter).get()
    let options = try documentOptions.parsed()
    return .find(
      collection: name, filter: filter, projection: options.projection,
      sort: options.sort.map { .document($0) }, skip: options.skip, limit: options.limit,
      options: options.cursor)
  }

  /// The `countDocuments` options of the user window, only the set keys, nil when none.
  private func countOptions(_ options: MongoQueryOptions.Parsed) -> MongoValue? {
    var fields: [MongoValue.Field] = []
    if let collation = options.cursor.collation { fields.append(.init("collation", collation)) }
    if let hint = options.cursor.hint { fields.append(.init("hint", hint)) }
    if let skip = options.skip { fields.append(.init("skip", Self.integer(skip))) }
    if let limit = options.limit { fields.append(.init("limit", Self.integer(limit))) }
    if let maxTimeMS = options.cursor.maxTimeMS {
      fields.append(.init("maxTimeMS", Self.integer(maxTimeMS)))
    }
    return fields.isEmpty ? nil : .document(fields)
  }

  /// int32 when it fits, else int64 (the count options refuse doubles).
  private static func integer(_ number: Int) -> MongoValue {
    Int32(exactly: number).map { .int32($0) } ?? .int64(Int64(number))
  }
}
