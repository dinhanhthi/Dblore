// AggregationBuilderModel.swift
// The aggregation builder's state: one collection and an ordered list of stages (operator and
// relaxed-JSON body), per-stage errors, previews of each enabled prefix sent through the gate
// under a read-only policy (never past a `$out`/`$merge` stage), results cached per prefix
// text, the aggregate options (collation, maxTimeMS), the Text mode (the whole pipeline as one
// mongosh array, disabled stages as `//` lines), and the effective pipeline: the `aggregate` of
// the enabled stages and options that Insert as Cell, Copy, Explain, Run and Export use (in Text
// mode, those of the text). Run and Export Data send that pipeline through the gate read-only,
// never one that writes (`$out`/`$merge`); Export Data renders the documents off the main actor
// and saves them as JSON or CSV. A saved pipeline restores its stages, collation and maxTimeMS.
// A builder opens empty on a collection or from a cell holding exactly one `aggregate`.

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

  /// The effective pipeline as one `aggregate`, or why an action cannot use it.
  enum PipelineTarget {
    case success(MongoCommand)
    case blocked(String)

    var command: MongoCommand? {
      if case .success(let command) = self { command } else { nil }
    }

    var reason: String? {
      if case .blocked(let reason) = self { reason } else { nil }
    }
  }

  /// The last Run of the whole pipeline.
  enum RunState {
    case idle
    case running
    /// The result and the `aggregate` text the run sent (before the gate's row cap)
    case done(QueryResult, command: String)
    /// Refused before sending (with the reason) or failed on the server
    case failed(String)
  }

  /// The file Export Data writes.
  enum DataExportFormat {
    case json
    case csv

    var fileExtension: String {
      switch self {
      case .json: "json"
      case .csv: "csv"
      }
    }
  }

  /// The last Export Data of the whole pipeline.
  enum ExportState {
    case idle
    /// Reading and rendering the documents, or the save panel is open
    case running(DataExportFormat)
    /// Refused before sending (with the reason) or failed on the server
    case failed(String)
    /// The file is saved; `note` says when it holds only the first documents
    case finished(note: String?)
  }

  /// How the pipeline is edited: one editor per stage, or the whole pipeline as text.
  enum EditMode {
    case stages
    case text
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
  /// The aggregate options as typed. Only `collation` and `maxTimeMS` are used: the other
  /// fields stay blank and are never sent.
  var options = MongoQueryOptions()
  private(set) var editMode = EditMode.stages
  /// The pipeline as text in Text mode, written by `showText()`. An edit clears `textError`.
  var pipelineText = "" {
    didSet { textError = nil }
  }
  /// Why the text is not a pipeline, set when `showStages()` refuses it
  private(set) var textError: String?
  /// The text `showText()` wrote: while `pipelineText` still equals it, the stages stand as is
  @ObservationIgnored private var writtenText = ""
  /// Preview results by preview command text (the prefix "hash"): an edit to a stage changes
  /// the text of its own and every later preview, so those miss the cache.
  private var results: [String: QueryResult] = [:]
  private var failures: [String: String] = [:]
  /// Running previews by command text; the token tells a restarted preview from a cancelled one
  private var inFlight: [String: (token: UUID, task: Task<Void, Never>)] = [:]
  private(set) var runState = RunState.idle
  /// Whether the results pane shows the Run result rather than a stage preview: set by `run`,
  /// cleared by `preview(_:)`. The views own the stage selection and clear it on a selection.
  var showsRunResults = false
  @ObservationIgnored private var runTask: Task<Void, Never>?
  private(set) var exportState = ExportState.idle
  @ObservationIgnored private var exportTask: Task<Void, Never>?
  /// The export the save panel answers for: a cancelled or superseded one never sets the state
  @ObservationIgnored private var exportToken: UUID?
  @ObservationIgnored private let connectionManager: DatabaseConnectionManager

  init(collection: String, connectionManager: DatabaseConnectionManager) {
    self.collection = collection
    self.connectionManager = connectionManager
  }

  /// A builder holding the stages, collation and maxTimeMS of an `aggregate` command, nil for
  /// any other command or when a pipeline element is not a one-key document (see `stages(from:)`).
  convenience init?(command: MongoCommand, connectionManager: DatabaseConnectionManager) {
    guard case .aggregate(let collection, _, let cursor) = command,
      let stages = Self.stages(from: command)
    else { return nil }
    self.init(collection: collection, connectionManager: connectionManager)
    for stage in stages { addStage(operator: stage.operator, body: stage.body) }
    options.collation = cursor.collation.map { MongoRelaxedJSON.render($0, as: .mongosh) } ?? ""
    options.maxTimeMS = cursor.maxTimeMS.map(String.init) ?? ""
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
  /// `stages(from:)`), nil otherwise. Nil too for an aggregate with a hint: the builder holds
  /// only collation and maxTimeMS, so its whole-cell Insert would drop the hint.
  nonisolated static func aggregateCommand(in text: String) -> MongoCommand? {
    let pieces = MongoshSplitter.split(text)
    guard pieces.count == 1, let command = try? MongoshParser.parse(pieces[0]),
      case .aggregate(_, _, let options) = command, options.hint == nil,
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

  // MARK: - Effective pipeline

  /// The `aggregate` of the enabled stages (`$out`/`$merge` included, no preview limit) with
  /// the collation and maxTimeMS options, or why there is none: no enabled stage, a stage
  /// error, or an option that does not parse. `verb` names the action in the reason.
  /// In Text mode, the stages and options of the edited text, blocked when it is not a pipeline.
  func pipeline(verb: String) -> PipelineTarget {
    let draft: Draft
    switch self.draft() {
    case .success(let value): draft = value
    case .failure(let error): return .blocked(error.message)
    }
    guard draft.stages.contains(where: \.isEnabled) else {
      return .blocked("Add an enabled stage to \(verb)")
    }
    return effectivePipeline(draft, verb: verb)
  }

  /// `pipeline(verb: "explain")`, also blocked when a stage writes (`$out`, `$merge`: the
  /// gate's classifier decides): such a pipeline is never explained.
  var explainTarget: PipelineTarget {
    readTarget(verb: "explain", refusal: "explained")
  }

  /// `pipeline(verb: "run")`, also blocked when a stage writes, as `explainTarget` is.
  var runTarget: PipelineTarget {
    readTarget(verb: "run", refusal: "run")
  }

  /// `pipeline(verb: "export")`, also blocked when a stage writes, as `explainTarget` is.
  var exportTarget: PipelineTarget {
    readTarget(verb: "export", refusal: "exported")
  }

  /// `pipeline(verb:)`, blocked when the gate's classifier does not read it as a read.
  private func readTarget(verb: String, refusal: String) -> PipelineTarget {
    let target = pipeline(verb: verb)
    guard case .success(let command) = target else { return target }
    guard MongoCommandClassifier.classifyStatement(command.render())?.kind == .read else {
      return .blocked("A stage writes data ($out or $merge): such a pipeline is not \(refusal)")
    }
    return target
  }

  /// `pipeline(verb:)` without the enabled-stage check: no enabled stage is an empty pipeline.
  private func effectivePipeline(_ draft: Draft, verb: String) -> PipelineTarget {
    var pipeline: [MongoValue] = []
    for stage in draft.stages where stage.isEnabled {
      guard case .success(let value) = Self.value(of: stage) else {
        return .blocked("Fix the stage errors to \(verb) the pipeline")
      }
      pipeline.append(value)
    }
    let parsed: MongoQueryOptions.Parsed
    do {
      parsed = try draft.options.parsed()
    } catch {
      return .blocked(error.localizedDescription)
    }
    // Only collation and maxTimeMS are aggregate options of the builder
    let cursor = MongoCommand.CursorOptions(
      collation: parsed.cursor.collation, maxTimeMS: parsed.cursor.maxTimeMS)
    return .success(
      MongoCommand.aggregate(collection: collection, pipeline: pipeline, options: cursor))
  }

  // MARK: - Text mode

  /// The stages and options an action uses.
  private struct Draft {
    var stages: [Stage]
    var options: MongoQueryOptions
  }

  /// The builder's stages and options, or in Text mode those of the text once it is edited.
  private func draft() -> Result<Draft, StageError> {
    guard editMode == .text, pipelineText != writtenText else {
      return .success(Draft(stages: stages, options: options))
    }
    return textDraft()
  }

  /// Writes the stages as text, one per line, and switches to Text.
  func showText() {
    pipelineText = Self.text(of: stages)
    writtenText = pipelineText
    editMode = .text
  }

  /// Switches to Stages. An unchanged text keeps the stages as they are; an edited one replaces
  /// them (new ids) and sets the collation and maxTimeMS it holds. False, staying in Text with
  /// `textError` set, when the text is not a pipeline.
  @discardableResult
  func showStages() -> Bool {
    guard editMode == .text else { return true }
    if pipelineText != writtenText {
      switch textDraft() {
      case .failure(let error):
        textError = error.message
        return false
      case .success(let draft):
        stages = draft.stages
        options = draft.options
        cancelStalePreviews()
      }
    }
    textError = nil
    editMode = .stages
    return true
  }

  /// The text formatted for Text mode's Format button: a stage array, a stage on one line when
  /// it fits 80 columns, else one key per line (comments inside stages are dropped). The text's
  /// collation and maxTimeMS move to `options`, so the array runs as the text did. Nil, with
  /// `textError` set, when the text is not a pipeline.
  func format() -> String? {
    switch textDraft() {
    case .failure(let error):
      textError = error.message
      return nil
    case .success(let draft):
      options = draft.options
      guard !draft.stages.isEmpty else { return "" }
      let lines = draft.stages.map { stage in
        guard stage.isEnabled, let body = try? MongoRelaxedJSON.parse(stage.body) else {
          return Self.line(of: stage)
        }
        let document = MongoValue.document([.init(stage.operator, body)])
        let inline = "  " + MongoRelaxedJSON.render(document, as: .mongosh)
        guard inline.count > 80 else { return inline }
        return MongoRelaxedJSON.render(document, as: .mongosh, indented: true)
          .components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n")
      }
      return "[\n" + lines.joined(separator: ",\n") + "\n]"
    }
  }

  /// The stages as `AIMongoAssist.pipelineText` writes them, a disabled stage as a `// ` line
  /// with its body on one line; `""` for no stages.
  private static func text(of stages: [Stage]) -> String {
    guard !stages.isEmpty else { return "" }
    return "[\n" + stages.map(line(of:)).joined(separator: ",\n") + "\n]"
  }

  /// One stage of `text(of:)`. A body whose last line has a `//` comment closes on the next
  /// line, so the comment cannot swallow the closing brace and comma.
  private static func line(of stage: Stage) -> String {
    guard stage.isEnabled else { return "  // { \(stage.operator): \(oneLine(stage.body)) }" }
    let lastLine = stage.body.components(separatedBy: .newlines).last ?? ""
    return lastLine.contains("//")
      ? "  { \(stage.operator): \(stage.body)\n  }" : "  { \(stage.operator): \(stage.body) }"
  }

  /// `body` on one line: rendered again when it parses, else its lines joined by spaces.
  private static func oneLine(_ body: String) -> String {
    guard body.contains(where: \.isNewline) else { return body }
    if let value = try? MongoRelaxedJSON.parse(body) {
      return MongoRelaxedJSON.render(value, as: .mongosh)
    }
    return body.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  /// The stages and options of `pipelineText`: a stage array or a `db.<c>.aggregate([...], {...})`
  /// (its collation and maxTimeMS replace the builder's), `// { $op: body }` lines between
  /// stages as disabled stages in place. Blank text is no stage.
  private func textDraft() -> Result<Draft, StageError> {
    var draft = Draft(stages: [], options: options)
    // A pasted reply loses its code fence once, for the parse and the disabled lines alike
    let text = AIMongoAssist.unfenced(pipelineText)
    guard !text.isEmpty else {
      return .success(draft)
    }
    let parsed:
      (
        collection: String, stages: [AIMongoAssist.GeneratedStage],
        options: MongoCommand.CursorOptions
      )
    do {
      parsed = try AIMongoAssist.aggregate(fromReply: text, collection: collection)
    } catch {
      return .failure(StageError(message: error.localizedDescription, offset: nil))
    }
    guard parsed.collection == collection else {
      return .failure(
        StageError(
          message: "This builder runs on \(collection): the text names \(parsed.collection)",
          offset: nil))
    }
    // The builder holds only collation and maxTimeMS (as `aggregateCommand(in:)` refuses hints)
    guard parsed.options.hint == nil else {
      return .failure(
        StageError(
          message: "The builder keeps only the collation and maxTimeMS options: remove the hint",
          offset: nil))
    }
    draft.stages = parsed.stages.map {
      Stage(id: UUID(), operator: $0.operator, body: $0.body, isEnabled: true)
    }
    for (offset, found) in disabledStages(in: text).enumerated() {
      draft.stages.insert(found.stage, at: found.enabledBefore + offset)
    }
    if let collation = parsed.options.collation {
      draft.options.collation = MongoRelaxedJSON.render(collation, as: .mongosh)
    }
    if let maxTimeMS = parsed.options.maxTimeMS { draft.options.maxTimeMS = String(maxTimeMS) }
    return .success(draft)
  }

  /// The `// { $op: body }` lines of `text` that sit between stages (the text before the line,
  /// closed with `]` or `])`, is a pipeline), in order, with the number of stages before each.
  /// Such a line anywhere else (inside a stage, before the array) is only a comment.
  private func disabledStages(in text: String) -> [(enabledBefore: Int, stage: Stage)] {
    let lines = text.components(separatedBy: "\n")
    let isCall = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("db.")
    var found: [(enabledBefore: Int, stage: Stage)] = []
    for (index, line) in lines.enumerated() {
      guard let stage = Self.disabledStage(in: line) else { continue }
      // On its own line, so a `//` comment ending the line before cannot swallow it
      let prefix = lines[..<index].joined(separator: "\n") + (isCall ? "\n])" : "\n]")
      guard let before = try? AIMongoAssist.aggregate(fromReply: prefix, collection: collection)
      else { continue }
      found.append((before.stages.count, stage))
    }
    return found
  }

  /// The disabled stage of a `// { $op: body }` line (a trailing comma allowed), nil for any
  /// other line. A body that does not parse is kept as written.
  private static func disabledStage(in line: String) -> Stage? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("//") else { return nil }
    var content = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
    if content.hasSuffix(",") {
      content = content.dropLast().trimmingCharacters(in: .whitespaces)
    }
    guard content.hasPrefix("{"), content.hasSuffix("}") else { return nil }
    if case .document(let fields)? = try? MongoRelaxedJSON.parse(content), fields.count == 1 {
      let body = MongoRelaxedJSON.render(fields[0].value, as: .mongosh)
      return Stage(id: UUID(), operator: fields[0].key, body: body, isEnabled: false)
    }
    // As written: the operator up to the first colon, the body up to the closing brace
    let inner = content.dropFirst().dropLast()
    guard let colon = inner.firstIndex(of: ":") else { return nil }
    let name = inner[..<colon].trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { return nil }
    let body = inner[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    return Stage(id: UUID(), operator: name, body: body, isEnabled: false)
  }

  // MARK: - Insert and Copy

  /// The full `aggregate` with its options for Insert, Copy and Open in Query (an empty
  /// pipeline when no stage is enabled), nil while a stage or an option has an error.
  var commandText: String? {
    guard case .success(let draft) = draft() else { return nil }
    return effectivePipeline(draft, verb: "copy").command?.render()
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
    showsRunResults = false
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

  // MARK: - Run

  /// Runs `runTarget` through the gate with a read-only policy, at most `maxRows` documents,
  /// dropping a run in flight, and shows the run results. Nil, nothing sent, when the pipeline
  /// is blocked or writes (`runState` is `.failed` with the reason). A cancelled or superseded
  /// run never writes its result.
  @discardableResult
  func run(maxRows: Int) -> Task<Void, Never>? {
    cancelRun()
    showsRunResults = true
    let command: MongoCommand
    switch runTarget {
    case .success(let value): command = value
    case .blocked(let reason):
      runState = .failed(reason)
      return nil
    }
    runState = .running
    let text = command.render()
    let manager = connectionManager
    let task = Task { [weak self] in
      let state: RunState
      do {
        let result = try await manager.execute(
          userSQL: text, policy: ProtectionPolicy(protectionLevel: .readOnly), maxRows: maxRows)
        try Task.checkCancellation()
        state = .done(result, command: text)
      } catch {
        state = .failed(error.localizedDescription)
      }
      guard !Task.isCancelled, let self else { return }
      self.runState = state
      self.runTask = nil
    }
    runTask = task
    return task
  }

  /// Drops the run in flight; nothing is shown for it.
  func cancelRun() {
    runTask?.cancel()
    runTask = nil
    if case .running = runState { runState = .idle }
  }

  // MARK: - Export Data

  /// The most documents Export Data writes: the session row cap's upper bound.
  static let exportDocumentLimit = SessionBrakeLimits.rowCapRange.upperBound

  /// Reads the documents of `exportTarget` through the gate with a read-only policy (at most
  /// `exportDocumentLimit`), renders them as `format` off the main actor, then asks where to save
  /// them (`<collection>.json` / `.csv`), dropping an export in flight. Nil, nothing sent, when
  /// the pipeline is blocked or writes (`exportState` is `.failed` with the reason). A cancelled
  /// or superseded export never writes its state; a cancelled save panel goes back to idle.
  @discardableResult
  func exportData(_ format: DataExportFormat) -> Task<Void, Never>? {
    cancelExport()
    let command: MongoCommand
    switch exportTarget {
    case .success(let value): command = value
    case .blocked(let reason):
      exportState = .failed(reason)
      return nil
    }
    exportState = .running(format)
    let text = command.render()
    let manager = connectionManager
    let filename = "\(collection).\(format.fileExtension)"
    let token = UUID()
    exportToken = token
    let task = Task { [weak self] in
      let content: String
      let truncated: Bool
      do {
        let read = try await manager.executeMongoDocuments(
          userSQL: text, policy: ProtectionPolicy(protectionLevel: .readOnly),
          maxRows: Self.exportDocumentLimit)
        try Task.checkCancellation()
        let documents = read.documents
        content = await Task.detached(priority: .userInitiated) {
          Self.render(documents, as: format)
        }.value
        try Task.checkCancellation()
        truncated = read.truncated
      } catch {
        guard !Task.isCancelled, let self, self.exportToken == token else { return }
        self.exportState = .failed(error.localizedDescription)
        self.exportTask = nil
        return
      }
      guard !Task.isCancelled, let self, self.exportToken == token else { return }
      self.exportTask = nil
      DataExporter.saveFile(
        content: content, defaultFilename: filename, allowedFileTypes: [format.fileExtension]
      ) { [weak self] saved in
        guard let self, self.exportToken == token else { return }
        self.exportToken = nil
        let note = "Exported the first \(Self.exportDocumentLimit.formatted()) documents"
        self.exportState = saved ? .finished(note: truncated ? note : nil) : .idle
      }
    }
    exportTask = task
    return task
  }

  /// Drops the export in flight; nothing is saved or shown for it.
  func cancelExport() {
    exportTask?.cancel()
    exportTask = nil
    exportToken = nil
    if case .running = exportState { exportState = .idle }
  }

  /// The documents as indented relaxed Extended JSON (one array), or as CSV with one column per
  /// top-level field (`MongoBSONMapping`).
  nonisolated private static func render(
    _ documents: [MongoValue], as format: DataExportFormat
  ) -> String {
    switch format {
    case .json:
      return MongoRelaxedJSON.render(.array(documents), as: .relaxedExtendedJSON, indented: true)
    case .csv:
      let columns = MongoBSONMapping.columns(for: documents)
      let rows = documents.map { MongoBSONMapping.row(for: $0, columns: columns) }
      return DataExporter.toCSV(
        result: CellResult(columns: columns, rows: rows, rowCount: rows.count))
    }
  }

  // MARK: - Saved pipelines

  /// The stages as a saved pipeline holds them. In Text mode, call `showStages()` first.
  func savedStages() -> [SavedMongoPipeline.Stage] {
    stages.map { .init(operator: $0.operator, body: $0.body, isEnabled: $0.isEnabled) }
  }

  /// Replaces the stages (new ids, `isEnabled` kept) and options with those of `saved`, of
  /// which only collation and maxTimeMS are kept, in Stages mode (the text is dropped unparsed),
  /// with no run result.
  func restore(_ saved: SavedMongoPipeline) {
    stages = saved.stages.map {
      Stage(id: UUID(), operator: $0.operator, body: $0.body, isEnabled: $0.isEnabled)
    }
    var restored = MongoQueryOptions()
    restored.collation = saved.options.collation
    restored.maxTimeMS = saved.options.maxTimeMS
    options = restored
    editMode = .stages
    textError = nil
    cancelRun()
    cancelExport()
    runState = .idle
    showsRunResults = false
    cancelStalePreviews()
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
