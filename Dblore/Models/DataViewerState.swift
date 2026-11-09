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
  /// Column name → the schema read's type data (`DatabaseColumn.postgresType`) of the viewed
  /// relation, from the schema cache: picks the operator of each PostgreSQL filter comparison.
  /// A column without type data (a built-in type, or the cache does not have the relation yet)
  /// compares with `pg_catalog`'s operator.
  var columnTypeData: [String: PostgresColumnType] = [:]
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
  /// Every column of the table in order when the page reads large binary or text values lazily
  /// (`lazyColumns(_:databaseType:orderColumns:binaryValueColumns:located:text:)`), nil for
  /// `SELECT *`.
  /// Set from what is cached before each page read, never from a catalog query.
  var lazyColumns: [LazyColumn]? = nil
  /// How the rows of a keyless table are named (`EditTarget.rowLocator`): the page appends them
  /// as hidden `locatorColumns`, moved into `Truncation.locators` as soon as it is read. Set from
  /// the shown edit target before each page read, never from a catalog query; nil for a table
  /// with a primary key, or before its target is known (`SELECT *`).
  var rowLocator: RowLocatorKind? = nil
  /// Another tab wrote to the relation since the shown page was read: the viewer offers Reload
  /// (never reloads on its own, so staged changes stay). Cleared by the next page load.
  var isStale = false

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
      return CellUpdateStatement.quoteIdentifier(name, dialect: databaseType.dialect)
    }
  }

  /// ` WHERE <clause>` for the applied filter, empty without a complete condition
  private var whereSQL: String {
    filter.whereClause(dialect: databaseType.dialect, columnTypeData: columnTypeData)
      .map { " WHERE " + $0 } ?? ""
  }

  /// ` ORDER BY <orderColumns>`, empty for heap order
  private var orderBySQL: String {
    orderColumns.isEmpty
      ? "" : " ORDER BY " + orderColumns.map { quotedIdentifier($0) }.joined(separator: ", ")
  }

  /// `SELECT * FROM rel [WHERE ...] [ORDER BY ...] LIMIT n [OFFSET m]` (OFFSET only after page 1).
  /// A lazy page lists `lazyColumns` instead of `*`, then its `lengthColumns`; a keyless page
  /// appends its `locatorColumns`.
  var pageSQL: String {
    assert(databaseType != .mongodb, "MongoDB pages are mongoQueries()")
    var sql = "SELECT \(selectList) FROM \(relation)\(whereSQL)\(orderBySQL)"
    if page > 1 {
      let offset = (page - 1) * pageSize
      sql += " " + databaseType.dialect.limitOffset(limit: pageSize, offset: offset)
    } else {
      sql += " LIMIT \(pageSize)"
    }
    return sql
  }

  /// `pageSQL` as the user reads it (the result's `sourceQuery`: executed-query sidebar, pins,
  /// exports): without the locator columns of a keyless page, which only the app reads
  var shownPageSQL: String {
    var shown = self
    shown.rowLocator = nil
    return shown.pageSQL
  }

  /// The read of every row the page's filter and order give, for the all-rows export:
  /// `SELECT * FROM rel [WHERE ...] [ORDER BY ...]` without LIMIT / OFFSET. A lazy page lists
  /// `lazyColumns` whole, in order (the page's result columns), without its length or locator
  /// columns. SQLite names them through the table: a double-quoted name that matches no column
  /// (a stale cache's) would be read as a string literal, so it fails instead.
  var exportSQL: String {
    assert(databaseType != .mongodb, "MongoDB pages are mongoQueries()")
    let table = databaseType == .sqlite ? relation + "." : ""
    let list = lazyColumns.map { $0.map { table + quotedIdentifier($0.name) } } ?? ["*"]
    return "SELECT \(list.joined(separator: ", ")) FROM \(relation)\(whereSQL)\(orderBySQL)"
  }

  var countSQL: String {
    assert(databaseType != .mongodb, "MongoDB counts are mongoQueries()")
    switch databaseType {
    case .postgresql:
      return "SELECT \(databaseType.dialect.function("count", "*")) FROM \(relation)\(whereSQL)"
    default: return "SELECT count(*) FROM \(relation)\(whereSQL)"
    }
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

// MARK: - Lazy binary and text columns

extension DataViewerState {
  /// Bytes a lazy page reads of each prefixed binary value
  static let lazyPrefixBytes = 65536
  /// Characters a lazy page reads of each prefixed text value
  static let lazyPrefixCharacters = 16384

  /// A column of a lazy page
  struct LazyColumn: Equatable {
    /// How a lazy page cuts a column
    enum Prefix: Equatable {
      /// Binary: its first `lazyPrefixBytes` bytes
      case bytes
      /// Text: its first `lazyPrefixCharacters` characters, with the value's UTF-8 byte length
      /// (a SQLite column also cuts its blob values as `bytes` does)
      case characters
    }

    let name: String
    /// Cached (catalog) type: given back to a prefixed column, whose result type is the
    /// expression's (none on SQLite, text for a cut PostgreSQL `jsonb`)
    let type: String
    let isPrimaryKey: Bool
    /// How it is cut, with its byte length in a length column; nil: read whole
    let prefix: Prefix?

    init(name: String, type: String, isPrimaryKey: Bool, prefix: Prefix?) {
      self.name = name
      self.type = type
      self.isPrimaryKey = isPrimaryKey
      self.prefix = prefix
    }

    /// A binary column (`bytes`) when `isPrefixed`
    init(name: String, type: String, isPrimaryKey: Bool, isPrefixed: Bool) {
      self.init(
        name: name, type: type, isPrimaryKey: isPrimaryKey, prefix: isPrefixed ? .bytes : nil)
    }

    /// Read cut, with its byte length in a length column
    var isPrefixed: Bool { prefix != nil }
  }

  /// What picks the text columns a lazy page cuts (`lazyColumns`). Given only when the text
  /// byte lengths are UTF-8: PostgreSQL `server_encoding` `UTF8`, SQLite `PRAGMA encoding`
  /// `UTF-8`, always on MySQL (its lengths convert to utf8mb4).
  struct TextPrefixRules {
    /// The connection's mask rules: a column one matches by name (any style) is read whole, as
    /// a partial style on a prefix would show part of it as the value's end
    var masks: ColumnMaskRuleSet
    /// PostgreSQL type data of the relation (`columnTypeData`): a column that has some is an
    /// extension or user type, read whole
    var columnTypeData: [String: PostgresColumnType] = [:]
    /// SQLite columns whose loaded values were text (SQLite columns have no fixed type)
    var textValueColumns: Set<String> = []
  }

  /// Values a lazy page cut (binary to `lazyPrefixBytes`, text to `lazyPrefixCharacters`),
  /// carried by its result (`CellResult.truncation`) with what reads their full values
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
    /// The locator kind the page was read with (`DataViewerState.rowLocator`), nil for none
    var rowLocator: RowLocatorKind? = nil
    /// The locator key (`RowChangeSet.RowKey(locator:)`) of each page row, by index into
    /// `CellResult.rows`: never matched by row values, since keyless rows can be identical.
    /// Empty without `rowLocator`.
    var locators: [RowChangeSet.RowKey] = []

    /// The locator key of page row `row` for a target located by `kind`, nil when the page was
    /// read with another locator (or none) or has no such row
    func locatorKey(row: Int, kind: RowLocatorKind) -> RowChangeSet.RowKey? {
      guard rowLocator == kind, locators.indices.contains(row) else { return nil }
      return locators[row]
    }
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
  /// other than PostgreSQL, MySQL and SQLite, no primary key (unless `located`: the page reads
  /// the row locators its cut cells are read by), or no binary or long text column. Binary
  /// (`bytes`): PostgreSQL `bytea`, a MySQL or SQLite type naming BLOB or BINARY, and a SQLite
  /// column in `binaryValueColumns` (its loaded values were blobs: SQLite columns have no fixed
  /// type). Text (`characters`), only with `text` rules (`isLongText`).
  /// Primary key and ORDER BY columns are never prefixed: the alias would shadow them.
  static func lazyColumns(
    _ columns: [(name: String, type: String, isPrimaryKey: Bool)], databaseType: DatabaseType,
    orderColumns: [String], binaryValueColumns: Set<String> = [], located: Bool = false,
    text: TextPrefixRules? = nil
  ) -> [LazyColumn]? {
    guard [.postgresql, .mysql, .sqlite].contains(databaseType),
      located || columns.contains(where: \.isPrimaryKey)
    else { return nil }
    let kinds = columns.map { column -> (binary: Bool, text: Bool) in
      guard !column.isPrimaryKey, !orderColumns.contains(column.name) else { return (false, false) }
      let type = column.type.lowercased()
      let isBinary =
        databaseType == .postgresql
        ? type == "bytea"
        : type.contains("blob") || type.contains("binary")
          || (databaseType == .sqlite && binaryValueColumns.contains(column.name))
      let isText = text.map { isLongText(column.name, type: column.type, databaseType, rules: $0) }
      return (isBinary, isText ?? false)
    }
    // A cut column is an expression, which names no table: with every column cut, the page
    // would have no column origin and no edit target, so its text is read whole
    let cutsText = kinds.contains { !$0.binary && !$0.text }
    let lazy = zip(columns, kinds).map { column, kind in
      LazyColumn(
        name: column.name, type: column.type, isPrimaryKey: column.isPrimaryKey,
        prefix: kind.text && cutsText ? .characters : kind.binary ? .bytes : nil)
    }
    // A table column named like a length alias would make the names ambiguous (MySQL and
    // SQLite names ignore case)
    let names = Set(columns.map { $0.name.lowercased() })
    guard lazy.contains(where: \.isPrefixed),
      !lengthColumns(lazy).contains(where: { names.contains($0.lowercased()) })
    else { return nil }
    return lazy
  }

  /// A text column a lazy page cuts, never one a mask rule of `rules` matches by name (the
  /// broadest match). PostgreSQL: built-in `text`, `json`, `jsonb`, `xml`, and `character
  /// varying` without a length or with one above `lazyPrefixCharacters` (the schema cache's
  /// type text; a column with type data is an extension or user type). MySQL: `TINYTEXT` to
  /// `LONGTEXT`, `JSON`, and `VARCHAR(n)` above the prefix. SQLite: a declared type with TEXT
  /// affinity (SQLite ignores a length), a declared JSON, or loaded text values; the page cuts
  /// only its text (and blob) values.
  private static func isLongText(
    _ name: String, type: String, _ databaseType: DatabaseType, rules: TextPrefixRules
  ) -> Bool {
    guard rules.masks.matchingRule(column: name, origin: nil) == nil else { return false }
    let type = type.trimmingCharacters(in: .whitespaces).lowercased()
    if databaseType == .sqlite {
      // TEXT affinity (INT first, then CHAR, CLOB or TEXT; never a length) or a declared JSON
      return rules.textValueColumns.contains(name) || type == "json"
        || (!type.contains("int") && ["char", "clob", "text"].contains(where: type.contains))
    }
    // `name` or `name(n)` and nothing after: an array or any other form is read whole
    let parts = type.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false)
    let base = parts[0].trimmingCharacters(in: .whitespaces)
    var isLong = true
    if parts.count == 2 {
      guard parts[1].hasSuffix(")"), let length = Int(parts[1].dropLast()) else { return false }
      isLong = length > lazyPrefixCharacters
    }
    switch databaseType {
    case .postgresql:
      guard rules.columnTypeData[name] == nil else { return false }
      if ["text", "json", "jsonb", "xml"].contains(base) { return parts.count == 1 }
      return ["character varying", "varchar"].contains(base) && isLong
    case .mysql:
      if ["tinytext", "text", "mediumtext", "longtext", "json"].contains(base) {
        return parts.count == 1
      }
      return base == "varchar" && parts.count == 2 && isLong
    default: return false
    }
  }

  /// `*`, or the lazy columns in order (prefixed ones aliased to their name) then the length
  /// columns; then the locator columns of `rowLocator`, whichever of the two it is
  private var selectList: String {
    var list = ["*"]
    if let lazyColumns {
      // SQLite reads a double-quoted name that matches no column (a stale cache's) as a string
      // literal: a cut text column is named through its table, so it fails instead
      func source(_ column: LazyColumn) -> String {
        let name = quotedIdentifier(column.name)
        return databaseType == .sqlite && column.prefix == .characters
          ? "\(relation).\(name)" : name
      }
      let columns = lazyColumns.map { column in
        let name = quotedIdentifier(column.name)
        guard let prefix = column.prefix else { return name }
        return "\(prefixExpression(source(column), prefix, type: column.type)) AS \(name)"
      }
      let prefixed = lazyColumns.compactMap { column in
        column.prefix.map { (source(column), $0, column.type) }
      }
      let lengths = zip(prefixed, lengthColumns).map { column, alias in
        "\(lengthExpression(column.0, column.1, type: column.2)) AS \(quotedIdentifier(alias))"
      }
      list = columns + lengths
    }
    return (list + locatorExpressions).joined(separator: ", ")
  }

  /// Aliases of the locator columns a page of `rowLocator` appends, in order (the bind order of
  /// `RowLocatorKind.terms`). Moved out of the result as soon as the page is read.
  var locatorColumns: [String] {
    switch rowLocator {
    case nil: return []
    case .pgLocator: return ["dblore_tableoid", "dblore_ctid", "dblore_xmin"]
    case .sqliteRowid: return ["dblore_rowid"]
    }
  }

  /// PostgreSQL `tableoid`, `ctid` and `xmin` as `pg_catalog.text`, or the SQLite rowid alias,
  /// under `locatorColumns`
  private var locatorExpressions: [String] {
    let sources: [String]
    switch rowLocator {
    case nil: sources = []
    case .pgLocator:
      sources = ["tableoid", "ctid", "xmin"].map { databaseType.dialect.cast($0, to: "text") }
    case .sqliteRowid(let alias, _): sources = [alias.rawValue]
    }
    return zip(sources, locatorColumns).map { "\($0) AS \(quotedIdentifier($1))" }
  }

  /// `bytes`: the first `lazyPrefixBytes` bytes of `column`, still a binary value: PostgreSQL
  /// `substring(bytea ...)` is bytea, MySQL `LEFT` of a binary string is a binary string, and
  /// SQLite `substr` of a blob counts bytes and is a blob. SQLite stores any type in any
  /// column, so only its blobs are cut; other values are read whole.
  /// `characters`: the first `lazyPrefixCharacters` characters, as text (PostgreSQL through
  /// `pg_catalog.text`, a MySQL `JSON` as `CHAR`); SQLite cuts text values so and blob values
  /// as `bytes` does, other values are read whole.
  private func prefixExpression(
    _ column: String, _ prefix: LazyColumn.Prefix, type: String
  ) -> String {
    let bytes = Self.lazyPrefixBytes
    let characters = Self.lazyPrefixCharacters
    let dialect = databaseType.dialect
    switch (databaseType, prefix) {
    case (.mysql, .bytes): return "LEFT(\(column), \(bytes))"
    case (.mysql, .characters): return "LEFT(\(mysqlText(column, type: type)), \(characters))"
    case (.sqlite, .bytes):
      return "CASE WHEN typeof(\(column)) = 'blob' THEN substr(\(column), 1, \(bytes))"
        + " ELSE \(column) END"
    case (.sqlite, .characters):
      return "CASE WHEN typeof(\(column)) = 'text' THEN substr(\(column), 1, \(characters))"
        + " WHEN typeof(\(column)) = 'blob' THEN substr(\(column), 1, \(bytes))"
        + " ELSE \(column) END"
    case (_, .characters):
      return dialect.function("left", dialect.cast(column, to: "text"), String(characters))
    default: return "substring(\(column) from 1 for \(bytes))"
    }
  }

  /// Byte length of `column`, NULL for NULL (and for a SQLite value that is not a blob, or not
  /// text for `characters`). Text counts its UTF-8 bytes: PostgreSQL `octet_length` of a UTF8
  /// database's text, MySQL `LENGTH` of its utf8mb4 conversion, SQLite `length` of the text as
  /// a blob in a UTF-8 database (`length` of the text itself stops at the first NUL).
  private func lengthExpression(
    _ column: String, _ prefix: LazyColumn.Prefix, type: String
  ) -> String {
    let dialect = databaseType.dialect
    switch (databaseType, prefix) {
    case (.mysql, .bytes): return "LENGTH(\(column))"
    case (.mysql, .characters):
      return "LENGTH(CONVERT(\(mysqlText(column, type: type)) USING utf8mb4))"
    case (.sqlite, .bytes): return "CASE WHEN typeof(\(column)) = 'blob' THEN length(\(column)) END"
    case (.sqlite, .characters):
      return "CASE WHEN typeof(\(column)) = 'text' THEN length(CAST(\(column) AS BLOB))"
        + " WHEN typeof(\(column)) = 'blob' THEN length(\(column)) END"
    case (.postgresql, .characters):
      return dialect.function("octet_length", dialect.cast(column, to: "text"))
    case (.postgresql, .bytes): return dialect.function("octet_length", column)
    default: return "octet_length(\(column))"
    }
  }

  /// A MySQL text `column`, its `JSON` as `CHAR`
  private func mysqlText(_ column: String, type: String) -> String {
    type.trimmingCharacters(in: .whitespaces).lowercased() == "json"
      ? databaseType.dialect.cast(column, to: "CHAR") : column
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
