//
//  CellView+Components.swift
//  SQLNotebook
//

import SwiftUI

// MARK: - Floating Panel Button Component

/// Reusable button component for floating panels (top-right and bottom action panels)
struct FloatingPanelButton: View {
  let icon: String
  let helpText: String
  var useSymbolEffect: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 12))
        .if(useSymbolEffect) { view in
          view.contentTransition(.symbolEffect(.replace))
        }
    }
    .buttonStyle(FloatingPanelButtonStyle())
    .help(helpText)
  }
}
