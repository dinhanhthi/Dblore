// AIMongoAssist.swift
// Classifies AI mongosh blocks for the shown collection and parses one-shot filter/pipeline replies

import Foundation

/// Pure helpers behind the assistant's MongoDB collection actions. Replies are only parsed
/// (`MongoshParser`, `MongoRelaxedJSON`), never executed.
nonisolated enum AIMongoAssist {

  /// What a one-shot request generates.
  nonisolated enum Target: Sendable { case filter, pipeline }

  /// The collection screen the user is viewing: names and section only, never filter or
  /// pipeline text.
  nonisolated struct Screen: Sendable, Equatable {
    let database: String?
    let collection: String
    let showsAggregations: Bool
  }

  /// One stage of a generated pipeline: operator and mongosh-notation body.
  nonisolated struct GeneratedStage: Equatable, Sendable {
    let `operator`: String
    let body: String
  }

  /// The action a chat code block offers on the shown collection.
  nonisolated enum BlockAction: Equatable {
    case insertFilter(String)
    case generateAggregation([GeneratedStage])
  }

  /// A reply that is not a usable filter or pipeline.
  nonisolated struct ReplyError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
  }

  /// The action of a code block that is exactly one `find` or `aggregate` on `collection`, nil
  /// otherwise. A find gives only its filter (`""` for none).
  static func blockAction(code: String, collection: String) -> BlockAction? {
    let pieces = MongoshSplitter.split(code)
    guard pieces.count == 1, let command = try? MongoshParser.parse(pieces[0]),
      command.collection == collection
    else { return nil }
    switch command {
    case .find(_, let filter, _, _, _, _, _):
      return .insertFilter(filter.map { MongoRelaxedJSON.render($0, as: .mongosh) } ?? "")
    case .aggregate:
      return generatedStages(command).map { .generateAggregation($0) }
    default:
      return nil
    }
  }

  /// The filter text of a reply: one filter document, or a `db.<c>.find(...)` whose filter is
  /// taken. Rendered in mongosh notation, `""` for no filter.
  static func filter(fromReply reply: String) throws -> String {
    let text = unfenced(reply)
    let value: MongoValue?
    if text.hasPrefix("db.") {
      guard case .find(_, let filter, _, _, _, _, _) = try command(text) else {
        throw ReplyError(message: "The reply is not a find command")
      }
      value = filter
    } else {
      switch DataViewerState.documentFilterValue(text) {
      case .success(let filter): value = filter
      case .failure(let error): throw ReplyError(message: error.message)
      }
    }
    return value.map { MongoRelaxedJSON.render($0, as: .mongosh) } ?? ""
  }

  /// The stages of a reply: an array of stages, or a `db.<c>.aggregate([...])`. Throws when the
  /// reply is not a pipeline or has no stages.
  static func stages(fromReply reply: String, collection: String) throws -> [GeneratedStage] {
    let stages = try aggregate(fromReply: reply, collection: collection).stages
    guard !stages.isEmpty else { throw ReplyError(message: "The pipeline has no stages") }
    return stages
  }

  /// The collection, stages (none allowed) and aggregate options of a reply: an array of stages
  /// (`collection`, no options), or a `db.<c>.aggregate([...], {...})` (its own collection).
  /// Throws when it is not a pipeline.
  static func aggregate(
    fromReply reply: String, collection: String
  ) throws -> (
    collection: String, stages: [GeneratedStage], options: MongoCommand.CursorOptions
  ) {
    let text = unfenced(reply)
    let aggregate: MongoCommand
    if text.hasPrefix("db.") {
      aggregate = try command(text)
      guard case .aggregate = aggregate else {
        throw ReplyError(message: "The reply is not an aggregate command")
      }
    } else {
      let value: MongoValue
      do { value = try MongoRelaxedJSON.parse(text) } catch {
        throw ReplyError(message: error.message)
      }
      guard case .array(let pipeline) = value else {
        throw ReplyError(message: "The pipeline must be an array of stages, e.g. [{$match: {}}]")
      }
      aggregate = .aggregate(collection: collection, pipeline: pipeline)
    }
    guard case .aggregate(let named, _, let options) = aggregate,
      let stages = generatedStages(aggregate)
    else {
      throw ReplyError(message: "Each stage must be a document with exactly one operator")
    }
    return (named, stages, options)
  }

  /// The stages as a mongosh array, one stage per line; `""` for no stages.
  static func pipelineText(_ stages: [GeneratedStage]) -> String {
    guard !stages.isEmpty else { return "" }
    let lines = stages.map { "  { \($0.operator): \($0.body) }" }
    return "[\n" + lines.joined(separator: ",\n") + "\n]"
  }

  private static func generatedStages(_ command: MongoCommand) -> [GeneratedStage]? {
    AggregationBuilderModel.stages(from: command)?.map {
      GeneratedStage(operator: $0.operator, body: $0.body)
    }
  }

  private static func command(_ text: String) throws -> MongoCommand {
    do { return try MongoshParser.parse(text) } catch { throw ReplyError(message: error.message) }
  }

  /// `reply` trimmed, without one surrounding code fence (with or without a language tag).
  static func unfenced(_ reply: String) -> String {
    let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("```"), text.count >= 6, text.hasSuffix("```"),
      let lineEnd = text.firstIndex(of: "\n")
    else { return text }
    let body = text[text.index(after: lineEnd)..<text.index(text.endIndex, offsetBy: -3)]
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
