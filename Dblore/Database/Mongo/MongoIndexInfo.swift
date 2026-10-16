// MongoIndexInfo.swift
// The indexes of one MongoDB collection, merged from three reads (MongoDB's documented shapes):
//
// - `listIndexes` (cursor): one document per index with `name`, `key` (ordered field: kind),
//   and options when set: `unique`, `sparse`, `hidden`, `expireAfterSeconds`,
//   `partialFilterExpression`, `weights` (text indexes, whose `key` holds `_fts`/`_ftsx`).
// - `$indexStats` (aggregate): one row per index per host (or shard member) with
//   `accesses.ops` (operations since `accesses.since`) and `building: true` while the index
//   builds. Rows of the same index are merged: ops summed, earliest `since`, Building when any
//   row says so. Needs the `indexStats` privilege.
// - `$collStats` with `storageStats` (aggregate): one document per shard (one when unsharded),
//   `storageStats.indexSizes` maps index names to bytes; sizes are summed across documents.
//   Needs the `collStats` privilege.
//
// A read that failed (nil) leaves its columns nil: no usage, size or status is guessed. Stats
// rows for names `listIndexes` does not report (dropped meanwhile) are ignored. `_id_` comes
// first, the rest in `listIndexes` order.

import Foundation

nonisolated struct MongoIndexInfo: Equatable, Sendable, Identifiable {
  typealias Field = MongoValue.Field

  /// One indexed field and its kind as written in the key (`1`, `-1`, `text`, `2dsphere`, …).
  struct KeyPart: Equatable, Sendable {
    let field: String
    let kind: String
  }

  enum IndexType: String, Sendable {
    case regular, compound, text, geo2dsphere, geo2d, hashed, wildcard
  }

  enum Status: Equatable, Sendable {
    case ready, building
  }

  var id: String { name }
  let name: String
  let keys: [KeyPart]
  let type: IndexType
  let isUnique: Bool
  let isSparse: Bool
  let isHidden: Bool
  let ttlSeconds: Int?
  /// `partialFilterExpression` in mongosh notation.
  let partialFilter: String?
  /// Bytes, summed across shards; nil when `$collStats` was not read or lacks the index.
  let size: Int64?
  let ops: Int64?
  let since: Date?
  let status: Status?

  // MARK: - Commands

  /// `listIndexes` on `collection` (cursor reply).
  static func listIndexesCommand(collection: String) -> [Field] {
    [Field("listIndexes", .string(collection)), Field("cursor", .document([]))]
  }

  /// `aggregate` with `[{$indexStats: {}}]` on `collection` (cursor reply).
  static func indexStatsCommand(collection: String) -> [Field] {
    aggregate(collection, stage: Field("$indexStats", .document([])))
  }

  /// `aggregate` with `[{$collStats: {storageStats: {}}}]` on `collection` (cursor reply).
  static func collStatsCommand(collection: String) -> [Field] {
    aggregate(
      collection,
      stage: Field("$collStats", .document([Field("storageStats", .document([]))])))
  }

  private static func aggregate(_ collection: String, stage: Field) -> [Field] {
    [
      Field("aggregate", .string(collection)), Field("pipeline", .array([.document([stage])])),
      Field("cursor", .document([])),
    ]
  }

  // MARK: - Merge

  /// Joins `listIndexes` documents with `$indexStats` rows and `$collStats` documents (see the
  /// file header). `stats`/`collStats` nil = that read failed or was not run.
  static func merge(
    indexes: [MongoValue], stats: [MongoValue]?, collStats: [MongoValue]?
  ) -> [MongoIndexInfo] {
    let usage = stats.map(Self.usage)
    let sizes = collStats.map(Self.sizes)
    let infos = indexes.compactMap { document -> MongoIndexInfo? in
      guard case .string(let name)? = value("name", of: document) else { return nil }
      let keys = keyParts(of: document)
      let row = usage?[name]
      return MongoIndexInfo(
        name: name, keys: keys, type: indexType(of: keys),
        isUnique: flag("unique", of: document), isSparse: flag("sparse", of: document),
        isHidden: flag("hidden", of: document),
        ttlSeconds: value("expireAfterSeconds", of: document).flatMap(integer).map(Int.init),
        partialFilter: value("partialFilterExpression", of: document).map {
          MongoRelaxedJSON.render($0, as: .mongosh)
        },
        size: sizes?[name], ops: row?.ops, since: row?.since,
        status: row.map { $0.building ? .building : .ready })
    }
    return infos.filter { $0.name == "_id_" } + infos.filter { $0.name != "_id_" }
  }

  // MARK: - Parsing

  private struct Usage {
    var ops: Int64?
    var since: Date?
    var building: Bool
  }

  /// `$indexStats` rows merged by index name.
  private static func usage(_ rows: [MongoValue]) -> [String: Usage] {
    var result: [String: Usage] = [:]
    for row in rows {
      guard case .string(let name)? = value("name", of: row) else { continue }
      let accesses = value("accesses", of: row)
      let ops = accesses.flatMap { value("ops", of: $0) }.flatMap(integer)
      var since: Date?
      if case .date(let milliseconds)? = accesses.flatMap({ value("since", of: $0) }) {
        since = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
      }
      let building = flag("building", of: row)
      guard var merged = result[name] else {
        result[name] = Usage(ops: ops, since: since, building: building)
        continue
      }
      if let ops { merged.ops = (merged.ops ?? 0) + ops }
      if let since { merged.since = min(merged.since ?? since, since) }
      merged.building = merged.building || building
      result[name] = merged
    }
    return result
  }

  /// `storageStats.indexSizes` summed by index name across `$collStats` documents.
  private static func sizes(_ documents: [MongoValue]) -> [String: Int64] {
    var result: [String: Int64] = [:]
    for document in documents {
      guard
        case .document(let fields)? = value("storageStats", of: document).flatMap({
          value("indexSizes", of: $0)
        })
      else { continue }
      for field in fields {
        guard let bytes = integer(field.value) else { continue }
        result[field.key, default: 0] += bytes
      }
    }
    return result
  }

  /// The key's fields in order. A text index's `_fts`/`_ftsx` pair is replaced, at its place,
  /// by the `weights` fields (kind `text`).
  private static func keyParts(of document: MongoValue) -> [KeyPart] {
    guard case .document(let fields)? = value("key", of: document) else { return [] }
    var parts: [KeyPart] = []
    for field in fields {
      switch field.key {
      case "_fts":
        if case .document(let weights)? = value("weights", of: document) {
          parts += weights.map { KeyPart(field: $0.key, kind: "text") }
        }
      case "_ftsx":
        continue
      default:
        parts.append(KeyPart(field: field.key, kind: kind(field.value)))
      }
    }
    return parts
  }

  /// Wildcard when any field is `$**` (or ends in `.$**`), then the first special kind, then
  /// compound for several fields.
  private static func indexType(of keys: [KeyPart]) -> IndexType {
    if keys.contains(where: { $0.field == "$**" || $0.field.hasSuffix(".$**") }) {
      return .wildcard
    }
    for key in keys {
      switch key.kind {
      case "text": return .text
      case "2dsphere": return .geo2dsphere
      case "2d": return .geo2d
      case "hashed": return .hashed
      default: continue
      }
    }
    return keys.count > 1 ? .compound : .regular
  }

  /// A key value as text: numbers plain (`1`, `-1`), strings as written.
  private static func kind(_ value: MongoValue) -> String {
    if case .string(let text) = value { return text }
    if let number = integer(value) { return String(number) }
    if case .double(let number) = value { return String(number) }
    return MongoRelaxedJSON.render(value, as: .mongosh)
  }

  /// int32, int64 or an integral double.
  private static func integer(_ value: MongoValue) -> Int64? {
    switch value {
    case .int32(let number): return Int64(number)
    case .int64(let number): return number
    case .double(let number) where number.rounded() == number && abs(number) < 9e18:
      return Int64(number)
    default: return nil
    }
  }

  private static func flag(_ key: String, of document: MongoValue) -> Bool {
    value(key, of: document) == .bool(true)
  }

  private static func value(_ key: String, of document: MongoValue) -> MongoValue? {
    guard case .document(let fields) = document else { return nil }
    return fields.first { $0.key == key }?.value
  }
}
