// UserTypeDraftTests.swift
// `UserTypeDraft`, the New Type form: a half-filled row gives its incomplete note (a CHECK's
// name is optional, an attribute needs both), the CREATE keeps complete rows only with trimmed
// names, and the enum kind ignores the other kinds' rows.

import Foundation
import Testing

@testable import Dblore

@Suite("UserTypeDraftTests")
struct UserTypeDraftTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let label: String
    let draft: UserTypeDraft
    let note: String?
    let create: UserTypeChange?
    var testDescription: String { label }
  }

  private static func domain(_ checks: [UserTypeDraft.Row]) -> UserTypeDraft {
    var draft = UserTypeDraft()
    draft.kind = .domain
    draft.baseType = " integer "
    draft.checks = checks
    return draft
  }

  private static func composite(_ attributes: [UserTypeDraft.Row]) -> UserTypeDraft {
    var draft = UserTypeDraft()
    draft.kind = .composite
    draft.attributes = attributes
    return draft
  }

  private static func createDomain(_ checks: [UserTypeChange.Check]) -> UserTypeChange {
    .createDomain(
      .init(baseType: "integer", notNull: false, defaultExpression: nil, checks: checks))
  }

  private static func asEnum(_ draft: UserTypeDraft) -> UserTypeDraft {
    var draft = draft
    draft.kind = .enumType
    draft.labels = [.init(first: "a")]
    return draft
  }

  static let cases: [Case] = [
    Case(
      label: "CHECK with a name and no expression",
      draft: domain([.init(first: "positive"), .init(second: "VALUE > 0")]),
      note: UserTypeDraft.incompleteCheckMessage,
      create: createDomain([.init(name: "", expression: "VALUE > 0")])),
    Case(
      label: "CHECK with an expression and no name",
      draft: domain([.init(first: "  ", second: "VALUE > 0")]), note: nil,
      create: createDomain([.init(name: "", expression: "VALUE > 0")])),
    Case(
      label: "CHECK name trimmed",
      draft: domain([.init(first: " positive ", second: "VALUE > 0")]), note: nil,
      create: createDomain([.init(name: "positive", expression: "VALUE > 0")])),
    Case(
      label: "Attribute with only a name",
      draft: composite([.init(first: "x"), .init(first: "y", second: "int")]),
      note: UserTypeDraft.incompleteAttributeMessage,
      create: .createComposite([.init(name: "y", type: "int")])),
    Case(
      label: "Attribute with only a type",
      draft: composite([.init(second: "text"), .init(first: "y", second: "int")]),
      note: UserTypeDraft.incompleteAttributeMessage,
      create: .createComposite([.init(name: "y", type: "int")])),
    Case(
      label: "Attribute name trimmed",
      draft: composite([.init(first: " y ", second: "int")]), note: nil,
      create: .createComposite([.init(name: "y", type: "int")])),
    Case(
      label: "Enum kind ignores a half-filled CHECK",
      draft: asEnum(domain([.init(first: "positive")])), note: nil,
      create: .createEnum(labels: ["a"])),
    Case(
      label: "Enum kind ignores a half-filled attribute",
      draft: asEnum(composite([.init(first: "x")])), note: nil,
      create: .createEnum(labels: ["a"])),
  ]

  @Test("A draft's incomplete note and CREATE", arguments: cases)
  func noteAndCreate(_ testCase: Case) {
    #expect(testCase.draft.incompleteNote == testCase.note)
    #expect(testCase.draft.create == testCase.create)
  }
}
