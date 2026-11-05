// CopyObjectsDDLCheck.swift
// Copy Objects: the check of the DDL the user edited in the preview, before anything runs. A
// security boundary: the copy runs these statements on the target (on MySQL / MariaDB it then
// drops the tables it created if it fails), so they may only build the planned tables.
//
// The text is split with `SQLTokenizer.splitStatements` and each statement lexed with the
// target's tokenizer. Allowed, on planned tables only (a bare name or one qualified with the
// target schema):
// - CREATE TABLE <planned table> ( ... ), exactly once per planned table, nothing after the
//   closing parenthesis, with the planned column names in the planned order (types, constraints
//   and CHECK text inside the parentheses may change);
// - CREATE [UNIQUE] INDEX [name] ON <planned table> [USING method] ( keys ), then nothing,
//   WHERE <predicate> or (MySQL) USING method;
// - ALTER TABLE <planned table> ADD [CONSTRAINT name] FOREIGN KEY | UNIQUE | CHECK | PRIMARY KEY
//   ..., one action (PostgreSQL and MySQL);
// - PRAGMA defer_foreign_keys = ON (SQLite).
// Every REFERENCES must name a planned table. CHECK expressions, index keys and predicates, the
// keys of inline constraints and what a column puts in parentheses (a DEFAULT or generated
// expression) pass `expressionRefusal`: the target evaluates them on every copied row, so they
// may call only a few side-effect-free built-ins, with no subquery and no `.` outside a number.
// At a column's or constraint's own level a parenthesis opens a type's numbers (MySQL: ENUM / SET
// strings), a key list or one of those expressions, or calls one of those built-ins (a column
// also a clock: NOW, CURRENT_TIMESTAMP); a DEFAULT runs on every later INSERT. Identity options
// are numbers and option words, so an identity cannot name its sequence. Anything
// else refuses the copy with the statement: other statement kinds, other tables, three-part
// names, comments (MySQL executable comments included), a `;` left inside a statement (a
// DELIMITER or trigger body), dollar quotes, strings with a backslash (where a PostgreSQL or
// MySQL string ends depends on a server setting) and unterminated quotes. Names compare scalar
// for scalar, unquoted PostgreSQL names folded to lowercase: a name that merely looks the same is
// another table.
//
// The identity restart is not part of this text: it is a run-only postlude built from the plan
// (`CopyObjectsPlan.identityRestartStatements`).

import Foundation

nonisolated enum CopyObjectsDDLCheck {
  struct Refusal: Error, Equatable, LocalizedError {
    /// The offending statement. Nil when a planned table has no CREATE TABLE.
    var statement: String?
    var reason: String

    var errorDescription: String? { reason }
  }

  /// The checked statements, as the user wrote them, in run order within each group
  struct Checked: Sendable, Equatable {
    struct Statement: Sendable, Equatable {
      var sql: String
      /// The planned table a CREATE TABLE creates (what MySQL records as created); nil for the
      /// PRAGMA
      var createsTable: String?
    }

    /// PRAGMA and CREATE TABLE: before the rows
    var prelude: [Statement]
    /// CREATE INDEX and ALTER TABLE: after the rows
    var postRows: [String]
  }

  static func check(_ ddl: String, plan: CopyObjectsPlan) throws -> Checked {
    let dialect = plan.target.dialect
    var checked = Checked(prelude: [], postRows: [])
    var created: [String] = []
    for statement in SQLTokenizer(dialect: dialect).splitStatements(ddl) {
      let reader = try Reader(statement: statement, plan: plan)
      switch try reader.kind() {
      case .pragma:
        checked.prelude.append(.init(sql: statement, createsTable: nil))
      case .createTable(let table):
        guard !created.contains(where: { same($0, table) }) else {
          throw Refusal(statement: statement, reason: "\"\(table)\" is created twice.")
        }
        created.append(table)
        checked.prelude.append(.init(sql: statement, createsTable: table))
      case .createIndex, .alterTable:
        checked.postRows.append(statement)
      }
    }
    if let missing = plan.tables.first(where: { table in
      !created.contains { same($0, table.name) }
    }) {
      throw Refusal(
        statement: nil, reason: "The DDL has no CREATE TABLE for \"\(missing.name)\".")
    }
    return checked
  }

  /// Scalar-for-scalar equality: Swift `==` treats canonically equivalent names as equal, the
  /// servers do not
  static func same(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.elementsEqual(b.unicodeScalars)
  }

  // MARK: - Expressions

  /// The functions a copied CHECK or index expression may call: side-effect free and
  /// deterministic. JSON_VALID is MariaDB's check on a JSON column, TYPEOF SQLite's type check.
  static let safeFunctions: Set<String> = [
    "LOWER", "UPPER", "LENGTH", "CHAR_LENGTH", "CHARACTER_LENGTH", "OCTET_LENGTH", "COALESCE",
    "NULLIF", "ABS", "ROUND", "TRIM", "BTRIM", "LTRIM", "RTRIM", "SUBSTR", "SUBSTRING", "CAST",
    "JSON_VALID", "TYPEOF",
  ]

  /// Keywords a parenthesis may follow in an expression
  private static let expressionKeywords: Set<String> = [
    "AND", "OR", "NOT", "IN", "IS", "BETWEEN", "ANY", "ALL", "SOME", "ARRAY", "CASE", "WHEN",
    "THEN", "ELSE", "CHECK",
  ]

  /// Type names a group of numbers may follow (`numeric(10,2)`, `character varying(80)`)
  private static let typeNames: Set<String> = [
    "CHAR", "CHARACTER", "VARCHAR", "VARYING", "NCHAR", "NUMERIC", "DECIMAL", "DEC", "FLOAT",
    "BIT", "TIME", "TIMESTAMP", "DATETIME", "BINARY", "VARBINARY",
  ]

  /// The words a column definition's own parenthesis may follow after its type
  private static let columnGroupWords: Set<String> = ["DEFAULT", "CHECK", "AS", "IDENTITY"]

  /// The words a table constraint's own parenthesis may follow
  private static let constraintGroupWords: Set<String> = [
    "KEY", "UNIQUE", "INDEX", "FULLTEXT", "SPATIAL", "CHECK",
  ]

  /// The words that end a column's type and start its clauses
  private static let columnClauseWords: Set<String> = [
    "CONSTRAINT", "NOT", "NULL", "DEFAULT", "PRIMARY", "UNIQUE", "KEY", "CHECK", "REFERENCES",
    "GENERATED", "AS", "COLLATE", "AUTO_INCREMENT", "AUTOINCREMENT", "COMMENT", "ON", "IDENTITY",
    "VISIBLE", "INVISIBLE",
  ]

  /// The clock built-ins a column's DEFAULT or ON UPDATE may call, with at most a precision
  private static let clockFunctions: Set<String> = [
    "NOW", "CURRENT_TIMESTAMP", "LOCALTIMESTAMP", "CURRENT_TIME",
  ]

  /// The words of PostgreSQL identity options
  private static let identityOptionWords: Set<String> = [
    "START", "RESTART", "WITH", "INCREMENT", "BY", "MINVALUE", "MAXVALUE", "NO", "CACHE", "CYCLE",
  ]

  /// Keywords that start or join a subquery
  private static let subqueryWords: Set<String> = [
    "SELECT", "WITH", "UNION", "INTERSECT", "EXCEPT", "EXISTS", "VALUES", "INTO", "LATERAL",
    "TABLE",
  ]

  /// Sequence calls with no `word (`: MariaDB `NEXT VALUE FOR s` / `PREVIOUS VALUE FOR s`, and
  /// the sequence words of Oracle mode (`s.nextval`); each would advance or read a target sequence
  private static let sequenceWords: Set<String> = ["NEXTVAL", "LASTVAL", "SETVAL", "CURRVAL"]

  /// Why `token` (with `previous`) is a sequence call, or nil
  private static func sequenceRefusal(_ token: SQLToken, after previous: SQLToken?) -> String? {
    let upper = { (token: SQLToken?) in token?.keyword.map(SQLTokenizer.asciiUppercased) }
    if let word = upper(token), sequenceWords.contains(word) {
      return "a sequence call (\(word))"
    }
    if upper(token) == "FOR", upper(previous) == "VALUE" {
      return "a sequence call (VALUE FOR)"
    }
    return nil
  }

  /// Why the expression `text` (a CHECK or an index key from the source catalog) cannot be
  /// copied, or nil when it can (see the slice form). A MySQL string with a backslash is refused
  /// as the DDL check refuses it.
  static func expressionRefusal(_ text: String, dialect: SQLDialect) -> String? {
    let tokens = SQLTokenizer(dialect: dialect).tokens(text)
    if dialect == .mysql,
      tokens.contains(where: { $0.kind == .string && $0.text.unicodeScalars.contains("\\") })
    {
      return "a string with a backslash"
    }
    return expressionRefusal(tokens[...])
  }

  /// Why the expression `tokens` cannot be copied, or nil when it can: a call to a function that
  /// is not in `safeFunctions` (a quoted or qualified name included), a subquery keyword, a
  /// table after IN (SQLite), a string with a backslash or an executable comment. A `.` may only
  /// sit inside a number: PostgreSQL reads `(x).f` and `x.f` as the call `f(x)`, and a column
  /// in these expressions is never qualified. A type name may take a group of numbers.
  /// Tokens shallower than `minDepth` are not looked at. `prefixLengthDepth`: on MySQL index
  /// keys, a name with one number in parentheses at that depth is a column prefix length.
  static func expressionRefusal(
    _ tokens: ArraySlice<SQLToken>, minDepth: Int = 0, prefixLengthDepth: Int? = nil
  ) -> String? {
    let isNumber = { (token: SQLToken) in
      token.kind == .word && !token.text.isEmpty
        && token.text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }
    // A string is a name under MySQL ANSI_QUOTES
    let isName = { (token: SQLToken) in
      (token.kind == .word && !isNumber(token)) || token.kind == .quotedIdentifier
        || token.kind == .string
    }
    for index in tokens.indices where tokens[index].depth >= minDepth {
      let token = tokens[index]
      switch token.kind {
      case .backslashString: return "a string with a backslash"
      case .executableComment: return "an executable comment"
      default: break
      }
      if let word = token.keyword, subqueryWords.contains(word) {
        return "a subquery (\(word))"
      }
      let previous = index > tokens.startIndex ? tokens[index - 1] : nil
      let next = index + 1 < tokens.endIndex ? tokens[index + 1] : nil
      if let reason = sequenceRefusal(token, after: previous) { return reason }
      if token.isSymbol(".") {
        if let previous, previous.isSymbol(")") || previous.isSymbol("]") {
          return "a function called on a value (a . after a parenthesis)"
        }
        // 1.5, .5 and 5. touch a number and no name
        let inNumber =
          ((previous.map(isNumber) ?? false) || (next.map(isNumber) ?? false))
          && !(previous.map(isName) ?? false) && !(next.map(isName) ?? false)
        guard inNumber else { return "a qualified name" }
        continue
      }
      // SQLite: `x IN t` reads the table t
      if token.keyword == "IN", let next, !next.isSymbol("(") {
        return "a table after IN"
      }
      let open = index + 1
      guard open < tokens.endIndex, tokens[open].isSymbol("(") else { continue }
      let inner = group(tokens, opening: open)
      if token.depth == prefixLengthDepth, token.kind == .word || token.kind == .quotedIdentifier,
        inner.count == 1, inner.allSatisfy(isNumber)
      {
        continue
      }
      let name = SQLTokenizer.asciiLowercased(token.text)
      // A string before `(` is a quoted name under MySQL ANSI_QUOTES
      switch token.kind {
      case .word, .quotedIdentifier, .string: break
      default: continue
      }
      let qualified = index > tokens.startIndex && tokens[index - 1].isSymbol(".")
      guard token.kind == .word, !qualified, let word = token.keyword else {
        return "a call to \(name)"
      }
      if safeFunctions.contains(word) || expressionKeywords.contains(word) { continue }
      if typeNames.contains(word), inner.allSatisfy({ isNumber($0) || $0.isSymbol(",") }) {
        continue
      }
      return "a call to \(name)"
    }
    return nil
  }

  /// The tokens inside the group whose `(` is at `opening`
  private static func group(_ tokens: ArraySlice<SQLToken>, opening: Int) -> ArraySlice<SQLToken> {
    let depth = tokens[opening].depth
    let close =
      tokens[(opening + 1)...].firstIndex { $0.depth == depth && $0.isSymbol(")") }
      ?? tokens.endIndex
    return tokens[(opening + 1)..<close]
  }

  // MARK: - Statements

  private enum Kind {
    case pragma
    case createTable(String)
    case createIndex
    case alterTable
  }

  private struct Token {
    enum Kind { case word, identifier, string, number, symbol }

    var kind: Kind
    /// Word: as written; identifier and string: content
    var text: String
    /// Parenthesis depth, as `SQLTokenizer.tokens` counts it
    var depth: Int

    func isKeyword(_ keyword: String) -> Bool {
      kind == .word && text.unicodeScalars.allSatisfy(\.isASCII)
        && SQLTokenizer.asciiUppercased(text) == keyword
    }

    func isSymbol(_ symbol: String) -> Bool { kind == .symbol && text == symbol }

    /// As `SQLTokenizer.tokens` writes it, for `expressionRefusal`
    var sqlToken: SQLToken {
      switch kind {
      case .word, .number:
        SQLToken(kind: .word, text: SQLTokenizer.asciiUppercased(text), depth: depth)
      case .identifier: SQLToken(kind: .quotedIdentifier, text: text, depth: depth)
      case .string: SQLToken(kind: .string, text: text, depth: depth)
      case .symbol: SQLToken(kind: .symbol, text: text, depth: depth)
      }
    }
  }

  private struct Reader {
    let statement: String
    let plan: CopyObjectsPlan
    let dialect: SQLDialect
    let tokens: [Token]
    /// `tokens` in `SQLTokenizer.tokens` form, index for index
    let expression: [SQLToken]

    init(statement: String, plan: CopyObjectsPlan) throws {
      self.statement = statement
      self.plan = plan
      dialect = plan.target.dialect
      tokens = try Self.lex(statement, dialect: dialect)
      expression = tokens.map(\.sqlToken)
    }

    private static func lex(_ statement: String, dialect: SQLDialect) throws -> [Token] {
      func refuse(_ reason: String) -> Refusal { Refusal(statement: statement, reason: reason) }
      // The trailing newline shows an unterminated quote: it swallows it
      let scalars = Array((statement + "\n").unicodeScalars)
      let tokenizer = SQLTokenizer(dialect: dialect)
      var tokens: [Token] = []
      var depth = 0
      var i = 0
      while i < scalars.count {
        let lexeme = tokenizer.lexeme(in: scalars, at: i)
        let raw = SQLTokenizer.text(scalars, lexeme.range)
        switch lexeme.kind {
        case .whitespace:
          break
        case .comment, .executableComment:
          throw refuse("Comments are not allowed in the copy's DDL.")
        case .dollarString:
          throw refuse("Dollar-quoted strings are not allowed in the copy's DDL.")
        case .word:
          tokens.append(Token(kind: .word, text: raw, depth: depth))
        case .number:
          tokens.append(Token(kind: .number, text: raw, depth: depth))
        case .quoted(let kind, let content):
          guard lexeme.range.upperBound < scalars.count else {
            throw refuse("The statement has an unterminated quote.")
          }
          switch kind {
          case .quotedIdentifier:
            tokens.append(Token(kind: .identifier, text: content, depth: depth))
          case .string:
            // MySQL: where it ends depends on sql_mode NO_BACKSLASH_ESCAPES
            guard dialect != .mysql || !content.unicodeScalars.contains("\\") else {
              throw refuse("Strings with a backslash are not allowed in the copy's DDL.")
            }
            tokens.append(Token(kind: .string, text: content, depth: depth))
          default:
            throw refuse("Strings with a backslash are not allowed in the copy's DDL.")
          }
        case .symbol:
          switch scalars[i] {
          case ";":
            throw refuse("Each statement must be one statement.")
          case "(":
            tokens.append(Token(kind: .symbol, text: raw, depth: depth))
            depth += 1
          case ")":
            depth -= 1
            guard depth >= 0 else { throw refuse("The statement has unbalanced parentheses.") }
            tokens.append(Token(kind: .symbol, text: raw, depth: depth))
          default:
            tokens.append(Token(kind: .symbol, text: raw, depth: depth))
          }
        }
        i = lexeme.range.upperBound
      }
      guard depth == 0 else { throw refuse("The statement has unbalanced parentheses.") }
      return tokens
    }

    func refusal(_ reason: String) -> Refusal { Refusal(statement: statement, reason: reason) }

    private func token(_ index: Int) -> Token? {
      tokens.indices.contains(index) ? tokens[index] : nil
    }

    func kind() throws -> Kind {
      try checkReferences()
      let first = token(0)
      let second = token(1)
      if first?.isKeyword("CREATE") == true, second?.isKeyword("TABLE") == true {
        return .createTable(try createTable())
      }
      if first?.isKeyword("CREATE") == true,
        second?.isKeyword("INDEX") == true || second?.isKeyword("UNIQUE") == true
      {
        try createIndex()
        return .createIndex
      }
      if first?.isKeyword("ALTER") == true, second?.isKeyword("TABLE") == true,
        dialect != .sqlite
      {
        try alterTable()
        return .alterTable
      }
      if first?.isKeyword("PRAGMA") == true, dialect == .sqlite {
        try pragma()
        return .pragma
      }
      throw refusal(
        "Only CREATE TABLE, CREATE INDEX, ALTER TABLE ... ADD CONSTRAINT"
          + (dialect == .sqlite ? " and PRAGMA defer_foreign_keys" : "")
          + " on the copied tables can run.")
    }

    // MARK: Kinds

    /// `CREATE TABLE <planned> ( <planned columns and constraints> )`; returns the table
    private func createTable() throws -> String {
      var i = 2
      let table = try plannedTable(at: &i)
      guard let open = token(i), open.isSymbol("("), let close = tokens.last,
        close.isSymbol(")"), tokens.dropFirst(i + 1).dropLast().allSatisfy({ $0.depth > 0 })
      else {
        throw refusal("A CREATE TABLE must end with its column list.")
      }
      let constraintWords: Set<String> = [
        "CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN", "KEY", "INDEX", "FULLTEXT",
        "SPATIAL", "EXCLUDE",
      ]
      // The items between the depth-1 commas
      var items: [Range<Int>] = []
      let end = tokens.count - 1
      var start = i + 1
      for index in start..<end where tokens[index].depth == 1 && tokens[index].isSymbol(",") {
        items.append(start..<index)
        start = index + 1
      }
      if start < end || !items.isEmpty { items.append(start..<end) }
      var columns: [String] = []
      for item in items {
        guard let first = item.first else { throw refusal("The column list has an empty item.") }
        if constraintWords.contains(where: tokens[first].isKeyword) {
          try checkGroups(item, depth: 1, isColumn: false)
          continue
        }
        // `LIKE other` copies another table's columns
        guard !tokens[first].isKeyword("LIKE") else {
          throw refusal("The column list may not copy another table with LIKE.")
        }
        guard let name = identifier(tokens[first]) else {
          throw refusal("Each item of the column list must be a column or a constraint.")
        }
        columns.append(name)
        try checkColumn(item)
      }
      try checkCheckClauses()
      let planned = plan.tables.first { CopyObjectsDDLCheck.same($0.name, table) }
      let names = planned?.columns.map(\.name) ?? []
      guard columns.count == names.count, zip(columns, names).allSatisfy(CopyObjectsDDLCheck.same)
      else {
        throw refusal(
          "\"\(table)\" must keep its columns: "
            + names.map { "\"\($0)\"" }.joined(separator: ", ") + ", in that order.")
      }
      return table
    }

    /// `CREATE [UNIQUE] INDEX [name] ON <planned> ...`
    private func createIndex() throws {
      var i = token(1)?.isKeyword("UNIQUE") == true ? 2 : 1
      guard token(i)?.isKeyword("INDEX") == true else {
        throw refusal("Only CREATE [UNIQUE] INDEX can create an index.")
      }
      i += 1
      if token(i)?.isKeyword("ON") != true {
        let reserved = ["IF", "CONCURRENTLY", "ONLY", "ON"]
        guard let name = token(i), !reserved.contains(where: name.isKeyword),
          let qualified = qualifiedName(at: &i),
          qualified.schema.map({ CopyObjectsDDLCheck.same($0, plan.targetSchema) }) ?? true
        else {
          throw refusal("The index needs a plain name in the target schema.")
        }
      }
      guard token(i)?.isKeyword("ON") == true else {
        throw refusal("The index must be ON a copied table.")
      }
      i += 1
      _ = try plannedTable(at: &i)
      if token(i)?.isKeyword("USING") == true, dialect == .postgresql {
        guard token(i + 1)?.kind == .word else { throw refusal("USING needs an index method.") }
        i += 2
      }
      guard let open = token(i), open.isSymbol("("),
        let close = tokens[(i + 1)...].firstIndex(where: {
          $0.depth == open.depth && $0.isSymbol(")")
        })
      else {
        throw refusal("The index must list its keys after the table.")
      }
      try checkExpression(expression[(i + 1)..<close], keyDepth: 1)
      let rest = (close + 1)..<tokens.count
      if rest.isEmpty { return }
      if tokens[rest.lowerBound].isKeyword("WHERE"), rest.count > 1 {
        try checkExpression(expression[(rest.lowerBound + 1)...])
        return
      }
      guard dialect == .mysql, rest.count == 2, tokens[rest.lowerBound].isKeyword("USING"),
        tokens[rest.lowerBound + 1].kind == .word
      else {
        throw refusal("After its keys the index may only have a WHERE predicate.")
      }
    }

    /// `ALTER TABLE <planned> ADD [CONSTRAINT name] FOREIGN KEY | UNIQUE | CHECK | PRIMARY KEY`
    /// with one action
    private func alterTable() throws {
      var i = 2
      _ = try plannedTable(at: &i)
      guard token(i)?.isKeyword("ADD") == true else {
        throw refusal("ALTER TABLE may only ADD a constraint.")
      }
      i += 1
      if token(i)?.isKeyword("CONSTRAINT") == true {
        guard let name = token(i + 1), identifier(name) != nil else {
          throw refusal("ADD CONSTRAINT needs a name.")
        }
        i += 2
      }
      let kinds = ["FOREIGN", "UNIQUE", "CHECK", "PRIMARY"]
      guard let kind = token(i), kinds.contains(where: kind.isKeyword) else {
        throw refusal("ALTER TABLE may only ADD a constraint.")
      }
      guard !tokens.contains(where: { $0.depth == 0 && $0.isSymbol(",") }) else {
        throw refusal("ALTER TABLE may add one constraint per statement.")
      }
      // PostgreSQL: USING INDEX takes over an existing index
      for index in i..<(tokens.count - 1) where tokens[index].depth == 0 {
        if tokens[index].isKeyword("USING"), tokens[index + 1].isKeyword("INDEX") {
          throw refusal("ALTER TABLE ADD may not use an existing index.")
        }
      }
      try checkGroups(i..<tokens.count, depth: 0, isColumn: false)
    }

    // MARK: Expressions

    /// `tokens` pass `expressionRefusal`; on MySQL a column at `keyDepth` may take a prefix
    /// length
    private func checkExpression(
      _ tokens: ArraySlice<SQLToken>, minDepth: Int = 0, keyDepth: Int? = nil
    ) throws {
      if let reason = CopyObjectsDDLCheck.expressionRefusal(
        tokens, minDepth: minDepth, prefixLengthDepth: dialect == .mysql ? keyDepth : nil)
      {
        throw refusal(
          "CHECK and index expressions may only use simple built-in functions, with no "
            + "subquery; this one has \(reason).")
      }
    }

    /// A column item of CREATE TABLE: its own parentheses pass `checkGroups`, no `.` follows a
    /// parenthesis or bracket (`('1'::float8).pg_sleep`) and the identity names no sequence
    private func checkColumn(_ item: Range<Int>) throws {
      try checkGroups(item, depth: 1, isColumn: true)
      for index in item.dropFirst() {
        let previous = tokens[index - 1]
        // At any depth: a DEFAULT runs on every later INSERT
        if let reason = CopyObjectsDDLCheck.sequenceRefusal(
          tokens[index].sqlToken, after: previous.sqlToken)
        {
          throw refusal("A column's expressions may not contain \(reason).")
        }
        if tokens[index].isSymbol("."), previous.isSymbol(")") || previous.isSymbol("]") {
          throw refusal(
            "A column's expressions may not call a function on a value (a . after a "
              + "parenthesis).")
        }
        if tokens[index].depth >= 2, tokens[index].isKeyword("NAME"),
          previous.isKeyword("SEQUENCE")
        {
          throw refusal("An identity column may not name its sequence.")
        }
      }
    }

    /// Each `(` at `depth`, the item's own depth (1 in CREATE TABLE, 0 in ALTER TABLE ADD), opens
    /// a group: a call there would run unseen, and a DEFAULT runs on every later INSERT. It may
    /// follow the planned table after REFERENCES, a symbol (a parenthesized expression) or a word
    /// that is not qualified. In a column: a word of the type with only numbers (MySQL: ENUM / SET
    /// with only strings), DEFAULT, CHECK, AS, IDENTITY, a `safeFunctions` call or a clock
    /// built-in with at most a precision. In a constraint: KEY, UNIQUE, INDEX, FULLTEXT, SPATIAL,
    /// CHECK or an index name after KEY, INDEX or UNIQUE. Each group's contents pass
    /// `expressionRefusal`, identity options their own list.
    private func checkGroups(_ range: Range<Int>, depth: Int, isColumn: Bool) throws {
      var referenced: Set<Int> = []
      for index in range where tokens[index].depth == depth && tokens[index].isKeyword("REFERENCES")
      {
        var i = index + 1
        _ = try plannedTable(at: &i)
        if token(i)?.isSymbol("(") == true { referenced.insert(i) }
      }
      let groupWords =
        isColumn ? CopyObjectsDDLCheck.columnGroupWords : CopyObjectsDDLCheck.constraintGroupWords
      // A column's type runs from after its name to its first clause word
      var inType = isColumn
      for index in range where tokens[index].depth == depth {
        let owner = tokens[index]
        if inType, index > range.lowerBound,
          CopyObjectsDDLCheck.columnClauseWords.contains(where: owner.isKeyword)
        {
          inType = false
        }
        guard owner.isSymbol("(") else { continue }
        let close =
          tokens[(index + 1)...].firstIndex { $0.depth == depth && $0.isSymbol(")") }
          ?? tokens.count
        let inner = (index + 1)..<close
        let named = index > range.lowerBound ? tokens[index - 1] : nil
        if let named, named.kind != .symbol || named.isSymbol("."), !referenced.contains(index) {
          let qualified = index - 2 >= range.lowerBound && tokens[index - 2].isSymbol(".")
          guard named.kind != .symbol, !qualified,
            groupAllowed(
              named, at: index - 1, inner: inner, range: range, words: groupWords,
              isColumn: isColumn, inType: inType)
          else {
            throw refusal(
              "A column or constraint may only call simple built-in functions, unqualified; "
                + "this one calls \(named.text).")
          }
        }
        if isColumn, named?.isKeyword("IDENTITY") == true {
          try checkIdentityOptions(inner)
          continue
        }
        // A CHECK has no key, so no prefix length
        let isKey = !isColumn && named?.isKeyword("CHECK") != true
        try checkExpression(expression[inner], keyDepth: isKey ? depth + 1 : nil)
      }
    }

    /// Whether the word or name `named` (at `at`) may own the group `inner` (see `checkGroups`)
    private func groupAllowed(
      _ named: Token, at: Int, inner: Range<Int>, range: Range<Int>, words: Set<String>,
      isColumn: Bool, inType: Bool
    ) -> Bool {
      let numbers = inner.allSatisfy {
        tokens[$0].kind == .number || [",", "+", "-"].contains(where: tokens[$0].isSymbol)
      }
      guard named.kind == .word else {
        // An index name: KEY `k` (...)
        return !isColumn && named.kind == .identifier && at > range.lowerBound
          && ["KEY", "INDEX", "UNIQUE"].contains(where: tokens[at - 1].isKeyword)
      }
      if words.contains(where: named.isKeyword) { return true }
      if isColumn {
        if inType, at > range.lowerBound {
          if numbers { return true }
          let strings = inner.allSatisfy { tokens[$0].kind == .string || tokens[$0].isSymbol(",") }
          if dialect == .mysql, strings, ["ENUM", "SET"].contains(where: named.isKeyword) {
            return true
          }
        }
        if numbers, dialect == .postgresql, isCastType(at, range: range) { return true }
        if CopyObjectsDDLCheck.safeFunctions.contains(where: named.isKeyword) { return true }
        let precision = inner.allSatisfy { tokens[$0].kind == .number }
        return precision && CopyObjectsDDLCheck.clockFunctions.contains(where: named.isKeyword)
      }
      // MySQL: KEY k (...)
      return at > range.lowerBound && ["KEY", "INDEX"].contains(where: tokens[at - 1].isKeyword)
    }

    /// Whether the word at `at` ends the type of a PostgreSQL cast (`'1'::numeric(10,2)`,
    /// `'x'::character varying(5)`): `::` right before it or before one more word
    private func isCastType(_ at: Int, range: Range<Int>) -> Bool {
      let isCast = { (start: Int) in
        start - 2 > range.lowerBound && self.tokens[start - 1].isSymbol(":")
          && self.tokens[start - 2].isSymbol(":")
      }
      return isCast(at) || (tokens[at - 1].kind == .word && isCast(at - 1))
    }

    /// PostgreSQL identity options: numbers and the option words only
    private func checkIdentityOptions(_ inner: Range<Int>) throws {
      for index in inner {
        let token = tokens[index]
        guard
          token.kind == .number || token.isSymbol("-") || token.isSymbol("+")
            || CopyObjectsDDLCheck.identityOptionWords.contains(where: token.isKeyword)
        else {
          throw refusal(
            "Identity options may only be START, RESTART, INCREMENT, MINVALUE, MAXVALUE, CACHE "
              + "and CYCLE with numbers.")
        }
      }
    }

    /// Every `CHECK ( ... )` of the statement passes `expressionRefusal`
    private func checkCheckClauses() throws {
      for index in tokens.indices where tokens[index].isKeyword("CHECK") {
        guard let open = token(index + 1), open.isSymbol("("),
          let close = tokens[(index + 2)...].firstIndex(where: {
            $0.depth == open.depth && $0.isSymbol(")")
          })
        else { throw refusal("CHECK needs its expression in parentheses.") }
        try checkExpression(expression[(index + 2)..<close])
      }
    }

    /// `PRAGMA defer_foreign_keys = ON`
    private func pragma() throws {
      guard tokens.count == 4, tokens[1].isKeyword("DEFER_FOREIGN_KEYS"), tokens[2].isSymbol("="),
        ["ON", "TRUE", "YES"].contains(where: tokens[3].isKeyword)
          || (tokens[3].kind == .number && tokens[3].text == "1")
      else {
        throw refusal("Only PRAGMA defer_foreign_keys = ON can run.")
      }
    }

    // MARK: Names

    /// Every `REFERENCES` names a planned table
    private func checkReferences() throws {
      for index in tokens.indices where tokens[index].isKeyword("REFERENCES") {
        var i = index + 1
        _ = try plannedTable(at: &i)
      }
    }

    /// A planned table name at `i` (bare or in the target schema); moves `i` past it
    private func plannedTable(at i: inout Int) throws -> String {
      guard let name = qualifiedName(at: &i),
        name.schema.map({ CopyObjectsDDLCheck.same($0, plan.targetSchema) }) ?? true,
        let table = plan.tables.first(where: { CopyObjectsDDLCheck.same($0.name, name.name) })
      else {
        throw refusal("Only the copied tables can be named.")
      }
      return table.name
    }

    /// `name` or `schema.name` at `i`; moves `i` past it
    private func qualifiedName(at i: inout Int) -> (schema: String?, name: String)? {
      guard let first = token(i).flatMap(identifier) else { return nil }
      i += 1
      guard token(i)?.isSymbol(".") == true else { return (nil, first) }
      // No three-part names
      guard let second = token(i + 1).flatMap(identifier), token(i + 2)?.isSymbol(".") != true
      else { return nil }
      i += 2
      return (first, second)
    }

    /// The name a token stands for: quoted as written, unquoted PostgreSQL folded to lowercase
    private func identifier(_ token: Token) -> String? {
      switch token.kind {
      case .identifier: return token.text
      case .word:
        return dialect == .postgresql ? SQLTokenizer.asciiLowercased(token.text) : token.text
      case .string, .number, .symbol: return nil
      }
    }
  }
}
