// MySQLCharacterSets.swift
// The character sets and collations a MySQL / MariaDB server offers
// (information_schema.CHARACTER_SETS and COLLATIONS, or COLLATION_CHARACTER_SET_APPLICABILITY on
// MariaDB 10.10+), read once per connection for the structure
// editor's table options. The DDL builder writes a character set or collation only when it is
// listed here, so a name is never taken from free text.

import Foundation

nonisolated struct MySQLCharacterSets: Sendable, Equatable {
  struct CharacterSet: Sendable, Equatable {
    var name: String
    /// CHARACTER_SETS.DEFAULT_COLLATE_NAME
    var defaultCollation: String
    /// Every collation of the set, by name
    var collations: [String]
  }

  /// By name
  var characterSets: [CharacterSet]

  init(characterSets: [CharacterSet]) {
    self.characterSets = characterSets
  }

  /// From CHARACTER_SETS rows (name, default collation) and collation rows (name, set): COLLATIONS,
  /// or on MariaDB 10.10+ COLLATION_CHARACTER_SET_APPLICABILITY's full names
  /// (`utf8mb4_uca1400_ai_ci`). A collation without a set is skipped before this; a set's
  /// default collation is always listed with it.
  init(sets: [(name: String, defaultCollation: String)], collations: [(name: String, set: String)])
  {
    var bySet: [String: [String]] = [:]
    for collation in collations { bySet[collation.set, default: []].append(collation.name) }
    characterSets = sets.sorted { $0.name < $1.name }.map { set in
      var names = bySet[set.name] ?? []
      if !names.contains(set.defaultCollation) { names.append(set.defaultCollation) }
      return CharacterSet(
        name: set.name, defaultCollation: set.defaultCollation, collations: names.sorted())
    }
  }

  func characterSet(named name: String) -> CharacterSet? {
    characterSets.first { $0.name == name }
  }

  /// True when `charset` is listed and `collation` is one of its collations
  func contains(charset: String, collation: String) -> Bool {
    characterSet(named: charset)?.collations.contains(collation) == true
  }
}
