// CrossTableSearchView.swift
// Find a Value in Every Table: the value, contains or equals, then the tables searched one at a
// time with "N of M tables" and Cancel. Matches are grouped per table (key columns, else the
// first searched ones); clicking one opens the table filtered on the column it matched.
// Closing the sheet stops a running search and keeps the results for the next time it opens;
// opening a match closes it without stopping the search.

import SwiftUI

extension View {
  func crossTableSearchSheet(workspaceManager: WorkspaceManager) -> some View {
    sheet(
      isPresented: Binding(
        get: {
          workspaceManager.isCrossTableSearchPresented && workspaceManager.crossTableSearch != nil
        },
        // Only a dismissal by the user stops the search (opening a match already cleared the flag)
        set: {
          if !$0, workspaceManager.isCrossTableSearchPresented {
            workspaceManager.crossTableSearch?.hide()
          }
        })
    ) {
      if let model = workspaceManager.crossTableSearch {
        CrossTableSearchView(model: model)
      }
    }
  }
}

private struct CrossTableSearchView: View {
  @Bindable var model: CrossTableSearchModel
  @FocusState private var valueFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      searchBar
      Divider()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      footer
    }
    .frame(width: 640, height: 520)
    .background(Color.appBackground)
    .onAppear { valueFocused = true }
  }

  // MARK: - Bars

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Text("Find a Value in Every Table")
        .font(.subheading)
        .foregroundColor(.foreground)
      Spacer()
      Button {
        model.hide()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Close")
    }
    .modalBarPadding(vertical: Spacing.sm)
  }

  private var searchBar: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        TextField("Value", text: $model.value)
          .textFieldStyle(.plain)
          .font(.bodyText)
          .autocorrectionDisabled()
          .inputCapsuleStyle()
          .focused($valueFocused)
          .onSubmit { model.start() }
          .disabled(model.isSearching)
        Picker("Match", selection: $model.mode) {
          ForEach(CrossTableSearchModel.Mode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(model.isSearching)
        .help("Contains: the column's text includes the value. Equals: it is the value.")
        if model.isSearching {
          Button("Cancel") { model.cancel() }
            .buttonStyle(SecondaryButtonStyle())
        } else {
          Button("Search") { model.start() }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!model.canStart)
            .keyboardShortcut(.defaultAction)
        }
      }
      if model.isSearching {
        ProgressView(
          value: Double(model.completed), total: Double(max(model.targets.count, 1))
        )
        .progressViewStyle(.linear)
      }
      Text(statusText)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .monospacedDigit()
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(Spacing.md)
  }

  private var footer: some View {
    HStack(spacing: Spacing.sm) {
      Text(footerText)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
      Spacer()
      Button("Close") { model.hide() }
        .buttonStyle(GhostButtonStyle())
        .keyboardShortcut(.cancelAction)
    }
    .modalBarPadding()
  }

  private var tablesText: String {
    let count = model.targets.count
    return count == 1 ? "1 table" : "\(count.formatted()) tables"
  }

  private var statusText: String {
    let capped =
      model.totalTableCount > model.targets.count
      ? " Only the first \(model.targets.count.formatted()) of "
        + "\(model.totalTableCount.formatted()) tables are searched." : ""
    switch model.phase {
    case .ready:
      return "Searches the text of every column in \(tablesText), one table at a time, at most "
        + "\(CrossTableSearchQueryBuilder.rowLimit) rows each. Binary and spatial columns are "
        + "skipped.\(capped)"
    case .searching:
      return "Searching \(model.completed.formatted()) of \(tablesText)…"
    case .finished:
      return "Searched \(tablesText).\(capped)"
    case .cancelled:
      return "Cancelled after \(model.completed.formatted()) of \(tablesText)."
    case .failed(let message):
      return message
    }
  }

  private var footerText: String {
    let found = model.results.filter { $0.status == .matched }
    guard !found.isEmpty else { return "" }
    let rows = found.reduce(0) { $0 + $1.matches.count }
    let tables = found.count == 1 ? "1 table" : "\(found.count.formatted()) tables"
    return "\(rows.formatted()) row\(rows == 1 ? "" : "s") in \(tables)"
  }

  // MARK: - Results

  @ViewBuilder
  private var content: some View {
    if model.results.isEmpty {
      switch model.phase {
      case .ready:
        placeholder("Type a value, then Search", icon: "text.magnifyingglass")
      case .searching:
        MongoOverviewPlaceholder(text: "Searching…", isLoading: true)
      case .finished:
        placeholder("No table contains \"\(model.searchedValue)\"", icon: "text.magnifyingglass")
      case .cancelled where model.completed == 0:
        placeholder("Cancelled before any table was searched", icon: "text.magnifyingglass")
      case .failed where model.completed == 0:
        placeholder("The search could not run", icon: "exclamationmark.triangle")
      case .cancelled, .failed:
        // Only some tables were searched: the others may still contain the value
        let tables =
          model.completed == 1 ? "the 1 table" : "the \(model.completed.formatted()) tables"
        placeholder(
          "No match in \(tables) searched before the search stopped.",
          icon: "text.magnifyingglass")
      }
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Spacing.md) {
          ForEach(model.results) { result in
            tableSection(result)
          }
        }
        .padding(Spacing.md)
      }
    }
  }

  private func placeholder(_ text: String, icon: String) -> some View {
    VStack(spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: 24))
        .foregroundColor(.foregroundSubtle)
      Text(text)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)
        .lineLimit(3)
    }
    .padding(Spacing.md)
  }

  private func tableSection(_ result: CrossTableSearchModel.TableResult) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "tablecells")
          .font(.system(size: 11))
          .foregroundColor(.foregroundSubtle)
        Text(result.schema.isEmpty ? result.name : "\(result.schema).\(result.name)")
          .font(.labelText.weight(.medium))
          .foregroundColor(.foreground)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: Spacing.sm)
        statusLabel(result)
      }
      if !result.matches.isEmpty {
        Text(result.displayColumns.joined(separator: " · "))
          .font(.smallest)
          .foregroundColor(.foregroundSubtle)
          .lineLimit(1)
        VStack(alignment: .leading, spacing: 0) {
          ForEach(result.matches) { match in
            CrossTableSearchMatchRow(match: match) { model.open(result, match) }
          }
        }
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: CornerRadius.md))
        .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))
      }
    }
  }

  @ViewBuilder
  private func statusLabel(_ result: CrossTableSearchModel.TableResult) -> some View {
    switch result.status {
    case .matched:
      let count = result.matches.count
      let atLimit = count >= CrossTableSearchQueryBuilder.rowLimit
      Text("\(count.formatted())\(atLimit ? "+" : "") row\(count == 1 ? "" : "s")")
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .monospacedDigit()
    case .timedOut:
      Label(
        "Timed out after \(CrossTableSearchModel.tableTimeoutSeconds) s",
        systemImage: "clock.badge.exclamationmark"
      )
      .font(.small)
      .foregroundColor(.warning)
    case .failed(let message):
      Label("Failed", systemImage: "exclamationmark.triangle")
        .font(.small)
        .foregroundColor(.destructive)
        .help(message)
    }
  }
}

/// One matching row: its display values and the column that matched. Click opens the table
/// filtered on that column.
private struct CrossTableSearchMatchRow: View {
  let match: CrossTableSearchModel.Match
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: Spacing.sm) {
        Text(match.values.joined(separator: " · "))
          .font(.monoSmall)
          .foregroundColor(.foreground)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: Spacing.sm)
        Text("in \(match.column)")
          .font(.smallest)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isHovering ? Color.hoverFill : Color.clear, in: Rectangle())
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .linkPointer()
    .help("Open the table filtered on \(match.column)")
  }
}
