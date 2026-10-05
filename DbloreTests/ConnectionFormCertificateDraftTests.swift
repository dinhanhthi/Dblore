import Foundation
import Testing

@testable import Dblore

@Suite("Connection form certificate draft")
@MainActor
struct ConnectionFormCertificateDraftTests {
  @Test("Picked PEM files survive a host, port, database, or username edit")
  func pickedFilesSurviveFieldEdit() {
    #expect(
      ConnectionFormContent.keepsCertificateDraft(
        filesPicked: true, isHistoryLoad: false, engineChanged: false, isBlankForm: false))
  }

  @Test(
    "Saved certificate material is reloaded on a target edit, even after passphrase or CA edits")
  func storeLoadedDraftIsReloaded() {
    #expect(
      !ConnectionFormContent.keepsCertificateDraft(
        filesPicked: false, isHistoryLoad: false, engineChanged: false, isBlankForm: false))
  }

  @Test("Loading a Recent connection resets picked PEM files")
  func historyLoadResetsDraft() {
    #expect(
      !ConnectionFormContent.keepsCertificateDraft(
        filesPicked: true, isHistoryLoad: true, engineChanged: false, isBlankForm: false))
  }

  @Test("Changing the engine resets picked PEM files")
  func engineChangeResetsDraft() {
    #expect(
      !ConnectionFormContent.keepsCertificateDraft(
        filesPicked: true, isHistoryLoad: false, engineChanged: true, isBlankForm: false))
  }

  @Test("Blanking the form resets picked PEM files")
  func blankFormResetsDraft() {
    #expect(
      !ConnectionFormContent.keepsCertificateDraft(
        filesPicked: true, isHistoryLoad: false, engineChanged: false, isBlankForm: true))
  }
}
