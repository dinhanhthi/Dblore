// CascadeImpactPlannerTests.swift
// COUNT statements for a staged delete: blockers, cascade cycles, binds, and the key limit.

import Foundation
import Testing

@testable import Dblore

@Suite("Cascade impact planner")
struct CascadeImpactPlannerTests {
  @Test("A RESTRICT key is counted as a blocker")
  func restrictIsBlocker() throws {
    let keys = [
      key("orders_user_fk", child: "orders", ["user_id"], parent: "users", ["id"], .restrict)
    ]
    let plan = try plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "users", keyColumns: ["id"], keys: [[.int(1)], [.int(2)]],
        foreignKeys: keys, dialect: .postgresql))

    #expect(plan.steps.count == 1)
    let step = try #require(plan.steps.first)
    #expect(step.effect == .blocking)
    #expect(step.constraintName == "orders_user_fk")
    #expect(step.depth == 1)
    #expect(
      step.sql
        == #"SELECT pg_catalog.count(*) FROM "public"."orders" WHERE ("user_id" \#(eq) :k1 "#
        + #"OR "user_id" \#(eq) :k2)"#)
    #expect(step.parameters == ["k1": .text("1"), "k2": .text("2")])
    #expect(plan.enforcementCheck == nil)

    // Edits or inserts in the same batch can remove the blocker before COMMIT (deferred keys,
    // statement order): every blocker only may block
    let withWrites = try self.plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "users", keyColumns: ["id"], keys: [[.int(1)]],
        foreignKeys: keys, dialect: .postgresql, batchAlsoWrites: true))
    #expect(withWrites.steps.map(\.effect) == [.mayBlock])
  }

  @Test("A cascade cycle is counted once around and stops")
  func cascadeCycleTerminates() throws {
    let keys = [
      key("b_a_fk", child: "b", ["a_id"], parent: "a", ["id"], .cascade),
      key("a_b_fk", child: "a", ["b_id"], parent: "b", ["id"], .cascade),
      key("a_self_fk", child: "a", ["parent_id"], parent: "a", ["id"], .cascade),
    ]
    let plan = try plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "a", keyColumns: ["id"], keys: [[.int(7)]],
        foreignKeys: keys, dialect: .postgresql))

    #expect(plan.steps.map(\.constraintName) == ["b_a_fk", "a_b_fk", "a_self_fk"])
    #expect(plan.steps.map(\.depth) == [1, 2, 1])
    #expect(plan.steps.allSatisfy { $0.effect == .deleted })
    #expect(
      plan.steps[1].sql
        == #"SELECT pg_catalog.count(*) FROM "public"."a" WHERE "b_id" \#(eq) ANY "#
        + #"(SELECT "id" FROM "public"."b" WHERE ("a_id" \#(eq) :k1))"#
    )
    // The qualified ANY subquery still passes the read-only check the counts run behind
    #expect(throws: Never.self) {
      try ReadOnlyQueryGuard.check(plan.steps[1].sql, dialect: .postgresql)
    }
  }

  @Test("Key values are binds in every dialect, never SQL text")
  func keysAreBinds() throws {
    let keys = [
      key(
        "line_fk", child: "lines", ["o_code", "o_no"], parent: "orders", ["code", "no"], .cascade),
      key("note_fk", child: "notes", ["l_id"], parent: "lines", ["id"], .setNull),
    ]
    let values: [[CellValue]] = [[.string("needle'x"), .int(987_654)]]
    for dialect in [SQLDialect.postgresql, .mysql, .sqlite, .duckdb] {
      let plan = try plan(
        CascadeImpactPlanner.impact(
          deletingFrom: "public", table: "orders", keyColumns: ["code", "no"], keys: values,
          foreignKeys: keys, dialect: dialect))
      #expect(!plan.steps.isEmpty, "\(dialect)")
      for step in plan.steps {
        #expect(!step.sql.contains("needle"), "\(dialect)")
        #expect(!step.sql.contains("987654"), "\(dialect)")
        #expect(step.parameters.values.contains(.text("needle'x")), "\(dialect)")
      }
      #expect(plan.enforcementCheck == (dialect == .sqlite ? "PRAGMA foreign_keys" : nil))
      // Composite keys: row values (SQLite through VALUES), DuckDB and PostgreSQL an OR of AND
      // groups (PostgreSQL with pg_catalog's =)
      let expected: String =
        switch dialect {
        case .postgresql:
          #"SELECT pg_catalog.count(*) FROM "public"."lines" "#
            + #"WHERE (("o_code" \#(eq) :k1 AND "o_no" \#(eq) :k2))"#
        case .mysql:
          "SELECT COUNT(*) FROM `public`.`lines` WHERE (`o_code`, `o_no`) IN ((:k1, :k2))"
        case .sqlite:
          #"SELECT COUNT(*) FROM "public"."lines" WHERE ("o_code", "o_no") IN (VALUES (:k1, :k2))"#
        default:
          #"SELECT COUNT(*) FROM "public"."lines" WHERE (("o_code" = :k1 AND "o_no" = :k2))"#
        }
      #expect(plan.steps.first?.sql == expected, "\(dialect)")
    }
  }

  @Test("A self-reference does not count the rows that are deleted too")
  func selfReferenceExcludesDeletedRows() throws {
    let keys = [
      key("parent_fk", child: "categories", ["parent_id"], parent: "categories", ["id"], .noAction)
    ]
    let plan = try plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "categories", keyColumns: ["id"],
        keys: [[.int(1)], [.int(2)]], foreignKeys: keys, dialect: .postgresql))

    let step = try #require(plan.steps.first)
    #expect(step.effect == .blocking)
    #expect(
      step.sql
        == #"SELECT pg_catalog.count(*) FROM "public"."categories" "#
        + #"WHERE ("parent_id" \#(eq) :k1 OR "parent_id" \#(eq) :k2) "#
        + #"AND NOT (("id" \#(eq) :k3 OR "id" \#(eq) :k4))"#)
    #expect(
      step.parameters == ["k1": .text("1"), "k2": .text("2"), "k3": .text("1"), "k4": .text("2")])
    // One DELETE per staged row: a parent deleted before its staged child may still fail
    try #require(plan.steps.map(\.effect) == [.blocking, .mayBlock])
    #expect(
      plan.steps[1].sql
        == #"SELECT pg_catalog.count(*) FROM "public"."categories" "#
        + #"WHERE ("parent_id" \#(eq) :k1 OR "parent_id" \#(eq) :k2) "#
        + #"AND ((("id" \#(eq) :k3 OR "id" \#(eq) :k4)))"#)
  }

  @Test("A blocker on a table the cascade deletes does not count the cascaded rows")
  func blockerOnCascadedTableExcludesCascadedRows() throws {
    let keys = [
      key("comments_post_fk", child: "comments", ["post_id"], parent: "posts", ["id"], .cascade),
      key(
        "comments_parent_fk", child: "comments", ["parent_id"], parent: "comments", ["id"],
        .noAction),
      key("flags_post_fk", child: "flags", ["post_id"], parent: "posts", ["id"], .restrict),
    ]
    let plan = try plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "posts", keyColumns: ["id"], keys: [[.int(1)]],
        foreignKeys: keys, dialect: .postgresql))

    #expect(
      plan.steps.map(\.constraintName) == [
        "comments_post_fk", "comments_parent_fk", "flags_post_fk",
      ])
    #expect(plan.steps.map(\.effect) == [.deleted, .blocking, .blocking])
    // Replies deleted with their post are left out: only replies on other posts are counted
    #expect(
      plan.steps[1].sql
        == #"SELECT pg_catalog.count(*) FROM "public"."comments" WHERE "parent_id" \#(eq) ANY "#
        + #"(SELECT "id" FROM "public"."comments" WHERE ("post_id" \#(eq) :k1)) "#
        + #"AND NOT COALESCE((("post_id" \#(eq) :k2)), FALSE)"#)
    #expect(plan.steps[1].parameters == ["k1": .text("1"), "k2": .text("1")])

    // MySQL checks NO ACTION row by row during the cascade: the left-out rows may still block
    let mysql = try self.plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "posts", keyColumns: ["id"], keys: [[.int(1)]],
        foreignKeys: keys, dialect: .mysql))
    #expect(mysql.steps.map(\.effect) == [.deleted, .blocking, .mayBlock, .blocking])
    #expect(
      mysql.steps[2].sql
        == "SELECT COUNT(*) FROM `public`.`comments` WHERE `parent_id` IN "
        + "(SELECT `id` FROM `public`.`comments` WHERE `post_id` IN (:k1)) "
        + "AND ((`post_id` IN (:k2)))")
    #expect(!CascadeImpactSummary.grouped([(mysql.steps[2], 2)]).blocksCommit)
  }

  @Test("A NO ACTION key next to a CASCADE key on the same table still blocks")
  func blockerBesideCascadeStillBlocks() throws {
    // Messages a user sent are deleted with the user; messages the user received block it
    let keys = [
      key(
        "messages_sender_fk", child: "messages", ["sender_id"], parent: "users", ["id"], .cascade),
      key(
        "messages_recipient_fk", child: "messages", ["recipient_id"], parent: "users", ["id"],
        .noAction),
    ]
    let plan = try plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "users", keyColumns: ["id"], keys: [[.int(7)]],
        foreignKeys: keys, dialect: .postgresql))

    #expect(plan.steps.map(\.effect) == [.deleted, .blocking])
    let step = plan.steps[1]
    #expect(step.constraintName == "messages_recipient_fk")
    #expect(
      step.sql
        == #"SELECT pg_catalog.count(*) FROM "public"."messages" "#
        + #"WHERE ("recipient_id" \#(eq) :k1) "#
        + #"AND NOT COALESCE((("sender_id" \#(eq) :k2)), FALSE)"#)
    #expect(step.parameters == ["k1": .text("7"), "k2": .text("7")])
    #expect(CascadeImpactSummary.grouped([(step, 1)]).blocksCommit)
    // The count still passes the read-only check it runs behind
    #expect(throws: Never.self) { try ReadOnlyQueryGuard.check(step.sql, dialect: .postgresql) }

    // RESTRICT is checked at once, during the cascade: the cascaded messages may still block
    let restrict = try self.plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "users", keyColumns: ["id"], keys: [[.int(7)]],
        foreignKeys: [
          keys[0],
          key(
            "messages_recipient_fk", child: "messages", ["recipient_id"], parent: "users",
            ["id"], .restrict),
        ], dialect: .postgresql))
    #expect(restrict.steps.map(\.effect) == [.deleted, .blocking, .mayBlock])
    #expect(
      restrict.steps[2].sql
        == #"SELECT pg_catalog.count(*) FROM "public"."messages" "#
        + #"WHERE ("recipient_id" \#(eq) :k1) AND ((("sender_id" \#(eq) :k2)))"#)

    // One DELETE per staged row: a message 8 sent to 7 still refers to 7 when 7 goes first
    let twoRows = try self.plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "users", keyColumns: ["id"], keys: [[.int(7)], [.int(8)]],
        foreignKeys: keys, dialect: .postgresql))
    try #require(twoRows.steps.map(\.effect) == [.deleted, .blocking, .mayBlock])
    #expect(
      twoRows.steps[2].sql
        == #"SELECT pg_catalog.count(*) FROM "public"."messages" "#
        + #"WHERE ("recipient_id" \#(eq) :k1 OR "recipient_id" \#(eq) :k2) "#
        + #"AND ((("sender_id" \#(eq) :k3 OR "sender_id" \#(eq) :k4)))"#)
    let summary = CascadeImpactSummary.grouped([(twoRows.steps[1], 0), (twoRows.steps[2], 1)])
    #expect(!summary.blocksCommit)
    #expect(summary.affected.map(\.text).first?.contains("up to 1 row") == true)
  }

  @Test("A cascade the walk stops (cycle) makes its table's blockers non-refusing")
  func stoppedCascadeBlockerMayBlock() throws {
    // The server deletes the whole thread; the walk stops at the replies of the root
    let keys = [
      key(
        "comments_parent_fk", child: "comments", ["parent_id"], parent: "comments", ["id"],
        .cascade),
      key(
        "comments_root_fk", child: "comments", ["root_id"], parent: "comments", ["id"], .noAction),
      key(
        "flags_comment_fk", child: "flags", ["comment_id"], parent: "comments", ["id"], .noAction),
    ]
    let plan = try plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "comments", keyColumns: ["id"], keys: [[.int(1)]],
        foreignKeys: keys, dialect: .postgresql))

    // `flags` is never deleted: a flag on a deleted comment still refuses the delete
    try #require(plan.steps.map(\.effect) == [.deleted, .mayBlock, .blocking])
    #expect(
      plan.steps[1].sql
        == #"SELECT pg_catalog.count(*) FROM "public"."comments" WHERE ("root_id" \#(eq) :k1) "#
        + #"AND NOT (("id" \#(eq) :k2)) AND NOT COALESCE((("parent_id" \#(eq) :k3)), FALSE)"#)
    #expect(!CascadeImpactSummary.grouped([(plan.steps[1], 2)]).blocksCommit)
    #expect(CascadeImpactSummary.grouped([(plan.steps[2], 1)]).blocksCommit)
  }

  @Test("A blocker on a table cascaded from below a stopped cascade only may block")
  func blockerBelowStoppedCascadeMayBlock() throws {
    // The walk stops at the replies (`comments` cycle); the server also deletes their
    // attachments, and the `t` rows owned by those attachments
    let keys = [
      key(
        "comments_parent_fk", child: "comments", ["parent_id"], parent: "comments", ["id"],
        .cascade),
      key(
        "attachments_comment_fk", child: "attachments", ["comment_id"], parent: "comments",
        ["id"], .cascade),
      key(
        "t_attachment_fk", child: "t", ["attachment_id"], parent: "attachments", ["id"], .noAction),
      key("t_owner_fk", child: "t", ["owner_id"], parent: "attachments", ["id"], .cascade),
    ]
    let plan = try plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "comments", keyColumns: ["id"], keys: [[.int(1)]],
        foreignKeys: keys, dialect: .postgresql))

    #expect(
      plan.steps.map(\.constraintName) == [
        "comments_parent_fk", "attachments_comment_fk", "t_attachment_fk", "t_owner_fk",
      ])
    #expect(plan.steps.map(\.effect) == [.deleted, .deleted, .mayBlock, .deleted])
    #expect(!CascadeImpactSummary.grouped([(plan.steps[2], 1)]).blocksCommit)
  }

  @Test("A RESTRICT key on a table a cascade also reaches leaves out its rows (diamond)")
  func diamondBlockerExcludesCascadedRows() throws {
    // The RESTRICT key comes first: `invoices` is found deleted only later in the walk
    let keys = [
      key("inv_order_fk", child: "invoices", ["order_id"], parent: "orders", ["id"], .restrict),
      key("orders_user_fk", child: "orders", ["user_id"], parent: "users", ["id"], .cascade),
      key("inv_user_fk", child: "invoices", ["user_id"], parent: "users", ["id"], .cascade),
    ]
    let plan = try plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "users", keyColumns: ["id"], keys: [[.int(1)]],
        foreignKeys: keys, dialect: .postgresql))

    #expect(
      plan.steps.map(\.constraintName) == [
        "orders_user_fk", "inv_order_fk", "inv_order_fk", "inv_user_fk",
      ])
    // RESTRICT is checked during the cascade: the left-out invoices may still block
    #expect(plan.steps.map(\.effect) == [.deleted, .blocking, .mayBlock, .deleted])
    #expect(
      plan.steps[1].sql
        == #"SELECT pg_catalog.count(*) FROM "public"."invoices" WHERE "order_id" \#(eq) ANY "#
        + #"(SELECT "id" FROM "public"."orders" WHERE ("user_id" \#(eq) :k1)) "#
        + #"AND NOT COALESCE((("user_id" \#(eq) :k2)), FALSE)"#)
  }

  @Test("SQLite names a key by its columns and matches the table name in any case")
  func sqliteKeyNameAndCase() throws {
    let orders = key(
      "0", child: "orders", ["user_id"], parent: "Users", ["id"], .restrict, schema: "main")
    let plan = try plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "main", table: "users", keyColumns: ["id"], keys: [[.int(1)]],
        foreignKeys: [orders], dialect: .sqlite))

    #expect(plan.steps.map(\.constraintName) == ["orders(user_id)"])
  }

  @Test("Too many related counts is not computed")
  func tooManyStepsNotComputed() {
    let keys = (0...CascadeImpactPlanner.maxSteps).map {
      key("fk\($0)", child: "c\($0)", ["p_id"], parent: "p", ["id"], .cascade)
    }
    let impact = CascadeImpactPlanner.impact(
      deletingFrom: "public", table: "p", keyColumns: ["id"], keys: [[.int(1)]],
      foreignKeys: keys, dialect: .postgresql)
    guard case .notComputed = impact else {
      Issue.record("expected notComputed, got \(impact)")
      return
    }
  }

  @Test("Over 1,000 deleted keys is not computed")
  func tooManyKeysNotComputed() {
    let keys = [key("fk", child: "c", ["p_id"], parent: "p", ["id"], .cascade)]
    let impact = CascadeImpactPlanner.impact(
      deletingFrom: "public", table: "p", keyColumns: ["id"],
      keys: (0...CascadeImpactPlanner.maxKeys).map { [.int($0)] }, foreignKeys: keys,
      dialect: .postgresql)
    guard case .notComputed = impact else {
      Issue.record("expected notComputed, got \(impact)")
      return
    }
  }

  @Test("A citext key compares with its extension's operator, at each level of the cascade")
  func citextKeyUsesExtensionOperator() throws {
    let keys = [
      key("accounts_user_fk", child: "accounts", ["user_id"], parent: "users", ["id"], .cascade),
      key(
        "logins_account_fk", child: "logins", ["account_id"], parent: "accounts", ["id"],
        .cascade),
    ]
    let types = [
      "public.users": ["id": Self.citext],
      "public.accounts": ["id": Self.citext, "user_id": Self.citext],
      "public.logins": ["account_id": Self.citext],
    ]
    let plan = try plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "users", keyColumns: ["id"], keys: [[.string("Ann")]],
        foreignKeys: keys, dialect: .postgresql, columnTypes: types))

    // A child row holding "ann" is counted: citext's own = matches it, pg_catalog's would not
    #expect(
      plan.steps.map(\.sql) == [
        #"SELECT pg_catalog.count(*) FROM "public"."accounts" WHERE ("user_id" \#(ext) :k1)"#,
        #"SELECT pg_catalog.count(*) FROM "public"."logins" WHERE "account_id" \#(ext) ANY "#
          + #"(SELECT "id" FROM "public"."accounts" WHERE ("user_id" \#(ext) :k1))"#,
      ])
    expectClean(plan, ["user_id": Self.citext, "account_id": Self.citext, "id": Self.citext])
  }

  @Test("A key on a domain over citext casts both sides, in the key list and the subquery")
  func domainKeyCastsBothSides() throws {
    let keys = [
      key("b_a_fk", child: "b", ["a_id"], parent: "a", ["id"], .cascade),
      key("c_b_fk", child: "c", ["b_id"], parent: "b", ["code"], .cascade),
      // A composite key mixing a domain and an int4 column stays qualified (one operator)
      key("d_b_fk", child: "d", ["b_code", "b_num"], parent: "b", ["code", "num"], .cascade),
    ]
    let types = [
      "public.a": ["id": Self.citextDomain],
      "public.b": ["a_id": Self.citextDomain, "code": Self.citextDomain],
      "public.c": ["b_id": Self.citextDomain],
      "public.d": ["b_code": Self.citextDomain],
    ]
    let plan = try plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "a", keyColumns: ["id"], keys: [[.string("X")]],
        foreignKeys: keys, dialect: .postgresql, columnTypes: types))

    let cast = "::public.citext"
    let condition = #"("a_id"\#(cast) \#(ext) :k1\#(cast))"#
    #expect(
      plan.steps.map(\.sql) == [
        #"SELECT pg_catalog.count(*) FROM "public"."b" WHERE "# + condition,
        #"SELECT pg_catalog.count(*) FROM "public"."c" WHERE "b_id"\#(cast) \#(ext) ANY "#
          + #"(SELECT "code"\#(cast) FROM "public"."b" WHERE \#(condition))"#,
        #"SELECT pg_catalog.count(*) FROM "public"."d" WHERE ("b_code", "b_num") \#(eq) ANY "#
          + #"(SELECT "code", "num" FROM "public"."b" WHERE \#(condition))"#,
      ])
    expectClean(
      plan, ["a_id": Self.citextDomain, "b_id": Self.citextDomain, "code": Self.citextDomain])
  }

  @Test("Each column takes its own table's type; a citext child of a text parent is qualified")
  func typesComeFromTheColumnsOwnTable() throws {
    let keys = [
      // `items.id` is int4, `tags.id` citext: the int4 key never borrows the citext type
      key("items_parent_fk", child: "items", ["parent_id"], parent: "items", ["id"], .noAction),
      key("tags_parent_fk", child: "tags", ["parent_id"], parent: "tags", ["id"], .noAction),
      // A citext column referencing a text key (the implicit cast): compared as the key is
      key("notes_user_fk", child: "notes", ["user_name"], parent: "users", ["name"], .cascade),
      key("pins_note_fk", child: "pins", ["note_tag"], parent: "notes", ["tag"], .cascade),
    ]
    let types = [
      "public.tags": ["id": Self.citext, "parent_id": Self.citext],
      "public.notes": ["user_name": Self.citext, "tag": Self.citext],
      "public.pins": ["note_tag": Self.citextDomain],
    ]
    func sql(_ table: String, _ column: String) throws -> [String] {
      try plan(
        CascadeImpactPlanner.impact(
          deletingFrom: "public", table: table, keyColumns: [column], keys: [[.int(1)]],
          foreignKeys: keys, dialect: .postgresql, columnTypes: types)
      ).steps.map(\.sql)
    }

    #expect(
      try sql("items", "id") == [
        #"SELECT pg_catalog.count(*) FROM "public"."items" WHERE ("parent_id" \#(eq) :k1) "#
          + #"AND NOT (("id" \#(eq) :k2))"#
      ])
    #expect(
      try sql("tags", "id") == [
        #"SELECT pg_catalog.count(*) FROM "public"."tags" WHERE ("parent_id" \#(ext) :k1) "#
          + #"AND NOT (("id" \#(ext) :k2))"#
      ])
    // `users.name` is text, `notes.user_name` citext: they do not agree, so pg_catalog's =.
    // `pins.note_tag` is a domain over citext and `notes.tag` citext itself: the same base
    // type, so citext's own = (the key's), both sides cast to citext
    #expect(
      try sql("users", "name") == [
        #"SELECT pg_catalog.count(*) FROM "public"."notes" WHERE ("user_name" \#(eq) :k1)"#,
        #"SELECT pg_catalog.count(*) FROM "public"."pins" WHERE "note_tag"::public.citext "#
          + #"\#(ext) ANY (SELECT "tag"::public.citext FROM "public"."notes" "#
          + #"WHERE ("user_name" \#(eq) :k1))"#,
      ])
  }

  @Test("A domain over citext and citext itself compare as citext, both sides cast")
  func domainAndBaseTypeAgree() throws {
    let cast = "::public.citext"
    // A domain child referencing a citext key, and a citext child referencing a domain key
    let keys = [
      key("pins_note_fk", child: "pins", ["note_tag"], parent: "notes", ["tag"], .cascade),
      key("marks_pin_fk", child: "marks", ["pin_tag"], parent: "pins", ["code"], .cascade),
      key("flags_pin_fk", child: "flags", ["pin_code"], parent: "pins", ["code"], .noAction),
    ]
    let types = [
      "public.notes": ["tag": Self.citext],
      "public.pins": ["note_tag": Self.citextDomain, "code": Self.citextDomain],
      "public.marks": ["pin_tag": Self.citext],
      "public.flags": ["pin_code": Self.citext],
    ]
    let fromNotes = try plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "notes", keyColumns: ["tag"], keys: [[.string("Zed")]],
        foreignKeys: keys, dialect: .postgresql, columnTypes: types))
    let pins = #"("note_tag"\#(cast) \#(ext) :k1\#(cast))"#
    let subquery = #"ANY (SELECT "code"\#(cast) FROM "public"."pins" WHERE \#(pins))"#
    #expect(
      fromNotes.steps.map(\.sql) == [
        #"SELECT pg_catalog.count(*) FROM "public"."pins" WHERE "# + pins,
        #"SELECT pg_catalog.count(*) FROM "public"."marks" WHERE "pin_tag"\#(cast) \#(ext) "#
          + subquery,
        #"SELECT pg_catalog.count(*) FROM "public"."flags" WHERE "pin_code"\#(cast) \#(ext) "#
          + subquery,
      ])
    // The citext child's key list against the domain key
    let fromPins = try plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "pins", keyColumns: ["code"], keys: [[.string("Zed")]],
        foreignKeys: keys, dialect: .postgresql, columnTypes: types))
    #expect(
      fromPins.steps.map(\.sql) == [
        #"SELECT pg_catalog.count(*) FROM "public"."marks" WHERE ("pin_tag"\#(cast) \#(ext) "#
          + #":k1\#(cast))"#,
        #"SELECT pg_catalog.count(*) FROM "public"."flags" WHERE ("pin_code"\#(cast) \#(ext) "#
          + #":k1\#(cast))"#,
      ])
    // The lint cannot tell a cast citext column from a domain one: the domain side is linted,
    // the plain citext side's statements are checked as written above
    expectClean(
      CascadeImpactPlanner.Plan(steps: [fromNotes.steps[0]], enforcementCheck: nil),
      ["note_tag": Self.citextDomain])
    for step in fromNotes.steps + fromPins.steps {
      #expect(throws: Never.self) { try ReadOnlyQueryGuard.check(step.sql, dialect: .postgresql) }
    }
  }

  @Test("A composite key whose column pairs all agree compares the row with their operator")
  func compositeKeyWithAgreeingColumns() throws {
    // Each key references `p (a, b)` while `p` is deleted by `id`: the subquery form
    let keys = [
      key("c_p_fk", child: "c", ["x", "y"], parent: "p", ["a", "b"], .cascade),
      key("d_q_fk", child: "d", ["x", "y"], parent: "q", ["a", "b"], .cascade),
      // `t` is text: a citext child of it does not agree, so the row stays qualified
      key("e_p_fk", child: "e", ["x", "y"], parent: "p", ["a", "t"], .cascade),
    ]
    let types = [
      "public.p": ["a": Self.citext, "b": Self.citext],
      "public.c": ["x": Self.citext, "y": Self.citext],
      "public.q": ["a": Self.citextDomain, "b": Self.citextDomain],
      "public.d": ["x": Self.citextDomain, "y": Self.citextDomain],
      "public.e": ["x": Self.citext, "y": Self.citext],
    ]
    func sql(_ table: String) throws -> [String] {
      try plan(
        CascadeImpactPlanner.impact(
          deletingFrom: "public", table: table, keyColumns: ["id"], keys: [[.int(1)]],
          foreignKeys: keys, dialect: .postgresql, columnTypes: types)
      ).steps.map(\.sql)
    }

    let cast = "::public.citext"
    #expect(
      try sql("p") == [
        #"SELECT pg_catalog.count(*) FROM "public"."c" WHERE ("x", "y") \#(ext) ANY "#
          + #"(SELECT "a", "b" FROM "public"."p" WHERE ("id" \#(eq) :k1))"#,
        #"SELECT pg_catalog.count(*) FROM "public"."e" WHERE ("x", "y") \#(eq) ANY "#
          + #"(SELECT "a", "t" FROM "public"."p" WHERE ("id" \#(eq) :k1))"#,
      ])
    #expect(
      try sql("q") == [
        #"SELECT pg_catalog.count(*) FROM "public"."d" WHERE ("x"\#(cast), "y"\#(cast)) "#
          + #"\#(ext) ANY (SELECT "a"\#(cast), "b"\#(cast) FROM "public"."q" "#
          + #"WHERE ("id" \#(eq) :k1))"#
      ])
    // The lint matches an operator after one column only: the row forms are checked as
    // written above
    for step in try sql("p") + sql("q") {
      #expect(throws: Never.self) { try ReadOnlyQueryGuard.check(step, dialect: .postgresql) }
    }
  }

  /// No lint finding with the columns' type data, and the read-only check the counts run behind
  /// still passes
  private func expectClean(
    _ plan: CascadeImpactPlanner.Plan, _ columnTypeData: [String: PostgresColumnType]
  ) {
    for step in plan.steps {
      #expect(
        PostgresQualificationLint.violations(step.sql, columnTypeData: columnTypeData) == [],
        "\(step.sql)")
      #expect(throws: Never.self) { try ReadOnlyQueryGuard.check(step.sql, dialect: .postgresql) }
    }
  }

  /// pg_catalog's `=`, as every PostgreSQL count compares keys
  private let eq = "OPERATOR(pg_catalog.=)"
  /// citext's own `=`, owned by its extension in `public`
  private let ext = "OPERATOR(public.=)"
  /// citext owned by its extension in `public`
  private static let citext = PostgresColumnType(
    oid: 16_400, operand: .bare, castName: "public.citext", compareCast: nil,
    operatorSchema: "public")
  /// A domain over citext: compared cast to citext
  private static let citextDomain = PostgresColumnType(
    oid: 16_401, operand: .bare, castName: "public.cit_dom", compareCast: "public.citext",
    operatorSchema: "public")

  private func key(
    _ name: String, child: String, _ sourceColumns: [String], parent: String,
    _ targetColumns: [String], _ onDelete: ForeignKeyAction, schema: String = "public"
  ) -> ForeignKey {
    ForeignKey(
      constraintName: name, sourceSchema: schema, sourceTable: child,
      sourceColumns: sourceColumns, targetSchema: schema, targetTable: parent,
      targetColumns: targetColumns, onDelete: onDelete)
  }

  private func plan(_ impact: CascadeImpactPlanner.Impact) throws -> CascadeImpactPlanner.Plan {
    guard case .plan(let plan) = impact else {
      Issue.record("expected a plan, got \(impact)")
      throw CancellationError()
    }
    return plan
  }
}
