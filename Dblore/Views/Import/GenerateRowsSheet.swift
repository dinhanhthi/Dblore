import Foundation
import SwiftUI

/// Generate Rows for one table in the active tab: row count, seed, a generator per column and
/// the NULL ratio, with the first rows a run makes. The run is one batch for the tab with one
/// Safe Mode decision; the sheet keeps its progress and Cancel until it ends, while Safe Mode
/// asks too.
struct GenerateRowsSheet: View {
  let viewModel: NotebookViewModel
  @Bindable var model: GenerateRowsModel
  @Binding var isPresented: Bool
  @Binding var isBusy: Bool

  private static let contentEndAnchor = "generate-rows-content-end"
  private static let previewRowHeight: CGFloat = 24

  @State private var generateTask: Task<Void, Never>?
  @State private var isCancelling = false

  /// What the preview is made from: a change makes it again once typing pauses
  private struct PreviewSettings: Equatable {
    var rowCount: Int
    var seed: UInt64
    var nullRatio: Double
    var kinds: [String: ColumnValueGenerator.Kind]
  }

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: "Generate Rows", titleIcon: "wand.and.stars", titleBadge: model.table,
        onClose: { if !isBusy { isPresented = false } })
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.lg) {
            Group {
              settingsSection
              columnsSection
            }
            .disabled(model.isGenerating)
            previewSection
            if model.isGenerating { progressSection }
            if let error = model.errorMessage {
              Text(error)
                .font(.small)
                .foregroundColor(.destructive)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.md)
                .background(
                  Color.destructive.opacity(0.1),
                  in: RoundedRectangle(cornerRadius: CornerRadius.lg)
                )
                .overlay(
                  HairlineBorder(
                    shape: RoundedRectangle(cornerRadius: CornerRadius.lg),
                    color: .destructive.opacity(0.4))
                )
            }
          }
          .padding(Spacing.md)
          .frame(maxWidth: .infinity, alignment: .leading)
          .id(Self.contentEndAnchor)
        }
        .onChange(of: model.errorMessage) { _, message in
          guard message != nil else { return }
          withAnimation { proxy.scrollTo(Self.contentEndAnchor, anchor: .bottom) }
        }
        // The progress sits below the preview; bring it into view once the run starts
        .onChange(of: model.isGenerating) { _, generating in
          guard generating else { return }
          withAnimation { proxy.scrollTo(Self.contentEndAnchor, anchor: .bottom) }
        }
      }
      .frame(maxHeight: .infinity)
      footer
    }
    .background(Color.cardBackground)
    .task { await model.load(for: viewModel) }
    .task(id: previewSettings) { await refreshPreview() }
    .onChange(of: model.rowCount) { _, count in
      let clamped = min(
        max(count, GenerateRowsModel.rowCountRange.lowerBound),
        GenerateRowsModel.rowCountRange.upperBound)
      if clamped != count { model.rowCount = clamped }
    }
    // The run ended (Safe Mode's decision included): sent or declined closes, a failure stays
    .onChange(of: model.isGenerating) { _, generating in
      guard !generating else { return }
      isBusy = false
      if model.errorMessage == nil { isPresented = false }
    }
    // Closed by the panel (tab closed, relock): a run already with the tab stays the tab's
    .onChange(of: isPresented) { _, presented in
      if !presented { model.cancel() }
    }
  }

  private var footer: some View {
    GenericModalFooter {
      Spacer()
      Button("Cancel", action: cancel)
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(isCancelling)
      Button(action: generate) {
        if model.isGenerating {
          HStack(spacing: Spacing.sm) {
            ProgressView().controlSize(.mini)
            Text("Generating...")
          }
        } else {
          Text("Generate")
        }
      }
      .buttonStyle(PrimaryButtonStyle())
      .disabled(model.columns.isEmpty || model.isGenerating || isBusy)
    }
  }

  // MARK: - Settings

  private var settingsSection: some View {
    SettingsGroupCard(title: "Rows") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(spacing: Spacing.sm) {
          Text("Rows to generate")
            .font(.bodyText)
            .foregroundColor(.foreground)
          Spacer()
          TextField("", value: $model.rowCount, format: .number.grouping(.never))
            .textFieldStyle(.plain)
            .numberInputCapsuleStyle()
            .frame(width: 110)
            .accessibilityLabel("Rows to generate")
        }
        HStack(spacing: Spacing.sm) {
          Text("Seed")
            .font(.bodyText)
            .foregroundColor(.foreground)
          Spacer()
          TextField("", value: $model.seed, format: .number.grouping(.never))
            .textFieldStyle(.plain)
            .numberInputCapsuleStyle()
            .frame(width: 110)
            .accessibilityLabel("Seed")
          Button {
            model.seed = UInt64.random(in: 1...999_999)
          } label: {
            Image(systemName: "dice")
          }
          .buttonStyle(GhostButtonStyle())
          .help("New seed")
          .accessibilityLabel("New seed")
        }
        Text("The same seed and settings make the same rows.")
          .font(.small)
          .foregroundColor(.foregroundMuted)
        SettingsSlider(
          title: "NULL ratio",
          valueText: model.nullRatio.formatted(.percent.precision(.fractionLength(0))),
          value: $model.nullRatio, range: 0...1, step: 0.05,
          description: "Share of NULLs in nullable columns that need not be unique.")
        if model.pendsUntilCommit {
          Label(GenerateRowsModel.pendingUntilCommitNotice, systemImage: "info.circle")
            .font(.small)
            .foregroundColor(.foreground)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  // MARK: - Columns

  private var columnsSection: some View {
    SettingsGroupCard(title: "Columns") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        if model.columns.isEmpty {
          if model.isLoading {
            ImportLoadingRow(text: "Reading the table...")
          } else if model.errorMessage == nil {
            Text("No columns to fill: the database fills every column of this table.")
              .font(.small)
              .foregroundColor(.foregroundMuted)
          }
        }
        ForEach(model.columns) { column in
          columnRow(column)
        }
      }
    }
  }

  private func columnRow(_ column: GenerateRowsColumn) -> some View {
    HStack(spacing: Spacing.sm) {
      Text(column.name)
        .font(.bodyText)
        .foregroundColor(.foreground)
        .lineLimit(1)
        .truncationMode(.middle)
      Text(column.type)
        .font(.monoSmall)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
      Spacer()
      if column.isForeignKey {
        // Its values are keys sampled from the referenced table: no generator applies
        Label("Sampled parent keys", systemImage: "link")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      } else {
        let kind = model.kinds[column.name] ?? column.defaultKind
        CapsuleDropdown(
          title: kind?.label ?? "NULL", width: 170,
          accessibilityLabel: "Generator of \(column.name)", options: column.choices,
          optionTitle: \.label, isSelected: { $0 == kind },
          onSelect: { model.kinds[column.name] = $0 })
      }
    }
  }

  // MARK: - Preview

  /// Same card while the rows are made, so the sheet does not jump when they arrive
  private var previewSection: some View {
    SettingsGroupCard(title: "Preview (first \(GenerateRowsModel.previewRowCount) rows)") {
      if model.previewRows.isEmpty {
        if model.isLoading {
          ImportLoadingRow(text: "Making the preview...")
        } else {
          Text("No rows to preview")
            .font(.small)
            .foregroundColor(.foregroundMuted)
        }
      } else {
        // The reader's width pins narrow content to the leading edge (a scroll view centers it)
        GeometryReader { geometry in
          ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
              previewRow(model.previewColumns, header: true)
              ForEach(model.previewRows.indices, id: \.self) { index in
                previewRow(model.previewRows[index].map { $0 ?? "NULL" }, header: false)
              }
            }
            .frame(minWidth: geometry.size.width, alignment: .topLeading)
          }
        }
        .frame(height: Self.previewRowHeight * CGFloat(model.previewRows.count + 1))
        .background(Color.appBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
        .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))
        .opacity(model.isLoading ? 0.5 : 1)
      }
    }
  }

  private func previewRow(_ values: [String], header: Bool) -> some View {
    HStack(spacing: 0) {
      ForEach(values.indices, id: \.self) { index in
        Text(values[index])
          .font(.monoSmall)
          .foregroundColor(header ? .foreground : .foregroundMuted)
          .lineLimit(1)
          .textSelection(.enabled)
          .frame(width: 170, alignment: .leading)
          .padding(.horizontal, Spacing.sm)
          .frame(height: Self.previewRowHeight)
          .overlay(alignment: .trailing) { Rectangle().fill(Color.border).frame(width: 1) }
      }
    }
    .background(header ? Color.cardHeaderBackground : Color.clear)
    .overlay(alignment: .bottom) { Rectangle().fill(Color.border).frame(height: 1) }
  }

  // MARK: - Progress

  private var progressSection: some View {
    SettingsGroupCard(title: "Progress") {
      if model.awaitsConfirmation {
        ImportLoadingRow(text: "Waiting for the Safe Mode confirmation...")
      } else if model.isExecutingBatch {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          ProgressView(value: model.progress)
            .accessibilityLabel("Generate Rows progress")
          Text(
            "\(model.chunksDone.formatted()) of \(model.chunkTotal.formatted()) chunks sent"
          )
          .font(.small)
          .foregroundColor(.foregroundMuted)
        }
      } else {
        ImportLoadingRow(text: "Planning the rows...")
      }
    }
  }

  // MARK: - Actions

  private var previewSettings: PreviewSettings {
    PreviewSettings(
      rowCount: model.rowCount, seed: model.seed, nullRatio: model.nullRatio, kinds: model.kinds)
  }

  /// Makes the preview again once the settings stop changing (`.task(id:)` cancels the wait
  /// on each change). The first preview comes with `load`.
  private func refreshPreview() async {
    guard !model.columns.isEmpty else { return }
    try? await Task.sleep(for: .milliseconds(350))
    guard !Task.isCancelled, !model.isGenerating else { return }
    await model.refreshPreview(for: viewModel)
  }

  /// The run; the sheet closes when it ends (`onChange(of: model.isGenerating)`)
  private func generate() {
    isBusy = true
    generateTask = Task {
      // Refused before the run starts: the error shows and the sheet stays
      if !(await model.generate(in: viewModel)) { isBusy = false }
      generateTask = nil
    }
  }

  /// Sending: the tab's cancel rolls the run back. Waiting on Safe Mode: declined. Planning or
  /// idle: dropped.
  private func cancel() {
    guard !isCancelling else { return }
    if model.isExecutingBatch {
      isCancelling = true
      Task {
        if await viewModel.cancelRunningStatement(cancelQueue: false) { close() }
        isCancelling = false
      }
      return
    }
    if model.awaitsConfirmation { viewModel.cancelPendingQuery() }
    generateTask?.cancel()
    close()
  }

  private func close() {
    model.cancel()
    isBusy = false
    isPresented = false
  }
}
