// UserTypeDraft.swift
// A new PostgreSQL user type as the types editor sheet's New Type form holds it: its kind and
// rows as typed. `create` is the one `UserTypeChange` that defines it, from complete rows only
// (nil while empty); `incompleteNote` says why a half-filled row blocks Create. Names are
// trimmed; a CHECK without a name leaves it to the server.

import Foundation

nonisolated struct UserTypeDraft: Sendable, Equatable {
  enum Kind: String, CaseIterable, Sendable {
    case enumType = "Enum"
    case domain = "Domain"
    case composite = "Composite"
  }

  struct Row: Identifiable, Sendable, Equatable {
    let id = UUID()
    var first = ""
    var second = ""
  }

  var kind = Kind.enumType
  var labels = [Row()]
  var baseType = ""
  var notNull = false
  var defaultExpression = ""
  /// Name and expression
  var checks: [Row] = []
  /// Name and type
  var attributes = [Row()]

  static let incompleteCheckMessage =
    "A CHECK row has a name but no expression: fill it in or remove the row"
  static let incompleteAttributeMessage =
    "An attribute row is missing its name or type: fill it in or remove the row"

  /// Why the draft cannot be created yet: a row half filled (a CHECK's name is optional)
  var incompleteNote: String? {
    switch kind {
    case .enumType:
      nil
    case .domain:
      checks.contains { !Self.isBlank($0.first) && Self.isBlank($0.second) }
        ? Self.incompleteCheckMessage : nil
    case .composite:
      attributes.contains { Self.isBlank($0.first) != Self.isBlank($0.second) }
        ? Self.incompleteAttributeMessage : nil
    }
  }

  /// The draft's CREATE, from complete rows only; nil while the draft is empty
  var create: UserTypeChange? {
    switch kind {
    case .enumType:
      let labels = labels.map(\.first).filter { !$0.isEmpty }
      return labels.isEmpty ? nil : .createEnum(labels: labels)
    case .domain:
      let baseType = Self.trimmed(baseType)
      let defaultExpression = Self.trimmed(defaultExpression)
      guard !baseType.isEmpty else { return nil }
      return .createDomain(
        .init(
          baseType: baseType, notNull: notNull,
          defaultExpression: defaultExpression.isEmpty ? nil : defaultExpression,
          checks: checks.filter { !Self.isBlank($0.second) }.map {
            .init(name: Self.trimmed($0.first), expression: $0.second)
          }))
    case .composite:
      let attributes = attributes.filter { !Self.isBlank($0.first) && !Self.isBlank($0.second) }
        .map { UserTypeChange.Attribute(name: Self.trimmed($0.first), type: $0.second) }
      return attributes.isEmpty ? nil : .createComposite(attributes)
    }
  }

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func isBlank(_ text: String) -> Bool { trimmed(text).isEmpty }
}
