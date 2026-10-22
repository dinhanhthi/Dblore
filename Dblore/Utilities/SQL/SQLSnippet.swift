// SQLSnippet.swift
// SQL snippets: a body the editor inserts in place of its trigger, with tab stops to fill in.
// Validation of saved snippets and the pure expansion of a body.

import Foundation

/// A snippet the user wrote in Settings. Saved in `SQLSnippetStore`, so every field is untrusted
/// when read back (`SQLSnippet.sanitized`).
///
/// The body may hold:
/// - `${n:default}`: tab stop `n` (1 or more), written as `default`
/// - `${n}`: empty tab stop `n`
/// - `$0` (or `${0}`): where the caret ends up
/// - `\$`: a literal dollar
///
/// Anything else stays as written, a bare `$1` included (a PostgreSQL parameter).
nonisolated struct SQLSnippet: Codable, Equatable, Sendable, Identifiable {
  var id = UUID()
  var name: String
  /// Typed in the editor, then accepted from autocomplete, to insert the body
  var trigger: String
  var body: String

  /// An expanded body: its text, and the stops in visiting order, as UTF-16 ranges into `text`
  nonisolated struct Expansion: Equatable, Sendable {
    let text: String
    /// Stops 1, 2, … by index, then the final caret (`$0`, else the end of the text) last
    let stops: [NSRange]
    /// Where each stop of `stops` (same index) was written: 0 for the first in the text. Tells
    /// apart stops at one location (`${1}${2}`); the final caret without `$0` comes last.
    let textOrder: [Int]
  }

  nonisolated enum ValidationError: Error, Equatable, Sendable {
    case emptyName, nameTooLong, invalidTrigger, duplicateTrigger, emptyBody, bodyTooLong
    case tooManySnippets

    var message: String {
      switch self {
      case .emptyName: "Give the snippet a name."
      case .nameTooLong: "Use at most \(SQLSnippet.maxNameLength) characters for the name."
      case .invalidTrigger:
        "Use 1 to \(SQLSnippet.maxTriggerLength) letters, digits, underscores or hyphens."
      case .duplicateTrigger: "Another snippet already has this trigger."
      case .emptyBody: "Write the text the snippet inserts."
      case .bodyTooLong:
        "The body is longer than "
          + SQLSnippet.maxBodyChars.formatted(.number.locale(Locale(identifier: "en_US")))
          + " characters."
      case .tooManySnippets: "At most \(SQLSnippet.maxSnippets) snippets."
      }
    }
  }

  static let maxSnippets = 200
  static let maxBodyChars = 4_000
  static let maxNameLength = 64
  static let maxTriggerLength = 32
  /// UTF-16 caps beside the character ones: a character with combining marks can be many units
  static let maxBodyUTF16 = 16_000
  static let maxNameUTF16 = 256
  /// UTF-16 units past which a repeated index no longer writes its default (see `expand`)
  static let maxExpandedLength = 50_000

  // MARK: - Validation

  /// `[A-Za-z0-9_-]{1,32}`: one editor token, so autocomplete can match and replace it
  static func isValidTrigger(_ trigger: String) -> Bool {
    (1...maxTriggerLength).contains(trigger.count)
      && trigger.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
          || $0 == "_" || $0 == "-"
      }
  }

  /// Why `snippet` cannot be saved into `snippets` (which may hold its earlier version, matched
  /// by id); nil when it can. Triggers match case-insensitively, as autocomplete does.
  static func validate(_ snippet: SQLSnippet, among snippets: [SQLSnippet]) -> ValidationError? {
    let others = snippets.filter { $0.id != snippet.id }
    if others.count == snippets.count, snippets.count >= maxSnippets { return .tooManySnippets }
    let name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return .emptyName }
    if snippet.name.count > maxNameLength || snippet.name.utf16.count > maxNameUTF16 {
      return .nameTooLong
    }
    if !isValidTrigger(snippet.trigger) { return .invalidTrigger }
    let trigger = snippet.trigger.lowercased()
    if others.contains(where: { $0.trigger.lowercased() == trigger }) { return .duplicateTrigger }
    if snippet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyBody }
    if snippet.body.count > maxBodyChars || snippet.body.utf16.count > maxBodyUTF16 {
      return .bodyTooLong
    }
    return nil
  }

  /// The saved snippets that pass `validate`, in order, the first of an id or trigger kept, at
  /// most `maxSnippets`
  static func sanitized(_ snippets: [SQLSnippet]) -> [SQLSnippet] {
    snippets.reduce(into: []) { kept, snippet in
      guard !kept.contains(where: { $0.id == snippet.id }),
        validate(snippet, among: kept) == nil
      else { return }
      kept.append(snippet)
    }
  }

  // MARK: - Expansion

  private static let dollar = unit("$")
  private static let backslash = unit("\\")
  private static let openBrace = unit("{")
  private static let closeBrace = unit("}")
  private static let colon = unit(":")

  /// Expands `body` in one pass over its UTF-16 units, so every range is an editor offset.
  /// A repeated index (`${1:id} … ${1}`) is one stop, its first occurrence; the later ones write
  /// the first one's default and are no stops (they do not follow edits). The same goes for a
  /// repeated `$0`. Malformed placeholders (`${x}`, `${2` without its brace) stay literal.
  /// A repeated index that would take the text past `maxExpandedLength` is written as it stands
  /// in the body (`${1}`), so the text stays within the cap plus the body's own length.
  static func expand(_ body: String) -> Expansion {
    let units = Array(body.utf16)
    var text: [UInt16] = []
    var stops: [Int: NSRange] = [:]
    var written: [Int: [UInt16]] = [:]
    var order: [Int: Int] = [:]
    var index = 0
    while index < units.count {
      let unit = units[index]
      if unit == backslash, index + 1 < units.count, units[index + 1] == dollar {
        text.append(dollar)
        index += 2
      } else if unit == dollar, let placeholder = placeholder(in: units, at: index) {
        let first = written[placeholder.index] == nil
        let value = written[placeholder.index] ?? placeholder.value
        if !first, text.count + value.count > maxExpandedLength {
          text += units[index..<placeholder.end]
          index = placeholder.end
          continue
        }
        if first {
          written[placeholder.index] = value
          stops[placeholder.index] = NSRange(location: text.count, length: value.count)
          order[placeholder.index] = order.count
        }
        text += value
        index = placeholder.end
      } else {
        text.append(unit)
        index += 1
      }
    }
    let final = stops.removeValue(forKey: 0) ?? NSRange(location: text.count, length: 0)
    let finalOrder = order.removeValue(forKey: 0) ?? order.count
    let indexes = stops.keys.sorted()
    return Expansion(
      text: String(decoding: text, as: UTF16.self),
      stops: indexes.compactMap { stops[$0] } + [final],
      textOrder: indexes.compactMap { order[$0] } + [finalOrder])
  }

  /// The placeholder starting at the `$` at `start`: its index, its default text and the offset
  /// after it. Nil when the text there is no placeholder.
  private static func placeholder(
    in units: [UInt16], at start: Int
  ) -> (index: Int, value: [UInt16], end: Int)? {
    var cursor = start + 1
    guard cursor < units.count else { return nil }
    // `$0`, not followed by another digit
    if units[cursor] == unit("0") {
      let next = cursor + 1
      return next < units.count && isDigit(units[next]) ? nil : (0, [], next)
    }
    guard units[cursor] == openBrace else { return nil }
    cursor += 1
    let digitsStart = cursor
    while cursor < units.count, isDigit(units[cursor]), cursor - digitsStart < 4 { cursor += 1 }
    guard cursor > digitsStart, cursor < units.count,
      let number = Int(String(decoding: units[digitsStart..<cursor], as: UTF16.self))
    else { return nil }
    if units[cursor] == closeBrace { return (number, [], cursor + 1) }
    guard units[cursor] == colon,
      let close = units[(cursor + 1)...].firstIndex(of: closeBrace)
    else { return nil }
    return (number, Array(units[(cursor + 1)..<close]), close + 1)
  }

  private static func isDigit(_ value: UInt16) -> Bool {
    (unit("0")...unit("9")).contains(value)
  }

  private static func unit(_ scalar: Unicode.Scalar) -> UInt16 { UInt16(scalar.value) }
}
