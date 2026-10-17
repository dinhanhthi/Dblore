// AIMongoAssistTests.swift
// The AI Mongo helper: chat code blocks classified against the shown collection (find fills the
// filter, aggregate fills the builder) and one-shot replies parsed into a filter or stages

import Foundation
import Testing

@testable import Dblore

@Suite("AI Mongo assist")
struct AIMongoAssistTests {
  private typealias Stage = AIMongoAssist.GeneratedStage

  @Test("A find on the shown collection inserts its filter only")
  func findInsertsFilter() {
    let action = AIMongoAssist.blockAction(
      code: "db.orders.find({status: \"a\"}).limit(5)", collection: "orders")
    #expect(action == .insertFilter("{ status: \"a\" }"))
  }

  @Test("An aggregate on the shown collection generates its stages")
  func aggregateGeneratesStages() {
    let action = AIMongoAssist.blockAction(
      code: "db.orders.aggregate([{$match: {}}])", collection: "orders")
    #expect(action == .generateAggregation([Stage(operator: "$match", body: "{}")]))
  }

  @Test("Blocks on another collection or that do not parse give no action")
  func otherCollectionOrUnparsableGivesNil() {
    #expect(
      AIMongoAssist.blockAction(code: "db.orders.find({status: \"a\"})", collection: "users")
        == nil)
    #expect(
      AIMongoAssist.blockAction(code: "db.orders.aggregate([{$match: {}}])", collection: "users")
        == nil)
    #expect(
      AIMongoAssist.blockAction(code: "db.orders.find({status: ", collection: "orders") == nil)
  }

  @Test("A fenced filter reply gives the filter text")
  func fencedFilterReply() throws {
    #expect(try AIMongoAssist.filter(fromReply: "```json\n{a: 1}\n```") == "{ a: 1 }")
    #expect(try AIMongoAssist.filter(fromReply: "```mongodb\n{a: 1}\n```") == "{ a: 1 }")
  }

  @Test("A bare stage array and a db.aggregate wrapper give the stages in order")
  func pipelineReplies() throws {
    let expected = [
      Stage(operator: "$match", body: "{ a: 1 }"), Stage(operator: "$limit", body: "5"),
    ]
    #expect(
      try AIMongoAssist.stages(fromReply: "[{$match: {a: 1}}, {$limit: 5}]", collection: "orders")
        == expected)
    #expect(
      try AIMongoAssist.stages(
        fromReply: "db.orders.aggregate([{$match: {a: 1}}, {$limit: 5}])", collection: "orders")
        == expected)
  }

  @Test("A non-document filter, a non-array pipeline and an empty pipeline throw")
  func invalidRepliesThrow() throws {
    let filterError = try #require(throws: AIMongoAssist.ReplyError.self) {
      try AIMongoAssist.filter(fromReply: "[1, 2]")
    }
    #expect(!filterError.message.isEmpty)
    let objectError = try #require(throws: AIMongoAssist.ReplyError.self) {
      try AIMongoAssist.stages(fromReply: "{$match: {}}", collection: "orders")
    }
    #expect(!objectError.message.isEmpty)
    let emptyError = try #require(throws: AIMongoAssist.ReplyError.self) {
      try AIMongoAssist.stages(fromReply: "[]", collection: "orders")
    }
    #expect(!emptyError.message.isEmpty)
  }
}
