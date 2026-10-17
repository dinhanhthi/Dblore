// AggregationBuilderModel.swift
// The aggregation builder's state: one collection and an ordered list of stages (operator and
// relaxed-JSON body), per-stage errors, previews of each enabled prefix sent through the gate
// under a read-only policy (never past a `$out`/`$merge` stage), results cached per prefix
// text, and the rendered `aggregate` command for Insert as Cell and Copy. A builder opens empty
// on a collection or from a cell holding exactly one `aggregate` command.

import AppKit
import Foundation
import Observation

/// `Identifiable` by object identity, so a sheet can present a builder (`sheet(item:)`).
@MainActor
@Observable
final class AggregationBuilderModel: Identifiable {
  struct Stage: Identifiable, Equatable {
    let id: UUID
    /// The stage operator, e.g. `$match`
    var `operator`: String
    /// Relaxed JSON (mongosh notation) of the operator's value
    var body: String
    var isEnabled: Bool
  }

  /// Why a stage cannot be used. `offset` (UTF-16 units into the body) is set for parse errors.
  struct StageError: Error, Equatable, LocalizedError {
    let message: String
    let offset: Int?

    var errorDescription: String? {
      offset.map { "\(message) (offset \($0))" } ?? message
    }
  }

  /// The value a stage operator takes.
  enum BodyKind: Equatable {
    case document
    case integer
    case string
    case stringOrDocument
    case stringOrArray
    /// An aggregation expression: any value
    case expression
  }

  enum PreviewState {
    /// The stage is switched off
    case disabled
    /// The stage or an earlier enabled one writes (`$out`/`$merge`): never sent
    case writesData
    /// The stage or an earlier enabled one has an error
    case invalid(String)
    /// Previewable, not run yet
    case notRun
    case loading
    case loaded(QueryResult)
    case failed(String)

    /// The text shown instead of a result, nil while loading, not run or loaded.
    var message: String? {
      switch self {
      case .disabled: "not previewed (disabled)"
      case .writesData: "not previewed (writes data)"
      case .invalid(let message), .failed(let message): message
      case .notRun, .loading, .loaded: nil
      }
    }

    var result: QueryResult? {
      if case .loaded(let result) = self { result } else { nil }
    }

    var isDisabled: Bool {
      if case .disabled = self { true } else { false }
    }
  }

  /// Documents a preview shows: the `{$limit: 20}` stage appended to each preview prefix.
  nonisolated static let previewLimit: Int32 = 20

  /// Operators whose value is not a document. Any other `$` operator takes a document.
  static let bodyKinds: [String: BodyKind] = [
    "$limit": .integer, "$skip": .integer, "$count": .string,
    "$unwind": .stringOrDocument, "$out": .stringOrDocument, "$merge": .stringOrDocument,
    "$unionWith": .stringOrDocument, "$unset": .stringOrArray,
    "$replaceWith": .expression, "$sortByCount": .expression,
  ]

  let collection: String
  private(set) var stages: [Stage] = []
  /// Preview results by preview command text (the prefix "hash"): an edit to a stage changes
  /// the text of its own and every later preview, so those miss the cache.
  private var results: [String: QueryResult] = [:]
  private var failures: [String: String] = [:]
  /// Running previews by command text; the token tells a restarted preview from a cancelled one
  private var inFlight: [String: (token: UUID, task: Task<Void, Never>)] = [:]
  @ObservationIgnored private let connectionManager: DatabaseConnectionManager

  init(collection: String, connectionManager: DatabaseConnectionManager) {
    self.collection = collection
    self.connectionManager = connectionManager
  }

  /// A builder holding the stages of an `aggregate` command, nil for any other command or when
  /// a pipeline element is not a one-key document (see `stages(from:)`).
  convenience init?(command: MongoCommand, connectionManager: DatabaseConnectionManager) {
    guard case .aggregate(let collection, _, _) = command,
      let stages = Self.stages(from: command)
    else { return nil }
    self.init(collection: collection, connectionManager: connectionManager)
    for stage in stages { addStage(operator: stage.operator, body: stage.body) }
  }

  /// Operator and mongosh-notation body of each stage of an `aggregate` command. Nil for any
  /// other command or when an element is not a document with exactly one key.
  nonisolated static func stages(
    from command: MongoCommand
  ) -> [(operator: String, body: String)]? {
    guard case .aggregate(_, let pipeline, _) = command else { return nil }
    var stages: [(operator: String, body: String)] = []
    for element in pipeline {
      guard case .document(let fields) = element, fields.count == 1 else { return nil }
      stages.append((fields[0].key, MongoRelaxedJSON.render(fields[0].value, as: .mongosh)))
    }
    return stages
  }

  /// The command of a mongosh cell that is exactly one `aggregate` the builder can open (see
  /// `stages(from:)`), nil otherwise. Nil too for an aggregate with options: the builder does
  /// not hold them yet, so its whole-cell Insert would drop them.
  nonisolated static func aggregateCommand(in text: String) -> MongoCommand? {
    let pieces = MongoshSplitter.split(text)
    guard pieces.count == 1, let command = try? MongoshParser.parse(pieces[0]),
      case .aggregate(_, _, let options) = command, options == .none,
      stages(from: command) != nil
    else { return nil }
    return command
  }

  /// Whether Insert from a builder opened on a cell may replace the cell's whole text: only
  /// when it is exactly one `aggregate` with no comments (conservatively, no `//` or `/*`
  /// anywhere), so no user text is deleted. Otherwise the command is appended below.
  nonisolated static func replacesWholeCell(_ text: String) -> Bool {
    !text.contains("//") && !text.contains("/*") && aggregateCommand(in: text) != nil
  }

  // MARK: - Editing

  @discardableResult
  func addStage(operator name: String = "$match", body: String = "{}") -> Stage.ID {
    let stage = Stage(id: UUID(), operator: name, body: body, isEnabled: true)
    stages.append(stage)
    return stage.id
  }

  func removeStage(_ id: Stage.ID) {
    stages.removeAll { $0.id == id }
    cancelStalePreviews()
  }

  /// Drops every current stage, disabled ones included, for the given ones, all enabled.
  func replaceStages(_ new: [AIMongoAssist.GeneratedStage]) {
    stages = new.map { Stage(id: UUID(), operator: $0.operator, body: $0.body, isEnabled: true) }
    cancelStalePreviews()
  }

  /// Same arguments as SwiftUI's `onMove`.
  func move(fromOffsets source: IndexSet, toOffset destination: Int) {
    let moving = source.map { stages[$0] }
    var rest = stages.enumerated().filter { !source.contains($0.offset) }.map(\.element)
    let insertAt = destination - source.count(in: 0..<destination)
    rest.insert(contentsOf: moving, at: insertAt)
    stages = rest
    cancelStalePreviews()
  }

  func setEnabled(_ enabled: Bool, for id: Stage.ID) {
    update(id) { $0.isEnabled = enabled }
  }

  func setOperator(_ name: String, for id: Stage.ID) {
    update(id) { $0.operator = name }
  }

  func setBody(_ body: String, for id: Stage.ID) {
    update(id) { $0.body = body }
  }

  private func update(_ id: Stage.ID, _ change: (inout Stage) -> Void) {
    guard let index = stages.firstIndex(where: { $0.id == id }) else { return }
    change(&stages[index])
    cancelStalePreviews()
  }

  // MARK: - Stage values

  /// The stage's error, nil when it is a valid `{<operator>: <body>}` stage.
  func error(for id: Stage.ID) -> StageError? {
    guard let stage = stages.first(where: { $0.id == id }) else { return nil }
    if case .failure(let error) = Self.value(of: stage) { return error }
    return nil
  }

  /// `{<operator>: <body>}`, or why not: the operator is not a `$` name, the body does not parse,
  /// or it is not the operator's body kind.
  static func value(of stage: Stage) -> Result<MongoValue, StageError> {
    let name = stage.operator.trimmingCharacters(in: .whitespaces)
    guard isOperatorName(name) else {
      return .failure(
        StageError(message: "The stage must be a $ operator, e.g. $match", offset: nil))
    }
    let body: MongoValue
    do {
      body = try MongoRelaxedJSON.parse(stage.body)
    } catch {
      return .failure(StageError(message: error.message, offset: error.offset))
    }
    let kind = bodyKinds[name] ?? .document
    guard accepts(kind, body) else {
      return .failure(
        StageError(message: "The \(name) value must be \(describe(kind))", offset: nil))
    }
    return .success(.document([MongoValue.Field(name, body)]))
  }

  /// `$` then an ASCII letter, then ASCII letters or digits.
  private static func isOperatorName(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    guard bytes.count >= 2, bytes[0] == 0x24 else { return false }
    let isLetter = { (byte: UInt8) in (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }
    return isLetter(bytes[1])
      && bytes.dropFirst(2).allSatisfy { isLetter($0) || (0x30...0x39).contains($0) }
  }

  private static func accepts(_ kind: BodyKind, _ value: MongoValue) -> Bool {
    switch (kind, value) {
    case (.expression, _), (.document, .document), (.integer, .int32), (.integer, .int64),
      (.string, .string), (.stringOrDocument, .string), (.stringOrDocument, .document),
      (.stringOrArray, .string), (.stringOrArray, .array):
      true
    default:
      false
    }
  }

  private static func describe(_ kind: BodyKind) -> String {
    switch kind {
    case .document: "a document, e.g. {a: 1}"
    case .integer: "an integer"
    case .string: "a string"
    case .stringOrDocument: "a string or a document"
    case .stringOrArray: "a string or an array"
    case .expression: "an expression"
    }
  }

  /// A stage that writes data: the classifier (the gate's own rule) does not read a one-stage
  /// `aggregate` of it as a read. Covers `$out`/`$merge` at any depth (sub-pipelines included).
  private func writes(_ stage: MongoValue) -> Bool {
    let text = MongoCommand.aggregate(collection: collection, pipeline: [stage]).render()
    return MongoCommandClassifier.classifyStatement(text)?.kind != .read
  }

  // MARK: - Insert and Copy

  /// The full `aggregate` of the enabled stages (`$out`/`$merge` included, no preview limit),
  /// nil while an enabled stage has an error.
  var commandText: String? {
    var pipeline: [MongoValue] = []
    for stage in stages where stage.isEnabled {
      guard case .success(let value) = Self.value(of: stage) else { return nil }
      pipeline.append(value)
    }
    return MongoCommand.aggregate(collection: collection, pipeline: pipeline).render()
  }

  /// Inserts `commandText` at the cursor of `viewModel`, as the sidebar does. False when there
  /// is nothing to insert or the tab has nowhere to insert it (`canInsertText`).
  @discardableResult
  func insert(into viewModel: NotebookViewModel) -> Bool {
    guard let text = commandText, viewModel.canInsertText else { return false }
    viewModel.insertTextIntoSelectedCell(text)
    return true
  }

  /// Copies `commandText`. False when there is nothing to copy.
  @discardableResult
  func copy() -> Bool {
    guard let text = commandText else { return false }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    return true
  }

  // MARK: - Preview

  private enum Plan {
    case command(String)
    case blocked(PreviewState)
  }

  /// The preview command of stage `id`: the enabled stages up to it, then `{$limit: 20}`.
  /// Blocked when the stage is off, when it or an earlier enabled stage writes, or has an error.
  private func plan(for id: Stage.ID) -> Plan {
    guard let index = stages.firstIndex(where: { $0.id == id }) else {
      return .blocked(.notRun)
    }
    guard stages[index].isEnabled else { return .blocked(.disabled) }
    let prefix = stages[...index].filter(\.isEnabled)
    let values = prefix.map(Self.value(of:))
    // Writing comes first: a write is never sent, whatever else is wrong
    for case .success(let value) in values where writes(value) {
      return .blocked(.writesData)
    }
    var pipeline: [MongoValue] = []
    for (stage, value) in zip(prefix, values) {
      switch value {
      case .success(let value):
        pipeline.append(value)
      case .failure(let error):
        guard stage.id != id else { return .blocked(.invalid(error.localizedDescription)) }
        let number = (stages.firstIndex { $0.id == stage.id } ?? 0) + 1
        return .blocked(.invalid("Stage \(number) has an error"))
      }
    }
    let limit = MongoValue.document([MongoValue.Field("$limit", .int32(Self.previewLimit))])
    return .command(
      MongoCommand.aggregate(collection: collection, pipeline: pipeline + [limit]).render())
  }

  /// The text a preview of stage `id` sends, nil when it is not previewed.
  func previewCommand(for id: Stage.ID) -> String? {
    if case .command(let text) = plan(for: id) { return text }
    return nil
  }

  func previewState(for id: Stage.ID) -> PreviewState {
    switch plan(for: id) {
    case .blocked(let state):
      return state
    case .command(let text):
      if let result = results[text] { return .loaded(result) }
      if inFlight[text] != nil { return .loading }
      if let message = failures[text] { return .failed(message) }
      return .notRun
    }
  }

  /// Runs the preview of stage `id` in a task (the main actor only waits on the manager).
  /// Nil, nothing sent, when it is not previewable or its result is cached; the running task
  /// when the same prefix is already in flight. A failure is shown and not cached.
  @discardableResult
  func preview(_ id: Stage.ID) -> Task<Void, Never>? {
    guard case .command(let text) = plan(for: id), results[text] == nil else { return nil }
    if let running = inFlight[text] { return running.task }
    failures[text] = nil
    let manager = connectionManager
    let token = UUID()
    let task = Task { [weak self] in
      let outcome: Result<QueryResult, any Error>
      do {
        outcome = .success(try await Self.runPreview(text, on: manager))
      } catch {
        outcome = .failure(error)
      }
      self?.finishPreview(text, token: token, outcome)
    }
    inFlight[text] = (token, task)
    return task
  }

  /// Sends a preview command through the gate with a read-only policy (never the connection's),
  /// so a write that got into it is refused before anything is sent.
  nonisolated static func runPreview(
    _ text: String, on manager: DatabaseConnectionManager
  ) async throws -> QueryResult {
    try await manager.execute(
      userSQL: text, policy: ProtectionPolicy(protectionLevel: .readOnly),
      maxRows: Int(previewLimit))
  }

  private func finishPreview(
    _ text: String, token: UUID, _ outcome: Result<QueryResult, any Error>
  ) {
    // A cancelled preview (its prefix was edited away) leaves no result and no error
    guard inFlight[text]?.token == token, !Task.isCancelled else { return }
    inFlight[text] = nil
    switch outcome {
    case .success(let result): results[text] = result
    case .failure(let error): failures[text] = error.localizedDescription
    }
  }

  /// Cancels in-flight previews whose command no stage would send any more.
  private func cancelStalePreviews() {
    let current = Set(stages.compactMap { previewCommand(for: $0.id) })
    for (text, running) in inFlight where !current.contains(text) {
      running.task.cancel()
      inFlight[text] = nil
    }
  }
}
