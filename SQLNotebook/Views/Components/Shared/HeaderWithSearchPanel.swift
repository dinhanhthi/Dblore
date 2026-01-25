//
//  HeaderWithSearchPanel.swift
//  SQLNotebook
//

import SwiftUI

/// Header container (search panel has been moved to body content area)
/// Used by both Notebook and Editor modes
struct HeaderWithSearchPanel: View {
  let viewModel: NotebookViewModel

  var body: some View {
    HeaderView(viewModel: viewModel)
  }
}
