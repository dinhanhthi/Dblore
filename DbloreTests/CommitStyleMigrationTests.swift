// CommitStyleMigrationTests.swift
// Migration from protected mode and SafeMode onto CommitStyle

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Commit Style Migration")
struct CommitStyleMigrationTests {

  @Test("Workspace format stays at version 1")
  func workspaceFormatVersionStaysOne() {
    #expect(Workspace.currentVersion == 1)
  }

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
}
