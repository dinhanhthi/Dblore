// AggregationTemplate.swift
// The aggregation Wizard's templates: a few common pipelines, each filled from one to three
// typed values and built as stage bodies in mongosh notation.

import Foundation

/// A pipeline the Wizard builds from typed values. Bodies are built as `MongoValue` and rendered
/// in mongosh notation, so any typed name is quoted and escaped as needed.
nonisolated struct AggregationTemplate: Identifiable, Sendable {
  /// One typed value of a template.
  nonisolated struct Field: Equatable, Sendable {
    let label: String
    let placeholder: String
  }

  private enum Kind: Sendable {
    case groupCount, lookup, topN, unwind, match, bucket
  }

  let id: String
  let title: String
  let summary: String
  let systemImage: String
  let fields: [Field]
  private let kind: Kind

  static let all: [AggregationTemplate] = [
    AggregationTemplate(
      id: "groupCount", title: "Count by field",
      summary: "Groups documents by a field and counts each group, largest first.",
      systemImage: "square.stack.3d.up", fields: [Field(label: "Field", placeholder: "status")],
      kind: .groupCount),
    AggregationTemplate(
      id: "lookup", title: "Join a collection",
      summary: "Adds the matching documents of another collection as an array.",
      systemImage: "link",
      fields: [
        Field(label: "Collection", placeholder: "orders"),
        Field(label: "Local field", placeholder: "_id"),
        Field(label: "Foreign field", placeholder: "userId"),
      ], kind: .lookup),
    AggregationTemplate(
      id: "topN", title: "Top documents",
      summary: "Keeps the documents with the highest values of a field.",
      systemImage: "list.number",
      fields: [
        Field(label: "Field", placeholder: "score"), Field(label: "Count", placeholder: "10"),
      ], kind: .topN),
    AggregationTemplate(
      id: "unwind", title: "Split an array",
      summary: "Outputs one document per element of an array field.",
      systemImage: "square.split.2x1", fields: [Field(label: "Array field", placeholder: "tags")],
      kind: .unwind),
    AggregationTemplate(
      id: "match", title: "Filter by value",
      summary: "Keeps the documents whose field equals a value.",
      systemImage: "line.3.horizontal.decrease",
      fields: [
        Field(label: "Field", placeholder: "status"),
        Field(label: "Value", placeholder: "\"active\""),
      ], kind: .match),
    AggregationTemplate(
      id: "bucket", title: "Group into ranges",
      summary: "Splits documents into ranges of a field with about the same count each.",
      systemImage: "chart.bar",
      fields: [
        Field(label: "Field", placeholder: "price"), Field(label: "Ranges", placeholder: "5"),
      ], kind: .bucket),
  ]

  /// The template's stages from `values`, one per field in order (missing values are blank).
  func build(_ values: [String]) -> [AIMongoAssist.GeneratedStage] {
    let value = { (index: Int) in
      index < values.count ? values[index].trimmingCharacters(in: .whitespaces) : ""
    }
    switch kind {
    case .groupCount:
      return [
        Self.stage(
          "$group",
          .document([
            MongoValue.Field("_id", Self.expression(value(0))),
            MongoValue.Field("count", .document([MongoValue.Field("$sum", .int32(1))])),
          ])),
        Self.stage("$sort", .document([MongoValue.Field("count", .int32(-1))])),
      ]
    case .lookup:
      let from = Self.path(value(0))
      return [
        Self.stage(
          "$lookup",
          .document([
            MongoValue.Field("from", .string(from)),
            MongoValue.Field("localField", .string(Self.path(value(1)))),
            MongoValue.Field("foreignField", .string(Self.path(value(2)))),
            MongoValue.Field("as", .string(from)),
          ]))
      ]
    case .topN:
      return [
        Self.stage("$sort", .document([MongoValue.Field(Self.path(value(0)), .int32(-1))])),
        Self.stage("$limit", .int32(Self.count(value(1), default: 10))),
      ]
    case .unwind:
      return [Self.stage("$unwind", Self.expression(value(0)))]
    case .match:
      let typed = value(1)
      let parsed = (try? MongoRelaxedJSON.parse(typed)) ?? .string(typed)
      return [Self.stage("$match", .document([MongoValue.Field(Self.path(value(0)), parsed)]))]
    case .bucket:
      return [
        Self.stage(
          "$bucketAuto",
          .document([
            MongoValue.Field("groupBy", Self.expression(value(0))),
            MongoValue.Field("buckets", .int32(Self.count(value(1), default: 5))),
          ]))
      ]
    }
  }

  private static func stage(_ name: String, _ body: MongoValue) -> AIMongoAssist.GeneratedStage {
    AIMongoAssist.GeneratedStage(operator: name, body: MongoRelaxedJSON.render(body, as: .mongosh))
  }

  /// A field name as typed, without a leading `$`.
  private static func path(_ text: String) -> String {
    text.hasPrefix("$") ? String(text.dropFirst()) : text
  }

  /// A field path expression: the name with a leading `$`.
  private static func expression(_ text: String) -> MongoValue {
    .string("$" + path(text))
  }

  /// A positive count, `fallback` when the text is not one.
  private static func count(_ text: String, default fallback: Int32) -> Int32 {
    guard let value = Int32(text), value > 0 else { return fallback }
    return value
  }
}
