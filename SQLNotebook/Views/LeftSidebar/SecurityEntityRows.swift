//
//  SecurityEntityRows.swift
//  SQLNotebook
//
//  Row views for security entities: Users and Roles
//

import SwiftUI

// MARK: - User Row View

struct UserRowView: View {
  let user: DatabaseUser
  let isExpanded: Bool
  let onToggle: () -> Void

  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // User row
      HStack(spacing: Spacing.xs) {
        // Expand/collapse chevron
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(.foregroundMuted)
          .frame(width: 12, height: 12)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))

        // User icon
        Image(systemName: user.isSuperuser ? "person.badge.key" : "person")
          .font(.system(size: 12))
          .foregroundColor(user.isSuperuser ? .warning : .accent)

        // User name
        Text(user.name)
          .font(.monoMedium)
          .foregroundColor(.foreground)

        Spacer()
      }
      .contentShape(Rectangle())
      .onTapGesture {
        onToggle()
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(isHovering ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
      )
      .onHover { hovering in
        isHovering = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }

      // Attributes (when expanded)
      if isExpanded && !user.attributes.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          ForEach(user.attributes, id: \.self) { attribute in
            HStack {
              Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 8))
                .foregroundColor(.success)
              Text(attribute)
                .font(.monoSmall)
                .foregroundColor(.foregroundMuted)
            }
          }
        }
        .padding(.leading, Spacing.lg)
        .padding(.horizontal, Spacing.md)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.foregroundSubtle.opacity(0.2))
            .frame(width: 1)
            .padding(.leading, Spacing.md + 6)  // Align with chevron center
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .clipped()
  }
}

// MARK: - Role Row View

struct RoleRowView: View {
  let role: DatabaseRole
  let isExpanded: Bool
  let onToggle: () -> Void

  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Role row
      HStack(spacing: Spacing.xs) {
        // Expand/collapse chevron
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(.foregroundMuted)
          .frame(width: 12, height: 12)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))

        // Role icon
        Image(systemName: role.isSuperuser ? "person.2.badge.key" : "person.2")
          .font(.system(size: 12))
          .foregroundColor(role.isSuperuser ? .warning : .accent)

        // Role name
        Text(role.name)
          .font(.monoMedium)
          .foregroundColor(.foreground)

        Spacer()

        // Member count badge
        if !role.members.isEmpty {
          Text("\(role.members.count)")
            .font(.system(.caption2))
            .foregroundColor(.foregroundSubtle)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 1)
            .background(
              RoundedRectangle(cornerRadius: 3)
                .fill(Color.inputBackground)
            )
        }
      }
      .contentShape(Rectangle())
      .onTapGesture {
        onToggle()
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(isHovering ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
      )
      .onHover { hovering in
        isHovering = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }

      // Details (when expanded)
      if isExpanded {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          // Attributes
          if !role.attributes.isEmpty {
            ForEach(role.attributes, id: \.self) { attribute in
              HStack {
                Image(systemName: "checkmark.circle.fill")
                  .font(.system(size: 8))
                  .foregroundColor(.success)
                Text(attribute)
                  .font(.monoSmall)
                  .foregroundColor(.foregroundMuted)
              }
            }
          }

          // Members
          if !role.members.isEmpty {
            Text("Members:")
              .font(.monoSmall)
              .foregroundColor(.foregroundMuted)
            ForEach(role.members, id: \.self) { member in
              HStack {
                Image(systemName: "person.fill")
                  .font(.system(size: 8))
                  .foregroundColor(.accent)
                Text(member)
                  .font(.monoSmall)
                  .foregroundColor(.foreground)
              }
            }
          }
        }
        .padding(.leading, Spacing.lg)
        .padding(.horizontal, Spacing.md)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.foregroundSubtle.opacity(0.2))
            .frame(width: 1)
            .padding(.leading, Spacing.md + 6)  // Align with chevron center
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .clipped()
  }
}
