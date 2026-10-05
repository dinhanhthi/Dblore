//
//  QueryParameter.swift
//  Dblore
//

import Foundation

/// A named SQL parameter stored on a notebook.
/// Nil `value` is SQL NULL. Names match exactly, with no case-folding.
nonisolated struct QueryParameter: Codable, Equatable, Sendable {
  var name: String
  var value: String?
}

nonisolated extension Array where Element == QueryParameter {
  /// Values for `names` in request order. The first stored parameter for a name wins.
  /// Missing names are distinct and stay in request order. Extra stored parameters are ignored.
  func bindValues(for names: [String]) -> (values: [String: SQLBindValue], missing: [String]) {
    var stored: [String: SQLBindValue] = [:]
    for parameter in self where stored[parameter.name] == nil {
      stored[parameter.name] = SQLBindValue(optionalText: parameter.value)
    }

    var values: [String: SQLBindValue] = [:]
    var missing: [String] = []
    var seen: Set<String> = []
    for name in names {
      guard seen.insert(name).inserted else { continue }
      if let value = stored[name] {
        values[name] = value
      } else {
        missing.append(name)
      }
    }
    return (values, missing)
  }
}
