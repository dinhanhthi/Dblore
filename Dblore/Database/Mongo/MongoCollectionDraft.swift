// MongoCollectionDraft.swift
// The New Collection form as a value: name, one collection kind (plain, capped, clustered on
// `_id` or time series, which the server never combines) and a collation, checked and turned
// into `MongoAdminCommand.createCollection`. Numbers are typed as text; the collation is relaxed
// JSON as in the Documents bar; blank options are left out.

import Foundation

/// One collection to create. `command()` is nil while `validationMessages()` lists a problem.
nonisolated struct MongoCollectionDraft: Equatable, Sendable {
  /// Capped, clustered and time-series collections exclude each other
  nonisolated enum Kind: String, CaseIterable, Sendable {
    case standard
    case capped
    /// Clustered on `_id` (MongoDB 5.3 and later)
    case clustered
    /// MongoDB 5.0 and later; implicitly clustered on the time field
    case timeSeries
  }

  nonisolated enum Granularity: String, CaseIterable, Sendable {
    case seconds, minutes, hours
  }

  var name = ""
  var kind = Kind.standard
  /// Capped: maximum size in bytes, required
  var cappedSize = ""
  /// Capped: maximum document count; blank: no limit
  var cappedMax = ""
  var timeField = ""
  /// Blank: no meta field
  var metaField = ""
  /// Nil: the server's default
  var granularity: Granularity?
  /// Time series: documents expire this long after their time field; blank: never
  var expireAfterSeconds = ""
  var collation = ""

  /// Why `name` cannot name a new collection, nil when it can. The server's own limits (length,
  /// an existing name) are left to its error.
  static func nameProblem(_ name: String) -> String? {
    let name = trimmed(name)
    if name.isEmpty { return "Enter a collection name" }
    if name.contains("$") { return "A collection name cannot contain $" }
    if name.contains("\0") { return "A collection name cannot contain the null character" }
    if name.hasPrefix("system.") { return "Names starting with system. are reserved" }
    return nil
  }

  /// Every problem, in form order; empty when the draft can be created
  func validationMessages() -> [String] {
    var messages: [String] = []
    if let message = Self.nameProblem(name) {
      messages.append(message)
    }
    switch kind {
    case .standard, .clustered:
      break
    case .capped:
      if Self.trimmed(cappedSize).isEmpty {
        messages.append("A capped collection needs a size in bytes")
      } else if Self.positive(cappedSize) == nil {
        messages.append("Size must be a whole number of bytes above 0")
      }
      if !Self.trimmed(cappedMax).isEmpty, Self.positive(cappedMax) == nil {
        messages.append("Max documents must be a whole number above 0")
      }
    case .timeSeries:
      let timeField = Self.trimmed(timeField)
      if timeField.isEmpty {
        messages.append("A time-series collection needs a time field")
      } else if timeField == Self.trimmed(metaField) {
        messages.append("The meta field must differ from the time field")
      }
      if !Self.trimmed(expireAfterSeconds).isEmpty, Self.seconds(expireAfterSeconds) == nil {
        messages.append("Expire after must be a whole number of seconds from 0 to 2147483647")
      }
    }
    if let message = Self.documentProblem(collation, "Collation") {
      messages.append(message)
    }
    return messages
  }

  /// The `createCollection` command, nil while the draft has a problem
  func command() -> MongoAdminCommand? {
    guard validationMessages().isEmpty else { return nil }
    var options: [MongoValue.Field] = []
    switch kind {
    case .standard:
      break
    case .capped:
      options.append(.init("capped", .bool(true)))
      if let size = Self.positive(cappedSize) { options.append(.init("size", size)) }
      if let max = Self.positive(cappedMax) { options.append(.init("max", max)) }
    case .clustered:
      options.append(
        .init(
          "clusteredIndex",
          .document([
            .init("key", .document([.init("_id", .int32(1))])), .init("unique", .bool(true)),
          ])))
    case .timeSeries:
      var timeseries = [MongoValue.Field("timeField", .string(Self.trimmed(timeField)))]
      let metaField = Self.trimmed(metaField)
      if !metaField.isEmpty { timeseries.append(.init("metaField", .string(metaField))) }
      if let granularity { timeseries.append(.init("granularity", .string(granularity.rawValue))) }
      options.append(.init("timeseries", .document(timeseries)))
      if let seconds = Self.seconds(expireAfterSeconds) {
        options.append(.init("expireAfterSeconds", .int32(seconds)))
      }
    }
    if let document = Self.document(collation) { options.append(.init("collation", document)) }
    return .createCollection(
      name: Self.trimmed(name), options: options.isEmpty ? nil : .document(options))
  }

  // MARK: - Private

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A whole number above 0, int32 when it fits (as a typed literal parses), else int64
  private static func positive(_ text: String) -> MongoValue? {
    guard let number = Int64(trimmed(text)), number > 0 else { return nil }
    return Int32(exactly: number).map(MongoValue.int32) ?? .int64(number)
  }

  private static func seconds(_ text: String) -> Int32? {
    Int32(trimmed(text)).flatMap { $0 >= 0 ? $0 : nil }
  }

  /// The typed document, nil when blank, not a document or empty
  private static func document(_ text: String) -> MongoValue? {
    guard !trimmed(text).isEmpty, case .document(let fields)? = try? MongoRelaxedJSON.parse(text),
      !fields.isEmpty
    else { return nil }
    return .document(fields)
  }

  /// Why `text` is not a document; nil when blank or valid
  private static func documentProblem(_ text: String, _ label: String) -> String? {
    guard !trimmed(text).isEmpty else { return nil }
    do {
      guard case .document = try MongoRelaxedJSON.parse(text) else {
        return "\(label) must be a document"
      }
      return nil
    } catch {
      return "\(label): \(error.message)"
    }
  }
}
