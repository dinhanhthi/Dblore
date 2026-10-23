// SQLFingerprintTests.swift
// Query Insights groups runs by fingerprint: the statement with its literal values removed.

import Foundation
import Testing

@testable import Dblore

@Suite("SQL fingerprint")
struct SQLFingerprintTests {
  @Test("Statements that differ only in literals share one fingerprint, per dialect")
  func literalsShareFingerprint() {
    let postgres = SQLFingerprint.fingerprint(
      "select *  from orders -- recent\nwhere id = 42 and note = 'late' and price > 1.5",
      dialect: .postgresql)
    #expect(postgres == "SELECT * FROM orders WHERE id = ? AND note = ? AND price > ?")
    #expect(
      SQLFingerprint.fingerprint(
        "SELECT * FROM orders WHERE id = -7 AND note = $$it's late$$ AND price>2e3",
        dialect: .postgresql) == postgres)

    let mysql = SQLFingerprint.fingerprint(
      "SELECT `name` FROM t WHERE a = \"x\" /* note */ LIMIT 10", dialect: .mysql)
    #expect(mysql == "SELECT `name` FROM t WHERE a = ? LIMIT ?")
    #expect(
      SQLFingerprint.fingerprint("select `name` from t where a='y' limit 20", dialect: .mysql)
        == mysql)

    let mongo = SQLFingerprint.fingerprint(
      "db.users.find({ \"age\": { $gt: 30 }, name: 'Ann' }) // adults", dialect: .mongodb)
    #expect(mongo == "db.users.find({\"age\":{$gt:?},name:?})")
    #expect(
      SQLFingerprint.fingerprint(
        "db.users.find({\"age\": {$gt: 5}, name: /^B/i})", dialect: .mongodb)
        == mongo)
  }

  @Test("An IN list of literals collapses to one placeholder")
  func inListCollapses() {
    let one = SQLFingerprint.fingerprint("SELECT 1 FROM t WHERE id IN (1)", dialect: .sqlite)
    let many = SQLFingerprint.fingerprint(
      "select 1 from t where id in (1, 2, 'three')", dialect: .sqlite)
    #expect(many == "SELECT ? FROM t WHERE id IN (?)")
    #expect(many == one)
    #expect(
      SQLFingerprint.fingerprint("db.t.find({ _id: { $in: [1, 2, 3] } })", dialect: .mongodb)
        == "db.t.find({_id:{$in:[?]}})")
  }
}
