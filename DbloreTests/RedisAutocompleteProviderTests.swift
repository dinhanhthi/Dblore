// RedisAutocompleteProviderTests.swift
// Redis completions: command names at the start of a line and subcommands after a command that
// takes one, without the commands the editor refuses.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Redis autocomplete")
struct RedisAutocompleteProviderTests {

  @Test("Command names complete upper-case at the line start, refused ones left out")
  func commands() {
    #expect(suggest("ge|").contains("GET"))
    #expect(suggest("ge|").contains("GETRANGE"))
    #expect(suggest("get|").first == "GET")
    #expect(suggest("SET k v\n  hge|").contains("HGETALL"))
    #expect(suggestions("ge|").first?.type.isKeyword == true)
    // Refused: connection state, push streams, blocking
    #expect(suggest("sel|").isEmpty)
    #expect(!suggest("mu|").contains("MULTI"))
    #expect(!suggest("su|").contains("SUBSCRIBE"))
    #expect(!suggest("bl|").contains("BLPOP"))
  }

  @Test("Subcommands complete after a command that takes one, refused ones left out")
  func subcommands() {
    #expect(suggest("config g|") == ["GET"])
    #expect(suggest("CLIENT l|") == ["LIST"])
    #expect(suggest("XINFO s|") == ["STREAM"])
    #expect(suggest("MEMORY u|") == ["USAGE"])
    #expect(!suggest("CLIENT s|").contains("SETNAME"))
    #expect(suggest("SCRIPT d|").isEmpty)
    // No subcommands, and no key names
    #expect(suggest("GET ge|").isEmpty)
    #expect(suggest("CONFIG GET ma|").isEmpty)
  }

  @Test("Nothing is offered for an empty word, in a comment or inside quotes")
  func quietPlaces() {
    #expect(suggest("|").isEmpty)
    #expect(suggest("CONFIG |").isEmpty)
    #expect(suggest("# ge|").isEmpty)
    #expect(suggest("SET \"a ge|").isEmpty)
    #expect(suggest("SET 'a ge|").isEmpty)
  }

  // MARK: - Helpers

  /// Suggestions at the `|` marker of `marked` (the marker is removed), through the dialect
  /// routing of the editor's provider
  private func suggestions(_ marked: String) -> [AutocompleteSuggestion] {
    let marker = (marked as NSString).range(of: "|")
    let text = (marked as NSString).replacingCharacters(in: marker, with: "")
    return SQLAutocompleteProvider().getSuggestions(
      for: text, at: marker.location, dialect: .redis)
  }

  private func suggest(_ marked: String) -> [String] { suggestions(marked).map(\.text) }
}

extension AutocompleteSuggestionType {
  fileprivate var isKeyword: Bool {
    if case .keyword = self { return true }
    return false
  }
}
