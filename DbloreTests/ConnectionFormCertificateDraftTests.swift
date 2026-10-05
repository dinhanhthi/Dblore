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

@Suite("Connection form certificate draft sources")
@MainActor
struct ConnectionFormCertificateDraftSourceTests {
  @Test("Replacing both halves of a saved pair from files counts as picked")
  func bothHalvesReplacedCountsAsPicked() {
    #expect(
      ConnectionFormContent.draftCameFromFiles(
        hasCertificate: true, certificatePicked: true, hasKey: true, keyPicked: true))
  }

  @Test("Replacing only the certificate of a saved pair does not count as picked")
  func certificateOnlyReplacedIsNotPicked() {
    #expect(
      !ConnectionFormContent.draftCameFromFiles(
        hasCertificate: true, certificatePicked: true, hasKey: true, keyPicked: false))
  }

  @Test("Replacing only the key of a saved pair does not count as picked")
  func keyOnlyReplacedIsNotPicked() {
    #expect(
      !ConnectionFormContent.draftCameFromFiles(
        hasCertificate: true, certificatePicked: false, hasKey: true, keyPicked: true))
  }

  @Test("One file picked into an empty draft counts as picked")
  func singlePickIntoEmptyDraftCountsAsPicked() {
    #expect(
      ConnectionFormContent.draftCameFromFiles(
        hasCertificate: true, certificatePicked: true, hasKey: false, keyPicked: false))
  }

  @Test("An empty draft does not count as picked")
  func emptyDraftIsNotPicked() {
    #expect(
      !ConnectionFormContent.draftCameFromFiles(
        hasCertificate: false, certificatePicked: false, hasKey: false, keyPicked: false))
  }
}

@Suite("Connection form kept certificate extras")
@MainActor
struct ConnectionFormKeptCertificateExtrasTests {
  @Test("A kept draft drops the CA and passphrase loaded with the old pair")
  func loadedExtrasAreDropped() {
    // Loaded pair, both halves picked, then a target edit: the draft is kept.
    #expect(
      ConnectionFormContent.keepsCertificateDraft(
        filesPicked: ConnectionFormContent.draftCameFromFiles(
          hasCertificate: true, certificatePicked: true, hasKey: true, keyPicked: true),
        isHistoryLoad: false, engineChanged: false, isBlankForm: false))
    let kept = ConnectionFormContent.keptCertificateExtras(
      caPEM: "old CA", caPicked: false, passphrase: "old secret", passphraseEdited: false)
    #expect(kept.caPEM == nil)
    #expect(kept.passphrase == "")
  }

  @Test("A CA picked in this form survives a target edit")
  func pickedCAIsKept() {
    let kept = ConnectionFormContent.keptCertificateExtras(
      caPEM: "new CA", caPicked: true, passphrase: "old secret", passphraseEdited: false)
    #expect(kept.caPEM == "new CA")
    #expect(kept.passphrase == "")
  }

  @Test("A passphrase typed in this form survives a target edit")
  func typedPassphraseIsKept() {
    let kept = ConnectionFormContent.keptCertificateExtras(
      caPEM: "old CA", caPicked: false, passphrase: "typed", passphraseEdited: true)
    #expect(kept.caPEM == nil)
    #expect(kept.passphrase == "typed")
  }
}

@Suite("Connection form engine change")
@MainActor
struct ConnectionFormEngineChangeTests {
  @Test("Target keys for two engines with the same fields differ in engine")
  func differentEngineIsDetected() {
    var postgres = ConnectionConfig(databaseType: .postgresql)
    postgres.host = "db.local"
    postgres.database = "app"
    postgres.username = "me"
    var sqlite = postgres
    sqlite.databaseType = .sqlite
    #expect(
      ConnectionFormContent.engineChanged(
        oldKey: ConnectionFormContent.connectionTargetKey(postgres),
        newKey: ConnectionFormContent.connectionTargetKey(sqlite)))
  }

  @Test("A host edit on the same engine is not an engine change")
  func sameEngineIsNotAChange() {
    var old = ConnectionConfig(databaseType: .postgresql)
    old.host = "db.local"
    var new = old
    new.host = "other.local"
    #expect(
      !ConnectionFormContent.engineChanged(
        oldKey: ConnectionFormContent.connectionTargetKey(old),
        newKey: ConnectionFormContent.connectionTargetKey(new)))
  }
}

@Suite("Connection form unremembered certificate")
@MainActor
struct ConnectionFormUnrememberedCertificateTests {
  private let material = ClientCertificateMaterial(
    certificatePEM: "cert", privateKeyPEM: "key", caPEM: "ca", passphrase: "secret")

  private func config(remember: Bool, host: String = "db.local") -> ConnectionConfig {
    var config = ConnectionConfig(databaseType: .postgresql)
    config.host = host
    config.database = "app"
    config.username = "me"
    config.rememberConnection = remember
    return config
  }

  @Test("An unremembered connection restores the active session material")
  func unrememberedUsesActiveMaterial() {
    let config = config(remember: false)
    let active = ClientCertificateStoreFactory.ConnectionMaterial(
      account: ClientCertificateStoreFactory.account(for: config), material: material)
    #expect(ConnectionFormContent.unrememberedMaterial(active, for: config) == material)
  }

  @Test("A remembered connection ignores the active session material")
  func rememberedIgnoresActiveMaterial() {
    let config = config(remember: true)
    let active = ClientCertificateStoreFactory.ConnectionMaterial(
      account: ClientCertificateStoreFactory.account(for: config), material: material)
    #expect(ConnectionFormContent.unrememberedMaterial(active, for: config) == nil)
  }

  @Test("Active material for another target is not restored")
  func otherAccountIsIgnored() {
    let active = ClientCertificateStoreFactory.ConnectionMaterial(
      account: ClientCertificateStoreFactory.account(for: config(remember: false, host: "a")),
      material: material)
    #expect(
      ConnectionFormContent.unrememberedMaterial(active, for: config(remember: false, host: "b"))
        == nil)
  }
}
