//
//  PaginationView.swift
//  SQLNotebook
//
//  Pagination controls for navigating through paginated query results
//

import SwiftUI

struct PaginationView: View {
  let info: PaginationInfo
  let onPageChange: (Int) -> Void

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
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                .font(.caption)
                .fontWeight(pageNumber == info.currentPage ? .semibold : .regular)
                .foregroundColor(pageNumber == info.currentPage ? .white : .foreground)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .background(
                  RoundedRectangle(cornerRadius: CornerRadius.sm)
                    .fill(pageNumber == info.currentPage ? Color.accent : Color.clear)
                )
            }
            .buttonStyle(.plain)
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
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!info.hasNextPage)
      }

      Spacer()

      // Total info
      Text("\(info.totalRows) rows total • \(info.totalPages) pages")
        .font(.caption)
        .foregroundColor(.foregroundSubtle)
    }
    .padding(.vertical, Spacing.xs)
    .background(Color.cardBackground)
    .overlay(alignment: .top) {
      Divider()
    }
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
