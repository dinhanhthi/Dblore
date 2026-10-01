// ExplainPlan.swift
// Decode PostgreSQL EXPLAIN (FORMAT JSON) into a plan tree.

import Foundation

/// A JSON value kept for EXPLAIN keys this model does not name.
nonisolated enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value"
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}

/// Why `ExplainPlan.parse` rejected a cell.
nonisolated enum ExplainPlanError: Error, Equatable, Sendable {
  /// The cell was neither JSON nor text.
  case unsupportedValue
  /// The text was not JSON, or it had no plan object.
  case malformed
}

/// One row of the `Triggers` array on an `EXPLAIN` result.
nonisolated struct ExplainTrigger: Decodable, Equatable, Sendable {
  var name: String
  var time: Double?

  private enum CodingKeys: String, CodingKey {
    case name = "Trigger Name"
    case time = "Time"
  }
}

/// One node in an `EXPLAIN` tree. Missing keys stay nil. Unknown keys land in `extras`.
nonisolated struct ExplainNode: Decodable, Equatable, Sendable {
  var nodeType: String?
  var relationName: String?
  var alias: String?
  var indexName: String?
  var joinType: String?
  var strategy: String?
  var startupCost: Double?
  var totalCost: Double?
  var planRows: Double?
  var planWidth: Int?
  var actualStartupTime: Double?
  var actualTotalTime: Double?
  var actualRows: Double?
  var actualLoops: Double?
  var workersPlanned: Int?
  var workersLaunched: Int?
  var sharedHitBlocks: Int?
  var sharedReadBlocks: Int?
  var sharedDirtiedBlocks: Int?
  var sharedWrittenBlocks: Int?
  var localHitBlocks: Int?
  var localReadBlocks: Int?
  var localDirtiedBlocks: Int?
  var localWrittenBlocks: Int?
  var tempHitBlocks: Int?
  var tempReadBlocks: Int?
  var tempDirtiedBlocks: Int?
  var tempWrittenBlocks: Int?
  var sortMethod: String?
  var sortSpaceType: String?
  var sortSpaceUsed: Int?
  var filter: String?
  var indexCond: String?
  var hashCond: String?
  var rowsRemovedByFilter: Int?
  var output: [String]?
  var parentRelationship: String?
  var children: [ExplainNode]
  var extras: [String: JSONValue]

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case nodeType = "Node Type"
    case relationName = "Relation Name"
    case alias = "Alias"
    case indexName = "Index Name"
    case joinType = "Join Type"
    case strategy = "Strategy"
    case startupCost = "Startup Cost"
    case totalCost = "Total Cost"
    case planRows = "Plan Rows"
    case planWidth = "Plan Width"
    case actualStartupTime = "Actual Startup Time"
    case actualTotalTime = "Actual Total Time"
    case actualRows = "Actual Rows"
    case actualLoops = "Actual Loops"
    case workersPlanned = "Workers Planned"
    case workersLaunched = "Workers Launched"
    case sharedHitBlocks = "Shared Hit Blocks"
    case sharedReadBlocks = "Shared Read Blocks"
    case sharedDirtiedBlocks = "Shared Dirtied Blocks"
    case sharedWrittenBlocks = "Shared Written Blocks"
    case localHitBlocks = "Local Hit Blocks"
    case localReadBlocks = "Local Read Blocks"
    case localDirtiedBlocks = "Local Dirtied Blocks"
    case localWrittenBlocks = "Local Written Blocks"
    case tempHitBlocks = "Temp Hit Blocks"
    case tempReadBlocks = "Temp Read Blocks"
    case tempDirtiedBlocks = "Temp Dirtied Blocks"
    case tempWrittenBlocks = "Temp Written Blocks"
    case sortMethod = "Sort Method"
    case sortSpaceType = "Sort Space Type"
    case sortSpaceUsed = "Sort Space Used"
    case filter = "Filter"
    case indexCond = "Index Cond"
    case hashCond = "Hash Cond"
    case rowsRemovedByFilter = "Rows Removed by Filter"
    case output = "Output"
    case parentRelationship = "Parent Relationship"
    case children = "Plans"
  }

  private static let modeledKeys = Set(CodingKeys.allCases.map(\.rawValue))

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func field<T: Decodable>(_ key: CodingKeys, as type: T.Type = T.self) throws -> T? {
      try container.decodeIfPresent(type, forKey: key)
    }

    nodeType = try field(.nodeType)
    relationName = try field(.relationName)
    alias = try field(.alias)
    indexName = try field(.indexName)
    joinType = try field(.joinType)
    strategy = try field(.strategy)
    startupCost = try field(.startupCost)
    totalCost = try field(.totalCost)
    planRows = try field(.planRows)
    planWidth = try field(.planWidth)
    actualStartupTime = try field(.actualStartupTime)
    actualTotalTime = try field(.actualTotalTime)
    actualRows = try field(.actualRows)
    actualLoops = try field(.actualLoops)
    workersPlanned = try field(.workersPlanned)
    workersLaunched = try field(.workersLaunched)
    sharedHitBlocks = try field(.sharedHitBlocks)
    sharedReadBlocks = try field(.sharedReadBlocks)
    sharedDirtiedBlocks = try field(.sharedDirtiedBlocks)
    sharedWrittenBlocks = try field(.sharedWrittenBlocks)
    localHitBlocks = try field(.localHitBlocks)
    localReadBlocks = try field(.localReadBlocks)
    localDirtiedBlocks = try field(.localDirtiedBlocks)
    localWrittenBlocks = try field(.localWrittenBlocks)
    tempHitBlocks = try field(.tempHitBlocks)
    tempReadBlocks = try field(.tempReadBlocks)
    tempDirtiedBlocks = try field(.tempDirtiedBlocks)
    tempWrittenBlocks = try field(.tempWrittenBlocks)
    sortMethod = try field(.sortMethod)
    sortSpaceType = try field(.sortSpaceType)
    sortSpaceUsed = try field(.sortSpaceUsed)
    filter = try field(.filter)
    indexCond = try field(.indexCond)
    hashCond = try field(.hashCond)
    rowsRemovedByFilter = try field(.rowsRemovedByFilter)
    output = try field(.output)
    parentRelationship = try field(.parentRelationship)
    children = try field(.children) ?? []

    let raw = try decoder.container(keyedBy: DynamicCodingKey.self)
    var extras: [String: JSONValue] = [:]
    for key in raw.allKeys where !Self.modeledKeys.contains(key.stringValue) {
      extras[key.stringValue] = try raw.decode(JSONValue.self, forKey: key)
    }
    self.extras = extras
  }
}

/// The first plan in an `EXPLAIN (FORMAT JSON)` document.
nonisolated struct ExplainPlan: Decodable, Equatable, Sendable {
  var planningTime: Double?
  var executionTime: Double?
  var root: ExplainNode
  var triggers: [ExplainTrigger]

  /// Reads a plan from a JSON or text cell.
  /// The body is `[{"Plan": …}]` or `{"Plan": …}`. An array uses the first element.
  static func parse(_ value: CellValue) throws -> ExplainPlan {
    switch value {
    case .json(let text), .string(let text):
      return try decode(text)
    default:
      throw ExplainPlanError.unsupportedValue
    }
  }

  private static func decode(_ text: String) throws -> ExplainPlan {
    guard let data = text.data(using: .utf8) else {
      throw ExplainPlanError.malformed
    }
    let decoder = JSONDecoder()
    if let plans = try? decoder.decode([ExplainPlan].self, from: data) {
      guard let first = plans.first else { throw ExplainPlanError.malformed }
      return first
    }
    if let plan = try? decoder.decode(ExplainPlan.self, from: data) {
      return plan
    }
    throw ExplainPlanError.malformed
  }

  private enum CodingKeys: String, CodingKey {
    case planningTime = "Planning Time"
    case executionTime = "Execution Time"
    case root = "Plan"
    case triggers = "Triggers"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    planningTime = try container.decodeIfPresent(Double.self, forKey: .planningTime)
    executionTime = try container.decodeIfPresent(Double.self, forKey: .executionTime)
    root = try container.decode(ExplainNode.self, forKey: .root)
    triggers = try container.decodeIfPresent([ExplainTrigger].self, forKey: .triggers) ?? []
  }
}

private struct DynamicCodingKey: CodingKey, Hashable {
  var stringValue: String
  var intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init?(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}
