// MongoCommand.swift
// One command of the Dblore mongosh subset, as parsed by `MongoshParser` and rendered back to
// canonical mongosh text (values in mongosh notation, see `MongoRelaxedJSON`).

import Foundation

/// A command of the mongosh subset. Never JavaScript: only these shapes exist.
///
/// Documents are `MongoValue.document`, arrays of documents are `[MongoValue]`. An empty document
/// in an optional slot (find filter, projection and sort, `countDocuments` and `distinct`
/// filters) means the same as no document, so the parser stores it as `nil`. Required filters
/// (updates, `replaceOne`, deletes) keep `{}` as `.document([])`.
/// `skip` and `limit` keep the number as written (`limit(0)` and negative limits included).
nonisolated enum MongoCommand: Equatable, Sendable {
  case find(
    collection: String, filter: MongoValue?, projection: MongoValue?, sort: MongoValue?,
    skip: Int?, limit: Int?)
  case aggregate(collection: String, pipeline: [MongoValue])
  case countDocuments(collection: String, filter: MongoValue?)
  case distinct(collection: String, field: String, filter: MongoValue?)
  case insertOne(collection: String, document: MongoValue)
  case insertMany(collection: String, documents: [MongoValue])
  /// `update` is a document of update operators (`$set`, ...) or a pipeline array.
  case updateOne(collection: String, filter: MongoValue, update: MongoValue, upsert: Bool = false)
  case updateMany(collection: String, filter: MongoValue, update: MongoValue, upsert: Bool = false)
  case replaceOne(
    collection: String, filter: MongoValue, replacement: MongoValue, upsert: Bool = false)
  case deleteOne(collection: String, filter: MongoValue)
  case deleteMany(collection: String, filter: MongoValue)
  /// `show collections` or `db.getCollectionNames()`.
  case listCollections

  /// The target collection, nil for `listCollections`.
  var collection: String? {
    switch self {
    case .find(let name, _, _, _, _, _), .aggregate(let name, _), .countDocuments(let name, _),
      .distinct(let name, _, _), .insertOne(let name, _), .insertMany(let name, _),
      .updateOne(let name, _, _, _), .updateMany(let name, _, _, _), .replaceOne(let name, _, _, _),
      .deleteOne(let name, _), .deleteMany(let name, _):
      name
    case .listCollections:
      nil
    }
  }

  /// Canonical mongosh text: values in mongosh notation, find chains as `.sort .skip .limit`,
  /// `{upsert: true}` only when set, `show collections` for `listCollections`. A nil find filter
  /// is written `{}` when a projection follows. `MongoshParser.parse` reads it back unchanged.
  func render() -> String {
    switch self {
    case .find(let name, let filter, let projection, let sort, let skip, let limit):
      let arguments =
        projection.map { [filter ?? .document([]), $0] } ?? (filter.map { [$0] } ?? [])
      var text = Self.call(name, "find", arguments)
      if let sort { text += ".sort(\(Self.value(sort)))" }
      if let skip { text += ".skip(\(skip))" }
      if let limit { text += ".limit(\(limit))" }
      return text
    case .aggregate(let name, let pipeline):
      return Self.call(name, "aggregate", [.array(pipeline)])
    case .countDocuments(let name, let filter):
      return Self.call(name, "countDocuments", filter.map { [$0] } ?? [])
    case .distinct(let name, let field, let filter):
      return Self.call(name, "distinct", [.string(field)] + (filter.map { [$0] } ?? []))
    case .insertOne(let name, let document):
      return Self.call(name, "insertOne", [document])
    case .insertMany(let name, let documents):
      return Self.call(name, "insertMany", [.array(documents)])
    case .updateOne(let name, let filter, let update, let upsert):
      return Self.call(name, "updateOne", [filter, update] + Self.upsertOption(upsert))
    case .updateMany(let name, let filter, let update, let upsert):
      return Self.call(name, "updateMany", [filter, update] + Self.upsertOption(upsert))
    case .replaceOne(let name, let filter, let replacement, let upsert):
      return Self.call(name, "replaceOne", [filter, replacement] + Self.upsertOption(upsert))
    case .deleteOne(let name, let filter):
      return Self.call(name, "deleteOne", [filter])
    case .deleteMany(let name, let filter):
      return Self.call(name, "deleteMany", [filter])
    case .listCollections:
      return "show collections"
    }
  }

  private static func value(_ value: MongoValue) -> String {
    MongoRelaxedJSON.render(value, as: .mongosh)
  }

  private static func upsertOption(_ upsert: Bool) -> [MongoValue] {
    upsert ? [.document([MongoValue.Field("upsert", .bool(true))])] : []
  }

  private static func call(_ name: String, _ method: String, _ arguments: [MongoValue]) -> String {
    "\(access(name)).\(method)(\(arguments.map(value).joined(separator: ", ")))"
  }

  /// `db.name` for a plain name that is not a database method, else `db.getCollection("…")`.
  private static func access(_ name: String) -> String {
    let bytes = Array(name.utf8)
    let isPlain =
      bytes.first.map(isASCIILetter) == true
      && bytes.allSatisfy { isASCIILetter($0) || (0x30...0x39).contains($0) || $0 == 0x5F }
    if isPlain, !databaseMethods.contains(name) { return "db.\(name)" }
    return "db.getCollection(\(value(.string(name))))"
  }

  private static func isASCIILetter(_ byte: UInt8) -> Bool {
    (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
  }

  /// mongosh `Database` members: `db.<member>` names the member, not a collection.
  private static let databaseMethods: Set<String> = [
    "adminCommand", "aggregate", "auth", "changeUserPassword", "commandHelp", "createCollection",
    "createEncryptedCollection", "createRole", "createUser", "createView", "currentOp",
    "dropAllRoles", "dropAllUsers", "dropDatabase", "dropRole", "dropUser", "fsyncLock",
    "fsyncUnlock", "getCollection", "getCollectionInfos", "getCollectionNames", "getLogComponents",
    "getMongo", "getName", "getProfilingStatus", "getReplicationInfo", "getRole", "getRoles",
    "getSiblingDB", "getUser", "getUsers", "grantPrivilegesToRole", "grantRolesToRole",
    "grantRolesToUser", "hello", "help", "hostInfo", "isMaster", "killOp", "listCommands", "logout",
    "printCollectionStats", "printReplicationInfo", "printSecondaryReplicationInfo",
    "printShardingStatus", "revokePrivilegesFromRole", "revokeRolesFromRole",
    "revokeRolesFromUser", "rotateCertificates", "runCommand", "serverBuildInfo",
    "serverCmdLineOpts", "serverStatus", "setLogLevel", "setProfilingLevel", "shutdownServer",
    "sql", "stats", "updateRole", "updateUser", "version", "watch",
  ]
}
