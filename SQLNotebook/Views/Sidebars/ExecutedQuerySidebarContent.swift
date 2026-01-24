//
//  ExecutedQuerySidebarContent.swift
//  SQLNotebook
//
//  Displays executed SQL query with syntax highlighting in right sidebar.
//

import SwiftUI

// MARK: - Executed Query Sidebar Content

struct ExecutedQuerySidebarContent: View {
  let query: String
  let cellId: UUID?
  let limitWasCapped: Bool
  let actualLimit: Int?

  @State private var isCopied = false
  @State private var isWordWrapEnabled = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Fixed header: Title and Toolbar
      VStack(alignment: .leading, spacing: Spacing.md) {
        // Toolbar
        HStack {
          Spacer()

          FloatingPanelToggleButton(
            icon: "text.alignleft",
            helpText: "Word Wrap",
            isActive: isWordWrapEnabled,
            action: { isWordWrapEnabled.toggle() }
          )

          FloatingPanelButton(
            icon: isCopied ? "checkmark" : "doc.on.doc",
            helpText: "Copy Query",
            useSymbolEffect: true,
            action: copyToClipboard
          )
        }
      }
      .padding(.bottom, Spacing.md)

      // SQL query - scrollable both vertically and horizontally
      if isWordWrapEnabled {
        // With word wrap: only vertical scroll
        ScrollView(.vertical, showsIndicators: true) {
          Text(highlightedQuery)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(Spacing.sm)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      } else {
        // Without word wrap: both horizontal and vertical scroll
        ScrollView(.horizontal, showsIndicators: true) {
          ScrollView(.vertical, showsIndicators: true) {
            Text(highlightedQuery)
              .font(.system(size: 12, design: .monospaced))
              .textSelection(.enabled)
              .fixedSize(horizontal: true, vertical: true)
              .padding(Spacing.sm)
          }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      }

      // Warning footer when LIMIT was capped
      if limitWasCapped, let limit = actualLimit {
        limitCappedWarning(limit: limit)
      }
    }
  }

  // MARK: - Limit Capped Warning

  @ViewBuilder
  private func limitCappedWarning(limit: Int) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.yellow)
        .font(.system(size: 12))

      Text("LIMIT was adjusted to \(limit) based on Max Rows setting.")
        .font(.system(size: 11))
        .foregroundColor(.foregroundMuted)

      Spacer()
    }
    .padding(.top, Spacing.md)
  }

  private var highlightedQuery: AttributedString {
    // Use SQLSyntaxHighlighter to get syntax-highlighted NSAttributedString, then convert to AttributedString
    let nsAttributedString = SQLSyntaxHighlighter.highlight(query)
    return AttributedString(nsAttributedString)
  }

  private func copyToClipboard() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(query, forType: .string)

    // Show checkmark feedback
    isCopied = true

    // Reset back to copy icon after 500ms
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      isCopied = false
    }
  }
}

// MARK: - Previews

#Preview("Simple Query") {
  let viewModel = NotebookViewModel()
  let query =
    "SELECT id, name, email FROM users WHERE active = true ORDER BY created_at DESC LIMIT 100;"
  viewModel.rightSidebarContent = .executedQuery(
    query: query, cellId: UUID(), limitWasCapped: false, actualLimit: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Complex Query") {
  let viewModel = NotebookViewModel()
  let query = """
    SELECT
      u.id,
      u.name,
      u.email,
      COUNT(o.id) as order_count,
      SUM(o.total) as total_spent
    FROM users u
    LEFT JOIN orders o ON u.id = o.user_id
    WHERE u.active = true
      AND u.created_at >= '2024-01-01'
    GROUP BY u.id, u.name, u.email
    HAVING COUNT(o.id) > 5
    ORDER BY total_spent DESC
    LIMIT 1000;
    """
  viewModel.rightSidebarContent = .executedQuery(
    query: query, cellId: nil, limitWasCapped: false, actualLimit: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Query with Limit Capped Warning") {
  let viewModel = NotebookViewModel()
  let query = "SELECT * FROM users LIMIT 100;"
  viewModel.rightSidebarContent = .executedQuery(
    query: query, cellId: UUID(), limitWasCapped: true, actualLimit: 100
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
