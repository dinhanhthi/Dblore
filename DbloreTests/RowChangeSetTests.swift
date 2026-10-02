// RowChangeSetTests.swift
// Staged inserts, deletes, and cell edits for one data-viewer target.

import Foundation
import Testing

@testable import Dblore

@Suite("Row change set")
@MainActor
struct RowChangeSetTests {
  @Test("A new change set is empty")
  func emptySet() {
    let set = RowChangeSet(target: sampleTarget())
    #expect(set.isEmpty)
    #expect(set.counts.inserts == 0)
    #expect(set.counts.deletes == 0)
    #expect(set.counts.edits == 0)
    #expect(set.inserts.isEmpty)
    #expect(set.deletes.isEmpty)
    #expect(set.edits.isEmpty)
  }

  @Test("Editing a cell back to its original clears that column and the row")
  func editThenRevertToOriginalClearsTheEdit() throws {
    var set = RowChangeSet(target: sampleTarget())
    let row = RowChangeSet.RowKey(values: [.int(1)])

    try set.stageEdit(row: row, column: "name", value: .string("b"), original: .string("a"))
    try set.stageEdit(row: row, column: "note", value: .string("n"), original: .null)
    #expect(set.counts.edits == 1)
    #expect(set.edits[row]?["name"] == .string("b"))
    #expect(set.originals[row]?["name"] == .string("a"))
    #expect(!set.isEmpty)

    try set.stageEdit(row: row, column: "name", value: .string("a"), original: .string("a"))
    #expect(set.edits[row]?["name"] == nil)
    #expect(set.originals[row]?["name"] == nil)
    #expect(set.edits[row]?["note"] == .string("n"))
    #expect(set.originals[row]?["note"] == .null)

    try set.stageEdit(row: row, column: "note", value: .null, original: .null)
    #expect(set.edits[row] == nil)
    #expect(set.originals[row] == nil)
    #expect(set.isEmpty)
  }

  @Test("revert drops staged edits and deletes, and revertAll clears inserts")
  func revertRowsAndRevertAll() throws {
    var set = RowChangeSet(target: sampleTarget())
    let row = RowChangeSet.RowKey(values: [.int(7)])
    try set.stageEdit(row: row, column: "name", value: .string("b"), original: .string("a"))
    set.stageDelete(row: RowChangeSet.RowKey(values: [.int(8)]))
    let tempID = set.stageInsert(values: ["name": .string("new")])

    set.revert(rows: [row, RowChangeSet.RowKey(values: [.int(8)])])
    #expect(set.edits[row] == nil)
    #expect(set.originals[row] == nil)
    #expect(set.deletes.isEmpty)
    #expect(set.inserts.map(\.tempID) == [tempID])

    set.revertAll()
    #expect(set.isEmpty)
  }

  @Test("A staged insert can set its primary key")
  func insertCanSetPrimaryKey() {
    var set = RowChangeSet(target: sampleTarget())
    let tempID = set.stageInsert(values: ["name": .string("new")])
    set.updateInsert(tempID: tempID, column: "id", value: .int(3))
    let values = set.inserts.first?.values
    #expect(values?["name"] != nil)
    #expect(values?["id"] != nil)
    #expect(set.edits.isEmpty)
  }

  @Test("Filling integer keys keeps a chosen value and stops at Int.max")
  func assignMissingIntegerKeyStopsAtIntMax() {
    var set = RowChangeSet(target: sampleTarget())
    set.stageInsert(values: ["id": .int(5)])
    set.stageInsert(values: ["name": .string("a")])
    set.stageInsert(values: ["name": .string("b")])

    set.assignMissingIntegerKey("id", startingAt: Int.max)

    #expect(set.inserts[0].values["id"] == .int(5))
    #expect(set.inserts[1].values["id"] == .int(Int.max))
    #expect(set.inserts[2].values["id"] == nil)
  }

  @Test("A primary key edit is rejected and the message mentions SQL")
  func primaryKeyEditIsRejected() {
    var set = RowChangeSet(target: sampleTarget())
    let row = RowChangeSet.RowKey(values: [.int(1)])
    do {
      try set.stageEdit(row: row, column: "id", value: .int(2), original: .int(1))
      Issue.record("expected RowChangeError")
    } catch let error as RowChangeError {
      #expect(error.message.contains("SQL"))
    } catch {
      Issue.record("expected RowChangeError, got \(error)")
    }
    #expect(set.edits.isEmpty)
    #expect(set.isEmpty)
  }

  @Test("An edit of a deleted row is rejected")
  func editOfDeletedRowIsRejected() {
    var set = RowChangeSet(target: sampleTarget())
    let row = RowChangeSet.RowKey(values: [.int(1)])
    set.stageDelete(row: row)
    do {
      try set.stageEdit(row: row, column: "name", value: .string("b"), original: .string("a"))
      Issue.record("expected RowChangeError")
    } catch is RowChangeError {
      #expect(set.deletes.contains(row))
    } catch {
      Issue.record("expected RowChangeError, got \(error)")
    }
    #expect(set.edits.isEmpty)
  }

  @Test("Deleting an insert removes the insert")
  func deleteOfInsertRemovesTheInsert() {
    var set = RowChangeSet(target: sampleTarget())
    let tempID = set.stageInsert(values: ["name": .string("new"), "id": .int(9)])
    #expect(set.counts.inserts == 1)
    #expect(set.inserts.first?.tempID == tempID)
    #expect(set.inserts.first?.id == tempID)

    set.deleteInsert(tempID: tempID)
    #expect(set.inserts.isEmpty)
    #expect(set.deletes.isEmpty)
    #expect(set.isEmpty)
  }

  @Test("Deleting an edited row drops its edits")
  func deleteOfEditedRowDropsEdits() throws {
    var set = RowChangeSet(target: sampleTarget())
    let row = RowChangeSet.RowKey(values: [.int(1)])
    try set.stageEdit(row: row, column: "name", value: .string("b"), original: .string("a"))

    set.stageDelete(row: row)
    #expect(set.edits[row] == nil)
    #expect(set.originals[row] == nil)
    #expect(set.deletes == Set([row]))
    #expect(set.counts.deletes == 1)
    #expect(set.counts.edits == 0)
  }

  @Test("A different generation or connection epoch reports invalidation")
  func generationMismatchReportsInvalidation() {
    let generation = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let set = RowChangeSet(target: sampleTarget(generation: generation, connectionEpoch: 4))
    let changedGeneration = sampleTarget(generation: UUID(), connectionEpoch: 4)
    let changedEpoch = sampleTarget(generation: generation, connectionEpoch: 5)
    let same = sampleTarget(generation: generation, connectionEpoch: 4)

    #expect(
      set.invalidated(by: changedGeneration) == "The table changed; staged edits were discarded."
    )
    #expect(
      set.invalidated(by: changedEpoch) == "The table changed; staged edits were discarded."
    )
    #expect(set.invalidated(by: same) == nil)
  }
}

private func sampleTarget(
  generation: UUID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
  connectionEpoch: UInt64 = 4
) -> EditTarget {
  EditTarget(
    qualifiedName: "public.items",
    tableID: .postgresql(oid: 42),
    primaryKeyColumns: ["id"],
    connectionEpoch: connectionEpoch,
    generation: generation
  )
}
