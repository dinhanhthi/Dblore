//
//  MongoExportSheet.swift
//  Dblore
//
//  Export form of a MongoDB collection, query or aggregation (a `GenericModal`, presented with
//  `modalOverlay`): source, format (Extended JSON relaxed / canonical, NDJSON / array, or CSV
//  with a field picker read from a sample), then the progress with Cancel and the result.
//  `MongoExportModel` asks where to save and streams the documents. The presenters refuse to
//  close the form while an export runs (Cancel stops it, no file is left).
//

import SwiftUI

struct MongoExportSheet: View {
  @Bindable var model: MongoExportModel
  @Binding var isPresented: Bool

  private static let width: CGFloat = 560
  private static let height: CGFloat = 600
  private static let labelWidth: CGFloat = 110

  var body: some View {
    GenericModal(
      title: "Export", titleIcon: "square.and.arrow.up", titleBadge: model.collection,
      width: Self.width, height: Self.height, isPresented: $isPresented
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          optionsSection
          if model.format == .csv { fieldsSection }
          if let refusal = model.refusal {
            Text(refusal)
              .font(.small)
              .foregroundColor(.destructive)
              .fixedSize(horizontal: false, vertical: true)
          }
          statusSection
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    } footer: {
      GenericModalFooter {
        Spacer()
        Button("Close") { isPresented = false }
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(model.isRunning)
        Button("Export...") { Task { await model.export() } }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(!model.canExport || model.isBusy)
      }
    }
    .task { await model.prepare() }
  }

  // MARK: - Sections

  private var optionsSection: some View {
    Grid(alignment: .leading, horizontalSpacing: Spacing.sm, verticalSpacing: Spacing.sm) {
      GridRow {
        label("Source")
        if model.sources.count > 1 {
          segmented($model.source, model.sources.map { ($0, $0.title) })
        } else {
          Text(model.source.title)
            .font(.small)
            .foregroundColor(.foreground)
        }
      }
      GridRow {
        label("Format")
        segmented($model.format, [(.extendedJSON, "Extended JSON"), (.csv, "CSV")])
      }
      if model.format == .extendedJSON {
        GridRow {
          label("Mode")
          segmented($model.jsonMode, [(.relaxed, "Relaxed"), (.canonical, "Canonical")])
        }
        GridRow {
          label("Layout")
          segmented(
            $model.jsonLayout,
            [(.ndjson, "One document per line (NDJSON)"), (.array, "JSON array")])
        }
      }
    }
    .disabled(model.isBusy)
  }

  private var fieldsSection: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.sm) {
        sectionTitle("Fields")
        Spacer(minLength: 0)
        if let candidates = model.fieldCandidates, !candidates.isEmpty {
          Button("Select All") { model.checkedFields = Set(candidates) }
            .buttonStyle(GhostButtonStyle())
            .disabled(model.isBusy)
          Button("Select None") { model.checkedFields = [] }
            .buttonStyle(GhostButtonStyle())
            .disabled(model.isBusy)
        }
      }
      if model.state == .sampling {
        HStack(spacing: Spacing.sm) {
          ProgressView().controlSize(.small)
          Text("Reading a sample of \(MongoExportModel.sampleSize) documents...")
            .font(.small)
            .foregroundColor(.foregroundMuted)
          Spacer(minLength: 0)
          Button("Cancel", action: model.cancel)
            .buttonStyle(FilledSecondaryButtonStyle())
        }
      } else if let error = model.fieldsError {
        HStack(alignment: .top, spacing: Spacing.sm) {
          Text(error)
            .font(.small)
            .foregroundColor(.destructive)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button("Retry", action: model.loadFieldsIfNeeded)
            .buttonStyle(FilledSecondaryButtonStyle())
            .disabled(model.isBusy)
        }
      } else if let candidates = model.fieldCandidates {
        if candidates.isEmpty {
          Text("The sample has no fields.")
            .font(.small)
            .foregroundColor(.foregroundMuted)
        } else {
          VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(candidates, id: \.self) { path in
              Toggle(path, isOn: checked(path))
                .toggleStyle(.checkbox)
                .font(.monoMedium)
            }
          }
          .disabled(model.isBusy)
          Text("Columns follow this order. A missing field is an empty cell.")
            .font(.small)
            .foregroundColor(.foregroundMuted)
        }
      }
    }
  }

  @ViewBuilder
  private var statusSection: some View {
    switch model.state {
    case .running(let written):
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        Text(Self.written(written))
          .font(.bodyText)
          .foregroundColor(.foreground)
          .monospacedDigit()
        Spacer(minLength: 0)
        Button("Cancel", action: model.cancel)
          .buttonStyle(FilledSecondaryButtonStyle())
      }
    case .done(let count, let url):
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.success)
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text("Exported \(Self.documents(count)).")
            .font(.bodyText)
            .foregroundColor(.foreground)
          Text(url.lastPathComponent)
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer(minLength: 0)
        Button("Show in Finder", action: model.showInFinder)
          .buttonStyle(FilledSecondaryButtonStyle())
      }
    case .failed(let message):
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundColor(.destructive)
        Text(message)
          .font(.bodyText)
          .foregroundColor(.foreground)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    case .cancelled:
      Text("Export cancelled. No file was written.")
        .font(.small)
        .foregroundColor(.foregroundMuted)
    case .idle, .sampling:
      EmptyView()
    }
  }

  // MARK: - Rows

  private func label(_ title: String) -> some View {
    Text(title)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .frame(width: Self.labelWidth, alignment: .leading)
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .font(.caption)
      .foregroundColor(.foregroundMuted)
  }

  private func segmented<Value: Hashable>(
    _ selection: Binding<Value>, _ options: [(Value, String)]
  ) -> some View {
    Picker("", selection: selection) {
      ForEach(options, id: \.0) { option in
        Text(option.1).tag(option.0)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
  }

  private func checked(_ path: String) -> Binding<Bool> {
    Binding(
      get: { model.checkedFields.contains(path) },
      set: { isOn in
        if isOn {
          model.checkedFields.insert(path)
        } else {
          model.checkedFields.remove(path)
        }
      })
  }

  // MARK: - Helpers

  /// "1,234 documents written"
  private static func written(_ count: Int) -> String {
    "\(documents(count)) written"
  }

  private static func documents(_ count: Int) -> String {
    "\(count.formatted()) document\(count == 1 ? "" : "s")"
  }
}
