// PostgresUserTypeDDLBuilder.swift
// DDL for a list of `UserTypeChange` against one loaded PostgreSQL user type, or the CREATE of a
// new one. The types editor previews exactly these strings.
//
// The type is always written `schema.name` through `quoteIdentifier`, like every other name.
// Enum labels are string literals (`SQLDialect.literal`: quotes doubled, backslashes escaped).
// Type text, DEFAULT and CHECK expressions go through `StructureDDLBuilder.checkedText`: unsafe
// text is refused, never escaped.
//
// `ALTER TYPE ... ADD VALUE` statements come back in their own group, in staged order: below
// PostgreSQL 12 they cannot run inside a transaction block (25001), so they run one by one before
// the rest. From 12 on a new label cannot be used before COMMIT (55P04), so nothing here uses a
// label the same list adds: a new label is placed next to a loaded label only, and only loaded
// labels are renamed. Order of the rest: domain changes in the order given (one ALTER DOMAIN
// each); for a composite one ALTER TYPE with DROP, ADD and ALTER ATTRIBUTE actions (each group in
// the order given); then RENAME VALUE / RENAME ATTRIBUTE, one statement each, names as loaded.

import Foundation

/// The DDL of one types editor apply
nonisolated struct UserTypeDDL: Sendable, Equatable {
  /// `ALTER TYPE ... ADD VALUE`, in staged order
  var addValues: [String] = []
  /// Everything else, in run order
  var others: [String] = []

  /// Run order when everything goes in one batch
  var all: [String] { addValues + others }
}

nonisolated enum PostgresUserTypeDDLBuilder {
  /// The DDL for `changes` to the type `schema.name`. `loaded` is the type's kind as loaded, nil
  /// for a new type (then `changes` is exactly one create).
  static func build(
    _ changes: [UserTypeChange], schema: String, name: String, loaded: DatabaseUserType.Kind?
  ) throws -> UserTypeDDL {
    guard !changes.isEmpty else { return UserTypeDDL() }
    let type = try typeName(schema: schema, name: name)
    guard let loaded else {
      guard changes.count == 1, let create = changes.first, create.createsType else {
        throw StructureDDLError.unsupported("A new type is defined by one create change.")
      }
      return UserTypeDDL(others: [try createStatement(create, type: type)])
    }
    switch loaded {
    case .enum(let labels):
      return try enumStatements(changes, type: type, labels: labels)
    case .domain(_, _, _, let constraints):
      return UserTypeDDL(
        others: try domainStatements(changes, type: type, constraints: constraints))
    case .composite(let attributes):
      return UserTypeDDL(
        others: try compositeStatements(changes, type: type, attributes: attributes.map(\.name)))
    }
  }

  // MARK: - Enum

  private static func enumStatements(
    _ changes: [UserTypeChange], type: String, labels: [String]
  ) throws -> UserTypeDDL {
    let loaded = Set(labels)
    var taken = loaded
    var renamed = Set<String>()
    var ddl = UserTypeDDL()
    for change in changes {
      switch change {
      case .addValue(let label, let position):
        try checkedLabel(label, taken: taken)
        taken.insert(label)
        var statement = "ALTER TYPE \(type) ADD VALUE \(literal(label))"
        switch position {
        case .before(let anchor):
          try checkedAnchor(anchor, loaded: loaded)
          statement += " BEFORE \(literal(anchor))"
        case .after(let anchor):
          try checkedAnchor(anchor, loaded: loaded)
          statement += " AFTER \(literal(anchor))"
        case nil:
          break
        }
        ddl.addValues.append(statement)
      case .renameValue(let label, let newLabel):
        guard loaded.contains(label) else {
          throw StructureDDLError.unsupported(
            "Only a loaded label can be renamed: \(literal(label)) is new in this change.")
        }
        guard renamed.insert(label).inserted else {
          throw StructureDDLError.invalidText("The label \(literal(label)) is renamed twice.")
        }
        try checkedLabel(newLabel, taken: taken)
        taken.insert(newLabel)
        ddl.others.append(
          "ALTER TYPE \(type) RENAME VALUE \(literal(label)) TO \(literal(newLabel))")
      default:
        throw mismatch(kind: "an enum")
      }
    }
    return ddl
  }

  /// Non-empty, no NUL, and not a label the type has or this change list adds
  private static func checkedLabel(_ label: String, taken: Set<String>) throws {
    guard !label.isEmpty else {
      throw StructureDDLError.invalidText("An enum label cannot be empty.")
    }
    guard !label.contains("\0") else {
      throw StructureDDLError.invalidText("An enum label cannot contain a NUL character.")
    }
    guard !taken.contains(label) else {
      throw StructureDDLError.invalidText("The enum already has the label \(literal(label)).")
    }
  }

  /// A new label goes next to a loaded label only (55P04: a label added in the same
  /// transaction is not used)
  private static func checkedAnchor(_ anchor: String, loaded: Set<String>) throws {
    guard loaded.contains(anchor) else {
      throw StructureDDLError.unsupported(
        "A new label can only be placed next to a label the type already has; "
          + "apply first to place it next to \(literal(anchor)).")
    }
  }

  // MARK: - Domain

  private static func domainStatements(
    _ changes: [UserTypeChange], type: String, constraints: [DatabaseUserType.Constraint]
  ) throws -> [String] {
    let q = SQLDialect.postgresql.quoteIdentifier
    let loaded = Set(constraints.map(\.name))
    return try changes.map { change in
      let action: String
      switch change {
      case .setDefault(let expression):
        try StructureDDLBuilder.checkedText(expression, "default", dialect: .postgresql)
        action = "SET DEFAULT \(expression)"
      case .dropDefault:
        action = "DROP DEFAULT"
      case .setNotNull:
        action = "SET NOT NULL"
      case .dropNotNull:
        action = "DROP NOT NULL"
      case .addCheck(let check):
        action = "ADD " + (try checkDefinition(check))
      case .dropConstraint(let name):
        try checkedName(name, "constraint")
        guard loaded.contains(name) else {
          throw StructureDDLError.invalidText("The domain has no constraint \"\(name)\".")
        }
        action = "DROP CONSTRAINT \(try q(name))"
      default:
        throw mismatch(kind: "a domain")
      }
      return "ALTER DOMAIN \(type) \(action)"
    }
  }

  /// `CONSTRAINT "name" CHECK (expression)`, or `CHECK (expression)` when the name is empty
  /// (the server names it)
  private static func checkDefinition(_ check: UserTypeChange.Check) throws -> String {
    try StructureDDLBuilder.checkedText(check.expression, "check", dialect: .postgresql)
    guard !check.name.isEmpty else { return "CHECK (\(check.expression))" }
    try checkedName(check.name, "constraint")
    return "CONSTRAINT \(try SQLDialect.postgresql.quoteIdentifier(check.name)) "
      + "CHECK (\(check.expression))"
  }

  // MARK: - Composite

  private static func compositeStatements(
    _ changes: [UserTypeChange], type: String, attributes: [String]
  ) throws -> [String] {
    let q = SQLDialect.postgresql.quoteIdentifier
    let loaded = Set(attributes)
    func loadedAttribute(_ name: String) throws -> String {
      guard loaded.contains(name) else {
        throw StructureDDLError.invalidText("The type has no attribute \"\(name)\".")
      }
      return try q(name)
    }
    var drops: [String] = []
    var adds: [String] = []
    var alters: [String] = []
    var renames: [String] = []
    for change in changes {
      switch change {
      case .addAttribute(let attribute):
        adds.append("ADD ATTRIBUTE " + (try attributeDefinition(attribute)))
      case .dropAttribute(let name):
        drops.append("DROP ATTRIBUTE \(try loadedAttribute(name))")
      case .alterAttributeType(let name, let attributeType):
        try StructureDDLBuilder.checkedText(attributeType, "type", dialect: .postgresql)
        alters.append("ALTER ATTRIBUTE \(try loadedAttribute(name)) TYPE \(attributeType)")
      case .renameAttribute(let name, let newName):
        try checkedName(newName, "attribute")
        renames.append(
          "ALTER TYPE \(type) RENAME ATTRIBUTE \(try loadedAttribute(name)) TO \(try q(newName))")
      default:
        throw mismatch(kind: "a composite type")
      }
    }
    let actions = drops + adds + alters
    let alter = actions.isEmpty ? [] : ["ALTER TYPE \(type) " + actions.joined(separator: ", ")]
    return alter + renames
  }

  /// `"name" type`
  private static func attributeDefinition(_ attribute: UserTypeChange.Attribute) throws -> String {
    try checkedName(attribute.name, "attribute")
    try StructureDDLBuilder.checkedText(attribute.type, "type", dialect: .postgresql)
    return "\(try SQLDialect.postgresql.quoteIdentifier(attribute.name)) \(attribute.type)"
  }

  // MARK: - Create

  private static func createStatement(_ change: UserTypeChange, type: String) throws -> String {
    switch change {
    case .createEnum(let labels):
      var taken = Set<String>()
      for label in labels {
        try checkedLabel(label, taken: taken)
        taken.insert(label)
      }
      return "CREATE TYPE \(type) AS ENUM (\(labels.map(literal).joined(separator: ", ")))"
    case .createDomain(let domain):
      try StructureDDLBuilder.checkedText(domain.baseType, "type", dialect: .postgresql)
      var statement = "CREATE DOMAIN \(type) AS \(domain.baseType)"
      if let expression = domain.defaultExpression {
        try StructureDDLBuilder.checkedText(expression, "default", dialect: .postgresql)
        statement += " DEFAULT \(expression)"
      }
      if domain.notNull { statement += " NOT NULL" }
      try checkedUnique(domain.checks.map(\.name).filter { !$0.isEmpty }, "constraint")
      for check in domain.checks { statement += " " + (try checkDefinition(check)) }
      return statement
    case .createComposite(let attributes):
      try checkedUnique(attributes.map(\.name), "attribute")
      let list = try attributes.map(attributeDefinition).joined(separator: ", ")
      return "CREATE TYPE \(type) AS (\(list))"
    default:
      throw StructureDDLError.unsupported("A new type is defined by one create change.")
    }
  }

  // MARK: - Shared helpers

  /// `schema.name`, or just the name when the schema is empty
  static func typeName(schema: String, name: String) throws -> String {
    try checkedName(name, "type")
    let quoted = try SQLDialect.postgresql.quoteIdentifier(name)
    guard !schema.isEmpty else { return quoted }
    return try SQLDialect.postgresql.quoteIdentifier(schema) + "." + quoted
  }

  private static func literal(_ label: String) -> String {
    SQLDialect.postgresql.literal(.string(label))
  }

  /// Non-empty and without NUL (the identifier quoting refuses NUL too, with a vaguer error)
  private static func checkedName(_ name: String, _ what: String) throws {
    guard !name.isEmpty else {
      throw StructureDDLError.invalidText("A \(what) name cannot be empty.")
    }
    guard !name.contains("\0") else {
      throw StructureDDLError.invalidText("A \(what) name cannot contain a NUL character.")
    }
  }

  private static func checkedUnique(_ names: [String], _ what: String) throws {
    var seen = Set<String>()
    for name in names where !seen.insert(name).inserted {
      throw StructureDDLError.invalidText("The \(what) \"\(name)\" is listed twice.")
    }
  }

  private static func mismatch(kind: String) -> StructureDDLError {
    .unsupported("This change does not apply to \(kind).")
  }
}
