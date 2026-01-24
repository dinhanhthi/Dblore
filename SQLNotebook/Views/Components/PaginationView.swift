//
//  PaginationView.swift
//  SQLNotebook
//
//  Pagination controls for navigating through paginated query results
//

import SwiftUI

private struct PageButtonStyle: ButtonStyle {
  let isCurrentPage: Bool
  @State private var isHovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.caption)
      .fontWeight(isCurrentPage ? .semibold : .regular)
      .foregroundColor(isCurrentPage ? .white : .foreground)
      .frame(width: 24, height: 24)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(
            isCurrentPage
              ? Color.accent
              : (isHovering || configuration.isPressed
                  ? Color.foregroundMuted.opacity(0.2)
                  : Color.clear)
          )
      )
      .contentShape(Rectangle())
      .animation(.easeInOut(duration: 0.1), value: isHovering)
      .onHover { hovering in
        isHovering = hovering
      }
  }
}

private struct ArrowButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(width: 24, height: 24)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(
            isHovering && isEnabled || configuration.isPressed
              ? Color.foregroundMuted.opacity(0.2)
              : Color.clear
          )
      )
      .contentShape(Rectangle())
      .animation(.easeInOut(duration: 0.1), value: isHovering)
      .onHover { hovering in
        isHovering = hovering
      }
  }
}

struct PaginationView: View {
  let info: PaginationInfo
  let onPageChange: (Int) -> Void
  var includeHorizontalPadding: Bool = false

  var body: some View {
    HStack(spacing: Spacing.md) {
      // Pagination controls
      HStack(spacing: Spacing.xs) {
        // Previous button
        Button {
          if info.hasPreviousPage {
            onPageChange(info.currentPage - 1)
          }
        } label: {
          Image(systemName: "chevron.left")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(info.hasPreviousPage ? .foreground : .foregroundSubtle)
        }
        .buttonStyle(ArrowButtonStyle())
        .disabled(!info.hasPreviousPage)

        // Page numbers - use enumerated to handle duplicate -1 (ellipsis)
        ForEach(Array(visiblePageNumbers.enumerated()), id: \.offset) { index, pageNumber in
          if pageNumber == -1 {
            // Ellipsis
            Text("...")
              .font(.caption)
              .foregroundColor(.foregroundSubtle)
              .frame(width: 24, height: 24)
          } else {
            // Page button
            Button {
              onPageChange(pageNumber)
            } label: {
              Text("\(pageNumber)")
            }
            .buttonStyle(PageButtonStyle(isCurrentPage: pageNumber == info.currentPage))
          }
        }

        // Next button
        Button {
          if info.hasNextPage {
            onPageChange(info.currentPage + 1)
          }
        } label: {
          Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(info.hasNextPage ? .foreground : .foregroundSubtle)
        }
        .buttonStyle(ArrowButtonStyle())
        .disabled(!info.hasNextPage)
      }

      Spacer()

      // Total info
      Text("\(info.totalRows) rows total")
        .font(.labelText)
        .foregroundColor(.foregroundSubtle)
    }
    .padding(.vertical, Spacing.sm)
    .padding(.horizontal, includeHorizontalPadding ? Spacing.sm : 0)
    .background(Color.cardBackground)
    // .overlay(alignment: .top) {
    //   Divider()
    // }
  }

  private var visiblePageNumbers: [Int] {
    let current = info.currentPage
    let total = info.totalPages

    if total <= 7 {
      return Array(1...total)
    }

    var pages: [Int] = []
    pages.append(1)

    if current <= 4 {
      for page in 2...min(5, total - 1) {
        pages.append(page)
      }
      if total > 6 {
        pages.append(-1)
      }
    } else if current >= total - 3 {
      pages.append(-1)
      for page in max(2, total - 4)...total - 1 {
        pages.append(page)
      }
    } else {
      pages.append(-1)
      for page in (current - 1)...(current + 1) {
        pages.append(page)
      }
      pages.append(-1)
    }

    if pages.last != total && pages.last != -1 {
      pages.append(total)
    } else if pages.last == -1 {
      pages.append(total)
    }

    return pages
  }
}
