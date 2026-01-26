//
//  ExecutionQueueTests.swift
//  SQLNotebookTests
//
//  Tests for the ExecutionQueue system
//  Uses async waitForIdle() and waitForTask() methods for reliable testing
//  without race conditions or timing dependencies.
//

import Foundation
import Testing

@testable import SQLNotebook

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

    // Release the task
    taskContinuation?.resume()

    // Wait for completion
    await queue.waitForIdle()

    // Should no longer be executing
    #expect(!queue.isExecuting(cellId: cellId))
  }

  @Test("isInQueue returns correct state")
  func testIsInQueue() async throws {
    let queue = ExecutionQueue { _ in
      return nil
    }

    let cellId = UUID()

    // Not in queue initially
    #expect(!queue.isInQueue(cellId: cellId))

    queue.enqueue(cellId: cellId, query: "SELECT 1")

    // Should be in queue
    #expect(queue.isInQueue(cellId: cellId))

    // Wait for completion
    await queue.waitForIdle()

    // Clear completed tasks
    queue.clearCompleted()

    // Should no longer be in queue
    #expect(!queue.isInQueue(cellId: cellId))
  }

  // MARK: - Clear Completed

  @Test("Clear completed tasks")
  func testClearCompleted() async throws {
    let queue = ExecutionQueue { _ in
      return nil
    }

    let cellId1 = UUID()
    let cellId2 = UUID()

    queue.enqueue(cellId: cellId1, query: "SELECT 1")
    queue.enqueue(cellId: cellId2, query: "SELECT 2")

    // Wait for all executions to complete
    await queue.waitForIdle()

    // Tasks should be in queue (completed)
    #expect(queue.tasks.count == 2)

    // Clear completed
    queue.clearCompleted()

    // Queue should be empty
    #expect(queue.tasks.count == 0)
  }

  // MARK: - waitForTask Tests

  @Test("waitForTask returns final state on completion")
  func testWaitForTaskCompletion() async throws {
    let dummyResult = CellResult.errorResult("test")

    let queue = ExecutionQueue { _ in
      return dummyResult
    }

    let cellId = UUID()
    queue.enqueue(cellId: cellId, query: "SELECT 1")

    // Wait for task to complete
    let state = await queue.waitForTask(cellId: cellId)

    // Should be completed
    #expect(state == .completed(dummyResult))
  }

  @Test("waitForTask returns cancelled state when cancelled")
  func testWaitForTaskCancelled() async throws {
    var blockContinuation: CheckedContinuation<Void, Never>?

    let queue = ExecutionQueue { _ in
      await withCheckedContinuation { continuation in
        blockContinuation = continuation
      }
      return nil
    }

    let cellId = UUID()
    queue.enqueue(cellId: cellId, query: "SELECT 1")

    // Give queue time to start
    try await Task.sleep(for: .milliseconds(10))

    // Cancel the task
    queue.cancel(cellId: cellId)

    // Release blocked continuation
    blockContinuation?.resume()

    // waitForTask should return cancelled
    let state = await queue.waitForTask(cellId: cellId)
    #expect(state == .cancelled)
  }

  @Test("waitForTask returns nil for unknown cell")
  func testWaitForTaskUnknown() async throws {
    let queue = ExecutionQueue { _ in
      return nil
    }

    let unknownId = UUID()
    let state = await queue.waitForTask(cellId: unknownId)

    #expect(state == nil)
  }

  // MARK: - ExecutionState Tests

  @Test("ExecutionState isTerminal property")
  func testExecutionStateIsTerminal() {
    #expect(!ExecutionState.pending.isTerminal)
    #expect(!ExecutionState.executing.isTerminal)
    #expect(ExecutionState.cancelled.isTerminal)
    #expect(ExecutionState.failed("error").isTerminal)

    let dummyResult = CellResult.errorResult("test")
    #expect(ExecutionState.completed(dummyResult).isTerminal)
  }

  @Test("ExecutionState equality")
  func testExecutionStateEquality() {
    #expect(ExecutionState.pending == ExecutionState.pending)
    #expect(ExecutionState.executing == ExecutionState.executing)
    #expect(ExecutionState.cancelled == ExecutionState.cancelled)
    #expect(ExecutionState.failed("error") == ExecutionState.failed("error"))
    #expect(ExecutionState.failed("error1") != ExecutionState.failed("error2"))

    // Completed states are equal regardless of result content
    let result1 = CellResult.errorResult("test1")
    let result2 = CellResult.errorResult("test2")
    #expect(ExecutionState.completed(result1) == ExecutionState.completed(result2))

    // Different states should not be equal
    #expect(ExecutionState.pending != ExecutionState.executing)
    #expect(ExecutionState.pending != ExecutionState.cancelled)
  }

  // MARK: - ExecutionTask Tests

  @Test("ExecutionTask initialization")
  func testExecutionTaskInit() {
    let cellId = UUID()
    let query = "SELECT * FROM users"
    let task = ExecutionTask(cellId: cellId, query: query)

    #expect(task.cellId == cellId)
    #expect(task.query == query)
    #expect(task.state == .pending)
  }

  @Test("ExecutionTask state can be changed")
  func testExecutionTaskStateChange() {
    let cellId = UUID()
    var task = ExecutionTask(cellId: cellId, query: "SELECT 1")

    #expect(task.state == .pending)

    task.state = .executing
    #expect(task.state == .executing)

    task.state = .cancelled
    #expect(task.state == .cancelled)
  }
}
