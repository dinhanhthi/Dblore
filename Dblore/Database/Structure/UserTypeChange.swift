// UserTypeChange.swift
// One edit the types editor makes to a PostgreSQL user type (`DatabaseUserType`), or the
// definition of a new one. `PostgresUserTypeDDLBuilder` turns a list of them into DDL. Labels,
// attribute and constraint names are names as loaded: renames run after every other change.
// Enum labels are added and renamed, never dropped. Type text and DEFAULT / CHECK expressions
// are typed by the user and written into the SQL as they are, after validation.

import Foundation

nonisolated enum UserTypeChange: Sendable, Equatable {
  // Enum
  /// At the end when `position` is nil
  case addValue(label: String, position: LabelPosition?)
  case renameValue(label: String, newLabel: String)

  // Domain
  case setDefault(expression: String)
  case dropDefault
  case setNotNull
  case dropNotNull
  case addCheck(Check)
  case dropConstraint(name: String)

  // Composite
  case addAttribute(Attribute)
  case dropAttribute(name: String)
  case renameAttribute(name: String, newName: String)
  case alterAttributeType(name: String, type: String)

  // A new type: the only change in its list
  case createEnum(labels: [String])
  case createDomain(NewDomain)
  case createComposite([Attribute])

  /// Where a new enum label goes, next to a loaded label
  enum LabelPosition: Sendable, Equatable {
    case before(String)
    case after(String)
  }

  /// A domain CHECK; `expression` is what goes inside `CHECK ( )`. An empty `name` leaves the
  /// name to the server.
  struct Check: Sendable, Equatable {
    var name: String
    var expression: String
  }

  /// A composite type attribute; `type` is user-typed type text
  struct Attribute: Sendable, Equatable {
    var name: String
    var type: String
  }

  struct NewDomain: Sendable, Equatable {
    /// User-typed base type text
    var baseType: String
    var notNull: Bool
    /// User-typed DEFAULT expression. Nil for none.
    var defaultExpression: String?
    var checks: [Check]
  }

  /// True for the three changes that define a new type
  var createsType: Bool {
    switch self {
    case .createEnum, .createDomain, .createComposite: true
    default: false
    }
  }
}
