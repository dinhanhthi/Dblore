//
//  NotebookViewModel+Confirmation.swift
//  Dblore
//

import CryptoKit
import Foundation

// MARK: - Safe Mode Confirmation (classifier-driven)

extension NotebookViewModel {
  /// Shows the confirmation dialog for `query` if the connection's commit style asks for one.
  /// Returns true if the dialog was shown (the caller must not run the query).
  func presentConfirmationIfNeeded(for query: String, cellId: UUID?) -> Bool {
    let commitStyle =
      notebook.connectionConfig?.resolvedCommitStyle(fallback: AppSettings.shared.commitStyle)
      ?? AppSettings.shared.commitStyle
    let classified = classifiedStatements(for: query)
    let parameters = boundParameterValues(for: query, cellId: cellId) ?? [:]
    guard
      let statements = Self.statementsNeedingConfirmation(
        classified, commitStyle: commitStyle, parameters: parameters, dialect: sqlDialect)
    else { return false }

    queryConfirmationState.pendingCellId = cellId
    queryConfirmationState.pendingQuery = query
    queryConfirmationState.parameterValues = parameters
    if queryConfirmationState.runAllAwaitingUnlock {
      queryConfirmationState.runAllAwaitingUnlock = false
      queryConfirmationState.clearRunAll()
    }
    // Missing WHERE and a match-all LIKE bind are separate warnings.
    queryConfirmationState.affectsAllRows =
      SQLStatementClassifier.summary(classified).affectsAllRows
      || statements.contains(where: \.affectsAllRows)
    queryConfirmationState.likePatternAffectsAllRows = Self.scriptMatchesAllRowsByLike(
      classified, parameters: parameters, dialect: sqlDialect)
    queryConfirmationState.requiresPassword = commitStyle.requiresPassword
    queryConfirmationState.statements = statements
    // A dialog dismissed without Cancel (Escape, click outside) leaves its pending action armed.
    // Drop it so Execute Query runs what this dialog shows; the caller re-arms its own after.
    pendingExplainSQL = nil
    pendingStagedBatch = nil
    pendingInlineEdit = nil
    queryConfirmationState.showDialog = true
    return true
  }

  /// "Forgot Password?" fallback of the Safe Mode unlock: the database password unlocks only
  /// when no Safe Mode password exists, never when the stored or typed password is empty, and
  /// is compared in constant time (SHA-256 digests, so lengths do not leak either).
  nonisolated static func acceptsDatabasePasswordFallback(
    entry: String, storedPassword: String?, hasSafeModePassword: Bool
  ) -> Bool {
    guard !hasSafeModePassword, let storedPassword, !storedPassword.isEmpty, !entry.isEmpty
    else { return false }
    return SafeModePasswordRecord.constantTimeEquals(
      Data(SHA256.hash(data: Data(entry.utf8))), Data(SHA256.hash(data: Data(storedPassword.utf8))))
  }

  /// "Use database password" affordances are offered only while no Safe Mode password exists.
  nonisolated static func showsDatabasePasswordFallback(hasSafeModePassword: Bool) -> Bool {
    !hasSafeModePassword
  }

  /// Settings > Safe Mode credential check ("Change Password", "Authentication Required"):
  /// the database password path goes through `acceptsDatabasePasswordFallback`, the Safe Mode
  /// password path through `verifySafeModePassword`.
  nonisolated static func settingsAcceptsCredential(
    entry: String, usingDatabasePassword: Bool, storedDatabasePassword: String?,
    hasSafeModePassword: Bool, verifySafeModePassword: (String) -> Bool
  ) -> Bool {
    guard usingDatabasePassword else { return verifySafeModePassword(entry) }
    return acceptsDatabasePasswordFallback(
      entry: entry, storedPassword: storedDatabasePassword,
      hasSafeModePassword: hasSafeModePassword)
  }

  /// Statements to list in the confirmation dialog, or nil when no confirmation is needed.
  ///
  /// Every statement of the cell is checked, not only the first. `confirm` and `password` list
  /// statements `mayWrite` treats as writes (DML, DDL, utility, unknown, a brake reset, or a
  /// privilege change). They do not list a plain `SELECT`. `immediate` and `review` list nothing,
  /// including `SET statement_timeout`, `RESET ALL`, and `SET ROLE`.
  nonisolated static func statementsNeedingConfirmation(
    _ classified: [ClassifiedStatement], commitStyle: CommitStyle,
    parameters: [String: SQLBindValue] = [:], dialect: SQLDialect = .postgresql
  ) -> [StatementConfirmation]? {
    switch commitStyle {
    case .immediate, .review:
      // Immediate drops the old silent brake and privilege exception on purpose.
      return nil
    case .confirm, .password:
      let all = classified.enumerated().map {
        makeConfirmation(
          index: $0.offset, statement: $0.element, parameters: parameters, dialect: dialect)
      }
      let listed = zip(classified, all).filter { mayWrite($0.0) }.map(\.1)
      return listed.isEmpty ? nil : listed
    }
  }

  /// True when any statement has a match-all LIKE, including one the commit style does not list.
  nonisolated static func scriptMatchesAllRowsByLike(
    _ classified: [ClassifiedStatement], parameters: [String: SQLBindValue], dialect: SQLDialect
  ) -> Bool {
    classified.contains { statement in
      likeWildcardBindsAllRows(
        statement.text, kind: statement.kind, parameters: parameters, dialect: dialect)
    }
  }

  /// True if the statement may change data, schema, session brakes or privileges.
  private nonisolated static func mayWrite(_ statement: ClassifiedStatement) -> Bool {
    switch SQLStatementClassifier.effectiveKind(statement.kind) {
    case .dml, .ddl, .utility, .unknown: return true
    default: return statement.resetsSessionBrakes || statement.changesPrivileges
    }
  }

  private nonisolated static func makeConfirmation(
    index: Int, statement: ClassifiedStatement, parameters: [String: SQLBindValue],
    dialect: SQLDialect
  ) -> StatementConfirmation {
    return StatementConfirmation(
      index: index, preview: preview(statement.text),
      kindLabel: DatabaseConnectionManager.describe(statement.kind),
      affectsAllRows: statement.affectsAllRows, touchesBrake: statement.resetsSessionBrakes,
      changesPrivileges: statement.changesPrivileges,
      parameterNote: parameterNote(for: statement.text, parameters: parameters, dialect: dialect),
      likePatternAffectsAllRows: likeWildcardBindsAllRows(
        statement.text, kind: statement.kind, parameters: parameters, dialect: dialect))
  }

  /// `"name" = "value"` or `"name" = NULL` for each `:name`, in first-seen order.
  /// Quotes keep a comma inside one value. The text is the flattened form below.
  private nonisolated static func parameterNote(
    for statement: String, parameters: [String: SQLBindValue], dialect: SQLDialect
  ) -> String? {
    let names = SQLParameterRewriter.parameterNames(in: statement, dialect: dialect)
    guard !names.isEmpty else { return nil }
    let parts = names.map { name -> String in
      switch parameters[name] {
      case .text(let value):
        return "\(confirmationToken(name)) = \(confirmationToken(value))"
      case .null, .none: return "\(confirmationToken(name)) = NULL"
      }
    }
    return parts.joined(separator: ", ")
  }

  /// One quoted token. The closing quote stays even when the text was capped.
  private nonisolated static func confirmationToken(_ value: String) -> String {
    let escaped =
      confirmationValue(value)
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  /// One line, capped. Newlines and control characters become spaces. Format characters
  /// (bidi overrides, zero-width) are dropped so they cannot change how the note reads.
  /// The dialog draws this note above the `!` reasons.
  private nonisolated static func confirmationValue(_ value: String) -> String {
    let space: Unicode.Scalar = " "
    var scalars = String.UnicodeScalarView()
    for scalar in value.unicodeScalars {
      if scalar.properties.generalCategory == .format { continue }
      if CharacterSet.newlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
        scalars.append(space)
      } else {
        scalars.append(scalar)
      }
    }
    let flattened = String(scalars)
    let limit = 80
    guard flattened.count > limit else { return flattened }
    return String(flattened.prefix(limit - 1)) + "…"
  }

  /// DML whose LIKE, ILIKE, `~~`, or `~~*` operand trims to `%` only, including a literal
  /// with no `:name`. An odd number of `NOT` or `!` cancels that operator, including
  /// `NOT (name NOT LIKE ...)`. Casts, parentheses, `||`, and calls of the same kind of
  /// operand still count. Values stay out of the SQL text.
  private nonisolated static func likeWildcardBindsAllRows(
    _ text: String, kind: StatementKind, parameters: [String: SQLBindValue], dialect: SQLDialect
  ) -> Bool {
    guard likePatternApplies(to: kind) else { return false }
    let pieces = likeLexemes(text, dialect: dialect)
    var index = 0
    while index < pieces.count {
      guard let start = likeOperandStart(pieces, at: index) else {
        index += 1
        continue
      }
      let (matches, next) = operandIsAllPercent(pieces, from: start, parameters: parameters)
      if matches, !likeOperatorIsNegated(pieces, at: index) { return true }
      index = max(next, index + 1)
    }
    return false
  }

  /// DML, including a data-modifying `WITH` and `EXPLAIN ANALYZE` of DML. Plain EXPLAIN is a read.
  private nonisolated static func likePatternApplies(to kind: StatementKind) -> Bool {
    SQLStatementClassifier.effectiveKind(kind) == .dml
  }

  private enum LikeLexeme: Sendable {
    case word(String)
    case symbol(String)
    case literal(String)
    case number(String)
    case space
    case other

    nonisolated func isSymbol(_ symbol: String) -> Bool {
      if case .symbol(let text) = self { return text == symbol }
      return false
    }
  }

  private nonisolated static func likeLexemes(_ text: String, dialect: SQLDialect) -> [LikeLexeme] {
    let scalars = Array(text.unicodeScalars)
    let tokenizer = SQLTokenizer(dialect: dialect)
    var pieces: [LikeLexeme] = []
    var offset = 0
    while offset < scalars.count {
      let lexeme = tokenizer.lexeme(in: scalars, at: offset)
      let raw = SQLTokenizer.text(scalars, lexeme.range)
      switch lexeme.kind {
      case .whitespace, .comment: pieces.append(.space)
      case .word: pieces.append(.word(raw))
      case .symbol: pieces.append(.symbol(raw))
      case .number: pieces.append(.number(raw))
      case .dollarString:
        if let body = dollarBody(raw) {
          pieces.append(.literal(body))
        } else {
          pieces.append(.other)
        }
      case .quoted(let kind, let content):
        let escaped = raw.unicodeScalars.first == "E" || raw.unicodeScalars.first == "e"
        pieces.append(
          quotedLikeLexeme(kind, content: content, isEscapeString: escaped, dialect: dialect))
      }
      offset = lexeme.range.upperBound
    }
    return pieces
  }

  /// Body of a `$tag$...$tag$` lexeme, or nil when the closing tag is missing.
  private nonisolated static func dollarBody(_ raw: String) -> String? {
    let scalars = Array(raw.unicodeScalars)
    guard scalars.first == "$" else { return nil }
    var end = 1
    while end < scalars.count, scalars[end] != "$" { end += 1 }
    guard end < scalars.count else { return nil }
    let tagCount = end + 1
    guard scalars.count >= tagCount * 2 else { return nil }
    guard Array(scalars[0..<tagCount]) == Array(scalars[(scalars.count - tagCount)...]) else {
      return nil
    }
    return String(String.UnicodeScalarView(scalars[tagCount..<(scalars.count - tagCount)]))
  }

  /// A PostgreSQL or DuckDB `E'...'` escape string is decoded. A plain or ambiguous string
  /// stays raw: DuckDB plain strings have no backslash escapes, and SQLite has no `E'...'`.
  /// A quoted identifier is not a pattern literal.
  private nonisolated static func quotedLikeLexeme(
    _ kind: SQLToken.Kind, content: String, isEscapeString: Bool, dialect: SQLDialect
  ) -> LikeLexeme {
    if kind == .string, isEscapeString, dialect == .postgresql || dialect == .duckdb,
      content.contains("\\")
    {
      return .literal(eStringText(content))
    }
    if kind == .string || kind == .backslashString {
      return .literal(content)
    }
    return .other
  }

  /// PostgreSQL `E'...'` escapes. An unknown escape keeps the escaped character.
  private nonisolated static func eStringText(_ content: String) -> String {
    let scalars = Array(content.unicodeScalars)
    var out = String.UnicodeScalarView()
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      guard scalar == "\\", index + 1 < scalars.count else {
        out.append(scalar)
        index += 1
        continue
      }
      index += 1
      let escaped = scalars[index]
      index += 1
      switch escaped {
      case "b": out.append(contentsOf: "\u{08}".unicodeScalars)
      case "f": out.append(contentsOf: "\u{0C}".unicodeScalars)
      case "n": out.append("\n")
      case "r": out.append("\r")
      case "t": out.append("\t")
      case "x":
        let (value, next) = hexByte(scalars, from: index)
        if let value, let decoded = Unicode.Scalar(value) {
          out.append(decoded)
          index = next
        } else {
          out.append("x")
        }
      case "u", "U":
        let width = escaped == "u" ? 4 : 8
        if let (value, next) = hexRun(scalars, from: index, count: width),
          let decoded = Unicode.Scalar(value)
        {
          out.append(decoded)
          index = next
        } else {
          out.append(escaped)
        }
      default:
        if let value = octalByte(scalars, first: escaped, from: &index) {
          if let decoded = Unicode.Scalar(value) {
            out.append(decoded)
          } else {
            out.append("?")
          }
        } else {
          out.append(escaped)
        }
      }
    }
    return String(out)
  }

  /// One or two hex digits after `\x`, or nil when there are none.
  private nonisolated static func hexByte(
    _ scalars: [Unicode.Scalar], from start: Int
  ) -> (Int?, Int) {
    hexRun(scalars, from: start, count: 2).map { ($0.0, $0.1) } ?? (nil, start)
  }

  /// Exactly `count` hex digits, or a shorter run when `count` is 2 and one digit is present.
  private nonisolated static func hexRun(
    _ scalars: [Unicode.Scalar], from start: Int, count: Int
  ) -> (Int, Int)? {
    var value = 0
    var index = start
    var taken = 0
    while taken < count, index < scalars.count, let digit = hexValue(scalars[index]) {
      value = value * 16 + digit
      index += 1
      taken += 1
    }
    guard taken > 0, count == 2 || taken == count else { return nil }
    return (value, index)
  }

  /// Up to three octal digits. The first digit is `first`; `index` moves past the rest.
  private nonisolated static func octalByte(
    _ scalars: [Unicode.Scalar], first: Unicode.Scalar, from index: inout Int
  ) -> Int? {
    guard let firstDigit = octalValue(first) else { return nil }
    var value = firstDigit
    var taken = 1
    while taken < 3, index < scalars.count, let digit = octalValue(scalars[index]) {
      value = value * 8 + digit
      index += 1
      taken += 1
    }
    return value
  }

  private nonisolated static func hexValue(_ scalar: Unicode.Scalar) -> Int? {
    switch scalar {
    case "0"..."9": return Int(scalar.value - Unicode.Scalar("0").value)
    case "a"..."f": return Int(scalar.value - Unicode.Scalar("a").value) + 10
    case "A"..."F": return Int(scalar.value - Unicode.Scalar("A").value) + 10
    default: return nil
    }
  }

  private nonisolated static func octalValue(_ scalar: Unicode.Scalar) -> Int? {
    guard ("0"..."7").contains(scalar) else { return nil }
    return Int(scalar.value - Unicode.Scalar("0").value)
  }

  /// Index of the operand after LIKE, ILIKE, `~~`, or `~~*`, or nil when this token is not one.
  /// `~~` / `~~*` count only when those symbols are adjacent. Negation is counted separately.
  private nonisolated static func likeOperandStart(_ pieces: [LikeLexeme], at index: Int) -> Int? {
    switch pieces[index] {
    case .word(let text):
      let word = SQLTokenizer.asciiUppercased(text)
      guard word == "LIKE" || word == "ILIKE" else { return nil }
      return index + 1
    case .symbol:
      return posixLikeEnd(pieces, at: index)
    default:
      return nil
    }
  }

  /// True when an odd number of `NOT` or `!` negate this operator.
  /// Counts the `NOT`/`!` on the operator and each `NOT` wrapped around its parentheses,
  /// so `NOT (name NOT LIKE :pat)` stays positive. Stops at any other token.
  private nonisolated static func likeOperatorIsNegated(
    _ pieces: [LikeLexeme], at operatorIndex: Int
  ) -> Bool {
    var count = 0
    var cursor = operatorIndex
    if let not = previousNotIndex(pieces, before: operatorIndex) {
      count += 1
      cursor = not
    } else if negatedPosixLike(pieces, at: operatorIndex) {
      count += 1
      cursor = operatorIndex - 1
    }
    cursor = startOfLikeLeftOperand(pieces, endingBefore: cursor)
    while let previous = significantLikeIndex(pieces, before: cursor) {
      switch pieces[previous] {
      case .word(let text) where SQLTokenizer.asciiUppercased(text) == "NOT":
        count += 1
        cursor = previous
      case .symbol("("):
        cursor = previous
      default:
        return count % 2 == 1
      }
    }
    return count % 2 == 1
  }

  private nonisolated static func previousNotIndex(
    _ pieces: [LikeLexeme], before index: Int
  ) -> Int? {
    guard let previous = significantLikeIndex(pieces, before: index),
      case .word(let text) = pieces[previous],
      SQLTokenizer.asciiUppercased(text) == "NOT"
    else { return nil }
    return previous
  }

  /// First token of the column or call that this operator compares.
  private nonisolated static func startOfLikeLeftOperand(
    _ pieces: [LikeLexeme], endingBefore cursor: Int
  ) -> Int {
    guard let end = significantLikeIndex(pieces, before: cursor) else { return cursor }
    switch pieces[end] {
    case .symbol(")"):
      let open = matchingLikeOpen(pieces, close: end)
      guard let name = significantLikeIndex(pieces, before: open), isLikeName(pieces[name]) else {
        return open
      }
      return startOfDottedName(pieces, at: name)
    case .word, .other:
      return startOfDottedName(pieces, at: end)
    default:
      return end
    }
  }

  private nonisolated static func startOfDottedName(_ pieces: [LikeLexeme], at name: Int) -> Int {
    var index = name
    while let dot = significantLikeIndex(pieces, before: index), pieces[dot].isSymbol("."),
      let qualifier = significantLikeIndex(pieces, before: dot), isLikeName(pieces[qualifier])
    {
      index = qualifier
    }
    return index
  }

  private nonisolated static func isLikeName(_ piece: LikeLexeme) -> Bool {
    switch piece {
    case .word, .other: true
    default: false
    }
  }

  private nonisolated static func matchingLikeOpen(_ pieces: [LikeLexeme], close: Int) -> Int {
    var depth = 1
    var index = close - 1
    while index >= 0 {
      if pieces[index].isSymbol(")") {
        depth += 1
      } else if pieces[index].isSymbol("(") {
        depth -= 1
        if depth == 0 { return index }
      }
      index -= 1
    }
    return 0
  }

  private nonisolated static func significantLikeIndex(
    _ pieces: [LikeLexeme], before index: Int
  ) -> Int? {
    var cursor = index - 1
    while cursor >= 0 {
      if case .space = pieces[cursor] {
        cursor -= 1
        continue
      }
      return cursor
    }
    return nil
  }

  /// End index of `~~` or `~~*`, including when the tokenizer emits them as one symbol.
  private nonisolated static func posixLikeEnd(_ pieces: [LikeLexeme], at index: Int) -> Int? {
    if pieces[index].isSymbol("~~*") || pieces[index].isSymbol("~~") { return index + 1 }
    guard pieces[index].isSymbol("~"), index + 1 < pieces.count, pieces[index + 1].isSymbol("~")
    else { return nil }
    if index + 2 < pieces.count, pieces[index + 2].isSymbol("*") { return index + 3 }
    return index + 2
  }

  private nonisolated static func negatedPosixLike(_ pieces: [LikeLexeme], at index: Int) -> Bool {
    index > 0 && pieces[index - 1].isSymbol("!")
  }

  /// Known characters of a LIKE operand. Nil means the operand is not a value we can read.
  private struct LikePiece {
    var text: String?
    var next: Int
  }

  /// The operand is binds, percent literals, `||`, parentheses, casts, and calls of those.
  /// `replace` is applied when every argument is known text. Any other call matches only when
  /// every argument trims to `%`.
  private nonisolated static func operandIsAllPercent(
    _ pieces: [LikeLexeme], from start: Int, parameters: [String: SQLBindValue]
  ) -> (Bool, Int) {
    let parsed = parseLikeConcat(pieces, from: start, parameters: parameters)
    let matches = parsed.text.map { isPercentOnly(.text($0)) } ?? false
    return (matches, parsed.next)
  }

  /// One or more values joined by `||`. `requireValue` is set again after each `||`.
  private nonisolated static func parseLikeConcat(
    _ pieces: [LikeLexeme], from start: Int, parameters: [String: SQLBindValue]
  ) -> LikePiece {
    var index = start
    var combined = ""
    var saw = false
    var requireValue = true
    while true {
      let lead = skipLikeSpace(pieces, index)
      if !requireValue, lead >= pieces.count || isLikeValueBoundary(pieces, at: lead) {
        return LikePiece(text: saw ? combined : nil, next: lead)
      }
      let part = parseLikeCastable(pieces, from: lead, parameters: parameters)
      guard let text = part.text, part.next != lead else {
        return LikePiece(text: nil, next: part.next)
      }
      combined += text
      saw = true
      requireValue = false
      let after = skipLikeSpace(pieces, part.next)
      let width = after < pieces.count ? concatWidth(pieces, at: after) : 0
      guard width > 0 else { return LikePiece(text: combined, next: after) }
      index = after + width
      requireValue = true
    }
  }

  /// A value, then any number of `::type` casts. A cast keeps the value text.
  private nonisolated static func parseLikeCastable(
    _ pieces: [LikeLexeme], from start: Int, parameters: [String: SQLBindValue]
  ) -> LikePiece {
    let primary = parseLikePrimary(pieces, from: start, parameters: parameters)
    guard primary.text != nil else { return primary }
    var index = primary.next
    while true {
      let cast = skipLikeSpace(pieces, index)
      guard cast + 1 < pieces.count, pieces[cast].isSymbol(":"), pieces[cast + 1].isSymbol(":")
      else { return LikePiece(text: primary.text, next: cast) }
      let typeAt = skipLikeSpace(pieces, cast + 2)
      let afterType = skipLikeType(pieces, from: typeAt)
      guard afterType != typeAt else { return LikePiece(text: nil, next: cast) }
      index = afterType
    }
  }

  /// `:name`, a string literal, `(value)`, `CAST(value AS type)`, or `name(args)`.
  private nonisolated static func parseLikePrimary(
    _ pieces: [LikeLexeme], from start: Int, parameters: [String: SQLBindValue]
  ) -> LikePiece {
    let index = skipLikeSpace(pieces, start)
    guard index < pieces.count else { return LikePiece(text: nil, next: index) }
    switch pieces[index] {
    case .symbol("("):
      let inner = parseLikeConcat(pieces, from: index + 1, parameters: parameters)
      let close = skipLikeSpace(pieces, inner.next)
      guard inner.text != nil, close < pieces.count, pieces[close].isSymbol(")") else {
        return LikePiece(text: nil, next: close)
      }
      return LikePiece(text: inner.text, next: close + 1)
    case .literal(let text), .number(let text):
      return LikePiece(text: text, next: index + 1)
    case .symbol(":"):
      guard let name = bindName(pieces, at: index), case .text(let text) = parameters[name] else {
        return LikePiece(text: nil, next: index)
      }
      return LikePiece(text: text, next: index + 2)
    case .word(let text):
      let next = skipLikeSpace(pieces, index + 1)
      guard next < pieces.count, pieces[next].isSymbol("(") else {
        return LikePiece(text: nil, next: index)
      }
      if SQLTokenizer.asciiUppercased(text) == "CAST" {
        return parseLikeCastCall(pieces, from: next + 1, parameters: parameters)
      }
      return parseLikeCall(pieces, name: text, from: next + 1, parameters: parameters)
    default:
      return LikePiece(text: nil, next: index)
    }
  }

  /// `replace` is evaluated. Any other call matches only when every argument trims to `%`.
  private nonisolated static func parseLikeCall(
    _ pieces: [LikeLexeme], name: String, from start: Int, parameters: [String: SQLBindValue]
  ) -> LikePiece {
    var index = start
    var arguments: [String] = []
    while true {
      let lead = skipLikeSpace(pieces, index)
      if lead < pieces.count, pieces[lead].isSymbol(")") {
        return LikePiece(text: callText(name, arguments: arguments), next: lead + 1)
      }
      let argument = parseLikeConcat(pieces, from: lead, parameters: parameters)
      guard let text = argument.text else {
        let end = skipLikeUntilParen(pieces, from: start)
        let next = end < pieces.count ? end + 1 : end
        return LikePiece(text: nil, next: next)
      }
      arguments.append(text)
      let after = skipLikeSpace(pieces, argument.next)
      guard after < pieces.count else { return LikePiece(text: nil, next: after) }
      if pieces[after].isSymbol(",") {
        index = after + 1
        continue
      }
      guard pieces[after].isSymbol(")") else { return LikePiece(text: nil, next: after) }
      return LikePiece(text: callText(name, arguments: arguments), next: after + 1)
    }
  }

  /// Text of a call, or nil when this call is not a pattern of `%`.
  private nonisolated static func callText(_ name: String, arguments: [String]) -> String? {
    let upper = SQLTokenizer.asciiUppercased(name)
    if upper == "REPLACE", arguments.count == 3 {
      return replaced(arguments[0], arguments[1], arguments[2])
    }
    if upper == "CHR" || upper == "CHAR" {
      return characterCall(arguments)
    }
    guard !arguments.isEmpty, arguments.allSatisfy({ isPercentOnly(.text($0)) }) else {
      return nil
    }
    return "%"
  }

  /// `chr(37)` / `char(37)` when every argument is a decimal code point. One argument.
  private nonisolated static func characterCall(_ arguments: [String]) -> String? {
    guard arguments.count == 1 else { return nil }
    let trimmed = arguments[0].trimmingCharacters(in: .whitespacesAndNewlines)
    guard let code = Int(trimmed), let scalar = Unicode.Scalar(code) else { return nil }
    return String(scalar)
  }

  /// PostgreSQL `replace`: an empty search string leaves the source unchanged.
  private nonisolated static func replaced(
    _ source: String, _ from: String, _ to: String
  )
    -> String
  {
    guard !from.isEmpty else { return source }
    return source.replacingOccurrences(of: from, with: to)
  }

  /// `CAST(value AS type)`. The type is skipped; the value text is unchanged.
  private nonisolated static func parseLikeCastCall(
    _ pieces: [LikeLexeme], from start: Int, parameters: [String: SQLBindValue]
  ) -> LikePiece {
    let value = parseLikeConcat(pieces, from: start, parameters: parameters)
    let asWord = skipLikeSpace(pieces, value.next)
    guard value.text != nil, asWord < pieces.count, case .word(let text) = pieces[asWord],
      SQLTokenizer.asciiUppercased(text) == "AS"
    else { return LikePiece(text: nil, next: asWord) }
    let typeAt = skipLikeSpace(pieces, asWord + 1)
    let close = skipLikeUntilParen(pieces, from: typeAt)
    guard close < pieces.count, pieces[close].isSymbol(")") else {
      return LikePiece(text: nil, next: close)
    }
    return LikePiece(text: value.text, next: close + 1)
  }

  private nonisolated static func isLikeValueBoundary(
    _ pieces: [LikeLexeme], at index: Int
  )
    -> Bool
  {
    switch pieces[index] {
    case .symbol(")"), .symbol(","), .symbol(";"):
      return true
    case .word:
      let next = skipLikeSpace(pieces, index + 1)
      return next >= pieces.count || !pieces[next].isSymbol("(")
    case .symbol:
      return concatWidth(pieces, at: index) == 0
    default:
      return true
    }
  }

  /// One type name after `::`: optional qualifier, typmod, array brackets, and a short tail.
  private nonisolated static func skipLikeType(_ pieces: [LikeLexeme], from start: Int) -> Int {
    guard start < pieces.count else { return start }
    switch pieces[start] {
    case .word, .other: break
    default: return start
    }
    var index = start + 1
    while true {
      let dot = skipLikeSpace(pieces, index)
      guard dot < pieces.count, pieces[dot].isSymbol(".") else { break }
      let name = skipLikeSpace(pieces, dot + 1)
      guard name < pieces.count else { return index }
      switch pieces[name] {
      case .word, .other: index = name + 1
      default: return index
      }
    }
    index = skipLikeSpace(pieces, index)
    if index < pieces.count, pieces[index].isSymbol("(") {
      index = skipLikeBalanced(pieces, from: index)
    }
    index = skipLikeBrackets(pieces, from: index)
    return skipLikeTypeTail(pieces, from: index)
  }

  private nonisolated static func skipLikeTypeTail(_ pieces: [LikeLexeme], from start: Int) -> Int {
    let index = skipLikeSpace(pieces, start)
    guard index < pieces.count, case .word(let text) = pieces[index] else { return index }
    switch SQLTokenizer.asciiUppercased(text) {
    case "VARYING", "PRECISION":
      return index + 1
    case "WITH":
      let time = skipLikeSpace(pieces, index + 1)
      let zone = skipLikeSpace(pieces, time + 1)
      guard time < pieces.count, zone < pieces.count,
        case .word(let timeWord) = pieces[time], case .word(let zoneWord) = pieces[zone],
        SQLTokenizer.asciiUppercased(timeWord) == "TIME",
        SQLTokenizer.asciiUppercased(zoneWord) == "ZONE"
      else { return index }
      return zone + 1
    default:
      return index
    }
  }

  private nonisolated static func skipLikeBrackets(_ pieces: [LikeLexeme], from start: Int) -> Int {
    var index = skipLikeSpace(pieces, start)
    while index < pieces.count, pieces[index].isSymbol("[") {
      let close = skipLikeSpace(pieces, index + 1)
      guard close < pieces.count, pieces[close].isSymbol("]") else { return index }
      index = skipLikeSpace(pieces, close + 1)
    }
    return index
  }

  /// Index after the `)` that balances the `(` at `open`.
  private nonisolated static func skipLikeBalanced(_ pieces: [LikeLexeme], from open: Int) -> Int {
    var depth = 0
    var index = open
    while index < pieces.count {
      if pieces[index].isSymbol("(") {
        depth += 1
      } else if pieces[index].isSymbol(")") {
        depth -= 1
        if depth == 0 { return index + 1 }
      }
      index += 1
    }
    return index
  }

  /// Index of the `)` that closes the current `CAST(`, ignoring typmod parentheses.
  private nonisolated static func skipLikeUntilParen(
    _ pieces: [LikeLexeme], from start: Int
  )
    -> Int
  {
    var depth = 0
    var index = start
    while index < pieces.count {
      if pieces[index].isSymbol("(") {
        depth += 1
      } else if pieces[index].isSymbol(")"), depth == 0 {
        return index
      } else if pieces[index].isSymbol(")") {
        depth -= 1
      }
      index += 1
    }
    return index
  }

  private nonisolated static func skipLikeSpace(_ pieces: [LikeLexeme], _ index: Int) -> Int {
    var index = index
    while index < pieces.count {
      if case .space = pieces[index] {
        index += 1
        continue
      }
      return index
    }
    return index
  }

  /// 2 for adjacent `|` `|`, 1 for a single `||` symbol, 0 when this is not concatenation.
  private nonisolated static func concatWidth(_ pieces: [LikeLexeme], at index: Int) -> Int {
    if pieces[index].isSymbol("||") { return 1 }
    guard pieces[index].isSymbol("|"), index + 1 < pieces.count, pieces[index + 1].isSymbol("|")
    else { return 0 }
    return 2
  }

  private nonisolated static func bindName(_ pieces: [LikeLexeme], at index: Int) -> String? {
    guard index + 1 < pieces.count, case .word(let name) = pieces[index + 1] else { return nil }
    guard index == 0 || !blocksBind(pieces[index - 1]) else { return nil }
    return name
  }

  /// A `:name` glued to a word, number, `:`, `)`, or `]` is not a placeholder.
  private nonisolated static func blocksBind(_ piece: LikeLexeme) -> Bool {
    switch piece {
    case .word(_), .number, .other: true
    case .symbol(let symbol): symbol == ":" || symbol == ")" || symbol == "]"
    case .literal, .space: false
    }
  }

  private nonisolated static func isPercentOnly(_ value: SQLBindValue?) -> Bool {
    guard case .text(let text) = value else { return false }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "%" }
  }

  /// First non-empty line of the statement after any leading comments, truncated to 80
  /// characters.
  private nonisolated static func preview(_ text: String) -> String {
    let line =
      withoutLeadingComments(text).split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
    return previewLine(line)
  }

  /// First 79 characters plus an ellipsis. A later `%` inside a LIKE operand is appended
  /// after that prefix. The head is not shortened, and a `%` in a comment or elsewhere is not.
  private nonisolated static func previewLine(_ line: String) -> String {
    let limit = 80
    guard line.count > limit else { return line }
    let head = String(line.prefix(limit - 1)) + "…"
    guard let mark = likeOperandPercent(in: line, past: limit - 1) else { return head }
    let tailBudget = 24
    let tailStart =
      line.index(mark, offsetBy: -8, limitedBy: line.startIndex) ?? line.startIndex
    let cut = line.index(line.startIndex, offsetBy: limit - 1)
    let start = max(tailStart, cut)
    let tail = String(line[start...].prefix(tailBudget))
    guard tail.contains("%") else { return head }
    return head + tail
  }

  /// Scalar index of the last `%` at or past `cut` that sits in a LIKE, ILIKE, `~~`, or `~~*`
  /// operand. Comments and any `%` outside that operand are ignored.
  private nonisolated static func likeOperandPercent(
    in line: String, past cut: Int
  ) -> String.Index? {
    let scalars = Array(line.unicodeScalars)
    var offset = 0
    var depth = 0
    var operand = false
    var sawTilde = false
    var last: Int?
    while offset < scalars.count {
      let lexeme = SQLTokenizer.lexeme(in: scalars, at: offset)
      let raw = SQLTokenizer.text(scalars, lexeme.range)
      switch lexeme.kind {
      case .whitespace, .comment:
        break
      case .word:
        sawTilde = false
        let word = SQLTokenizer.asciiUppercased(raw)
        if !operand, depth == 0, word == "LIKE" || word == "ILIKE" {
          operand = true
        } else if operand, depth == 0, endsLikeOperand(word) {
          operand = false
        }
      case .symbol:
        if raw == "~", depth == 0 {
          if sawTilde {
            operand = true
            sawTilde = false
          } else {
            sawTilde = true
          }
          break
        }
        sawTilde = false
        if raw == "(" {
          depth += 1
        } else if raw == ")" {
          depth = max(0, depth - 1)
        } else if operand, depth == 0, raw == "," || raw == ";" {
          operand = false
        } else if operand, raw == "%", lexeme.range.lowerBound >= cut {
          last = lexeme.range.lowerBound
        }
      default:
        sawTilde = false
        guard operand else { break }
        var index = lexeme.range.lowerBound
        while index < lexeme.range.upperBound {
          if scalars[index] == "%", index >= cut { last = index }
          index += 1
        }
      }
      offset = lexeme.range.upperBound
    }
    guard let last else { return nil }
    return line.unicodeScalars.index(line.unicodeScalars.startIndex, offsetBy: last)
  }

  /// A word that ends a LIKE operand when it appears outside parentheses.
  private nonisolated static func endsLikeOperand(_ word: String) -> Bool {
    switch word {
    case "AND", "OR", "LIMIT", "OFFSET", "FETCH", "RETURNING", "ORDER", "GROUP", "HAVING",
      "UNION", "EXCEPT", "INTERSECT", "WINDOW", "FOR":
      return true
    default:
      return false
    }
  }

  /// `text` from its first token on (leading whitespace, `--` and `/* */` comments dropped);
  /// `text` unchanged if it holds only comments.
  private nonisolated static func withoutLeadingComments(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var offset = 0
    while offset < scalars.count {
      let lexeme = SQLTokenizer.lexeme(in: scalars, at: offset)
      switch lexeme.kind {
      case .whitespace, .comment: offset = lexeme.range.upperBound
      default: return SQLTokenizer.text(scalars, offset..<scalars.count)
      }
    }
    return text
  }

  // MARK: - Dialog text

  /// Maximum number of statements listed in a confirmation dialog message
  nonisolated static let confirmationListLimit = 8

  /// Plain-text statement list for the Safe Mode dialog message, capped at `limit` statements.
  nonisolated static func confirmationSummary(
    _ statements: [StatementConfirmation], limit: Int = confirmationListLimit
  ) -> String {
    cappedList(statements.map { summaryLine($0, prefix: "") }, limit: limit)
  }

  /// Plain-text list of the Run All cells that need confirmation, capped at `limit` statements.
  nonisolated static func runAllSummary(
    _ cells: [RunAllCell], limit: Int = confirmationListLimit
  ) -> String {
    let lines = cells.flatMap { cell in
      cell.statements.map { summaryLine($0, prefix: "Cell \(cell.number), ") }
    }
    return cappedList(lines, limit: limit)
  }

  private nonisolated static func summaryLine(
    _ statement: StatementConfirmation, prefix: String
  ) -> String {
    let note = statement.parameterNote.map { "\n   \($0)" } ?? ""
    let reasons = statement.reasons.map { "\n   ! \($0)" }.joined()
    return "\(prefix)\(statement.index + 1). \(statement.preview)\(note)\(reasons)"
  }

  private nonisolated static func cappedList(_ lines: [String], limit: Int) -> String {
    guard lines.count > limit else { return lines.joined(separator: "\n") }
    return (lines.prefix(limit) + ["…and \(lines.count - limit) more"]).joined(separator: "\n")
  }
}
