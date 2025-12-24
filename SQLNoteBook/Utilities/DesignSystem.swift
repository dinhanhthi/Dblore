//
//  DesignSystem.swift
//  SQLNotebook
//
//  shadcn-inspired design system for macOS
//

import SwiftUI

// MARK: - Colors

extension Color {
    // Background colors
    static let appBackground = Color(hex: "09090b")
    static let cardBackground = Color(hex: "0c0c0e")
    static let cellBackground = Color(hex: "18181b")
    static let cellBackgroundHover = Color(hex: "1f1f23")
    static let inputBackground = Color(hex: "27272a")

    // Foreground colors
    static let foreground = Color(hex: "fafafa")
    static let foregroundMuted = Color(hex: "a1a1aa")
    static let foregroundSubtle = Color(hex: "71717a")

    // Border colors
    static let border = Color(hex: "27272a")
    static let borderSubtle = Color(hex: "3f3f46")
    static let borderFocus = Color(hex: "a855f7")

    // Accent colors
    static let accent = Color(hex: "a855f7")  // Purple accent like shadcn
    static let accentMuted = Color(hex: "7c3aed")

    // Semantic colors
    static let success = Color(hex: "22c55e")
    static let warning = Color(hex: "f59e0b")
    static let destructive = Color(hex: "ef4444")

    // Table colors
    static let tableHeaderBackground = Color(hex: "1f1f23")
    static let tableRowAlternate = Color(hex: "0f0f11")

    // Syntax highlighting colors
    static let syntaxKeyword = Color(hex: "c084fc")    // Purple
    static let syntaxFunction = Color(hex: "38bdf8")   // Cyan
    static let syntaxString = Color(hex: "4ade80")     // Green
    static let syntaxNumber = Color(hex: "fb923c")     // Orange
    static let syntaxComment = Color(hex: "6b7280")    // Gray
    static let syntaxOperator = Color(hex: "fafafa")   // White
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Typography

extension Font {
    static let mono = Font.system(.body, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)
    static let monoLarge = Font.system(.title3, design: .monospaced)

    static let heading = Font.system(.title2, weight: .semibold)
    static let subheading = Font.system(.headline, weight: .medium)
    static let bodyText = Font.system(.body)
    static let caption = Font.system(.caption)
    static let small = Font.system(.caption2)
}

// MARK: - Spacing

enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Corner Radius

enum CornerRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 6
    static let lg: CGFloat = 8
    static let xl: CGFloat = 12
}

// MARK: - Sizes

enum ComponentSize {
    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 28
    static let sidebarWidth: CGFloat = 320
    static let cellSidebarWidth: CGFloat = 34
    static let buttonHeight: CGFloat = 32
    static let inputHeight: CGFloat = 36
    static let maxResultHeight: CGFloat = 500
    static let minCellHeight: CGFloat = 80
}

// MARK: - Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .medium))
            .foregroundColor(.foreground)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(configuration.isPressed ? Color.accentMuted : Color.accent)
            )
            .opacity(isEnabled ? 1 : 0.5)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .medium))
            .foregroundColor(.foreground)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .stroke(Color.border, lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(configuration.isPressed ? Color.cellBackgroundHover : Color.clear)
                    )
            )
            .opacity(isEnabled ? 1 : 0.5)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .medium))
            .foregroundColor(configuration.isPressed ? .foreground : .foregroundMuted)
            .padding(.horizontal, 0)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(configuration.isPressed ? Color.cellBackgroundHover : Color.clear)
            )
    }
}

struct ToolbarButtonStyle: ButtonStyle {
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .medium))
            .foregroundColor(isActive ? .accent : (configuration.isPressed ? .foreground : .foregroundMuted))
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(configuration.isPressed || isActive ? Color.cellBackgroundHover : Color.clear)
            )
            .contentShape(Rectangle())
    }
}

struct FloatingActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(Spacing.xs)
            .background(
                Circle()
                    .fill(configuration.isPressed ? Color.accent.opacity(0.2) : Color.clear)
            )
            .contentShape(Circle())
    }
}

struct FloatingPanelButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.foregroundMuted)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                ZStack {
                    // Opaque base layer to hide content behind
                    Capsule()
                        .fill(Color.cellBackgroundHover)

                    // Hover/press overlay with accent color
                    if isHovering || configuration.isPressed {
                        Capsule()
                            .fill(Color.accent.opacity(0.15))
                    }
                }
                .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
            )
            .overlay(
                Capsule()
                    .stroke(isHovering ? Color.accent.opacity(0.5) : Color.borderSubtle, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

// MARK: - Custom Shapes

struct RoundedLeftBorder: Shape {
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        // Start from top-left corner (accounting for line width)
        let startX = lineWidth / 2
        let startY = cornerRadius
        
        // Move to start position
        path.move(to: CGPoint(x: startX, y: startY))
        
        // Top-left corner arc
        // path.addArc(
        //     center: CGPoint(x: cornerRadius, y: cornerRadius),
        //     radius: cornerRadius - lineWidth / 2,
        //     startAngle: .degrees(180),
        //     endAngle: .degrees(270),
        //     clockwise: false
        // )
        
        // Move back to left edge (creating the vertical line)
        path.move(to: CGPoint(x: startX, y: cornerRadius))
        
        // Left edge line
        path.addLine(to: CGPoint(x: startX, y: rect.height - cornerRadius))
        
        // Bottom-left corner arc
        // path.addArc(
        //     center: CGPoint(x: cornerRadius, y: rect.height - cornerRadius),
        //     radius: cornerRadius - lineWidth / 2,
        //     startAngle: .degrees(180),
        //     endAngle: .degrees(90),
        //     clockwise: true
        // )
        
        return path.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}

// MARK: - View Extensions

extension View {
    func cardStyle() -> some View {
        self
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.lg)
                    .stroke(Color.border, lineWidth: 1)
            )
    }

    func cellStyle(isSelected: Bool = false) -> some View {
        self
            .background(Color.cellBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.lg)
                    .stroke(isSelected ? Color.accent : Color.border, lineWidth: isSelected ? 0.5 : 1)
            )
    }

    func inputStyle() -> some View {
        self
            .padding(Spacing.sm)
            .background(Color.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .stroke(Color.border, lineWidth: 1)
            )
    }
}
