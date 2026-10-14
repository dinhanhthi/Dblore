// CommitStyleMigrationTests.swift
// Migration from protected mode and SafeMode onto CommitStyle

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Commit Style Migration")
struct CommitStyleMigrationTests {

  @Test("Strength order is immediate, confirm, review, password")
  func strengthOrder() {
    #expect(CommitStyle.immediate.strength < CommitStyle.confirm.strength)
    #expect(CommitStyle.confirm.strength < CommitStyle.review.strength)
    #expect(CommitStyle.review.strength < CommitStyle.password.strength)
  }

  @Test("Protected mode migrates to review for every safe mode")
  func protectedModeMigratesToReview() {
    let modes: [SafeMode?] = [nil, .silent, .alertRead, .alertAll, .safeRead, .safeAll]
    for mode in modes {
      #expect(CommitStyle.migrate(protectedMode: true, safeMode: mode) == .review)
    }
  }

  @Test("Unprotected nil safe mode stays nil")
  func unprotectedNilStaysNil() {
    #expect(CommitStyle.migrate(protectedMode: false, safeMode: nil) == nil)
  }

  @Test("Unprotected safe mode maps onto a commit style")
  func unprotectedSafeModeMigrates() {
    #expect(CommitStyle.migrate(protectedMode: false, safeMode: .silent) == .immediate)
    #expect(CommitStyle.migrate(protectedMode: false, safeMode: .alertRead) == .confirm)
    #expect(CommitStyle.migrate(protectedMode: false, safeMode: .alertAll) == .confirm)
    #expect(CommitStyle.migrate(protectedMode: false, safeMode: .safeRead) == .password)
    #expect(CommitStyle.migrate(protectedMode: false, safeMode: .safeAll) == .password)
  }

  @Test("Legacy projection pairs")
  func legacyProjectionPairs() {
    #expect(CommitStyle.immediate.legacyProjection.protectedMode == false)
    #expect(CommitStyle.immediate.legacyProjection.safeMode == .silent)
    #expect(CommitStyle.confirm.legacyProjection.protectedMode == false)
    #expect(CommitStyle.confirm.legacyProjection.safeMode == .alertRead)
    #expect(CommitStyle.review.legacyProjection.protectedMode == true)
    #expect(CommitStyle.review.legacyProjection.safeMode == .silent)
    #expect(CommitStyle.password.legacyProjection.protectedMode == false)
    #expect(CommitStyle.password.legacyProjection.safeMode == .safeRead)
  }

  @Test("Absent global key migrates to review and ignores the stored mode")
  func missingGlobalKeyIsReview() {
    let stored: [SafeMode?] = [nil, .silent, .alertRead, .alertAll, .safeRead, .safeAll]
    for mode in stored {
      #expect(CommitStyle.migrateGlobal(stored: mode, keyPresent: false) == .review)
    }
  }

  @Test("Present global key maps the stored safe mode")
  func presentGlobalKeyMigratesStoredMode() {
    #expect(CommitStyle.migrateGlobal(stored: .silent, keyPresent: true) == .immediate)
    #expect(CommitStyle.migrateGlobal(stored: .alertRead, keyPresent: true) == .confirm)
    #expect(CommitStyle.migrateGlobal(stored: .alertAll, keyPresent: true) == .confirm)
    #expect(CommitStyle.migrateGlobal(stored: .safeRead, keyPresent: true) == .password)
    #expect(CommitStyle.migrateGlobal(stored: .safeAll, keyPresent: true) == .password)
    #expect(CommitStyle.migrateGlobal(stored: nil, keyPresent: true) == .review)
  }

  @Test("Only confirm and password confirm writes")
  func confirmsWritesOnlyForConfirmAndPassword() {
    #expect(CommitStyle.immediate.confirmsWrites == false)
    #expect(CommitStyle.confirm.confirmsWrites == true)
    #expect(CommitStyle.review.confirmsWrites == false)
    #expect(CommitStyle.password.confirmsWrites == true)
  }

  @Test("Only password requires a password")
  func requiresPasswordOnlyForPassword() {
    #expect(CommitStyle.immediate.requiresPassword == false)
    #expect(CommitStyle.confirm.requiresPassword == false)
    #expect(CommitStyle.review.requiresPassword == false)
    #expect(CommitStyle.password.requiresPassword == true)
  }

  @Test("Only review opens a review transaction")
  func opensReviewTransactionOnlyForReview() {
    #expect(CommitStyle.immediate.opensReviewTransaction == false)
    #expect(CommitStyle.confirm.opensReviewTransaction == false)
    #expect(CommitStyle.review.opensReviewTransaction == true)
    #expect(CommitStyle.password.opensReviewTransaction == false)
  }

  // MARK: - Engines with transactions (characterization of today's behavior)

  private static let safeModes: [SafeMode?] = [nil] + SafeMode.allCases
  private static let storedStyles: [CommitStyle?] = [nil] + CommitStyle.allCases
  /// Every engine but MongoDB, which has no transactions (see the section below).
  private static let transactionalEngines: [DatabaseType] = [.postgresql, .sqlite, .duckdb, .mysql]

  /// A config of `type` with every commit-style input set directly (init forces a nil style).
  private static func config(
    _ type: DatabaseType, protectedMode: Bool, safeMode: SafeMode?, commitStyle: CommitStyle?
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      databaseType: type, safeMode: safeMode, protectedMode: protectedMode, readOnlyFile: false)
    config.commitStyle = commitStyle
    return config
  }

  /// Today's rule: Protected mode wins as Review; otherwise the stored style, else the migrated
  /// safe mode, else the fallback, with Review demoted to Confirm.
  private static func expectedTransactionalStyle(
    protectedMode: Bool, safeMode: SafeMode?, commitStyle: CommitStyle?, fallback: CommitStyle
  ) -> CommitStyle {
    if protectedMode { return .review }
    let candidate =
      commitStyle ?? CommitStyle.migrate(protectedMode: false, safeMode: safeMode) ?? fallback
    return candidate == .review ? .confirm : candidate
  }

  @Test("Every engine resolves the commit style as today for every combination")
  func resolvedCommitStyleUnchangedForEveryEngine() {
    for type in Self.transactionalEngines {
      #expect(type.capabilities.supportsTransactions)
      for protectedMode in [false, true] {
        for safeMode in Self.safeModes {
          for commitStyle in Self.storedStyles {
            for fallback in CommitStyle.allCases {
              let config = Self.config(
                type, protectedMode: protectedMode, safeMode: safeMode, commitStyle: commitStyle)
              let expected = Self.expectedTransactionalStyle(
                protectedMode: protectedMode, safeMode: safeMode, commitStyle: commitStyle,
                fallback: fallback)
              #expect(
                config.resolvedCommitStyle(fallback: fallback) == expected,
                "\(type) protected=\(protectedMode) safe=\(String(describing: safeMode)) style=\(String(describing: commitStyle)) fallback=\(fallback)"
              )
            }
          }
        }
      }
    }
  }

  @Test("Every engine builds the protection policy as today for every combination")
  func protectionPolicyUnchangedForEveryEngine() {
    for type in Self.transactionalEngines {
      for protectedMode in [false, true] {
        for safeMode in Self.safeModes {
          for commitStyle in Self.storedStyles {
            let policy = ProtectionPolicy(
              config: Self.config(
                type, protectedMode: protectedMode, safeMode: safeMode, commitStyle: commitStyle))
            #expect(policy.protectionLevel == .none)
            #expect(policy.safeMode == safeMode)
            #expect(policy.protectedMode == protectedMode)
          }
        }
      }
    }
  }

  // MARK: - Engines without transactions (MongoDB)

  @Test("MongoDB: Protected mode raises the commit style to at least Confirm, never Review")
  func mongoDBEntryPointsRaiseProtectedModeToConfirm() {
    #expect(!DatabaseType.mongodb.capabilities.supportsTransactions)
    for protectedMode in [false, true] {
      for safeMode in Self.safeModes {
        for commitStyle in Self.storedStyles {
          let config = Self.config(
            .mongodb, protectedMode: protectedMode, safeMode: safeMode, commitStyle: commitStyle)
          for fallback in CommitStyle.allCases {
            let expected = Self.expectedWithoutTransactions(
              protectedMode: protectedMode, safeMode: safeMode, commitStyle: commitStyle,
              fallback: fallback)
            #expect(config.resolvedCommitStyle(fallback: fallback) == expected)
          }
          let policy = ProtectionPolicy(config: config)
          #expect(policy.protectedMode == false)
          #expect(policy.safeMode == safeMode)
        }
      }
    }
  }

  @Test("Without transactions Protected mode resolves to Confirm, never Review")
  func noTransactionsDegradesReviewToConfirm() {
    for safeMode in Self.safeModes {
      for fallback in CommitStyle.allCases {
        let config = Self.config(
          .postgresql, protectedMode: true, safeMode: safeMode, commitStyle: nil)
        #expect(
          config.resolvedCommitStyle(fallback: fallback, supportsTransactions: false) == .confirm)
      }
    }
    let storedReview = Self.config(
      .postgresql, protectedMode: true, safeMode: nil, commitStyle: .review)
    #expect(
      storedReview.resolvedCommitStyle(fallback: .review, supportsTransactions: false) == .confirm)
  }

  @Test("Without transactions Protected mode raises the style to at least Confirm, not Review")
  func noTransactionsProtectedModeRaisesToConfirm() {
    for protectedMode in [false, true] {
      for safeMode in Self.safeModes {
        for commitStyle in Self.storedStyles {
          for fallback in CommitStyle.allCases {
            let config = Self.config(
              .postgresql, protectedMode: protectedMode, safeMode: safeMode,
              commitStyle: commitStyle)
            let expected = Self.expectedWithoutTransactions(
              protectedMode: protectedMode, safeMode: safeMode, commitStyle: commitStyle,
              fallback: fallback)
            #expect(
              config.resolvedCommitStyle(fallback: fallback, supportsTransactions: false)
                == expected)
          }
        }
      }
    }
    // A stored Password style stays Password with Protected mode on; Immediate becomes Confirm.
    let storedPassword = Self.config(
      .postgresql, protectedMode: true, safeMode: nil, commitStyle: .password)
    #expect(
      storedPassword.resolvedCommitStyle(fallback: .immediate, supportsTransactions: false)
        == .password)
    let storedImmediate = Self.config(
      .postgresql, protectedMode: true, safeMode: nil, commitStyle: .immediate)
    #expect(
      storedImmediate.resolvedCommitStyle(fallback: .immediate, supportsTransactions: false)
        == .confirm)
  }

  /// The stored style, else the legacy pair (a Protected one migrates to Review), else the
  /// fallback; Review is demoted to Confirm, and Protected mode raises a weaker style to Confirm.
  private static func expectedWithoutTransactions(
    protectedMode: Bool, safeMode: SafeMode?, commitStyle: CommitStyle?, fallback: CommitStyle
  ) -> CommitStyle {
    let candidate =
      commitStyle
      ?? CommitStyle.migrate(protectedMode: protectedMode, safeMode: safeMode) ?? fallback
    let demoted: CommitStyle = candidate == .review ? .confirm : candidate
    return protectedMode && demoted.strength < CommitStyle.confirm.strength ? .confirm : demoted
  }

  @Test("Without transactions the protection policy drops Protected mode only")
  func noTransactionsPolicyIgnoresProtectedMode() {
    for protectedMode in [false, true] {
      for safeMode in Self.safeModes {
        var config = Self.config(
          .postgresql, protectedMode: protectedMode, safeMode: safeMode, commitStyle: nil)
        config.protectionLevel = .schemaOnly
        let policy = ProtectionPolicy(config: config, supportsTransactions: false)
        #expect(policy.protectedMode == false)
        #expect(policy.protectionLevel == .schemaOnly)
        #expect(policy.safeMode == safeMode)
      }
    }
  }

  @Test("With transactions the helpers match the public entry points")
  func helpersWithTransactionsMatchEntryPoints() {
    let config = Self.config(.postgresql, protectedMode: true, safeMode: nil, commitStyle: nil)
    #expect(config.resolvedCommitStyle(fallback: .immediate, supportsTransactions: true) == .review)
    #expect(ProtectionPolicy(config: config, supportsTransactions: true).protectedMode)
  }

  // MARK: - Gate backstop for MongoDB under Protected mode

  private static let mongoRefusal =
    "MongoDB has no transactions, so Protected mode cannot hold this change. Use Confirm."

  private static func mongoDecision(_ text: String, protectedMode: Bool) -> GateDecision {
    DatabaseConnectionManager.evaluate(
      SQLStatementClassifier.classify(text, dialect: .mongodb),
      policy: ProtectionPolicy(protectionLevel: .none, protectedMode: protectedMode),
      dialect: .mongodb)
  }

  @Test(
    "Protected mode refuses a MongoDB write at the gate",
    arguments: [
      "db.c.insertOne({a: 1})",
      "db.c.updateOne({a: 1}, {$set: {b: 2}})",
      "db.c.deleteMany({})",
      "db.c.aggregate([{$out: 'x'}])",
    ])
  func protectedModeRefusesMongoWrite(text: String) {
    guard case .blocked(let index, _, let reason) = Self.mongoDecision(text, protectedMode: true)
    else {
      Issue.record("Expected blocked: \(text)")
      return
    }
    #expect(index == 0)
    #expect(reason == Self.mongoRefusal)
  }

  @Test("Protected mode does not refuse a MongoDB read")
  func protectedModeAllowsMongoRead() {
    #expect(Self.mongoDecision("db.c.find({a: 1})", protectedMode: true) == .allowed)
  }

  @Test("Without Protected mode a MongoDB write passes the gate")
  func unprotectedAllowsMongoWrite() {
    #expect(Self.mongoDecision("db.c.insertOne({a: 1})", protectedMode: false) == .allowed)
  }

  @Test("The MongoDB refusal never applies to SQL dialects")
  func backstopIsMongoOnly() {
    let policy = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    for dialect in [SQLDialect.postgresql, .mysql, .sqlite, .duckdb] {
      let decision = DatabaseConnectionManager.evaluate(
        SQLStatementClassifier.classify("INSERT INTO t VALUES (1)", dialect: dialect),
        policy: policy, dialect: dialect)
      #expect(decision == .allowed)
    }
  }
}
