// MongoCommandRewriter.swift
// Caps a mongosh read at `maxRows + 1` documents before it is sent, so the capped read can tell
// a truncated result from a complete one.

import Foundation

nonisolated enum MongoCommandRewriter {

  /// `find`: `limit` becomes `min(effective, maxRows + 1)`, where no limit or `limit(0)` is
  /// unlimited and a negative limit counts as its absolute value (mongosh semantics), so the
  /// result is always in `1...maxRows + 1`. `aggregate`: appends `{$limit: NumberLong(maxRows +
  /// 1)}` unless the last stage is `$out` or `$merge`. Other commands are returned unchanged.
  /// A negative `maxRows` counts as 0.
  static func withLimit(_ command: MongoCommand, maxRows: Int) -> MongoCommand {
    let cap = maxRows == .max ? maxRows : max(maxRows, 0) + 1
    switch command {
    case .find(let name, let filter, let projection, let sort, let skip, let limit, let options):
      let magnitude = limit?.magnitude ?? 0
      let capped = magnitude == 0 ? cap : Int(min(magnitude, UInt(cap)))
      return .find(
        collection: name, filter: filter, projection: projection, sort: sort, skip: skip,
        limit: capped, options: options)
    case .aggregate(let name, let pipeline):
      if let last = pipeline.last,
        MongoCommandClassifier.hasStage(last, "$out")
          || MongoCommandClassifier.hasStage(last, "$merge")
      {
        return command
      }
      let stage = MongoValue.document([MongoValue.Field("$limit", .int64(Int64(cap)))])
      return .aggregate(collection: name, pipeline: pipeline + [stage])
    default:
      return command
    }
  }

  /// Parses `text`, applies `withLimit(_:maxRows:)` and renders canonical mongosh text (comments
  /// dropped, collection access canonicalized). Throws when `text` is not one command.
  static func withLimit(text: String, maxRows: Int) throws(MongoshParser.ParseError) -> String {
    withLimit(try MongoshParser.parse(text), maxRows: maxRows).render()
  }
}
