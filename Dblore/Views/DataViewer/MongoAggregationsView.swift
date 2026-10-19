//
//  MongoAggregationsView.swift
//  Dblore
//
//  Aggregations section of a MongoDB collection screen: the aggregation builder of the
//  collection (`AggregationBuilderBody`: stages or the pipeline as text, per-stage previews and
//  the results of a Run) under a header. Its left side holds icon buttons: AI, Copy, the Export
//  menu (driver code, or the documents through the export sheet), saved pipelines, the template
//  Wizard and the aggregate options, then a status line (why the pipeline is blocked).
//  Its right side holds the Stages | Text picker, Explain, Run, Open in Query and Create View
//  (`MongoViewEditorSheet` on this collection with the enabled stages; hidden when the tab is not
//  connected or its protection blocks schema changes). Previews and Run read through the gate with
//  a read-only policy (`AggregationBuilderModel`); Export Data streams through `MongoExportModel`.
//  A pipeline ending in `$out` / `$merge` swaps Run for "Run $out..." / "Run $merge..."
//  (`MongoAdminActionModel.requestPipelineWrite`; hidden, with the reason, when the connection's
//  rules refuse it); once written, the status line says "Wrote to <target>" with Show <target>.
//

import SwiftUI

struct MongoAggregationsView: View {
  let model: MongoCollectionModel
  /// The tab: connection, rules and history of Create View
  let viewModel: NotebookViewModel
  /// Opens a new query tab holding the command; nil disables Open in Query
  var openQuery: ((String) -> Void)? = nil
  /// The workspace's autocomplete source, for field names in stage bodies; nil = no completion
  var fieldSource: SQLAutocompleteProvider? = nil
  /// Database the exported driver code connects to
  var database: String = MongoSession.defaultDatabase
  var aiAssistant: AIAssistantViewModel? = nil
  /// The most documents a Run shows
  var runLimit: Int = 100
  /// Where the saved pipelines are kept
  var savedPipelineStore: SavedFilterStore
  /// The connection and collection the pipelines are saved for; nil disables saved pipelines
  var savedPipelineKey: String? = nil

  @State private var selectedStage: AggregationBuilderModel.Stage.ID?
  @State private var exportRequest: MongoExportCodeSheet.Request?
  @State private var showsOptions = false
  /// Create View: the command of the form opened last and the pipeline it starts from
  @State private var viewAction: MongoAdminActionModel?
  @State private var viewPipeline: [MongoValue] = []
  @State private var showsCreateView = false
  /// Run $out / $merge: the action of the last write and the collection it writes to
  @State private var writeAction: MongoAdminActionModel?
  @State private var writtenTarget: String?
  /// A write is being asked or sent at once: a second click must not send it again
  @State private var startsWrite = false

  private typealias EditMode = AggregationBuilderModel.EditMode

  var body: some View {
    VStack(spacing: 0) {
      if let builder = model.aggregationModel {
        header(builder)
        if showsOptions {
          MongoAggregationOptionsPanel(builder: builder)
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.sm)
        }
        Divider()
        AggregationBuilderBody(
          model: builder, selectedStage: $selectedStage, fieldSource: fieldSource
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.appBackground)
    .sheet(item: $exportRequest) { request in
      MongoExportCodeSheet(request: request)
    }
    .modalOverlay(isPresented: $showsCreateView) {
      if let viewAction {
        MongoViewEditorSheet(
          model: viewAction, mode: .createFrom(source: model.collection, pipeline: viewPipeline),
          sources: viewModel.databaseTables.map(\.name) + viewModel.databaseViews.map(\.name),
          isPresented: $showsCreateView)
      }
    }
  }

  // MARK: - Header

  /// The pipeline as each action sees it, read once per header evaluation: in Text mode every
  /// read parses the edited text again
  private struct Targets {
    let commandText: String?
    /// Why there is no `commandText` (Copy, Open in Query and the status line)
    let blocked: String?
    let run: AggregationBuilderModel.PipelineTarget
    let explain: AggregationBuilderModel.PipelineTarget
    /// Export Code: `$out` and `$merge` export too, since nothing runs
    let code: AggregationBuilderModel.PipelineTarget
    /// Export Data: reads, so a writing stage blocks it
    let data: AggregationBuilderModel.PipelineTarget
    /// Create View: a writing stage passes here, the view form refuses it with its reason
    let view: AggregationBuilderModel.PipelineTarget
    /// A pipeline ending in `$out` / `$merge`: where it writes, or why it may not; nil: a read
    let write: Result<AggregationBuilderModel.WriteTarget, AggregationBuilderModel.StageError>?
    /// Why the tab's rules refuse `write` (the request re-checks under the connection's)
    let writeRefusal: String?
  }

  private func header(_ builder: AggregationBuilderModel) -> some View {
    let commandText = builder.commandText
    let write = builder.writeTarget(
      database: database,
      collections: Set(viewModel.databaseTables.map(\.name) + viewModel.databaseViews.map(\.name)))
    var writeRefusal: String?
    if case .success(let target) = write {
      writeRefusal = MongoAdminActionModel.pipelineWriteRefusal(
        text: target.text, policy: viewModel.protectionPolicy)
    }
    let targets = Targets(
      commandText: commandText,
      blocked: commandText == nil ? builder.pipeline(verb: "copy or open").reason : nil,
      run: builder.runTarget,
      explain: builder.explainTarget,
      code: builder.pipeline(verb: "export"),
      data: builder.exportTarget,
      view: builder.pipeline(verb: "create a view from"),
      write: write, writeRefusal: writeRefusal)
    let isText = builder.editMode == .text
    return HStack(spacing: Spacing.sm) {
      // Tighter than the row: the buttons carry their own padding
      HStack(spacing: Spacing.xs) {
        if let aiAssistant {
          MongoAIPipelineButton(
            assistant: aiAssistant, builder: builder, database: model.database
          )
          .disabled(isText)
          .frame(height: MongoQueryField.styledLineHeight)
        }
        copyButton(builder, targets)
        exportMenu(targets)
        MongoSavedPipelinesButton(
          builder: builder, store: savedPipelineStore, key: savedPipelineKey
        )
        .frame(height: MongoQueryField.styledLineHeight)
        MongoAggregationWizardButton(builder: builder) { id in
          selectedStage = id
          builder.showsRunResults = false
        }
        .disabled(isText)
        .frame(height: MongoQueryField.styledLineHeight)
        optionsButton(builder)
      }
      status(builder, targets, isText: isText)
      Spacer(minLength: Spacing.sm)
      HStack(spacing: Spacing.xs) {
        modePicker(builder)
        explainButton(targets.explain)
        if let write = targets.write {
          writeRunButton(write, refusal: targets.writeRefusal)
        } else {
          runButton(builder, targets.run)
        }
        Button("Open in Query") {
          guard let text = targets.commandText else { return }
          openQuery?(text)
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(targets.commandText == nil || openQuery == nil)
        .help(targets.blocked ?? "Open the aggregate command in a new query tab")
        .frame(height: MongoQueryField.styledLineHeight)
        if canCreateView {
          createViewButton(targets.view)
        }
      }
      // Not on the header node, which hosts the Create View confirmation
      .sheet(isPresented: writeConfirmPresented) {
        if let writeAction {
          MongoAdminConfirmSheet(
            model: writeAction, databasePassword: viewModel.notebook.connectionConfig?.password,
            isConnected: viewModel.connectionState == .connected)
        }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    // "Wrote to <target>" belongs to the pipeline that wrote it
    .onChange(of: commandText) { writtenTarget = nil }
    // On its own node: the export sheet is on the root
    .sheet(isPresented: viewConfirmPresented) {
      if let viewAction {
        MongoAdminConfirmSheet(
          model: viewAction, databasePassword: viewModel.notebook.connectionConfig?.password,
          isConnected: viewModel.connectionState == .connected)
      }
    }
  }

  private func copyButton(_ builder: AggregationBuilderModel, _ targets: Targets) -> some View {
    Button {
      builder.copy()
    } label: {
      Image(systemName: "doc.on.doc")
    }
    .buttonStyle(SecondaryButtonStyle(iconOnly: true))
    .disabled(targets.commandText == nil)
    .help(targets.blocked ?? "Copy the aggregate command")
    .accessibilityLabel("Copy")
    .frame(height: MongoQueryField.styledLineHeight)
  }

  private func optionsButton(_ builder: AggregationBuilderModel) -> some View {
    let isSet = [builder.options.collation, builder.options.maxTimeMS].contains {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return Button {
      showsOptions.toggle()
    } label: {
      Image(systemName: "slider.horizontal.3")
        .foregroundColor(showsOptions || isSet ? .accent : nil)
    }
    .buttonStyle(SecondaryButtonStyle(iconOnly: true))
    .help(
      showsOptions
        ? "Hide the aggregate options"
        : isSet ? "Show the aggregate options (set)" : "Show the aggregate options"
    )
    .accessibilityLabel("Options")
    .frame(height: MongoQueryField.styledLineHeight)
  }

  // MARK: - Status

  /// The stage count (Stages mode) or why the pipeline is blocked
  private func status(
    _ builder: AggregationBuilderModel, _ targets: Targets, isText: Bool
  ) -> some View {
    HStack(spacing: Spacing.sm) {
      if let blocked = targets.blocked {
        statusText(blocked)
      } else if case .failure(let error) = targets.write {
        statusText(error.message)
      } else if let refusal = targets.writeRefusal {
        statusText(refusal)
      } else if writeAction?.state == .done, let writtenTarget {
        written(writtenTarget)
      } else if !isText {
        // In Text mode the stages are those of the text only once Stages takes it back
        statusText(stageCount(builder))
      }
    }
  }

  private func statusText(_ text: String) -> some View {
    Text(text)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .help(text)
  }

  private func stageCount(_ builder: AggregationBuilderModel) -> String {
    let count = builder.stages.count
    return count == 1 ? "1 stage" : "\(count) stages"
  }

  // MARK: - Export

  /// Export Code opens the driver code sheet; Export Data opens the export sheet (hosted by
  /// `DataViewerView`) on the pipeline. One export sheet at a time.
  private func exportMenu(_ targets: Targets) -> some View {
    let canExportData = targets.data.command != nil && model.export == nil
    return Menu {
      Button("Export Code…") {
        guard case .success(let command) = targets.code else { return }
        exportRequest = MongoExportCodeSheet.Request(command: command, database: database)
      }
      .disabled(targets.code.command == nil)
      Button("Export Data…") { openExport(targets.data) }
        .disabled(!canExportData)
      // Menu items show no tooltip: a disabled line says why the data does not export
      if let reason = targets.data.reason, targets.code.command != nil {
        Divider()
        Text(reason)
      }
    } label: {
      ExportMenuLabel(isEnabled: targets.code.command != nil)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .disabled(targets.code.command == nil)
    .help(targets.code.reason ?? "Export the pipeline as driver code, or its documents as a file")
    .accessibilityLabel("Export")
    .frame(height: MongoQueryField.styledLineHeight)
  }

  /// The export sheet with the pipeline as its only source (no document cap)
  private func openExport(_ target: AggregationBuilderModel.PipelineTarget) {
    guard case .success(let pipeline) = target, model.export == nil,
      let manager = viewModel.connectionManager
    else { return }
    model.export = MongoExportModel(
      collection: model.collection, database: model.database, pipeline: pipeline,
      connectionManager: manager, caller: viewModel.id)
  }

  // MARK: - Mode, Explain and Run

  /// Stages | Text. Stages may refuse a text that is not a pipeline: the picker follows the
  /// model's mode, so it stays on Text then.
  private func modePicker(_ builder: AggregationBuilderModel) -> some View {
    let mode = Binding<EditMode>(
      get: { builder.editMode },
      set: { new in
        guard new != builder.editMode else { return }
        if new == .text { builder.showText() } else { builder.showStages() }
      })
    return CapsuleTabPicker(
      selection: mode,
      tabs: [EditMode.stages, .text],
      height: MongoQueryField.styledLineHeight,
      inset: 2,
      verticalInset: 2
    ) { tab in
      let title = tab == .stages ? "Stages" : "Text"
      // Sized by the semibold title, so a selection change keeps both tab widths
      Text(title)
        .font(.small)
        .fontWeight(.semibold)
        .hidden()
        .overlay {
          Text(title)
            .font(.small)
            .fontWeight(builder.editMode == tab ? .semibold : .regular)
            .foregroundColor(builder.editMode == tab ? .onAccentFill : .foreground)
        }
        .lineLimit(1)
    }
    .fitsContent()
    .accessibilityLabel("Editor mode")
    .help("Edit the pipeline as stages or as text")
    .frame(height: MongoQueryField.styledLineHeight)
  }

  /// Explains the enabled stages as one `aggregate` (the sheet is in `DataViewerView`)
  private func explainButton(_ target: AggregationBuilderModel.PipelineTarget) -> some View {
    Button("Explain") {
      guard case .success(let command) = target else { return }
      model.explain(command)
    }
    .buttonStyle(SecondaryButtonStyle())
    .disabled(target.command == nil || model.explainState == .running)
    .help(target.reason ?? "Explain the pipeline with execution statistics")
    .frame(height: MongoQueryField.styledLineHeight)
  }

  /// Runs the pipeline and shows at most `runLimit` documents; Cancel while it runs
  private func runButton(
    _ builder: AggregationBuilderModel, _ target: AggregationBuilderModel.PipelineTarget
  ) -> some View {
    let isRunning: Bool
    if case .running = builder.runState { isRunning = true } else { isRunning = false }
    return Button(isRunning ? "Cancel" : "Run") {
      if isRunning {
        builder.cancelRun()
      } else {
        builder.run(maxRows: runLimit)
      }
    }
    .buttonStyle(PrimaryButtonStyle())
    .disabled(!isRunning && target.command == nil)
    .help(
      isRunning
        ? "Stop waiting for the pipeline results"
        : target.reason ?? "Run the pipeline and show up to \(runLimit.formatted()) documents"
    )
    .frame(height: MongoQueryField.styledLineHeight)
  }
}

// MARK: - Create View

extension MongoAggregationsView {
  /// A connected tab whose protection allows schema changes
  private var canCreateView: Bool {
    viewModel.connectionManager != nil && viewModel.connectionState == .connected
      && !viewModel.protectionPolicy.protectionLevel.blocksSchemaChanges
  }

  private var viewConfirmPresented: Binding<Bool> {
    viewAction.map(MongoAdminConfirmSheet.isPresented) ?? .constant(false)
  }

  /// Opens the view form on this collection with the enabled stages
  private func createViewButton(_ target: AggregationBuilderModel.PipelineTarget) -> some View {
    Button("Create View…") {
      guard case .success(.aggregate(_, let pipeline, _)) = target else { return }
      startCreateView(pipeline)
    }
    .buttonStyle(SecondaryButtonStyle())
    .disabled(target.command == nil || viewAction?.state == .running)
    .help(target.reason ?? "Create a view of \(model.collection) with this pipeline")
    .frame(height: MongoQueryField.styledLineHeight)
  }

  /// The command is gated on the connection epoch read at the click (nothing records the epoch
  /// the pipeline was built under): a reconnect while the form is open refuses it. A create
  /// cannot hit a wrong existing object.
  private func startCreateView(_ pipeline: [MongoValue]) {
    guard let manager = viewModel.connectionManager else { return }
    Task {
      let epoch = await manager.connectionEpoch
      guard let action = MongoAdminActionModel(tab: viewModel, connectionEpoch: epoch) else {
        return
      }
      viewAction = action
      viewPipeline = pipeline
      showsCreateView = true
    }
  }
}

// MARK: - Run $out / $merge

extension MongoAggregationsView {
  private var writeConfirmPresented: Binding<Bool> {
    writeAction.map(MongoAdminConfirmSheet.isPresented) ?? .constant(false)
  }

  /// "Run $out..." / "Run $merge..." in place of Run; a refused target leaves Run disabled with
  /// the reason. Absent when the tab's rules refuse the write (the status line says why).
  @ViewBuilder
  private func writeRunButton(
    _ write: Result<AggregationBuilderModel.WriteTarget, AggregationBuilderModel.StageError>,
    refusal: String?
  ) -> some View {
    switch write {
    case .failure(let error):
      Button("Run") {}
        .buttonStyle(PrimaryButtonStyle())
        .disabled(true)
        .help(error.message)
        .frame(height: MongoQueryField.styledLineHeight)
    case .success(let target) where refusal == nil:
      Button(target.isOut ? "Run $out…" : "Run $merge…") {
        startWrite(target)
      }
      .buttonStyle(PrimaryButtonStyle())
      .disabled(
        viewModel.connectionManager == nil || viewModel.connectionState != .connected
          || startsWrite || writeAction?.state == .running
      )
      .help(Self.writeHelp(target))
      .frame(height: MongoQueryField.styledLineHeight)
    case .success:
      EmptyView()
    }
  }

  private static func writeHelp(_ target: AggregationBuilderModel.WriteTarget) -> String {
    guard target.isOut else {
      return "Merge the pipeline results into collection \(target.collection)"
    }
    return target.exists
      ? "Replace collection \(target.collection) with the pipeline results"
      : "Write the pipeline results to collection \(target.collection)"
  }

  /// Asks for the write on the connection epoch read at the click, like Create View: the
  /// action checks whether an `$out` target exists live, so the collection list may be stale.
  private func startWrite(_ target: AggregationBuilderModel.WriteTarget) {
    guard !startsWrite, let manager = viewModel.connectionManager else { return }
    startsWrite = true
    Task {
      defer { startsWrite = false }
      let epoch = await manager.connectionEpoch
      guard let action = MongoAdminActionModel(tab: viewModel, connectionEpoch: epoch) else {
        return
      }
      writeAction = action
      writtenTarget = target.collection
      await action.requestPipelineWrite(
        text: target.text, target: target.collection, replacesExisting: target.exists,
        isOut: target.isOut)
    }
  }

  /// "Wrote to <target>" (the server returns no count) and the button opening it
  private func written(_ target: String) -> some View {
    HStack(spacing: Spacing.sm) {
      statusText("Wrote to \(target)")
      Button("Show \(target)") { show(target) }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(viewModel.onOpenDataViewer == nil)
        .help("Open collection \(target) in a data viewer")
        .frame(height: MongoQueryField.styledLineHeight)
    }
  }

  /// Opens `collection` in a data viewer, as a sidebar click does
  private func show(_ collection: String) {
    let table = viewModel.databaseTables.first {
      $0.schema == database && $0.name == collection
    }
    viewModel.onOpenDataViewer?(
      database, collection, table?.columns.filter(\.isPrimaryKey).map(\.name) ?? [], nil)
  }
}

/// The Export menu's icon, drawn as `SecondaryButtonStyle(iconOnly: true)` draws it (a custom
/// ButtonStyle is ignored on a Menu)
private struct ExportMenuLabel: View {
  let isEnabled: Bool
  @State private var isHovering = false

  var body: some View {
    Image(systemName: "square.and.arrow.up")
      .font(.system(size: 12))
      .foregroundColor(.foreground)
      .padding(Spacing.sm)
      .background(Circle().fill(isHovering ? Color.cellBackgroundHover : Color.clear))
      .overlay(HairlineBorder(shape: Circle()))
      .contentShape(Circle())
      .opacity(isEnabled ? 1 : 0.5)
      .animation(.easeInOut(duration: 0.15), value: isHovering)
      .onHover { isHovering = $0 }
      .linkPointer()
  }
}
