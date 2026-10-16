// MongoQueryOptions.swift
// The Documents bar's query options as typed (project, sort, collation, hint, skip, limit,
// maxTimeMS), and their typed values for the data viewer's find and countDocuments.

import Foundation

/// Query options of the MongoDB Documents bar, as typed. A blank text means the option is unset.
nonisolated struct MongoQueryOptions: Codable, Hashable, Sendable {
  var project = ""
  var sort = ""
  var collation = ""
  /// An index key document, a quoted index name, or a bare index name
  var hint = ""
  var skip = ""
  var limit = ""
  var maxTimeMS = ""

  /// The typed options. Nil (or `CursorOptions.none` fields) for unset options; an empty
  /// document is the same as no document.
  nonisolated struct Parsed: Equatable, Sendable {
    var projection: MongoValue? = nil
    var sort: [MongoValue.Field]? = nil
    var cursor = MongoCommand.CursorOptions.none
    var skip: Int? = nil
    var limit: Int? = nil
  }

  private var texts: [String] { [project, sort, collation, hint, skip, limit, maxTimeMS] }

  /// Number of set options, for the collapsed "Options (n)" label
  var setCount: Int { texts.filter { !Self.trimmed($0).isEmpty }.count }

  var isEmpty: Bool { setCount == 0 }

  /// The typed options. Throws for the first option that is not valid, naming it.
  func parsed() throws(DataViewerState.DocumentFilterError) -> Parsed {
    var parsed = Parsed()
    parsed.projection = try Self.document(project, "Project", example: "{name: 1}")
      .map { .document($0) }
    parsed.sort = try Self.document(sort, "Sort", example: "{age: -1}")
    parsed.cursor.collation = try Self.document(collation, "Collation", example: #"{locale: "en"}"#)
      .map { .document($0) }
    parsed.cursor.hint = try Self.hintValue(hint)
    parsed.skip = try Self.integer(skip, "Skip", minimum: 0)
    parsed.limit = try Self.integer(limit, "Limit", minimum: 1)
    parsed.cursor.maxTimeMS = try Self.integer(maxTimeMS, "maxTimeMS", minimum: 0)
    return parsed
  }

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The fields of a document option, nil when blank or `{}`.
  private static func document(
    _ text: String, _ name: String, example: String
  ) throws(DataViewerState.DocumentFilterError) -> [MongoValue.Field]? {
    guard !trimmed(text).isEmpty else { return nil }
    guard case .document(let fields) = try value(text, name) else {
      throw DataViewerState.DocumentFilterError(
        message: "\(name) must be a document, e.g. \(example)", offset: nil)
    }
    return fields.isEmpty ? nil : fields
  }

  /// A key document or a quoted name is parsed; any other text is a bare index name.
  private static func hintValue(
    _ text: String
  ) throws(DataViewerState.DocumentFilterError) -> MongoValue? {
    let text = trimmed(text)
    guard let first = text.first else { return nil }
    guard first == "{" || first == "\"" || first == "'" else { return .string(text) }
    switch try value(text, "Hint") {
    case .document(let fields): return fields.isEmpty ? nil : .document(fields)
    case .string(let name): return .string(name)
    default:
      throw DataViewerState.DocumentFilterError(
        message: "Hint must be an index name or a key document, e.g. {age: 1}", offset: nil)
    }
  }

  private static func value(
    _ text: String, _ name: String
  ) throws(DataViewerState.DocumentFilterError) -> MongoValue {
    do {
      return try MongoRelaxedJSON.parse(text)
    } catch {
      throw DataViewerState.DocumentFilterError(
        message: "\(name): \(error.message)", offset: error.offset)
    }
  }

  /// A whole number of at least `minimum`, nil when blank.
  private static func integer(
    _ text: String, _ name: String, minimum: Int
  ) throws(DataViewerState.DocumentFilterError) -> Int? {
    let text = trimmed(text)
    guard !text.isEmpty else { return nil }
    guard let number = Int(text), number >= minimum else {
      throw DataViewerState.DocumentFilterError(
        message: "\(name) must be a whole number, \(minimum) or more", offset: nil)
    }
    return number
  }
}

extension MongoQueryOptions {
  /// Every option is optional, so options saved before one existed still load
  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func text(_ key: CodingKeys) throws -> String {
      try container.decodeIfPresent(String.self, forKey: key) ?? ""
    }
    project = try text(.project)
    sort = try text(.sort)
    collation = try text(.collation)
    hint = try text(.hint)
    skip = try text(.skip)
    limit = try text(.limit)
    maxTimeMS = try text(.maxTimeMS)
  }
}
