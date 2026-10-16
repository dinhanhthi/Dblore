//
//  MongoDocumentAutocompleteProvider.swift
//  Dblore
//
//  Autocomplete for a bare MongoDB document (a filter or a stage body) of one collection
//

import Foundation

/// Completes field paths and operators in a field holding only a document of `collection`,
/// through `MongoshAutocompleteProvider.documentSuggestions`. Tables are read from `source` at
/// each request, so a schema loaded later is seen.
final class MongoDocumentAutocompleteProvider: SQLAutocompleteProvider {
  let collection: String
  let mode: MongoshAutocompleteProvider.DocumentMode
  private let source: SQLAutocompleteProvider

  /// Declared so the compiler does not synthesize a main actor `init()` override, which clashes
  /// with the base class's implicit nonisolated `init()`
  @available(*, unavailable)
  nonisolated override init() { fatalError("use init(collection:mode:source:)") }

  init(
    collection: String, mode: MongoshAutocompleteProvider.DocumentMode,
    source: SQLAutocompleteProvider
  ) {
    self.collection = collection
    self.mode = mode
    self.source = source
    super.init()
  }

  override func getSuggestions(
    for fullText: String, at fullCursorPosition: Int, dialect: SQLDialect
  ) -> [AutocompleteSuggestion] {
    MongoshAutocompleteProvider.documentSuggestions(
      for: fullText, at: fullCursorPosition, collection: collection, mode: mode,
      tables: source.tables)
  }
}
