//
//  ExecutionQueueTests.swift
//  DbloreTests
//
//  Tests for the ExecutionQueue system
//  Uses async waitForIdle() and waitForTask() methods for reliable testing
//  without race conditions or timing dependencies.
//

import Foundation
import Testing

@testable import Dblore

@MainActor
struct ExecutionQueueTests {

  // MARK: - Basic Queue Operations

  @Test("Queue enqueues tasks in order")
  func testEnqueueTasks() async throws {
    var executedCellIds: [UUID] = []

    let queue = ExecutionQueue { task in
      executedCellIds.append(task.cellId)
      return nil
    }

    let cellId1 = UUID()
    let cellId2 = UUID()
    let cellId3 = UUID()

    queue.enqueue(cellId: cellId1, query: "SELECT 1")
    queue.enqueue(cellId: cellId2, query: "SELECT 2")
    queue.enqueue(cellId: cellId3, query: "SELECT 3")

    // Wait for queue to complete all tasks
    await queue.waitForIdle()

    // Verify sequential execution order
    #expect(executedCellIds.count == 3)
    #expect(executedCellIds[0] == cellId1)
    #expect(executedCellIds[1] == cellId2)
    #expect(executedCellIds[2] == cellId3)
  }

  @Test("Queue position is correct for pending tasks")
  func testQueuePosition() async throws {
    // Use a continuation to control when tasks complete
    var taskContinuation: CheckedContinuation<Void, Never>?

    let queue = ExecutionQueue { _ in
      // Block until we release the task
      await withCheckedContinuation { continuation in
        taskContinuation = continuation
      }
      return nil
    }

    let cellId1 = UUID()
    let cellId2 = UUID()
    let cellId3 = UUID()

    queue.enqueue(cellId: cellId1, query: "SELECT 1")
    queue.enqueue(cellId: cellId2, query: "SELECT 2")
    queue.enqueue(cellId: cellId3, query: "SELECT 3")

    // Wait for first task to start executing
    let started = await queue.waitForExecuting(cellId: cellId1)
    #expect(started)  // Cell 1 should have started

    // Cell 1 should be executing (nil position means not pending)
    #expect(queue.queuePosition(for: cellId1) == nil)

    // Cell 2 should be at position 1
    #expect(queue.queuePosition(for: cellId2) == 1)

    // Cell 3 should be at position 2
    #expect(queue.queuePosition(for: cellId3) == 2)

    // Release all tasks to clean up
    queue.cancelAll()
    taskContinuation?.resume()
  }

  // MARK: - Cancellation

  @Test("Cancel specific task")
  func testCancelTask() async throws {
    var executedCellIds: [UUID] = []

    let queue = ExecutionQueue { task in
      executedCellIds.append(task.cellId)
      return nil
    }

    let cellId1 = UUID()
    let cellId2 = UUID()
    let cellId3 = UUID()

    queue.enqueue(cellId: cellId1, query: "SELECT 1")
    queue.enqueue(cellId: cellId2, query: "SELECT 2")
    queue.enqueue(cellId: cellId3, query: "SELECT 3")

    // Cancel second task immediately (before it executes)
    queue.cancel(cellId: cellId2)

    // Wait for task2 to be cancelled
    let state2 = await queue.waitForTask(cellId: cellId2)
    #expect(state2 == .cancelled)

    // Wait for queue to complete
    await queue.waitForIdle()

    // Verify cell2 was not executed
    #expect(!executedCellIds.contains(cellId2))

    // Cell1 and Cell3 should have executed
    #expect(executedCellIds.contains(cellId1))
    #expect(executedCellIds.contains(cellId3))
  }

  @Test("Cancel all tasks")
  func testCancelAll() async throws {
    var executedCellIds: [UUID] = []

    // Use a continuation to block execution
    var blockContinuation: CheckedContinuation<Void, Never>?

    let queue = ExecutionQueue { task in
      // Block first task so we can cancel before others run
      if executedCellIds.isEmpty {
        await withCheckedContinuation { continuation in
          blockContinuation = continuation
        }
      }
      executedCellIds.append(task.cellId)
      return nil
    }

    let cellId1 = UUID()
    let cellId2 = UUID()
    let cellId3 = UUID()

    queue.enqueue(cellId: cellId1, query: "SELECT 1")
    queue.enqueue(cellId: cellId2, query: "SELECT 2")
    queue.enqueue(cellId: cellId3, query: "SELECT 3")

    // Give queue time to start first task
    try await Task.sleep(for: .milliseconds(10))

    // Cancel all
    queue.cancelAll()

    // Release the blocked task
    blockContinuation?.resume()

    // All tasks should be cancelled
    for task in queue.tasks {
      #expect(task.state == .cancelled)
    }

    // No tasks should have completed execution (first was blocked, others cancelled)
    #expect(executedCellIds.isEmpty)
  }

  @Test(
    "A run stopped by cancelAll never cancels cells enqueued after it (Cancel then re-run)",
    .timeLimit(.minutes(1)))
  func testCancelledRunDoesNotTouchLaterWork() async throws {
    let first = UUID()
    let second = UUID()
    let third = UUID()
    var releaseFirst: CheckedContinuation<Void, Never>?
    var releaseSecond: CheckedContinuation<Void, Never>?
    var executed: [UUID] = []
    let done = CellResult.errorResult("done")

    let queue = ExecutionQueue { task in
      if task.cellId == first {
        await withCheckedContinuation { releaseFirst = $0 }
      } else if task.cellId == second {
        await withCheckedContinuation { releaseSecond = $0 }
      }
      executed.append(task.cellId)
      return done
    }

    // The first cell's statement is still being cancelled on the server
    queue.enqueue(cellId: first, query: "SELECT pg_sleep(30)")
    #expect(await queue.waitForExecuting(cellId: first))
    while releaseFirst == nil { await Task.yield() }
    queue.cancelAll()

    // The user runs again meanwhile
    queue.enqueue(cellId: second, query: "SELECT 2")
    #expect(await queue.waitForExecuting(cellId: second))
    while releaseSecond == nil { await Task.yield() }
    queue.enqueue(cellId: third, query: "SELECT 3")

    // The cancelled statement returns: its run must stop, not pick up the third cell
    releaseFirst?.resume()
    try await Task.sleep(for: .milliseconds(100))
    releaseSecond?.resume()

    let state = await queue.waitForTask(cellId: third)
    #expect(state == .completed(done), "got \(String(describing: state))")
    #expect(executed.contains(third))
    #expect(queue.tasks.first { $0.cellId == first }?.state == .cancelled)
  }

  @Test(
    "cancelPending cancels the queued tasks only: the executing one completes",
    .timeLimit(.minutes(1)))
  func testCancelPending() async throws {
    let first = UUID()
    let second = UUID()
    let third = UUID()
    var releaseFirst: CheckedContinuation<Void, Never>?
    var executed: [UUID] = []
    let done = CellResult.errorResult("done")

    let queue = ExecutionQueue { task in
      if task.cellId == first {
        await withCheckedContinuation { releaseFirst = $0 }
      }
      executed.append(task.cellId)
      return done
    }

    queue.enqueue(cellId: first, query: "SELECT 1")
    queue.enqueue(cellId: second, query: "SELECT 2")
    queue.enqueue(cellId: third, query: "SELECT 3")
    #expect(await queue.waitForExecuting(cellId: first))
    while releaseFirst == nil { await Task.yield() }

    #expect(queue.cancelPending() == 2)
    #expect(queue.isExecuting(cellId: first))
    #expect(await queue.waitForTask(cellId: second) == .cancelled)
    #expect(await queue.waitForTask(cellId: third) == .cancelled)

    releaseFirst?.resume()
    let state = await queue.waitForTask(cellId: first)
    #expect(state == .completed(done), "got \(String(describing: state))")
    await queue.waitForIdle()
    #expect(executed == [first])
    #expect(queue.cancelPending() == 0)
  }

  // MARK: - State Tracking

  @Test("isExecuting returns correct state")
  func testIsExecuting() async throws {
    var taskContinuation: CheckedContinuation<Void, Never>?

    let queue = ExecutionQueue { _ in
      // Block so we can verify from outside
      await withCheckedContinuation { continuation in
        taskContinuation = continuation
      }
      return nil
    }

    let cellId = UUID()

    // Not executing before enqueue
    #expect(!queue.isExecuting(cellId: cellId))

    queue.enqueue(cellId: cellId, query: "SELECT 1")

    // Wait for task to start executing
    let started = await queue.waitForExecuting(cellId: cellId)
    #expect(started)

    // Should be executing now
    #expect(queue.isExecuting(cellId: cellId))

    // The task is marked executing before its body runs: wait until it is blocked, then release
    while taskContinuation == nil { await Task.yield() }
    taskContinuation?.resume()

    // Wait for completion
    await queue.waitForIdle()

    // Should no longer be executing
    #expect(!queue.isExecuting(cellId: cellId))
  }

  // MARK: - Clear Completed

  // MARK: - waitForTask Tests

  // MARK: - ExecutionState Tests
}
