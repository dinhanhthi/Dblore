// AISlashCommand.swift
// Slash commands of the AI composer: parsing, the built-ins, custom command validation and the
// local placeholder expansion

import Foundation

/// A command the user wrote in Settings > AI. Saved in `AIConfiguration`, so every field is
/// untrusted when read back (`AISlashCommand.sanitized`).
nonisolated struct AICustomCommand: Codable, Equatable, Sendable, Identifiable {
  var id = UUID()
  var name: String
  var template: String
}

/// A command the composer runs: a built-in mapped to an existing flow, or a custom template
nonisolated enum AISlashCommand: Equatable, Sendable {
  case builtIn(BuiltIn)
  case custom(AICustomCommand)

  nonisolated enum BuiltIn: String, CaseIterable, Sendable {
    case explain, fix, review, optimize

    var summary: String {
      switch self {
      case .explain: "Explain the current query"
      case .fix: "Fix the current query's error"
      case .review: "Review the current query"
      case .optimize: "Optimize the current query"
      }
    }

    /// Review and Optimize read SQL only: never offered on MongoDB
    var isSQLOnly: Bool { self == .review || self == .optimize }
  }

  /// The four placeholders a template may hold, written `{{name}}` (exact, lowercase)
  nonisolated enum Placeholder: String, CaseIterable, Sendable {
    case query, selection, schema, error

    var token: String { "{{\(rawValue)}}" }
  }

  /// What the placeholders expand to. Nil (the gate does not allow the connection, or nothing
  /// to read) expands to empty.
  nonisolated struct Values: Equatable, Sendable {
    var query: String?
    var selection: String?
    var schema: String?
    var error: String?

    subscript(placeholder: Placeholder) -> String? {
      switch placeholder {
      case .query: query
      case .selection: selection
      case .schema: schema
      case .error: error
      }
    }
  }

  /// A draft that starts with `/name`: the name and the text after it
  nonisolated struct Invocation: Equatable, Sendable {
    let name: String
    let argument: String
  }

  nonisolated enum ValidationError: Error, Equatable, Sendable {
    case invalidName, reservedName, duplicateName, emptyTemplate, templateTooLong
    case tooManyCommands

    var message: String {
      switch self {
      case .invalidName:
        "Use 1 to \(AISlashCommand.maxNameLength) lowercase letters, digits or hyphens."
      case .reservedName: "This name belongs to a built-in command."
      case .duplicateName: "Another command already has this name."
      case .emptyTemplate: "Write the text the command puts in the draft."
      case .templateTooLong:
        "The template is longer than "
          + AISlashCommand.maxTemplateChars.formatted(.number.locale(Locale(identifier: "en_US")))
          + " characters."
      case .tooManyCommands:
        "At most \(AISlashCommand.maxCustomCommands) custom commands."
      }
    }
  }

  static let maxCustomCommands = 50
  static let maxNameLength = 32
  static let maxTemplateChars = 4_000
  /// Characters one placeholder value adds before it is cut
  static let maxValueChars = AIPrompts.maxInputChars
  /// Characters an expanded template keeps
  static let maxExpandedChars = 16_000
  static let truncationMarker = "[truncated]"

  var name: String {
    switch self {
    case .builtIn(let builtIn): builtIn.rawValue
    case .custom(let command): command.name
    }
  }

  // MARK: - Parsing

  /// The command the draft starts with: `/` then a valid name, then the end or whitespace.
  /// Leading whitespace is skipped. `//`, `/ x` and `/usr/bin` are no commands.
  static func parse(_ draft: String) -> Invocation? {
    let text = draft.drop(while: \.isWhitespace)
    guard text.first == "/" else { return nil }
    let rest = text.dropFirst()
    let name = rest.prefix { !$0.isWhitespace }
    guard isValidName(String(name)) else { return nil }
    let argument = rest.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
    return Invocation(name: String(name), argument: argument)
  }

  /// The built-in of that name, else the custom command; nil when none has it
  static func resolve(_ name: String, custom: [AICustomCommand]) -> AISlashCommand? {
    if let builtIn = BuiltIn(rawValue: name) { return .builtIn(builtIn) }
    return custom.first { $0.name == name }.map { .custom($0) }
  }

  /// The commands listed on a connection of `dialect`: the built-ins (Review and Optimize not on
  /// MongoDB), then the custom commands by name. Whether a built-in can run right now (SQL, an
  /// error) is checked when it runs.
  static func available(custom: [AICustomCommand], dialect: SQLDialect) -> [AISlashCommand] {
    let builtIns = BuiltIn.allCases.filter { !($0.isSQLOnly && dialect == .mongodb) }
    return builtIns.map { .builtIn($0) }
      + custom.sorted { $0.name < $1.name }.map { .custom($0) }
  }

  // MARK: - Validation

  /// `[a-z0-9-]{1,32}`
  static func isValidName(_ name: String) -> Bool {
    (1...maxNameLength).contains(name.count)
      && name.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
      }
  }

  /// Why `command` cannot be saved into `commands` (which may hold its earlier version, matched
  /// by id); nil when it can
  static func validate(
    _ command: AICustomCommand, among commands: [AICustomCommand]
  ) -> ValidationError? {
    let others = commands.filter { $0.id != command.id }
    if others.count == commands.count, commands.count >= maxCustomCommands {
      return .tooManyCommands
    }
    if !isValidName(command.name) { return .invalidName }
    if BuiltIn(rawValue: command.name) != nil { return .reservedName }
    if others.contains(where: { $0.name == command.name }) { return .duplicateName }
    if command.template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .emptyTemplate
    }
    if command.template.count > maxTemplateChars { return .templateTooLong }
    return nil
  }

  /// The saved commands that pass `validate`, in order, the first of a name or id kept, at most
  /// `maxCustomCommands`
  static func sanitized(_ commands: [AICustomCommand]) -> [AICustomCommand] {
    commands.reduce(into: []) { kept, command in
      guard !kept.contains(where: { $0.id == command.id }),
        validate(command, among: kept) == nil
      else { return }
      kept.append(command)
    }
  }

  // MARK: - Expansion

  /// The placeholders `template` holds
  static func placeholders(in template: String) -> Set<Placeholder> {
    Set(Placeholder.allCases.filter { template.contains($0.token) })
  }

  /// Replaces each known placeholder with its value (empty when nil), each value cut at
  /// `maxValueChars`. One pass over the template: a placeholder inside a value stays as written.
  /// Unknown `{{x}}` stays literal. The result is cut at `maxExpandedChars`.
  static func expand(template: String, values: Values) -> String {
    var result = ""
    var rest = Substring(template)
    while let first = rest.first {
      if first == "{",
        let placeholder = Placeholder.allCases.first(where: { rest.hasPrefix($0.token) })
      {
        result += cut(values[placeholder] ?? "", at: maxValueChars)
        rest = rest.dropFirst(placeholder.token.count)
      } else {
        result.append(first)
        rest = rest.dropFirst()
      }
    }
    return cut(result, at: maxExpandedChars)
  }

  private static func cut(_ text: String, at limit: Int) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "\n" + truncationMarker
  }
}
