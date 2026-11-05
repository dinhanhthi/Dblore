// ColumnMaskRuleTests.swift
// Column masking rules: which patterns are accepted, which rule a column matches (the strictest
// matching one, failing closed when the column's table is unknown) and what each style shows.

import Foundation
import Testing

@testable import Dblore

@Suite("Column mask rules")
@MainActor
struct ColumnMaskRuleTests {
  private static func rule(
    _ pattern: String, _ style: ColumnMaskRule.Style = .full
  ) throws
    -> ColumnMaskRule
  {
    try ColumnMaskRule(pattern: pattern, style: style)
  }

  @Test(
    "A pattern names a column, optionally its table and schema; a * column segment is refused",
    arguments: [
      ("email", true), ("users.email", true), ("public.users.email", true),
      ("*.email", true), ("*.*.email", true), ("public.*.email", true),
      (" Users . Email ", true),
      ("users.*", false), ("*", false), ("*.*", false), ("public.users.*", false),
      ("us*rs.email", false), ("users.em*", false), ("", false), ("users.", false),
      (".email", false), ("a.b.c.d", false), (String(repeating: "a", count: 256), false),
    ])
  func patternValidation(pattern: String, accepted: Bool) {
    #expect(((try? ColumnMaskRule(pattern: pattern, style: .full)) != nil) == accepted)
  }

  @Test("Decoding refuses a * column segment and an unknown style, and reads a valid rule")
  func decodingValidates() throws {
    func decode(_ json: String) throws -> ColumnMaskRule {
      try JSONDecoder().decode(ColumnMaskRule.self, from: Data(json.utf8))
    }
    #expect(throws: (any Error).self) { try decode(#"{"pattern":"users.*","style":"full"}"#) }
    #expect(throws: (any Error).self) { try decode(#"{"pattern":"email","style":"hash"}"#) }
    let rule = try Self.rule("users.email", .lastFour)
    #expect(try decode(String(decoding: JSONEncoder().encode(rule), as: UTF8.self)) == rule)
  }

  typealias Origin = ColumnMaskRule.Origin

  @Test(
    "Among rules of one style the most specific wins; an unknown origin matches on the column alone",
    arguments: [
      // column, origin, expected pattern (nil: unmasked)
      ("email", Origin(schema: "public", table: "users"), "public.users.email"),
      ("EMAIL", Origin(schema: "PUBLIC", table: "Users"), "public.users.email"),
      ("email", Origin(schema: "crm", table: "users"), "users.email"),
      ("email", Origin(schema: nil, table: "users"), "public.users.email"),
      ("email", Origin(schema: "crm", table: "orders"), "*.email"),
      ("phone", Origin(schema: "crm", table: "orders"), "phone"),
      ("card", Origin(schema: "crm", table: "orders"), nil),
      ("card", Origin(schema: "billing", table: "orders"), "billing.*.card"),
      // Fail closed: no origin, so the table-qualified rules match on their column segment
      ("card", nil, "billing.*.card"),
      ("email", nil, "public.users.email"),
      // Helper columns are masked only by a rule that names them
      ("dblore_ctid", nil, nil), ("dblore_byte_length_1", nil, nil),
      ("dblore_xmin", Origin(schema: "public", table: "users"), "users.dblore_xmin"),
    ] as [(String, Origin?, String?)])
  func matching(column: String, origin: Origin?, expected: String?) throws {
    let rules = try [
      Self.rule("*.email"), Self.rule("phone"), Self.rule("users.email"),
      Self.rule("public.users.email"), Self.rule("billing.*.card"),
      Self.rule("users.dblore_xmin"),
    ]
    let set = ColumnMaskRuleSet(rules)
    #expect(set.matchingRule(column: column, origin: origin)?.pattern == expected)
  }

  @Test(
    "The strictest matching style wins over a more specific pattern, whatever the list order",
    arguments: [
      // column, origin, expected pattern (nil: unmasked)
      ("email", Origin(schema: "public", table: "users"), "email"),
      ("email", nil, "email"),
      ("email", Origin(schema: "crm", table: "orders"), "email"),
      // Unknown origin: the qualified .email rule never outranks the broader .full one
      ("contact", nil, "*.contact"),
      ("contact", Origin(schema: "crm", table: "users"), "*.contact"),
      ("card", Origin(schema: "billing", table: "orders"), "billing.*.card"),
      ("card", Origin(schema: "crm", table: "orders"), "card"),
      ("card", nil, "billing.*.card"),
      // NULL outranks full
      ("ssn", Origin(schema: "hr", table: "staff"), "ssn"),
      // Same style: the more specific, then the first in the list
      ("phone", Origin(schema: "crm", table: "users"), "users.phone"),
      ("phone", nil, "users.phone"),
      ("token", nil, "a.*.token"),
    ] as [(String, Origin?, String?)])
  func strictestWins(column: String, origin: Origin?, expected: String?) throws {
    let rules = try [
      Self.rule("public.users.email", .lastFour), Self.rule("users.email", .email),
      Self.rule("email", .full),
      Self.rule("users.contact", .email), Self.rule("*.contact", .full),
      Self.rule("card", .lastFour), Self.rule("billing.*.card", .null),
      Self.rule("hr.staff.ssn", .full), Self.rule("ssn", .null),
      Self.rule("phone", .full), Self.rule("users.phone", .full),
      Self.rule("a.*.token", .email), Self.rule("b.*.token", .email),
    ]
    #expect(
      ColumnMaskRuleSet(rules).matchingRule(column: column, origin: origin)?.pattern == expected)
    // Reversed, so the list order is not what wins
    let reversed = ColumnMaskRuleSet(rules.reversed())
    let pick = reversed.matchingRule(column: column, origin: origin)?.pattern
    #expect(pick == (column == "token" ? "b.*.token" : expected))
  }

  @Test(
    "Each style on short, empty, multibyte, NULL and non-text values",
    arguments: [
      (ColumnMaskRule.Style.full, CellValue.string("secret"), CellValue.string("••••")),
      (.full, .null, .string("••••")),
      (.full, .int(42), .string("••••")),
      (.lastFour, .string("4111111111111234"), .string("••••1234")),
      (.lastFour, .string("1234"), .string("••••")),
      (.lastFour, .string(""), .string("••••")),
      (.lastFour, .string("café👩‍👩‍👧é"), .string("••••fé👩‍👩‍👧é")),
      (.lastFour, .int(1_234_567), .string("••••4567")),
      (.lastFour, .decimal("1234.50"), .string("••••4.50")),
      (.lastFour, .null, .string("••••")),
      (.lastFour, .data(Data(repeating: 1, count: 64)), .string("••••")),
      (.email, .string("jane@example.com"), .string("j•••@example.com")),
      (.email, .string("Élodie@exemple.fr"), .string("É•••@exemple.fr")),
      (.email, .string("not-an-email"), .string("••••")),
      (.email, .string("@example.com"), .string("••••")),
      (.email, .string("a@b@c"), .string("••••")),
      (.email, .string("jane@exa mple.com"), .string("••••")),
      (.email, .string("jane@example.com\nRe: urgent"), .string("••••")),
      (.email, .null, .string("••••")),
      (.null, .string("secret"), .null),
      (.null, .int(7), .null),
    ])
  func styles(style: ColumnMaskRule.Style, value: CellValue, expected: CellValue) {
    #expect(style.masked(value) == expected)
  }
}
