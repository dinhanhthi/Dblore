// MongoIndexDraft.swift
// The Create Index form as a value: key rows and options typed as text, checked and turned into
// `MongoAdminCommand.createIndex`. Option documents (partial filter, wildcard projection,
// collation) are relaxed JSON as in the Documents bar; blank options are left out.

import Foundation

/// One index to create. `command(collection:)` is nil while `validationMessages()` lists a
/// problem.
nonisolated struct MongoIndexDraft: Equatable, Sendable {
  nonisolated enum KeyKind: String, CaseIterable, Sendable {
    case ascending
    case descending
    case geo2dsphere = "2dsphere"
    case text
    /// `$**` (every field) or `path.$**` (the fields under `path`)
    case wildcard
  }

  nonisolated struct Key: Equatable, Sendable, Identifiable {
    let id = UUID()
    /// The field path; for a wildcard key the path prefix, empty for `$**`
    var field = ""
    var kind = KeyKind.ascending

    /// The key document's field name
    var path: String {
      let field = field.trimmingCharacters(in: .whitespacesAndNewlines)
      guard kind == .wildcard else { return field }
      if field.isEmpty || field == "$**" { return "$**" }
      return field.hasSuffix(".$**") ? field : "\(field).$**"
    }

    fileprivate var value: MongoValue {
      switch kind {
      case .ascending, .wildcard: .int32(1)
      case .descending: .int32(-1)
      case .geo2dsphere, .text: .string(kind.rawValue)
      }
    }
  }

  var keys = [Key()]
  /// Blank: the server's generated name (`a_1_b_-1`)
  var name = ""
  var unique = false
  var sparse = false
  /// `expireAfterSeconds` as typed; blank: no TTL
  var ttlSeconds = ""
  var partialFilter = ""
  /// Only with a `$**` key
  var wildcardProjection = ""
  var collation = ""
  /// MongoDB 4.4 and later
  var hidden = false

  /// Every problem, in form order; empty when the draft can be created
  func validationMessages() -> [String] {
    var messages: [String] = []
    if keys.isEmpty {
      messages.append("Add at least one key")
    }
    if keys.contains(where: { $0.kind != .wildcard && $0.path.isEmpty }) {
      messages.append("Every key needs a field name")
    }
    let paths = keys.map(\.path).filter { !$0.isEmpty }
    if let duplicate = paths.first(where: { path in paths.filter { $0 == path }.count > 1 }) {
      messages.append("The field \(duplicate) appears more than once")
    }
    if unique, keys.contains(where: { $0.kind == .text || $0.kind == .wildcard }) {
      messages.append("A text or wildcard index cannot be unique")
    }
    if !Self.trimmed(ttlSeconds).isEmpty {
      if Self.ttl(ttlSeconds) == nil {
        messages.append("TTL must be a whole number of seconds from 0 to 2147483647")
      }
      if keys.count != 1 {
        messages.append("TTL needs a single-field index, not a compound key")
      } else if keys[0].path == "_id" {
        messages.append("TTL cannot be set on the _id field")
      } else if keys[0].kind != .ascending && keys[0].kind != .descending {
        messages.append("TTL needs an ascending or descending key")
      }
    }
    if let message = Self.documentProblem(partialFilter, "Partial filter") {
      messages.append(message)
    }
    if !Self.trimmed(wildcardProjection).isEmpty, !keys.contains(where: { $0.path == "$**" }) {
      messages.append("A wildcard projection needs a $** key")
    }
    if let message = Self.documentProblem(wildcardProjection, "Wildcard projection") {
      messages.append(message)
    }
    if let message = Self.documentProblem(collation, "Collation") {
      messages.append(message)
    }
    return messages
  }

  /// The `createIndex` command on `collection`, nil while the draft has a problem
  func command(collection: String) -> MongoAdminCommand? {
    guard validationMessages().isEmpty else { return nil }
    var options: [MongoValue.Field] = []
    let name = Self.trimmed(name)
    if !name.isEmpty { options.append(.init("name", .string(name))) }
    if unique { options.append(.init("unique", .bool(true))) }
    if sparse { options.append(.init("sparse", .bool(true))) }
    if let seconds = Self.ttl(ttlSeconds) {
      options.append(.init("expireAfterSeconds", .int32(seconds)))
    }
    for (text, key) in [
      (partialFilter, "partialFilterExpression"), (wildcardProjection, "wildcardProjection"),
      (collation, "collation"),
    ] {
      if let document = Self.document(text) { options.append(.init(key, document)) }
    }
    if hidden { options.append(.init("hidden", .bool(true))) }
    return .createIndex(
      collection: collection,
      keys: .document(keys.map { MongoValue.Field($0.path, $0.value) }),
      options: options.isEmpty ? nil : .document(options))
  }

  // MARK: - Private

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func ttl(_ text: String) -> Int32? {
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
