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
      step.sql == #"SELECT COUNT(*) FROM "public"."orders" WHERE "user_id" IN (:k1, :k2)"#)
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
        == #"SELECT COUNT(*) FROM "public"."a" WHERE "b_id" IN "#
        + #"(SELECT "id" FROM "public"."b" WHERE "a_id" IN (:k1))"#
    )
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
      // Composite keys: row values (SQLite through VALUES), DuckDB an OR of AND groups
      let expected: String =
        switch dialect {
        case .postgresql:
          #"SELECT COUNT(*) FROM "public"."lines" WHERE ("o_code", "o_no") IN ((:k1, :k2))"#
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
        == #"SELECT COUNT(*) FROM "public"."categories" WHERE "parent_id" IN (:k1, :k2) "#
        + #"AND NOT ("id" IN (:k3, :k4))"#)
    #expect(
      step.parameters == ["k1": .text("1"), "k2": .text("2"), "k3": .text("1"), "k4": .text("2")])
    // One DELETE per staged row: a parent deleted before its staged child may still fail
    try #require(plan.steps.map(\.effect) == [.blocking, .mayBlock])
    #expect(
      plan.steps[1].sql
        == #"SELECT COUNT(*) FROM "public"."categories" WHERE "parent_id" IN (:k1, :k2) "#
        + #"AND (("id" IN (:k3, :k4)))"#)
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
        == #"SELECT COUNT(*) FROM "public"."comments" WHERE "parent_id" IN "#
        + #"(SELECT "id" FROM "public"."comments" WHERE "post_id" IN (:k1)) "#
        + #"AND NOT COALESCE(("post_id" IN (:k2)), FALSE)"#)
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
        == #"SELECT COUNT(*) FROM "public"."messages" WHERE "recipient_id" IN (:k1) "#
        + #"AND NOT COALESCE(("sender_id" IN (:k2)), FALSE)"#)
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
        == #"SELECT COUNT(*) FROM "public"."messages" WHERE "recipient_id" IN (:k1) "#
        + #"AND (("sender_id" IN (:k2)))"#)

    // One DELETE per staged row: a message 8 sent to 7 still refers to 7 when 7 goes first
    let twoRows = try self.plan(
      CascadeImpactPlanner.impact(
        deletingFrom: "public", table: "users", keyColumns: ["id"], keys: [[.int(7)], [.int(8)]],
        foreignKeys: keys, dialect: .postgresql))
    try #require(twoRows.steps.map(\.effect) == [.deleted, .blocking, .mayBlock])
    #expect(
      twoRows.steps[2].sql
        == #"SELECT COUNT(*) FROM "public"."messages" WHERE "recipient_id" IN (:k1, :k2) "#
        + #"AND (("sender_id" IN (:k3, :k4)))"#)
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
        == #"SELECT COUNT(*) FROM "public"."comments" WHERE "root_id" IN (:k1) "#
        + #"AND NOT ("id" IN (:k2)) AND NOT COALESCE(("parent_id" IN (:k3)), FALSE)"#)
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
        == #"SELECT COUNT(*) FROM "public"."invoices" WHERE "order_id" IN "#
        + #"(SELECT "id" FROM "public"."orders" WHERE "user_id" IN (:k1)) "#
        + #"AND NOT COALESCE(("user_id" IN (:k2)), FALSE)"#)
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
