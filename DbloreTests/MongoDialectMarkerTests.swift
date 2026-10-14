// MongoDialectMarkerTests.swift
// `SQLDialect.mongodb`: text entry points delegate to the mongosh classifier and splitter and
// never run the PostgreSQL lexer, parameter rewriting finds nothing, identifier quoting throws,
// the other SQL members stay PostgreSQL-shaped, and the other dialects are unchanged.

import Foundation
import Testing

@testable import Dblore

@Suite("MongoDialectMarkerTests")
struct MongoDialectMarkerTests {

  /// A backslash string and a `;` token make the PostgreSQL classifier return unknown, `//` is
  /// not a PostgreSQL comment, and `--` is not a mongosh comment.
  private static let texts = [
    #"db.c.find({a: {$regex: '\\d+'}})"#,
    #"db.c.find({a: 'it\'s'})"#,
    "db.c.find(); db.c.deleteMany({})",
    "db.c.find()\ndb.c.insertOne({a: 1})",
    "// only a comment",
    "-- x",
    "SELECT 1; DROP TABLE t",
    "db.c.aggregate([{$out: 'x'}])",
  ]

  // MARK: - Delegation

  @Test("classify and classifyStatement return MongoCommandClassifier's results")
  func classifyDelegates() {
    for text in Self.texts {
      #expect(
        SQLStatementClassifier.classify(text, dialect: .mongodb)
          == MongoCommandClassifier.classify(text), "\(text)")
      #expect(
        SQLStatementClassifier.classifyStatement(text, dialect: .mongodb)
          == MongoCommandClassifier.classifyStatement(text), "\(text)")
    }
  }

  @Test("Mongo strings with a backslash or an escaped quote classify as one read")
  func backslashStringsAreReads() {
    for text in [#"db.c.find({a: {$regex: '\\d+'}})"#, #"db.c.find({a: 'it\'s'})"#] {
      #expect(
        SQLStatementClassifier.classify(text, dialect: .mongodb).map(\.kind) == [.read],
        "\(text)")
      #expect(
        SQLStatementClassifier.classifyStatement(text, dialect: .mongodb)?.kind == .read,
        "\(text)")
    }
  }

  @Test("Two commands classify as two statements, the second a DML that affects all rows")
  func twoCommands() {
    let statements = SQLStatementClassifier.classify(
      "db.c.find(); db.c.deleteMany({})", dialect: .mongodb)
    #expect(statements.map(\.text) == ["db.c.find()", "db.c.deleteMany({})"])
    #expect(statements.map(\.kind) == [.read, .dml])
    #expect(statements.last?.affectsAllRows == true)
  }

  @Test("splitStatements returns MongoshSplitter's pieces, the same ones classify classifies")
  func splitDelegates() {
    for text in Self.texts {
      let pieces = MongoshSplitter.split(text)
      #expect(SQLTokenizer.splitStatements(text, dialect: .mongodb) == pieces, "\(text)")
      #expect(SQLTokenizer(dialect: .mongodb).splitStatements(text) == pieces, "\(text)")
      #expect(
        SQLStatementClassifier.classify(text, dialect: .mongodb).map(\.text) == pieces, "\(text)")
    }
  }

  // MARK: - Comment-only

  @Test("Comment-only follows mongosh comments: // and /* */ are comments, -- is not")
  @MainActor
  func commentOnly() {
    let manager = DatabaseConnectionManager()
    for text in ["// only a comment", "/* block */", "  \n// a\n/* b */\n", ""] {
      #expect(manager.isCommentOnlyStatement(text, dialect: .mongodb), "\(text)")
      #expect(SQLTokenizer.tokens(text, dialect: .mongodb).isEmpty, "\(text)")
      #expect(SQLStatementClassifier.classifyStatement(text, dialect: .mongodb) == nil, "\(text)")
    }
    for text in ["-- x", "db.c.find() // trailing", "db.c.find({a: '/* not a comment */'})"] {
      #expect(!manager.isCommentOnlyStatement(text, dialect: .mongodb), "\(text)")
    }
  }

  @Test("tokens gives one opaque string token per mongosh piece")
  func tokensAreOpaquePieces() {
    let tokens = SQLTokenizer.tokens("db.c.find(); db.c.deleteMany({})", dialect: .mongodb)
    #expect(tokens.map(\.kind) == [.string, .string])
    #expect(tokens.map(\.text) == ["db.c.find()", "db.c.deleteMany({})"])
    #expect(tokens.allSatisfy { $0.depth == 0 })
  }

  // MARK: - Parameters, functions, passwords

  @Test("The parameter rewriter finds no names and no placeholders")
  func noParameters() {
    for text in [
      "db.c.find({a :b})", "db.c.find({a:b})", "db.c.updateOne({a: :x}, {$set: {b: 1}})",
      "db.c.find({a: ?})", "db.c.find({a: $1})", "db.c.find({a: @x})",
    ] {
      let rewritten = SQLParameterRewriter.rewrite(statement: text, dialect: .mongodb)
      #expect(rewritten.text == text, "\(text)")
      #expect(rewritten.names.isEmpty, "\(text)")
      #expect(SQLParameterRewriter.parameterNames(in: text, dialect: .mongodb).isEmpty, "\(text)")
      #expect(
        !SQLParameterRewriter.containsPositionalPlaceholder(in: text, dialect: .mongodb),
        "\(text)")
    }
  }

  @Test("mayCallFunctions and containsPasswordLiteral are false")
  func noFunctionsOrPasswords() {
    for text in [
      "db.c.find({a: 1})", "SET PASSWORD = 'x'", "CREATE USER u IDENTIFIED BY 'p'",
      "db.c.aggregate([{$match: {a: 1}}])",
    ] {
      #expect(!SQLStatementClassifier.mayCallFunctions(text, dialect: .mongodb), "\(text)")
      #expect(!SQLStatementClassifier.containsPasswordLiteral(text, dialect: .mongodb), "\(text)")
    }
  }

  // MARK: - SQL-rendering members

  @Test("quoteIdentifier and qualified throw notSQL")
  func identifiersThrow() {
    #expect(throws: SQLDialectError.notSQL) { try SQLDialect.mongodb.quoteIdentifier("a") }
    #expect(throws: SQLDialectError.notSQL) { try SQLDialect.mongodb.quoteIdentifier("a\0b") }
    #expect(throws: SQLDialectError.notSQL) {
      try SQLDialect.mongodb.qualified(schema: nil, name: "a")
    }
    #expect(throws: SQLDialectError.notSQL) {
      try SQLDialect.mongodb.qualified(schema: "s", name: "a")
    }
  }

  @Test("The non-throwing members return the PostgreSQL value")
  func otherMembersArePostgreSQLShaped() {
    let mongo = SQLDialect.mongodb
    let pg = SQLDialect.postgresql
    #expect(mongo != pg)
    #expect(mongo.promptName == pg.promptName)
    #expect(mongo.defaultSchema == pg.defaultSchema)
    #expect(mongo.supportsUpdateOnly == pg.supportsUpdateOnly)
    #expect(mongo.likeIsCaseInsensitive == pg.likeIsCaseInsensitive)
    let values: [CellValue] = [
      .null, .bool(true), .int(3), .double(1.5), .double(.nan), .double(-.infinity),
      .string("it's"), .string(#"a\b"#), .json("{}"), .date(Date(timeIntervalSince1970: 0)),
      .data(Data([0x01, 0xAB])),
    ]
    for value in values {
      #expect(mongo.literal(value) == pg.literal(value), "\(value)")
    }
    #expect(mongo.placeholder(2) == pg.placeholder(2))
    #expect(mongo.limitOffset(limit: 5, offset: 10) == pg.limitOffset(limit: 5, offset: 10))
    for (analyze, buffers, format) in [(false, false, nil), (true, true, "json")]
      as [(
        Bool, Bool, String?
      )]
    {
      #expect(
        mongo.explainPrefix(analyze: analyze, buffers: buffers, format: format)
          == pg.explainPrefix(analyze: analyze, buffers: buffers, format: format))
    }
    #expect(mongo.likeSubject("c") == pg.likeSubject("c"))
    #expect(
      mongo.caseInsensitiveLike(column: "c", pattern: "$1")
        == pg.caseInsensitiveLike(column: "c", pattern: "$1"))
  }

  // MARK: - Other dialects unchanged

  @Test("MySQL and PostgreSQL quoting and literals are unchanged")
  func otherDialectsUnchanged() throws {
    #expect(try SQLDialect.mysql.quoteIdentifier("a`b") == "`a``b`")
    #expect(try SQLDialect.postgresql.quoteIdentifier("a\"b") == "\"a\"\"b\"")
    #expect(try SQLDialect.sqlite.quoteIdentifier("a\"b") == "\"a\"\"b\"")
    #expect(SQLDialect.mysql.literal(.string(#"a\b'c"#)) == #"'a\\b''c'"#)
    #expect(SQLDialect.postgresql.literal(.string(#"a\b'c"#)) == #"E'a\\b''c'"#)
    #expect(SQLDialect.sqlite.literal(.string(#"a\b'c"#)) == #"'a\b''c'"#)
    #expect(SQLDialect.duckdb.literal(.string(#"a\b'c"#)) == #"'a\b''c'"#)
    #expect(SQLDialect.mysql.supportsUpdateOnly == false)
    #expect(SQLDialect.mysql.likeIsCaseInsensitive)
    #expect(SQLDialect.postgresql.supportsUpdateOnly)
    #expect(!SQLDialect.postgresql.likeIsCaseInsensitive)
  }
}
