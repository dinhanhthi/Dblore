// TableRefIdentityTests.swift
// A table identity compares and hashes by Unicode scalars, not by canonical equivalence: an NFC
// and an NFD spelling of the same name are two tables, so a grid edit keyed by one can never
// resolve to the other. Its Codable form stays a bare string.

import Foundation
import Testing

@testable import Dblore

struct TableRefIdentityTests {
  private static let composed = "caf\u{E9}"
  private static let decomposed = "cafe\u{301}"

  @Test("Canonically equivalent names give different identities and dictionary slots")
  func canonicalEquivalentsStayApart() {
    let nfc = TableRef.mysql(database: "db", table: Self.composed)
    let nfd = TableRef.mysql(database: "db", table: Self.decomposed)
    #expect(nfc != nfd)
    var slots: [TableRef: Int] = [:]
    slots[nfc] = 1
    slots[nfd] = 2
    #expect(slots.count == 2)
    #expect(slots[nfc] == 1)
    #expect(slots[nfd] == 2)
  }

  @Test("The same name gives equal identities")
  func sameNameIsEqual() {
    let first = TableRef.mysql(database: "db", table: Self.decomposed)
    let second = TableRef.mysql(database: "db", table: Self.decomposed)
    #expect(first == second)
    #expect(Set([first, second]).count == 1)
  }

  @Test("Codable keeps the single string form and every scalar")
  func codableRoundTrip() throws {
    let ref = TableRef("pg:16400")
    let data = try JSONEncoder().encode(ref)
    #expect(String(decoding: data, as: UTF8.self) == "\"pg:16400\"")
    #expect(try JSONDecoder().decode(TableRef.self, from: data) == ref)

    let nfd = TableRef.mysql(database: "db", table: Self.decomposed)
    let decoded = try JSONDecoder().decode(TableRef.self, from: JSONEncoder().encode(nfd))
    #expect(decoded == nfd)
    #expect(decoded != TableRef.mysql(database: "db", table: Self.composed))
  }
}
