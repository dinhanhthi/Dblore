// MongoSchemaFilter.swift
// Filter text edited by clicks in the collection's Schema tab. A click sets one field's condition
// (equality, `$type` or `$exists: false`); a shift-click adds a value to the field's `$in`. Other
// fields stay (AND). The result is mongosh text that the filter parser reads back.

import Foundation

nonisolated enum MongoSchemaFilter {
  /// What a schema click filters on.
  nonisolated enum Kind: Equatable, Sendable {
    /// Equality with an exact value (`ValueShare.filterValue`).
    case value(MongoValue)
    /// `$type` with a BSON type alias (`TypeShare.name`).
    case type(String)
    /// `$exists: false` (the "undefined" type share).
    case missing
  }

  nonisolated struct Condition: Equatable, Sendable {
    /// The analyzer's key path (`Field.keyPath`), one key per segment.
    let keyPath: [String]
    let kind: Kind
  }

  nonisolated enum FilterError: Error, Equatable, Sendable, LocalizedError {
    /// A key of the path holds a dot or starts with `$`: no dotted path addresses it.
    case notAddressable(field: String)
    /// The current filter text does not parse or is not a document.
    case invalidFilter(DataViewerState.DocumentFilterError)

    var errorDescription: String? {
      switch self {
      case .notAddressable(let field):
        "The field \"\(field)\" cannot be filtered on: a key holding a dot or starting with $ "
          + "has no dotted path."
      case .invalidFilter(let error): error.errorDescription
      }
    }
  }

  /// `filterText` (blank is `{}`) with `condition` applied. Without `adding` the field's condition
  /// becomes the new one; with `adding` a value joins the field's `$in` (an equality becomes
  /// `$in: [old, new]`, a value already there is not repeated), and any other condition is
  /// replaced. The field keeps its position; a new field goes last. Of duplicate keys in the
  /// text, the first is edited and the rest stay as they are.
  static func apply(_ condition: Condition, to filterText: String, adding: Bool) throws -> String {
    if let key = condition.keyPath.first(where: { $0.contains(".") || $0.hasPrefix("$") }) {
      throw FilterError.notAddressable(field: key)
    }
    var fields: [MongoValue.Field]
    switch DataViewerState.documentFilterValue(filterText) {
    case .success(.document(let parsed)?): fields = parsed
    case .success: fields = []
    case .failure(let error): throw FilterError.invalidFilter(error)
    }
    let path = condition.keyPath.joined(separator: ".")
    let index = fields.firstIndex { $0.key == path }
    let existing = index.map { fields[$0].value }
    let value: MongoValue
    switch condition.kind {
    case .value(let new): value = adding ? added(new, to: existing) : new
    case .type(let alias): value = .document([MongoValue.Field("$type", .string(alias))])
    case .missing: value = .document([MongoValue.Field("$exists", .bool(false))])
    }
    if let index {
      fields[index].value = value
    } else {
      fields.append(MongoValue.Field(path, value))
    }
    return MongoRelaxedJSON.render(.document(fields), as: .mongosh)
  }

  /// `new` joined to the field's `$in`. `existing` is an equality (a document is an operator
  /// document when a key starts with `$`), a lone `$in`, or another condition (replaced).
  private static func added(_ new: MongoValue, to existing: MongoValue?) -> MongoValue {
    guard let existing, existing != new else { return new }
    var values = [existing]
    if case .document(let fields) = existing, fields.contains(where: { $0.key.hasPrefix("$") }) {
      guard fields.count == 1, fields[0].key == "$in", case .array(let items) = fields[0].value
      else { return new }
      values = items
    }
    if !values.contains(new) { values.append(new) }
    return .document([MongoValue.Field("$in", .array(values))])
  }
}
