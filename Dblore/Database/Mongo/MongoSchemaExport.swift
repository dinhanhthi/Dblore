// MongoSchemaExport.swift
// A schema report as JSON Schema (draft 2020-12) or as the body of a MongoDB `$jsonSchema`
// validator. The tree comes from the fields' key paths: `properties` for embedded documents,
// `items` for array elements (array element documents hold the array field's child fields),
// `required` for the fields never missing ("undefined") where their parent was present. Fields
// below the analyzer's depth are unknown, which a `description` says on the deepest objects.
// Printed as indented relaxed Extended JSON, key order kept.

import Foundation

nonisolated enum MongoSchemaExport {
  static let draftURI = "https://json-schema.org/draft/2020-12/schema"
  /// An ObjectId as 24 hex characters, for the JSON Schema `string` it maps to.
  static let objectIdPattern = "^[0-9a-fA-F]{24}$"

  /// JSON Schema: int / long are `integer`, double / decimal `number`, objectId a `string` with
  /// a 24-hex pattern, date a `string` with `format: date-time`, other BSON-only types `string`.
  static func jsonSchema(_ report: MongoSchemaAnalyzer.Report) -> String {
    Builder(report: report, flavor: .jsonSchema).rendered()
  }

  /// The `$jsonSchema` document: exact `bsonType` aliases, no `$schema` and no `format`.
  static func mongoJSONSchema(_ report: MongoSchemaAnalyzer.Report) -> String {
    Builder(report: report, flavor: .bson).rendered()
  }
}

// MARK: - Builder

extension MongoSchemaExport {
  fileprivate nonisolated enum Flavor {
    case jsonSchema, bson
  }

  fileprivate nonisolated struct Builder {
    typealias Field = MongoSchemaAnalyzer.Field
    let report: MongoSchemaAnalyzer.Report
    let flavor: Flavor
    /// Child fields by parent key path ([] for the top level), in report order.
    let children: [[String]: [Field]]

    init(report: MongoSchemaAnalyzer.Report, flavor: Flavor) {
      self.report = report
      self.flavor = flavor
      self.children = Dictionary(grouping: report.fields) { Array($0.keyPath.dropLast()) }
    }

    func rendered() -> String {
      var schema: [MongoValue.Field] = []
      if flavor == .jsonSchema { schema.append(MongoValue.Field("$schema", .string(draftURI))) }
      schema += typeKeywords(["object"])
      let documents = report.sampleSize == 1 ? "1 document" : "\(report.sampleSize) documents"
      schema.append(
        MongoValue.Field("description", .string("Inferred from a sample of \(documents).")))
      schema += members(of: [])
      return MongoRelaxedJSON.render(.document(schema), as: .relaxedExtendedJSON, indented: true)
    }

    /// `required` (when any) and `properties` (when any) of the fields under `parent`.
    private func members(of parent: [String]) -> [MongoValue.Field] {
      let fields = children[parent] ?? []
      guard !fields.isEmpty else { return [] }
      var result: [MongoValue.Field] = []
      let required = fields.filter { field in
        !field.types.contains { $0.name == MongoSchemaAnalyzer.undefinedTypeName }
      }
      if !required.isEmpty {
        result.append(MongoValue.Field("required", .array(required.map { .string($0.name) })))
      }
      let properties = fields.map { MongoValue.Field($0.name, schema(of: $0)) }
      result.append(MongoValue.Field("properties", .document(properties)))
      return result
    }

    private func schema(of field: Field) -> MongoValue {
      let types = field.types.map(\.name).filter { $0 != MongoSchemaAnalyzer.undefinedTypeName }
      let elementTypes = field.elementTypes?.map(\.name) ?? []
      var schema = typeKeywords(types)
      if field.depth == MongoSchemaAnalyzer.maxDepth,
        types.contains("object") || elementTypes.contains("object")
      {
        let note =
          "Fields below this level were not analyzed (depth limit \(MongoSchemaAnalyzer.maxDepth))."
        schema.append(MongoValue.Field("description", .string(note)))
      }
      if types.contains("object") { schema += members(of: field.keyPath) }
      if !elementTypes.isEmpty {
        var items = typeKeywords(elementTypes)
        if elementTypes.contains("object") { items += members(of: field.keyPath) }
        schema.append(MongoValue.Field("items", .document(items)))
      }
      return .document(schema)
    }

    /// `bsonType`, or `type` plus `pattern` / `format` when the field's only string-like type
    /// is objectId / date. One type is written alone, several as an array.
    private func typeKeywords(_ types: [String]) -> [MongoValue.Field] {
      let names: [String]
      switch flavor {
      case .bson: names = types
      case .jsonSchema:
        names = types.map(Self.jsonType).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
      }
      guard !names.isEmpty else { return [] }
      let value: MongoValue =
        names.count == 1 ? .string(names[0]) : .array(names.map { .string($0) })
      var result = [MongoValue.Field(flavor == .bson ? "bsonType" : "type", value)]
      guard flavor == .jsonSchema else { return result }
      switch types.filter({ Self.jsonType($0) == "string" }) {
      case ["objectId"]: result.append(MongoValue.Field("pattern", .string(objectIdPattern)))
      case ["date"]: result.append(MongoValue.Field("format", .string("date-time")))
      default: break
      }
      return result
    }

    /// The JSON type of a BSON type alias; BSON-only types are strings.
    private static func jsonType(_ alias: String) -> String {
      switch alias {
      case "int", "long": "integer"
      case "double", "decimal": "number"
      case "bool": "boolean"
      case "null": "null"
      case "object": "object"
      case "array": "array"
      default: "string"
      }
    }
  }
}
