// MongoValidationRules.swift
// The validation rules of one collection as a value: the `validator` document, the level and
// the action, read from its `listCollections` options and sent back as `collMod`. The server
// defaults (no key) are strict and error; `off` and `errorAndLog` (MongoDB 8.0) are kept when
// read. The validator is edited as mongosh text; a blank text is an empty validator, which
// removes the rules.

import Foundation

nonisolated struct MongoValidationRules: Equatable, Sendable {
  typealias Field = MongoValue.Field

  nonisolated enum Level: String, CaseIterable, Sendable {
    case strict, moderate, off
  }

  nonisolated enum Action: String, CaseIterable, Sendable {
    case error, warn, errorAndLog
  }

  /// A document; empty when the collection has no rules
  var validator: MongoValue
  var level: Level
  var action: Action

  init(validator: MongoValue = .document([]), level: Level = .strict, action: Action = .error) {
    self.validator = validator
    self.level = level
    self.action = action
  }

  /// From a `listCollections` entry's `options`; a missing or unknown value is the server
  /// default.
  init(options: MongoValue) {
    guard case .document(let fields) = options else {
      self.init()
      return
    }
    let value = { (key: String) in fields.first { $0.key == key }?.value }
    var validator = MongoValue.document([])
    if let found = value("validator"), case .document = found { validator = found }
    var level = Level.strict
    if case .string(let text)? = value("validationLevel"), let parsed = Level(rawValue: text) {
      level = parsed
    }
    var action = Action.error
    if case .string(let text)? = value("validationAction"), let parsed = Action(rawValue: text) {
      action = parsed
    }
    self.init(validator: validator, level: level, action: action)
  }

  /// `validatorText` as typed in the editor: blank is an empty validator; anything else must
  /// parse to a document without server-side JavaScript (`$where`, `$function`...).
  init(validatorText: String, level: Level, action: Action) throws(MongoRelaxedJSON.ParseError) {
    var validator = MongoValue.document([])
    if !validatorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      validator = try MongoRelaxedJSON.parse(validatorText)
      guard case .document = validator else {
        throw MongoRelaxedJSON.ParseError(message: "The validator must be a document", offset: 0)
      }
      guard !MongoCommandClassifier.usesServerSideJavaScript(validator) else {
        throw MongoRelaxedJSON.ParseError(
          message: "Server-side JavaScript is not allowed in a validator", offset: 0)
      }
    }
    self.init(validator: validator, level: level, action: action)
  }

  /// The validator as indented mongosh text for the editor; blank when empty.
  var validatorText: String {
    if validator == .document([]) { return "" }
    return MongoRelaxedJSON.render(validator, as: .mongosh, indented: true)
  }

  /// `collMod` with all three keys, so applying sets exactly these rules.
  func command(collection: String) -> MongoAdminCommand {
    .collMod(
      collection: collection,
      options: .document([
        Field("validator", validator),
        Field("validationLevel", .string(level.rawValue)),
        Field("validationAction", .string(action.rawValue)),
      ]))
  }

  /// `{$jsonSchema: …}` from a schema sample (`MongoSchemaExport.mongoJSONSchema`); throws
  /// rather than give an empty schema that would drop the rules.
  static func fromSample(
    _ report: MongoSchemaAnalyzer.Report
  ) throws(MongoRelaxedJSON.ParseError)
    -> MongoValue
  {
    let schema = try MongoRelaxedJSON.parse(MongoSchemaExport.mongoJSONSchema(report))
    return .document([Field("$jsonSchema", schema)])
  }
}
