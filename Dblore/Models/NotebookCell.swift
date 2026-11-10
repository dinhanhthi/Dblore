//
//  NotebookCell.swift
//  Dblore
//

import Foundation

/// A single cell in the notebook (SQL only)
struct NotebookCell: Codable, Identifiable, Sendable {
  let id: UUID
  var cellType: CellType
  var content: String
  var executionCount: Int?
  var result: CellResult?
  var isRunning: Bool
  var isResultVisible: Bool
  /// Results for multi-statement queries (empty for single statement)
  var statementResults: [StatementResult]
  /// Currently selected statement index (0-based) for multi-statement queries
  var selectedStatementIndex: Int
  /// Total execution time for all statements (for multi-statement queries)
  var totalExecutionTime: TimeInterval?
  /// Chart configuration for this cell's result. Absent in older `.sqlnb` files.
  var chartSpec: ChartSpec?
  /// Named :name parameter values for this cell's SQL. Absent in older files.
  var parameters: [QueryParameter]
  /// Persist `parameters` in the saved file. Off keeps the values session-only.
  var savesParameterValues: Bool
  /// Result pinned for comparison with later runs. Running the cell does not change it.
  var pinnedResult: PinnedResult?

  // MARK: - Codable

  enum CodingKeys: String, CodingKey {
    case id
    case cellType
    case content
    case executionCount
    case result
    case isRunning
    case isResultVisible
    case statementResults
    case selectedStatementIndex
    case totalExecutionTime
    case chartSpec
    case parameters
    case savesParameterValues
    case pinnedResult
  }

  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    cellType = try container.decode(CellType.self, forKey: .cellType)
    content = try container.decode(String.self, forKey: .content)
    executionCount = try container.decodeIfPresent(Int.self, forKey: .executionCount)
    result = try container.decodeIfPresent(CellResult.self, forKey: .result)
    isRunning = try container.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
    isResultVisible = try container.decodeIfPresent(Bool.self, forKey: .isResultVisible) ?? true
    // New properties with default values for backward compatibility
    statementResults =
      try container.decodeIfPresent([StatementResult].self, forKey: .statementResults) ?? []
    let savedIndex = try container.decodeIfPresent(Int.self, forKey: .selectedStatementIndex) ?? 0
    // An index past the decoded results reopens on the first one
    selectedStatementIndex = statementResults.indices.contains(savedIndex) ? savedIndex : 0
    totalExecutionTime =
      try container.decodeIfPresent(TimeInterval.self, forKey: .totalExecutionTime)
    chartSpec = try container.decodeIfPresent(ChartSpec.self, forKey: .chartSpec)
    parameters =
      try container.decodeIfPresent([QueryParameter].self, forKey: .parameters) ?? []
    savesParameterValues =
      try container.decodeIfPresent(Bool.self, forKey: .savesParameterValues) ?? false
    // A malformed pin is dropped instead of failing the cell
    pinnedResult = (try? container.decodeIfPresent(PinnedResult.self, forKey: .pinnedResult)) ?? nil
    // Legacy `paginationInfo` / `statementPaginationInfo` (LIMIT-rewrite pagination) are ignored
  }

  nonisolated func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(cellType, forKey: .cellType)
    try container.encode(content, forKey: .content)
    try container.encodeIfPresent(executionCount, forKey: .executionCount)
    try container.encodeIfPresent(result, forKey: .result)
    try container.encode(isRunning, forKey: .isRunning)
    try container.encode(isResultVisible, forKey: .isResultVisible)
    try container.encode(statementResults, forKey: .statementResults)
    try container.encode(selectedStatementIndex, forKey: .selectedStatementIndex)
    try container.encodeIfPresent(totalExecutionTime, forKey: .totalExecutionTime)
    try container.encodeIfPresent(chartSpec, forKey: .chartSpec)
    try container.encode(parameters, forKey: .parameters)
    try container.encode(savesParameterValues, forKey: .savesParameterValues)
    try container.encodeIfPresent(pinnedResult, forKey: .pinnedResult)
  }

  nonisolated init(
    id: UUID = UUID(),
    cellType: CellType = .sql,
    content: String = "",
    executionCount: Int? = nil,
    result: CellResult? = nil,
    isRunning: Bool = false,
    isResultVisible: Bool = true,
    statementResults: [StatementResult] = [],
    selectedStatementIndex: Int = 0,
    totalExecutionTime: TimeInterval? = nil,
    chartSpec: ChartSpec? = nil,
    parameters: [QueryParameter] = [],
    savesParameterValues: Bool = false,
    pinnedResult: PinnedResult? = nil
  ) {
    self.id = id
    self.cellType = cellType
    self.content = content
    self.executionCount = executionCount
    self.result = result
    self.isRunning = isRunning
    self.isResultVisible = isResultVisible
    self.statementResults = statementResults
    self.selectedStatementIndex = selectedStatementIndex
    self.totalExecutionTime = totalExecutionTime
    self.chartSpec = chartSpec
    self.parameters = parameters
    self.savesParameterValues = savesParameterValues
    self.pinnedResult = pinnedResult
  }
}

/// A result snapshot a cell keeps to compare later runs against
nonisolated struct PinnedResult: Codable, Sendable, Equatable {
  let result: CellResult
  let pinnedAt: Date
  /// The SQL that produced the pinned result. Nil for pins saved before it was recorded.
  let sourceQuery: String?
}

/// The type of cell content (SQL only)
enum CellType: String, Codable, Sendable {
  case sql
}

/// Result of executing a single SQL statement (within a multi-statement query)
struct StatementResult: Codable, Sendable, Identifiable {
  let id: UUID
  let queryText: String  // The individual statement text
  let result: CellResult  // The execution result
  let statementIndex: Int  // 0-based index in the query

  nonisolated init(
    id: UUID = UUID(),
    queryText: String,
    result: CellResult,
    statementIndex: Int
  ) {
    self.id = id
    self.queryText = queryText
    self.result = result
    self.statementIndex = statementIndex
  }
}

/// Result of executing a SQL cell
struct CellResult: Codable, Sendable {
  /// Replaced only by the background catalog read's enriched types (`typesPending`)
  var columns: [ColumnInfo]
  let rows: [[CellValue]]
  let executionTime: TimeInterval
  let rowCount: Int
  let timestamp: Date
  var error: String?
  /// True if the result was limited due to reaching max fetch rows
  let wasLimited: Bool
  /// The original SQL query that produced this result
  let sourceQuery: String?
  /// Table name if this is a simple SELECT from a single table
  var tableName: String?
  /// Primary key column names for the table (empty if no PK or unable to fetch)
  var primaryKeyColumns: [String]
  /// Number of rows affected by UPDATE/DELETE/INSERT (nil for SELECT queries)
  let affectedRows: Int?
  /// Validated inline-edit target of a live execution. Session-only: not coded, so a result
  /// read from a file is read-only until the cell is run again.
  var editTarget: EditTarget? = nil
  /// Read-only relation for the referenced-row lookup of a live single-table result, aliased
  /// columns included. Session-only: not coded.
  var lookupRelation: LookupRelation? = nil
  /// Session-only (not coded, see `withCapInfo(from:)`): the row cap closed and reopened the
  /// session, statements after it did not run. A truncated result is persisted as `wasLimited`.
  var sessionReset = false
  var skippedStatements: [String] = []
  /// Session-only: queued cells cancelled because this result reset the session
  var skippedQueuedCells = 0
  /// Session-only: `AIAccessGate.sessionKey` of the connection a result came from, read before
  /// the query was sent. The AI Fix action offers an error, and `@results` a result, only while
  /// the tab is on that connection; nil (a file, an unstamped result) never is.
  var aiSessionKey: String? = nil
  /// Session-only: bumped when the rows are replaced under the same `timestamp` (the inline
  /// edit refresh), so views keyed on the rows of a run rebuild.
  var dataRevision = 0
  /// Session-only: the binary values of a lazy data-viewer page that hold only their first
  /// bytes. Carried by the result, so a copy of it never takes a prefix for the whole value.
  var truncation: DataViewerState.Truncation? = nil
  /// Session-only: an inline edit changed stored rows and this editor result was not re-read
  /// (not a single read the app may re-run), so it shows "Run again to refresh".
  var staleAfterEdit = false
  /// Session-only: the rows are shown and the catalog is still read in the background for the
  /// enriched column types and the validated edit target. Not editable until it lands.
  var typesPending = false
  /// Session-only: `schema.table.column` of each column index read from a table column, set in
  /// the background after the result is shown (`startColumnSourceLabels`). Not coded.
  var columnSourceLabels: [Int: String] = [:]
  /// Cells the capped read cut (`QueryResult.cutCells`): they hold only a prefix, so they are
  /// never copied, exported or edited as whole values. Coded only when non-empty.
  var cutCells: Set<CellPosition> = []
  /// The read stopped at the byte budget (`QueryResult.stoppedAtByteBudget`). Coded only when
  /// true.
  var stoppedAtByteBudget = false

  private enum CodingKeys: String, CodingKey {
    case columns, rows, executionTime, rowCount, timestamp, error, wasLimited, sourceQuery
    case tableName, primaryKeyColumns, affectedRows, cutCells, stoppedAtByteBudget
  }

  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    columns = try container.decode([ColumnInfo].self, forKey: .columns)
    rows = try container.decode([[CellValue]].self, forKey: .rows)
    executionTime = try container.decode(TimeInterval.self, forKey: .executionTime)
    rowCount = try container.decode(Int.self, forKey: .rowCount)
    timestamp = try container.decode(Date.self, forKey: .timestamp)
    error = try container.decodeIfPresent(String.self, forKey: .error)
    wasLimited = try container.decode(Bool.self, forKey: .wasLimited)
    sourceQuery = try container.decodeIfPresent(String.self, forKey: .sourceQuery)
    tableName = try container.decodeIfPresent(String.self, forKey: .tableName)
    primaryKeyColumns = try container.decode([String].self, forKey: .primaryKeyColumns)
    affectedRows = try container.decodeIfPresent(Int.self, forKey: .affectedRows)
    // Absent (files from older builds): nothing was cut
    cutCells =
      try container.decodeIfPresent(Set<CellPosition>.self, forKey: .cutCells) ?? []
    stoppedAtByteBudget =
      try container.decodeIfPresent(Bool.self, forKey: .stoppedAtByteBudget) ?? false
  }

  nonisolated func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(columns, forKey: .columns)
    try container.encode(rows, forKey: .rows)
    try container.encode(executionTime, forKey: .executionTime)
    try container.encode(rowCount, forKey: .rowCount)
    try container.encode(timestamp, forKey: .timestamp)
    try container.encodeIfPresent(error, forKey: .error)
    try container.encode(wasLimited, forKey: .wasLimited)
    try container.encodeIfPresent(sourceQuery, forKey: .sourceQuery)
    try container.encodeIfPresent(tableName, forKey: .tableName)
    try container.encode(primaryKeyColumns, forKey: .primaryKeyColumns)
    try container.encodeIfPresent(affectedRows, forKey: .affectedRows)
    if !cutCells.isEmpty { try container.encode(cutCells, forKey: .cutCells) }
    if stoppedAtByteBudget { try container.encode(true, forKey: .stoppedAtByteBudget) }
  }

  nonisolated init(
    columns: [ColumnInfo] = [],
    rows: [[CellValue]] = [],
    executionTime: TimeInterval = 0,
    rowCount: Int = 0,
    timestamp: Date = Date(),
    error: String? = nil,
    wasLimited: Bool = false,
    sourceQuery: String? = nil,
    tableName: String? = nil,
    primaryKeyColumns: [String] = [],
    affectedRows: Int? = nil,
    editTarget: EditTarget? = nil,
    lookupRelation: LookupRelation? = nil,
    aiSessionKey: String? = nil
  ) {
    self.columns = columns
    self.rows = rows
    self.executionTime = executionTime
    self.rowCount = rowCount
    self.timestamp = timestamp
    self.error = error
    self.wasLimited = wasLimited
    self.sourceQuery = sourceQuery
    self.tableName = tableName
    self.primaryKeyColumns = primaryKeyColumns
    self.affectedRows = affectedRows
    self.editTarget = editTarget
    self.lookupRelation = lookupRelation
    self.aiSessionKey = aiSessionKey
  }

  /// Creates an error result of the connection `aiSessionKey` (see `aiSessionKey`)
  nonisolated static func errorResult(
    _ message: String, executionTime: TimeInterval = 0, sourceQuery: String? = nil,
    aiSessionKey: String?
  )
    -> CellResult
  {
    CellResult(
      executionTime: executionTime,
      timestamp: Date(),
      error: message,
      sourceQuery: sourceQuery,
      aiSessionKey: aiSessionKey
    )
  }
}

/// Opaque table identity. Callers compare values. PostgreSQL builds `pg:<oid>` in `Dblore/Database`.
/// Compared and hashed by Unicode scalars: canonically equivalent names (NFC and NFD) are two
/// different tables, so an edit keyed by one never resolves to the other.
nonisolated struct TableRef: Hashable, Sendable, Codable {
  private let rawValue: String

  nonisolated static func == (lhs: TableRef, rhs: TableRef) -> Bool {
    lhs.rawValue.unicodeScalars.elementsEqual(rhs.rawValue.unicodeScalars)
  }

  nonisolated func hash(into hasher: inout Hasher) {
    for scalar in rawValue.unicodeScalars { hasher.combine(scalar.value) }
  }

  nonisolated init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    rawValue = try container.decode(String.self)
  }

  nonisolated func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  /// Identity text. An engine parses its own prefix next to the factory that builds it.
  var identity: String { rawValue }
}

/// Where a result column came from: a table identity and a column ordinal in that table.
nonisolated struct ColumnOrigin: Hashable, Sendable, Codable {
  let tableID: TableRef
  let columnOrdinal: Int
}

/// Exact schema, table and column names of a result column (MySQL `schema`, `org_table`,
/// `org_name`). The `mysql:` table identity is built from these, never split back.
nonisolated struct ColumnSourceName: Hashable, Sendable {
  let schema: String
  let table: String
  let column: String
}

nonisolated extension CellResult: Equatable {}

/// Information about a result column
struct ColumnInfo: Codable, Identifiable, Sendable {
  nonisolated var id: String { name }
  nonisolated let name: String
  nonisolated let type: String
  /// Source table and column from the server's row description. nil when unknown.
  nonisolated let origin: ColumnOrigin?
  /// MySQL: source names from the column definition, until the manager resolves `origin`.
  /// Never persisted.
  nonisolated let sourceName: ColumnSourceName?
  /// A naive date-time column (PostgreSQL `timestamp`, MySQL DATETIME, DuckDB TIMESTAMP): its
  /// `.date` values hold the stored wall clock as a UTC instant and show without a time zone.
  /// Set once by the session that read the column; false (zoned) when unknown.
  nonisolated let wallClock: Bool
  /// A column a mask rule matched: its cells hold mask text, never the stored value. Set by
  /// the manager after the read; false when no rule matched.
  nonisolated let masked: Bool

  nonisolated init(
    name: String, type: String, origin: ColumnOrigin? = nil, sourceName: ColumnSourceName? = nil,
    wallClock: Bool = false, masked: Bool = false
  ) {
    self.name = name
    self.type = type
    self.origin = origin
    self.sourceName = sourceName
    self.wallClock = wallClock
    self.masked = masked
  }

  private enum CodingKeys: String, CodingKey {
    case name, type, origin, tableOID, attributeNumber, wallClock, masked
  }

  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    type = try container.decode(String.self, forKey: .type)
    if let origin = try container.decodeIfPresent(ColumnOrigin.self, forKey: .origin) {
      self.origin = origin
    } else if let oid = try container.decodeIfPresent(UInt32.self, forKey: .tableOID),
      let attributeNumber = try container.decodeIfPresent(Int16.self, forKey: .attributeNumber)
    {
      self.origin = ColumnOrigin(
        tableID: TableRef.postgresql(oid: oid), columnOrdinal: Int(attributeNumber))
    } else {
      self.origin = nil
    }
    sourceName = nil
    wallClock = try container.decodeIfPresent(Bool.self, forKey: .wallClock) ?? false
    masked = try container.decodeIfPresent(Bool.self, forKey: .masked) ?? false
  }

  nonisolated func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(type, forKey: .type)
    try container.encodeIfPresent(origin, forKey: .origin)
    if wallClock { try container.encode(true, forKey: .wallClock) }
    if masked { try container.encode(true, forKey: .masked) }
  }
}

nonisolated extension ColumnInfo: Equatable {}

/// A value in a result cell, supporting multiple SQL types
enum CellValue: Codable, Equatable, Sendable, Comparable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case null
  case json(String)
  case date(Date)
  case data(Data)
  /// Exact NUMERIC / DECIMAL text, never rounded through Double
  case decimal(String)

  /// Empty value of the case a `columnType` value decodes to (`postgresDataTypeName` names):
  /// the type a NULL cell of that column takes once it gets a value. NUMERIC and DECIMAL, with
  /// or without a modifier (`numeric(10,2)`), are exact decimal text. Other types (arrays, uuid,
  /// user-defined) are text.
  nonisolated static func placeholder(forColumnType columnType: String) -> CellValue {
    let upper = columnType.uppercased()
    switch upper {
    case "BOOLEAN": return .bool(false)
    case "SMALLINT", "INTEGER", "BIGINT": return .int(0)
    case "REAL", "DOUBLE PRECISION": return .double(0)
    case "DATE", "TIMESTAMP", "TIMESTAMPTZ": return .date(Date(timeIntervalSince1970: 0))
    case "JSON", "JSONB": return .json("")
    case "BYTEA": return .data(Data())
    default:
      let base = upper.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
      return base == "NUMERIC" || base == "DECIMAL" ? .decimal("0") : .string("")
    }
  }

  private nonisolated(unsafe) static let iso8601Formatter = ISO8601DateFormatter()

  /// Display string for the value, a date as zoned (`displayString(wallClock: false)`).
  /// Nonisolated: the notebook search scans it off the main actor
  nonisolated var displayString: String { displayString(wallClock: false) }

  /// Display string for a value of a column whose `ColumnInfo.wallClock` is `wallClock`.
  /// A date shows `yyyy-MM-dd HH:mm:ss[.ffffff]` (fraction without trailing zeros): naive
  /// (`wallClock`) in UTC with no zone, so the stored wall clock; zoned in the Mac's time zone
  /// followed by its offset, `±HH:MM`.
  nonisolated func displayString(wallClock: Bool) -> String {
    switch self {
    case .string(let value):
      return value
    case .int(let value):
      return String(value)
    case .double(let value):
      // Shortest round-trip text, so distinct values never share a label
      if value.isNaN { return "NaN" }
      if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
      return String(value)
    case .bool(let value):
      return value ? "true" : "false"
    case .null:
      return "NULL"
    case .json(let value):
      // Show preview for JSON
      if value.hasPrefix("{") {
        return "{...}"
      } else if value.hasPrefix("[") {
        return "[...]"
      }
      return value
    case .date(let value):
      return Self.dateText(value, wallClock: wallClock)
    case .data(let value):
      return "<\(value.count) bytes>"
    case .decimal(let value):
      return value
    }
  }

  /// The zone zoned dates show in, for tests: set per task, so a test never changes the
  /// process-wide default zone under suites running beside it. Nil is `NSTimeZone.default`.
  @TaskLocal nonisolated static var displayZone: TimeZone?

  /// `date` as `displayString(wallClock:)` text, or with `iso` as the zoned `outputString`
  /// (UTC, `T` separator, `Z`), built from whole microseconds in the proleptic Gregorian
  /// calendar (the engines' own), so a stored `.123456` never shows as `.123455`.
  /// A date beyond the microsecond range falls back to ISO 8601.
  private nonisolated static func dateText(
    _ date: Date, wallClock: Bool, iso: Bool = false
  ) -> String {
    // The default zone is the Mac's own unless set (TimeZone.current ignores a set default)
    let offset =
      wallClock || iso ? 0 : (displayZone ?? NSTimeZone.default).secondsFromGMT(for: date)
    guard
      let utcMicros = Int64(exactly: (date.timeIntervalSince1970 * 1_000_000).rounded()),
      case (let micros, false) = utcMicros.addingReportingOverflow(Int64(offset) * 1_000_000)
    else { return iso8601Formatter.string(from: date) }
    let perDay: Int64 = 86_400_000_000
    // Floor division without `days * perDay`, which overflows next to Int64.min
    var days = micros / perDay
    var ofDay = micros % perDay
    if ofDay < 0 {
      days -= 1
      ofDay += perDay
    }
    let seconds = Int(ofDay / 1_000_000)
    var text =
      CivilDate.text(daysSince1970: Int(days), bcSuffix: "")
      + (iso ? "T" : " ")
      + String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
    let fraction = Int(ofDay % 1_000_000)
    if fraction != 0 {
      var digits = String(format: "%06d", fraction)
      while digits.hasSuffix("0") { digits.removeLast() }
      text += "." + digits
    }
    if iso {
      text += "Z"
    } else if !wallClock {
      let magnitude = abs(offset)
      text +=
        (offset < 0 ? "-" : "+")
        + String(format: "%02d:%02d", magnitude / 3_600, magnitude / 60 % 60)
      // A local mean time offset before standard zones keeps its seconds
      if magnitude % 60 != 0 { text += String(format: ":%02d", magnitude % 60) }
    }
    // Year 0 and before (1 BC and before), marked the way PostgreSQL prints it
    return days < -719_162 ? text + " BC" : text
  }

  /// Full string representation (not truncated), a date as zoned (`outputString(wallClock:
  /// false)`). Nonisolated: CSV export builds off the main actor
  nonisolated var fullString: String { outputString(wallClock: false) }

  /// Full text of a value of a column whose `ColumnInfo.wallClock` is `wallClock`, for text
  /// outputs (copy, CSV/TSV/JSON/XLSX exports): unambiguous wherever it is pasted. A date is
  /// naive `yyyy-MM-dd HH:mm:ss[.ffffff]` (the stored wall clock, no zone) or zoned ISO 8601 UTC
  /// `yyyy-MM-ddTHH:mm:ss[.ffffff]Z`, fraction without trailing zeros.
  nonisolated func outputString(wallClock: Bool) -> String {
    switch self {
    case .string(let value):
      return value
    case .int(let value):
      return String(value)
    case .double(let value):
      return String(value)
    case .bool(let value):
      return value ? "true" : "false"
    case .null:
      return "NULL"
    case .json(let value):
      return value
    case .date(let value):
      return Self.dateText(value, wallClock: wallClock, iso: !wallClock)
    case .data(let value):
      return value.base64EncodedString()
    case .decimal(let value):
      return value
    }
  }

  nonisolated var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  nonisolated var isJSON: Bool {
    if case .json = self { return true }
    return false
  }

  // MARK: - Comparable

  /// Sort priority for different types (null always last)
  private var sortPriority: Int {
    switch self {
    case .null: return 999  // Nulls sort last
    case .bool: return 0
    case .int: return 1
    case .double: return 2
    case .date: return 3
    case .string: return 4
    case .json: return 5
    case .data: return 6
    case .decimal: return 2
    }
  }

  /// Numbers (`int`, `double`, `decimal`) order by exact value (`DecimalText.Number`), the rest
  /// by type then value; NULL is last
  static func < (lhs: CellValue, rhs: CellValue) -> Bool {
    // Nulls always sort last
    if case .null = lhs { return false }
    if case .null = rhs { return true }

    if let order = numericOrder(lhs, rhs) { return order < 0 }

    // Compare same types directly
    switch (lhs, rhs) {
    case (.string(let l), .string(let r)):
      return l.localizedStandardCompare(r) == .orderedAscending
    case (.bool(let l), .bool(let r)):
      return !l && r  // false < true
    case (.date(let l), .date(let r)):
      return l < r
    case (.json(let l), .json(let r)):
      return l.localizedStandardCompare(r) == .orderedAscending
    case (.data(let l), .data(let r)):
      return l.count < r.count
    default:
      // Different types: compare by sort priority
      return lhs.sortPriority < rhs.sortPriority
    }
  }

  /// -1, 0 or 1 when both values are numbers, else nil. Plain Int and Double comparisons
  /// decide every pair they can without disagreeing with `DecimalText.Number`'s order; the rest
  /// (decimals, NaN, an Int and the Double it rounds to) compare as `DecimalText.Number`.
  private nonisolated static func numericOrder(_ lhs: CellValue, _ rhs: CellValue) -> Int? {
    switch (lhs, rhs) {
    case (.int(let l), .int(let r)):
      return l < r ? -1 : (l == r ? 0 : 1)
    case (.double(let l), .double(let r)) where !l.isNaN && !r.isNaN:
      return l < r ? -1 : (l == r ? 0 : 1)
    case (.int(let l), .double(let r)) where !r.isNaN && Double(l) != r:
      return Double(l) < r ? -1 : 1
    case (.double(let l), .int(let r)) where !l.isNaN && l != Double(r):
      return l < Double(r) ? -1 : 1
    default:
      guard let l = DecimalText.Number(lhs), let r = DecimalText.Number(rhs) else { return nil }
      return DecimalText.compare(l, r)
    }
  }
}

/// Decimal text (`CellValue.decimal`): its grammar and its exact order, never through Double
nonisolated enum DecimalText {
  /// Plain decimal digits, `^-?[0-9]+(\.[0-9]+)?$` (ASCII digits only): the only decimal text
  /// a SQL literal writes unquoted
  static func isPlain(_ text: String) -> Bool {
    var bytes = text.utf8[...]
    if bytes.first == UInt8(ascii: "-") { bytes = bytes.dropFirst() }
    let integer = bytes.prefix { isDigit($0) }
    guard !integer.isEmpty else { return false }
    let rest = bytes.dropFirst(integer.count)
    if rest.isEmpty { return true }
    guard rest.first == UInt8(ascii: ".") else { return false }
    let fraction = rest.dropFirst()
    return !fraction.isEmpty && fraction.allSatisfy(isDigit)
  }

  /// Text a `.decimal` may hold: plain digits (`isPlain`) or PostgreSQL NUMERIC's `NaN`,
  /// `Infinity` and `-Infinity`, spelled as the server writes them. No exponent, no `+`, no
  /// space: an edit, a new row and a saved notebook only make a `.decimal` of this text.
  static func isValid(_ text: String) -> Bool {
    isPlain(text) || text == "NaN" || text == "Infinity" || text == "-Infinity"
  }

  /// Longest plain text an exponent is written out to
  static let maxExpandedLength = 1_000

  /// `plain(fromNumberToken:)`'s reading of a number token
  enum Expansion: Equatable, Sendable {
    case plain(String)
    /// Written out, longer than `maxExpandedLength` characters
    case tooLong
    case notANumber
  }

  /// A number token as plain digits (`isPlain`), exact and never through Double. A token with no
  /// exponent is used as written. With one (`e` or `E`, an optional sign, leading zeros allowed)
  /// the point moves in the token text: zeros pad it, a `0` goes before a leading point
  /// (`5e-1` → `0.5`), a trailing point is dropped (`1E+2` → `100`) and mantissa digits are
  /// never trimmed (`1.50e1` → `15.0`, `-0e0` → `-0`). The length limit is read from the
  /// exponent text before any arithmetic, so no exponent can overflow: the text is never
  /// shorter than the exponent's size.
  static func plain(fromNumberToken token: String) -> Expansion {
    let bytes = Array(token.utf8)
    guard
      let marker = bytes.firstIndex(where: { $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") })
    else { return isPlain(token) ? .plain(token) : .notANumber }
    let mantissa = String(decoding: bytes[..<marker], as: UTF8.self)
    guard isPlain(mantissa) else { return .notANumber }
    var exponentText = bytes[(marker + 1)...]
    let negativeExponent = exponentText.first == UInt8(ascii: "-")
    if negativeExponent || exponentText.first == UInt8(ascii: "+") {
      exponentText = exponentText.dropFirst()
    }
    guard !exponentText.isEmpty, exponentText.allSatisfy(isDigit) else { return .notANumber }
    let significant = exponentText.drop { $0 == UInt8(ascii: "0") }
    guard significant.count <= 4 else { return .tooLong }
    let size = significant.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
    guard size <= maxExpandedLength else { return .tooLong }
    let exponent = negativeExponent ? -size : size

    let negative = mantissa.hasPrefix("-")
    let parts = mantissa.utf8.dropFirst(negative ? 1 : 0)
      .split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
    let digits = Array(parts.joined())
    let point = parts[0].count + exponent
    let length =
      (negative ? 1 : 0)
      + (point <= 0 ? 2 - point + digits.count : (point >= digits.count ? point : digits.count + 1))
    guard length <= maxExpandedLength else { return .tooLong }

    var text: [UInt8] = negative ? [UInt8(ascii: "-")] : []
    text.reserveCapacity(length)
    if point <= 0 {
      text += Array("0.".utf8) + [UInt8](repeating: UInt8(ascii: "0"), count: -point) + digits
    } else if point >= digits.count {
      text += digits + [UInt8](repeating: UInt8(ascii: "0"), count: point - digits.count)
    } else {
      text += digits[..<point] + [UInt8(ascii: ".")] + digits[point...]
    }
    return .plain(String(decoding: text, as: UTF8.self))
  }

  /// Typed text a `.decimal` takes: valid text (`isValid`) as typed, or a number with an
  /// exponent written out as plain digits (`plain(fromNumberToken:)`); nil for any other text
  static func exactText(typed text: String) -> String? {
    if isValid(text) { return text }
    if case .plain(let written) = plain(fromNumberToken: text) { return written }
    return nil
  }

  /// A number as one total order: -Infinity, then finite values by exact value, Infinity, NaN
  /// (PostgreSQL's order; all NaNs equal), then decimal text that is no number, by its text.
  nonisolated enum Number {
    case negativeInfinity
    case finite(Finite)
    case positiveInfinity
    case nan
    case unparsed(String)

    /// Nil for a value that is not a number. A double is the value of its shortest text
    /// (`String(Double)`), so `.double(0.1)` equals `.decimal("0.1")`.
    init?(_ value: CellValue) {
      switch value {
      case .int(let number):
        self = Finite(String(number)).map(Number.finite) ?? .unparsed(String(number))
      case .double(let number):
        if number.isNaN {
          self = .nan
        } else if number.isInfinite {
          self = number > 0 ? .positiveInfinity : .negativeInfinity
        } else {
          let text = String(number)
          self = Finite(text).map(Number.finite) ?? .unparsed(text)
        }
      case .decimal(let text):
        switch text {
        case "NaN": self = .nan
        case "Infinity": self = .positiveInfinity
        case "-Infinity": self = .negativeInfinity
        default: self = Finite(text).map(Number.finite) ?? .unparsed(text)
        }
      default:
        return nil
      }
    }

    fileprivate var rank: Int {
      switch self {
      case .negativeInfinity: 0
      case .finite: 1
      case .positiveInfinity: 2
      case .nan: 3
      case .unparsed: 4
      }
    }
  }

  /// A finite value as `±0.d₁d₂…dₙ × 10^point`: `digits` (ASCII) have no leading or trailing
  /// zero, and are empty for zero (never negative)
  nonisolated struct Finite {
    let negative: Bool
    let digits: [UInt8]
    let point: Int

    /// `[-+]digits[.digits][e[-+]digits]` (at least one mantissa digit, an exponent of at most
    /// 6 digits after its leading zeros), as `String(Double)` writes too; nil otherwise
    init?(_ text: String) {
      var bytes = text.utf8[...]
      let sign = bytes.first
      let negative = sign == UInt8(ascii: "-")
      if sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") { bytes = bytes.dropFirst() }
      var digits: [UInt8] = []
      digits.reserveCapacity(bytes.count)
      var point = 0
      var sawDigit = false
      var inFraction = false
      while let byte = bytes.first, byte != UInt8(ascii: "e"), byte != UInt8(ascii: "E") {
        bytes = bytes.dropFirst()
        if byte == UInt8(ascii: "."), !inFraction {
          inFraction = true
          continue
        }
        guard DecimalText.isDigit(byte) else { return nil }
        sawDigit = true
        if digits.isEmpty && byte == UInt8(ascii: "0") {
          if inFraction { point -= 1 }
          continue
        }
        digits.append(byte)
        if !inFraction { point += 1 }
      }
      guard sawDigit else { return nil }
      if !bytes.isEmpty {
        bytes = bytes.dropFirst()
        let exponentSign = bytes.first
        if exponentSign == UInt8(ascii: "-") || exponentSign == UInt8(ascii: "+") {
          bytes = bytes.dropFirst()
        }
        guard !bytes.isEmpty, bytes.allSatisfy(DecimalText.isDigit) else { return nil }
        let significant = bytes.drop { $0 == UInt8(ascii: "0") }
        guard significant.count <= 6 else { return nil }
        let exponent = significant.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
        point += exponentSign == UInt8(ascii: "-") ? -exponent : exponent
      }
      while digits.last == UInt8(ascii: "0") { digits.removeLast() }
      self.negative = negative && !digits.isEmpty
      self.digits = digits
      self.point = digits.isEmpty ? 0 : point
    }

    fileprivate var sign: Int { digits.isEmpty ? 0 : (negative ? -1 : 1) }
  }

  /// -1, 0 or 1: `lhs` below, equal to or above `rhs`
  static func compare(_ lhs: Number, _ rhs: Number) -> Int {
    switch (lhs, rhs) {
    case (.finite(let l), .finite(let r)):
      return compare(l, r)
    case (.unparsed(let l), .unparsed(let r)):
      return l < r ? -1 : (l == r ? 0 : 1)
    default:
      return lhs.rank < rhs.rank ? -1 : (lhs.rank == rhs.rank ? 0 : 1)
    }
  }

  private static func compare(_ lhs: Finite, _ rhs: Finite) -> Int {
    guard lhs.sign == rhs.sign else { return lhs.sign < rhs.sign ? -1 : 1 }
    guard lhs.sign != 0 else { return 0 }
    guard lhs.point == rhs.point else { return lhs.point < rhs.point ? -lhs.sign : lhs.sign }
    for (l, r) in zip(lhs.digits, rhs.digits) where l != r {
      return l < r ? -lhs.sign : lhs.sign
    }
    // Same leading digits: the longer one has a further non-zero digit
    guard lhs.digits.count != rhs.digits.count else { return 0 }
    return lhs.digits.count < rhs.digits.count ? -lhs.sign : lhs.sign
  }

  fileprivate static func isDigit(_ byte: UInt8) -> Bool {
    byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
  }
}
