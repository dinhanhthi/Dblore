// MongoAdminCommandTests.swift
// The admin commands of the mongosh subset as sent: command documents (rename on admin with full
// namespaces, the drivers' generated index name), the database writeCommand routes to and the
// command tag of a reply

import Foundation
import Testing

@testable import Dblore

@Suite("MongoDB admin commands")
struct MongoAdminCommandTests {

  private func doc(_ pairs: (String, MongoValue)...) -> MongoValue {
    .document(pairs.map { MongoValue.Field($0.0, $0.1) })
  }

  @Test("A rename runs in admin with <db>.<name> namespaces and dropTarget false")
  func renameNamespaces() {
    let command = MongoAdminCommand.renameCollection(collection: "a", to: "b")
    let (fields, database) = command.commandDocument(in: "shop")
    #expect(database == "admin")
    #expect(
      fields == [
        .init("renameCollection", .string("shop.a")), .init("to", .string("shop.b")),
        .init("dropTarget", .bool(false)),
      ])
  }

  @Test(
    "createIndex without a name gets the drivers' generated index name",
    arguments: [
      ("a_1_b_-1", MongoValue.document([.init("a", .int32(1)), .init("b", .int32(-1))])),
      ("a_text", .document([.init("a", .string("text"))])),
      ("$**_1", .document([.init("$**", .int32(1))])),
      ("loc_2dsphere", .document([.init("loc", .string("2dsphere"))])),
    ])
  func generatedIndexName(name: String, keys: MongoValue) {
    let (fields, database) = MongoAdminCommand.createIndex(
      collection: "c", keys: keys, options: nil
    ).commandDocument(in: "shop")
    #expect(database == "shop")
    #expect(
      fields == [
        .init("createIndexes", .string("c")),
        .init("indexes", .array([doc(("key", keys), ("name", .string(name)))])),
      ])
  }

  @Test("An explicit index name is kept, never replaced by a generated one")
  func explicitIndexName() {
    let keys = doc(("a", .int32(1)))
    let (fields, _) = MongoAdminCommand.createIndex(
      collection: "c", keys: keys, options: doc(("name", .string("by_a")), ("unique", .bool(true)))
    ).commandDocument(in: "shop")
    #expect(
      fields.last
        == .init(
          "indexes",
          .array([doc(("key", keys), ("name", .string("by_a")), ("unique", .bool(true)))])))
  }

  @Test("writeCommand sends an admin command to its database: admin for a rename")
  func writeCommandRouting() throws {
    let drop = try #require(MongoSession.writeCommand(.admin(.drop(collection: "c")), in: "db"))
    #expect(drop.database == "db")
    #expect(drop.fields == [.init("drop", .string("c"))])
    let rename = try #require(
      MongoSession.writeCommand(.admin(.renameCollection(collection: "c", to: "d")), in: "db"))
    #expect(rename.database == "admin")
  }

  @Test("An admin reply gives its command tag and no affected count")
  func commandResultTag() throws {
    let reply = doc(("ok", .double(1)))
    let result = try MongoSession.commandResult(
      for: .admin(.setIndexHidden(collection: "c", name: "a_1", hidden: false)), reply: reply)
    #expect(result == CommandResult(affectedRows: 0, tag: "UNHIDE INDEX"))
    let drop = try MongoSession.commandResult(for: .admin(.drop(collection: "c")), reply: reply)
    #expect(drop == CommandResult(affectedRows: 0, tag: "DROP"))
  }
}
