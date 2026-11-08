// HiddenCharacterRule.swift
// Text that renders other than it runs: the one rule MCP execute_write and the AI proposal Run
// both refuse by, and the markers their displays (the MCP approval panel, the AI proposal card)
// show for the invisible characters it lets through inside a string literal.

nonisolated enum HiddenCharacterRule {
  /// Invisible characters allowed inside a string literal, where text needs them (emoji
  /// presentation VS16, ZWJ, ZWNJ, soft hyphen); the approval shows each as a marker
  /// (`markingInvisibles`).
  static let literalInvisibles: Set<Unicode.Scalar> = [
    "\u{FE0F}", "\u{200D}", "\u{200C}", "\u{00AD}",
  ]

  /// Text that renders other than it runs (`isHidden`), except `isLiteralInvisible` inside a
  /// string literal of `dialect` (quoted, escape or dollar-quoted; never an identifier). MongoDB
  /// text is not lexed as SQL, so it allows them nowhere.
  static func hasHiddenCharacters(_ sql: String, dialect: SQLDialect) -> Bool {
    let scalars = Array(sql.unicodeScalars)
    guard dialect != .mongodb else { return scalars.contains(where: isHidden) }
    let tokenizer = SQLTokenizer(dialect: dialect)
    var index = 0
    while index < scalars.count {
      let lexeme = tokenizer.lexeme(in: scalars, at: index)
      let inLiteral: Bool
      switch lexeme.kind {
      case .quoted(.string, _), .quoted(.backslashString, _), .dollarString: inLiteral = true
      default: inLiteral = false
      }
      if scalars[lexeme.range].contains(where: {
        isHidden($0) && !(inLiteral && isLiteralInvisible($0))
      }) {
        return true
      }
      index = lexeme.range.upperBound
    }
    return false
  }

  /// A control character other than tab, LF and CR, a format character (Cf: bidi controls,
  /// zero-width characters, BOM, ...), a space other than U+0020 (Zs: no-break, ideographic,
  /// ...), a line or paragraph separator, a private-use, unassigned or surrogate code point,
  /// U+2800 BRAILLE PATTERN BLANK, or any other default ignorable code point (variation
  /// selectors, fillers).
  private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == "\t" || scalar == "\n" || scalar == "\r" { return false }
    if scalar == "\u{2800}" { return true }
    switch scalar.properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned,
      .surrogate:
      return true
    case .spaceSeparator: return scalar != " "
    default: return scalar.properties.isDefaultIgnorableCodePoint
    }
  }

  /// One of `literalInvisibles` or a space other than U+0020: allowed inside a string literal,
  /// shown there as a marker.
  private static func isLiteralInvisible(_ scalar: Unicode.Scalar) -> Bool {
    literalInvisibles.contains(scalar)
      || (scalar != " " && scalar.properties.generalCategory == .spaceSeparator)
  }

  /// `text` with each `isLiteralInvisible` scalar as a visible `[U+200D]` marker, for the
  /// approval and the AI proposal card.
  static func markingInvisibles(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
      if isLiteralInvisible(scalar) {
        let hex = String(scalar.value, radix: 16, uppercase: true)
        result += "[U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex + "]"
      } else {
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }
}
