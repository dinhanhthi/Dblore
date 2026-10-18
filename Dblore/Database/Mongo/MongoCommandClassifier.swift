// MongoCommandClassifier.swift
// Classifies mongosh-subset commands into the SQL classifier's `ClassifiedStatement`, so the
// execution gate applies the same policies to MongoDB cells.

import Foundation

/// Classifies mongosh text with `MongoshSplitter` and `MongoshParser`. Same entry points as
/// `SQLStatementClassifier.classify`/`classifyStatement`; `SQLStatementClassifier.summary` works
/// on the result unchanged.
///
/// Mapping: `find`, `countDocuments`, `distinct`, `listCollections` and an `aggregate` without
/// `$out`/`$merge` are reads; inserts, updates, `replaceOne`, deletes and an `aggregate` with
/// `$merge` are DML; an `aggregate` with `$out` is DDL that creates a table; an `explain` is a
/// read when the explained command is one, otherwise unknown (never a write, so a writing
/// pipeline is refused rather than confirmed); administration commands (indexes, collections,
/// views) are DDL, `drop` and `dropIndex` destructive; text that does not parse is unknown.
/// `$out`/`$merge` count as a key at any depth of the pipeline (fail closed). No statement is
/// non-transactional (Schema-only lets DML run), none has RETURNING, and none touches session
/// brakes or privileges.
nonisolated enum MongoCommandClassifier {

  /// Split `text` into commands and classify each. Comment-only pieces are dropped.
  static func classify(_ text: String) -> [ClassifiedStatement] {
    MongoshSplitter.split(text).map(classifyPiece)
  }

  /// Classify one already-split command; nil if it is empty or comment-only. Text that does not
  /// parse as exactly one command (several commands included) is `.unknown` (fail closed).
  static func classifyStatement(_ text: String) -> ClassifiedStatement? {
    guard !MongoshSplitter.split(text).isEmpty else { return nil }
    return classifyPiece(text)
  }

  /// A piece that is not empty or comment-only (as `MongoshSplitter` returns them).
  private static func classifyPiece(_ text: String) -> ClassifiedStatement {
    guard let command = try? MongoshParser.parse(text) else {
      return statement(text, kind: .unknown)
    }
    return classify(command, text: text)
  }

  private static func classify(_ command: MongoCommand, text: String) -> ClassifiedStatement {
    switch command {
    case .find, .countDocuments, .distinct, .listCollections:
      return statement(text, kind: .read)
    case .aggregate(_, let pipeline, _):
      let stages = MongoValue.array(pipeline)
      if containsKey(stages, "$out") { return statement(text, kind: .ddl, createsTable: true) }
      return statement(text, kind: containsKey(stages, "$merge") ? .dml : .read)
    case .insertOne, .insertMany, .updateOne, .replaceOne, .deleteOne:
      return statement(text, kind: .dml)
    case .updateMany(_, let filter, _, _), .deleteMany(_, let filter):
      return statement(text, kind: .dml, affectsAllRows: filter == .document([]))
    case .explain(let inner, _):
      return statement(text, kind: classify(inner, text: text).kind == .read ? .read : .unknown)
    case .admin(let admin):
      return statement(text, kind: .ddl, isDestructive: admin.isDestructive)
    }
  }

  /// A pipeline stage document with a top-level `name` key (exact case, any value). A stage
  /// that is not a document has no key (`MongoshParser` refuses one).
  static func hasStage(_ stage: MongoValue, _ name: String) -> Bool {
    guard case .document(let fields) = stage else { return false }
    return fields.contains { $0.key == name }
  }

  /// Keys that make the server run JavaScript: the `$where`, `$function` and `$accumulator`
  /// operators, and `$code`, the Extended JSON shape `MongoBSONMapping` writes as BSON code.
  static let serverSideJavaScriptKeys: Set<String> = [
    "$where", "$function", "$accumulator", "$code",
  ]

  /// `text` would run JavaScript on the server: a `serverSideJavaScriptKeys` key (exact case,
  /// as the server matches operators) at any depth of any document argument (filter,
  /// projection, sort, find and aggregate collation and hint, count options, pipeline, update,
  /// document, and an admin command's keys, options and view pipeline, so a partial filter or a
  /// validator too). Text that does not parse as one command counts as JavaScript (fail closed;
  /// the classifier calls it unknown anyway). Only callers that ask are covered: the read-only
  /// guard, the schema sample and the Validation tab's validator; the write gate does not scan.
  static func usesServerSideJavaScript(_ text: String) -> Bool {
    guard let command = try? MongoshParser.parse(text) else { return true }
    return arguments(of: command).contains { usesServerSideJavaScript($0) }
  }

  /// `value` has a `serverSideJavaScriptKeys` key at any depth.
  static func usesServerSideJavaScript(_ value: MongoValue) -> Bool {
    serverSideJavaScriptKeys.contains { containsKey(value, $0) }
  }

  /// Every document or array argument of `command`.
  private static func arguments(of command: MongoCommand) -> [MongoValue] {
    switch command {
    case .find(_, let filter, let projection, let sort, _, _, let options):
      [filter, projection, sort, options.collation, options.hint].compactMap { $0 }
    case .aggregate(_, let pipeline, let options):
      [.array(pipeline), options.collation, options.hint].compactMap { $0 }
    case .countDocuments(_, let filter, let options): [filter, options].compactMap { $0 }
    case .distinct(_, _, let filter): filter.map { [$0] } ?? []
    case .insertOne(_, let document): [document]
    case .insertMany(_, let documents): [.array(documents)]
    case .updateOne(_, let filter, let update, _), .updateMany(_, let filter, let update, _),
      .replaceOne(_, let filter, let update, _):
      [filter, update]
    case .deleteOne(_, let filter), .deleteMany(_, let filter): [filter]
    case .listCollections: []
    case .explain(let command, _): arguments(of: command)
    case .admin(let admin): admin.documentArguments
    }
  }

  /// A document key `name` (exact case) at any depth of `value`: sub-pipelines (`$facet`,
  /// `$lookup`, `$unionWith`) and filters included, so nested writes fail closed. The parser's
  /// depth limit bounds the recursion.
  private static func containsKey(_ value: MongoValue, _ name: String) -> Bool {
    switch value {
    case .document(let fields): fields.contains { $0.key == name || containsKey($0.value, name) }
    case .array(let items): items.contains { containsKey($0, name) }
    default: false
    }
  }

  private static func statement(
    _ text: String, kind: StatementKind, affectsAllRows: Bool = false, createsTable: Bool = false,
    isDestructive: Bool = false
  ) -> ClassifiedStatement {
    ClassifiedStatement(
      text: text, kind: kind, hasReturning: false, hasTopLevelReturning: false,
      affectsAllRows: affectsAllRows, nonTransactional: false, resetsSessionBrakes: false,
      changesPrivileges: false, createsTable: createsTable, isDestructive: isDestructive)
  }
}
