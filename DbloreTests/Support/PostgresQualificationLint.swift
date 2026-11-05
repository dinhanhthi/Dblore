// PostgresQualificationLint.swift
// Token-level check that a PostgreSQL statement names pg_catalog for every function, operator,
// cast type and catalog relation it uses, so nothing resolves through the user's search_path.
// Shared by the catalog read suite and the user data suite.

import Foundation

@testable import Dblore

/// Token-level rules for a PostgreSQL statement. Words are uppercased by `SQLTokenizer`; strings
/// and quoted identifiers are opaque, so a user name or a pattern never matches a rule.
enum PostgresQualificationLint {
  /// Grammar constructs and keywords that may precede `(` without being looked up by name
  private static let notFunctions: Set<String> = [
    "COALESCE", "GREATEST", "LEAST", "CASE", "EXISTS", "ANY", "ALL", "ARRAY", "CAST", "ROW",
    "EXTRACT", "POSITION", "SUBSTRING", "TRIM", "VALUES", "AND", "OR", "NOT", "WHERE", "SELECT",
    "THEN", "ELSE", "WHEN", "ON", "FROM", "JOIN", "LATERAL", "BY", "IS", "FILTER", "OVER",
    // A CTE head (`WITH name AS (`)
    "AS",
    // Flagged on their own (`wordViolations`)
    "IN", "USING",
  ]
  /// Symbols that are punctuation, not operators (`*` and `:` and `$` are checked apart)
  private static let punctuation: Set<String> = ["(", ")", ",", ".", "[", "]", ";"]
  /// Symbols of the comparisons a column of a denylisted extension type keeps bare
  private static let comparisonSymbols: Set<String> = ["=", "<", ">"]

  /// `allowsBoundNameLookup`: a bound name may resolve through search_path (`to_regclass($n)`,
  /// `$n::pg_catalog.regclass`), see `boundNameLookups`. `extensionTypedColumns`: column name →
  /// type text the builder was given; a bare comparison right after such a quoted column passes
  /// only when that type keeps the bare operator (`SQLOperandKind(columnType:)`).
  static func violations(
    _ sql: String, allowsBoundNameLookup: Bool = false,
    extensionTypedColumns: [String: String] = [:]
  ) -> [String] {
    let tokens = SQLTokenizer.tokens(sql, dialect: .postgresql)
    // `SET [LOCAL] name = value, ...` names a setting and takes literal values: nothing in it
    // is looked up as a function, operator or relation
    if tokens.first?.keyword == "SET" { return [] }
    var found: [String] = []
    func word(_ index: Int) -> String? {
      tokens.indices.contains(index) ? tokens[index].keyword : nil
    }
    func symbol(_ index: Int, _ text: String) -> Bool {
      tokens.indices.contains(index) && tokens[index].isSymbol(text)
    }
    func qualified(_ index: Int) -> Bool {
      symbol(index - 1, ".") && word(index - 2) == "PG_CATALOG"
    }
    let castTypes = castTypeStarts(tokens)
    let assignments = setAssignments(tokens)
    var i = 0
    while i < tokens.count {
      if castTypes.contains(i) {
        let type = castType(tokens, at: i)
        found += type.found
        i = type.end
        continue
      }
      let token = tokens[i]
      if token.kind == .symbol {
        switch token.text {
        case _ where punctuation.contains(token.text):
          break
        case "*" where (symbol(i - 1, "(") && symbol(i + 1, ")")) || word(i - 1) == "SELECT":
          break
        case "$" where word(i + 1).map { $0.allSatisfy(\.isNumber) } ?? false:
          break
        case ":" where symbol(i + 1, ":"):
          let type = castType(tokens, at: i + 2)
          found += type.found
          found += regclassViolations(tokens, at: i, allowsBoundNameLookup: allowsBoundNameLookup)
          i = type.end
          continue
        // A named bind (`:name`) is a parameter, not an operator
        case ":" where word(i + 1).map { !($0.first?.isNumber ?? true) } ?? false:
          i += 2
          continue
        default:
          var end = i + 1
          while end < tokens.count, tokens[end].kind == .symbol,
            !punctuation.contains(tokens[end].text), tokens[end].text != "$",
            tokens[end].text != ":"
          {
            end += 1
          }
          let run = tokens[i..<end]
          let bareAllowed =
            (assignments.contains(i) && run.count == 1)
            || i > 0 && tokens[i - 1].kind == .quotedIdentifier
              && run.allSatisfy { comparisonSymbols.contains($0.text) }
              && extensionTypedColumns[tokens[i - 1].text].map {
                SQLOperandKind(columnType: $0) == .bare
              } == true
          if !bareAllowed {
            let text = run.map(\.text).joined()
            found.append("operator \(text) outside OPERATOR(pg_catalog.…)")
          }
          i = end
          continue
        }
        i += 1
        continue
      }
      guard let text = token.keyword else {
        i += 1
        continue
      }
      if text == "OPERATOR", symbol(i + 1, "(") {
        var end = i + 2
        while end < tokens.count, !tokens[end].isSymbol(")") { end += 1 }
        let operatorSymbols = tokens[min(i + 4, end)..<end]
        if word(i + 2) != "PG_CATALOG" || !symbol(i + 3, ".") || operatorSymbols.isEmpty
          || operatorSymbols.contains(where: { $0.kind != .symbol })
        {
          found.append("OPERATOR(…) not in pg_catalog")
        }
        i = end + 1
        continue
      }
      found += wordViolations(text, at: i, word: word, symbol: symbol, qualified: qualified)
      if text == "TO_REGCLASS", !allowsBoundNameLookup {
        found.append("to_regclass resolves a name through search_path")
      }
      i += 1
    }
    return found
  }

  private static func wordViolations(
    _ text: String, at i: Int, word: (Int) -> String?, symbol: (Int, String) -> Bool,
    qualified: (Int) -> Bool
  ) -> [String] {
    var found: [String] = []
    switch text {
    case "PG_CATALOG" where !symbol(i + 1, "."):
      found.append("pg_catalog not followed by a name")
    case "NULLIF", "LIKE", "ILIKE", "SIMILAR", "BETWEEN", "NATURAL":
      found.append("\(text) looks its operator up by name")
    case "IN" where symbol(i + 1, "("), "USING" where symbol(i + 1, "("),
      "DISTINCT" where word(i + 1) == "FROM":
      found.append("\(text) looks its operator up by name")
    case "CASE" where word(i + 1) != "WHEN":
      found.append("simple CASE looks = up by name")
    // On PostgreSQL 13 and older these are LANGUAGE sql functions (and information_schema's
    // views call `_pg_*` ones) whose string body is parsed when they run, with the caller's
    // search_path and unqualified operators, so qualifying the call does not help. Read
    // pg_catalog.pg_description and pg_attribute / pg_type instead.
    case "OBJ_DESCRIPTION", "COL_DESCRIPTION", "SHOBJ_DESCRIPTION":
      found.append("\(text) runs a SQL body with the caller's search_path on PG 13 and older")
    case "INFORMATION_SCHEMA" where symbol(i + 1, "."):
      found.append("information_schema runs SQL bodies with the caller's search_path on PG 13")
    default:
      break
    }
    if text.hasPrefix("PG_"), text != "PG_CATALOG", !qualified(i) {
      found.append("unqualified catalog name \(text)")
    }
    guard symbol(i + 1, "(") else { return found }
    if symbol(i - 1, ".") {
      if !qualified(i) { found.append("function \(text) qualified outside pg_catalog") }
    } else if !notFunctions.contains(text), word(i - 1) != "AS", word(i - 1) != "ORDINALITY",
      !text.hasPrefix("PG_")
    {
      found.append("unqualified function \(text)(")
    }
    return found
  }

  /// Indices of the `=` of each `column = value` in a SET clause (`UPDATE … SET`, `DO UPDATE
  /// SET`): an assignment, not an operator. Only an `=` right after a column name that follows
  /// the `SET` or a `,` at its depth, up to the `WHERE`, `FROM` or `RETURNING` there.
  private static func setAssignments(_ tokens: [SQLToken]) -> Set<Int> {
    var found: Set<Int> = []
    for start in tokens.indices where tokens[start].keyword == "SET" {
      let depth = tokens[start].depth
      var j = start + 1
      while j + 1 < tokens.count, tokens[j].depth >= depth {
        if tokens[j].depth == depth, ["WHERE", "FROM", "RETURNING"].contains(tokens[j].keyword) {
          break
        }
        let afterSeparator =
          j - 1 == start || (tokens[j - 1].isSymbol(",") && tokens[j - 1].depth == depth)
        if afterSeparator, tokens[j].depth == depth,
          tokens[j].kind == .word || tokens[j].kind == .quotedIdentifier,
          tokens[j + 1].isSymbol("=")
        {
          found.insert(j + 1)
        }
        j += 1
      }
    }
    return found
  }

  /// Indices of the first type token of each `CAST(expression AS type)`: the `AS` at the
  /// depth just inside the `CAST (`
  private static func castTypeStarts(_ tokens: [SQLToken]) -> Set<Int> {
    var starts: Set<Int> = []
    for i in tokens.indices where tokens[i].keyword == "CAST" && i + 1 < tokens.count {
      guard tokens[i + 1].isSymbol("(") else { continue }
      let inside = tokens[i + 1].depth + 1
      var j = i + 2
      while j < tokens.count, !(tokens[j].isSymbol(")") && tokens[j].depth < inside) {
        if tokens[j].depth == inside, tokens[j].keyword == "AS" {
          starts.insert(j + 1)
          break
        }
        j += 1
      }
    }
    return starts
  }

  /// SQL keywords that name a type: the parser binds them to `pg_catalog` itself
  /// (`::pg_catalog.integer` does not exist)
  private static let keywordTypes: Set<String> = [
    "INTEGER", "INT", "BIGINT", "SMALLINT", "REAL", "FLOAT", "DOUBLE", "NUMERIC", "DECIMAL",
    "DEC", "BOOLEAN", "BIT", "CHARACTER", "CHAR", "VARCHAR", "NCHAR", "NATIONAL", "TIME",
    "TIMESTAMP", "INTERVAL",
  ]
  /// Words that continue a keyword type name (`double precision`, `character varying`,
  /// `national character varying`)
  private static let keywordTypeContinuations: Set<String> = [
    "PRECISION", "VARYING", "CHARACTER", "CHAR",
  ]
  /// `pg_catalog` type names that are no SQL keyword, so an unqualified one is looked up through
  /// search_path. Kept apart from the app's own list on purpose: the lint is an independent
  /// check. `"char"` is matched quoted.
  private static let builtInTypes: Set<String> = [
    "text", "date", "uuid", "bytea", "json", "jsonb", "jsonpath", "xml", "int2", "int4", "int8",
    "float4", "float8", "bool", "oid", "tid", "xid", "xid8", "cid", "inet", "cidr", "macaddr",
    "macaddr8", "money", "name", "bpchar", "varbit", "timestamptz", "timetz", "point", "line",
    "lseg", "box", "path", "polygon", "circle", "regclass", "regtype", "regproc", "regprocedure",
    "regoper", "regoperator", "regnamespace", "regrole", "regconfig", "regdictionary",
    "regcollation", "tsvector", "tsquery", "pg_lsn", "pg_snapshot", "txid_snapshot",
    "int4range", "int8range", "numrange", "tsrange", "tstzrange", "daterange", "int4multirange",
    "int8multirange", "nummultirange", "tsmultirange", "tstzmultirange", "datemultirange",
  ]

  /// The type name at `start` (after `::` or a CAST's `AS`), through its typmod, time zone and
  /// `[]`: a `pg_catalog.` name, a SQL keyword type or a user type passes; an unqualified
  /// non-keyword built-in name does not. `end` is the index after the type.
  private static func castType(_ tokens: [SQLToken], at start: Int) -> (end: Int, found: [String]) {
    func word(_ index: Int) -> String? {
      tokens.indices.contains(index) ? tokens[index].keyword : nil
    }
    func symbol(_ index: Int, _ text: String) -> Bool {
      tokens.indices.contains(index) && tokens[index].isSymbol(text)
    }
    func isName(_ index: Int) -> Bool {
      tokens.indices.contains(index)
        && (tokens[index].kind == .word || tokens[index].kind == .quotedIdentifier)
    }
    guard isName(start) else { return (start, ["cast without a type name"]) }
    var found: [String] = []
    var i = start
    if symbol(i + 1, "."), isName(i + 2) {
      // `pg_catalog.name`, or a user type in another schema
      i += 3
    } else if let first = word(i), keywordTypes.contains(first) {
      i += 1
      while let next = word(i), keywordTypeContinuations.contains(next) { i += 1 }
    } else {
      let token = tokens[i]
      let builtIn =
        token.kind == .quotedIdentifier
        ? token.text == "char" || builtInTypes.contains(token.text)
        : builtInTypes.contains(SQLTokenizer.asciiLowercased(token.text))
      if builtIn { found.append("unqualified cast type \(token.text)") }
      i += 1
    }
    func skip(through close: String) {
      let depth = tokens[i].depth
      i += 1
      while i < tokens.count, !(tokens[i].isSymbol(close) && tokens[i].depth == depth) { i += 1 }
      i += 1
    }
    if symbol(i, "(") { skip(through: ")") }
    if word(i) == "WITH" || word(i) == "WITHOUT", word(i + 1) == "TIME", word(i + 2) == "ZONE" {
      i += 3
    }
    while symbol(i, "[") { skip(through: "]") }
    return (i, found)
  }

  /// `::` at `i` with a `pg_catalog.regclass` type: a regclass literal names a pg_catalog
  /// relation; a bound regclass is a name lookup.
  private static func regclassViolations(
    _ tokens: [SQLToken], at i: Int, allowsBoundNameLookup: Bool
  ) -> [String] {
    guard i + 4 < tokens.count, tokens[i + 2].keyword == "PG_CATALOG",
      tokens[i + 3].isSymbol("."), tokens[i + 4].keyword == "REGCLASS", i > 0
    else { return [] }
    let operand = tokens[i - 1]
    if operand.kind == .string {
      return operand.text.hasPrefix("pg_catalog.") ? [] : ["regclass literal '\(operand.text)'"]
    }
    if i > 1, tokens[i - 2].isSymbol("$"), !allowsBoundNameLookup {
      return ["bound regclass resolves a name through search_path"]
    }
    return []
  }
}
