// LaunchSessionTests.swift
// Launch snapshot: Codable round trip, group order, UserDefaults load, passwords
// stripped from the stored JSON, the pure restore plan, descriptor capture, and
// reapplying overlay text when a snapshot is reopened.

import Foundation
import Testing

@testable import Dblore

@Suite("Launch session")
@MainActor
struct LaunchSessionTests {
  private let secret = "dblore-snapshot-secret"

  private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let name = "LaunchSessionTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    try body(suite)
  }

  @Test("Codable round trip keeps frames, tab groups, overlays, and bookmarks")
  func roundTrip() throws {
    let cellID = UUID()
    let notebookTab = UUID()
    let scriptTab = UUID()
    let workspaceID = UUID()
    let fileURL = URL(fileURLWithPath: "/tmp/notes.sqlws")
    let bookmark = Data([0xAB, 0xCD])
    let folderBookmark = Data([0x01, 0x02, 0x03])
    let session = LaunchSession(windows: [
      window(
        x: 10, y: 20, width: 800, height: 600,
        miniaturized: true, group: 0, tab: 0, selected: true,
        content: .welcome),
      window(
        x: 30, y: 40, width: 900, height: 700,
        miniaturized: false, group: 0, tab: 1, selected: false,
        content: .workspace(
          LaunchWorkspace(
            fileURL: fileURL,
            bookmark: bookmark,
            folderBookmark: folderBookmark,
            workspace: Workspace(
              id: workspaceID,
              name: "Draft",
              connectionConfig: ConnectionConfig(
                host: "db.example", database: "app", username: "ada", password: "")),
            textOverlays: [
              LaunchTextOverlay(
                tabId: notebookTab,
                text: .notebook([
                  LaunchNotebookCell(id: cellID, cellType: .sql, content: "select 1")
                ])),
              LaunchTextOverlay(tabId: scriptTab, text: .script("select 2")),
            ]
          ))),
    ])

    let data = try JSONEncoder().encode(session)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("statementResults"))
    #expect(!json.contains("\"result\""))

    let decoded = try JSONDecoder().decode(LaunchSession.self, from: data)
    #expect(decoded.windows.count == 2)
    #expect(decoded.windows[0].frame == WindowFrame(x: 10, y: 20, width: 800, height: 600))
    #expect(decoded.windows[0].isMiniaturized == true)
    #expect(decoded.windows[0].groupIndex == 0)
    #expect(decoded.windows[0].tabIndex == 0)
    #expect(decoded.windows[0].isSelectedInGroup == true)
    guard case .welcome = decoded.windows[0].content else {
      Issue.record("Expected the first window to stay Welcome")
      return
    }

    let restored = decoded.windows[1]
    #expect(restored.frame == WindowFrame(x: 30, y: 40, width: 900, height: 700))
    #expect(restored.isMiniaturized == false)
    #expect(restored.isSelectedInGroup == false)
    guard case .workspace(let workspace) = restored.content else {
      Issue.record("Expected the second window to stay a workspace")
      return
    }
    #expect(workspace.fileURL == fileURL)
    #expect(workspace.bookmark == bookmark)
    #expect(workspace.folderBookmark == folderBookmark)
    #expect(workspace.workspace?.id == workspaceID)
    #expect(workspace.workspace?.name == "Draft")
    #expect(workspace.workspace?.connectionConfig?.host == "db.example")
    #expect(workspace.textOverlays.count == 2)
    #expect(workspace.textOverlays[0].tabId == notebookTab)
    #expect(
      workspace.textOverlays[0].text
        == .notebook([LaunchNotebookCell(id: cellID, cellType: .sql, content: "select 1")]))
    #expect(workspace.textOverlays[1].tabId == scriptTab)
    #expect(workspace.textOverlays[1].text == .script("select 2"))
    #expect(LaunchRestorer.isRestoring == false)
  }

  @Test("grouped orders groups by groupIndex and windows by tabIndex")
  func groupedOrdering() {
    let session = LaunchSession(windows: [
      window(x: 101, group: 1, tab: 1, selected: false, content: .welcome),
      window(x: 1, group: 0, tab: 1, selected: false, content: .welcome),
      window(x: 100, group: 1, tab: 0, selected: true, content: .welcome),
      window(x: 0, group: 0, tab: 0, selected: true, content: .welcome),
    ])

    let groups = session.grouped
    #expect(groups.map { $0.map(\.groupIndex) } == [[0, 0], [1, 1]])
    #expect(groups.map { $0.map(\.tabIndex) } == [[0, 1], [0, 1]])
    #expect(groups.map { $0.map(\.isSelectedInGroup) } == [[true, false], [true, false]])
    #expect(groups.map { $0.map(\.frame.x) } == [[0, 1], [100, 101]])
  }

  @Test("load returns nil for a missing or corrupt snapshot")
  func loadMissingOrCorrupt() throws {
    try withIsolatedDefaults { suite in
      let store = LaunchSessionStore(defaults: suite)
      if case .some = store.load() {
        Issue.record("A missing snapshot should load as nil")
      }

      suite.set(Data("not json".utf8), forKey: LaunchSessionStore.key)
      if case .some = store.load() {
        Issue.record("Corrupt snapshot data should load as nil")
      }
    }
  }

  @Test("The stored snapshot JSON does not contain the connection password")
  func storedJSONOmitsPassword() throws {
    try withIsolatedDefaults { suite in
      var connection = ConnectionConfig(
        host: "db.example", database: "app", username: "ada", password: secret)
      let session = LaunchSession(windows: [
        window(
          x: 0, group: 0, tab: 0, selected: true,
          content: .workspace(
            LaunchWorkspace(
              workspace: Workspace(name: "Scratch", connectionConfig: connection))))
      ])

      let store = LaunchSessionStore(defaults: suite)
      store.save(session)

      let data = try #require(suite.data(forKey: LaunchSessionStore.key))
      let json = try #require(String(data: data, encoding: .utf8))
      #expect(!json.contains(secret))

      guard case .workspace(let restored) = store.load()?.windows.first?.content else {
        Issue.record("Expected the saved untitled workspace to load")
        return
      }
      #expect(restored.workspace?.name == "Scratch")
      #expect(restored.workspace?.connectionConfig?.password == "")
      #expect(connection.password == secret)
    }
  }

  @Test("Welcome, a missing snapshot, or an empty snapshot plans Welcome")
  func welcomeWhenNothingToRestore() {
    let full = LaunchSession(windows: [
      savedWindow(url: URL(fileURLWithPath: "/tmp/kept.sqlws"), group: 0, tab: 0)
    ])
    guard
      case .welcome = LaunchRestorer.plan(
        behavior: .welcome, session: full, readable: { _ in true })
    else {
      Issue.record("Show Welcome screen ignores a full snapshot")
      return
    }
    guard
      case .welcome = LaunchRestorer.plan(
        behavior: .restoreLastSession, session: nil, readable: { _ in true })
    else {
      Issue.record("A missing snapshot plans Welcome")
      return
    }
    guard
      case .welcome = LaunchRestorer.plan(
        behavior: .restoreLastSession, session: LaunchSession(windows: []), readable: { _ in true })
    else {
      Issue.record("An empty snapshot plans Welcome")
      return
    }
  }

  @Test("An unreadable saved workspace is dropped, and an empty group goes with it")
  func dropsUnreadableWorkspaceAndEmptyGroup() {
    let kept = URL(fileURLWithPath: "/tmp/kept.sqlws")
    let sibling = URL(fileURLWithPath: "/tmp/sibling.sqlws")
    let alone = URL(fileURLWithPath: "/tmp/alone.sqlws")
    let session = LaunchSession(windows: [
      savedWindow(url: kept, group: 0, tab: 0, selected: true),
      savedWindow(url: sibling, group: 0, tab: 1, selected: false),
      savedWindow(url: alone, group: 1, tab: 0, selected: true),
      window(x: 50, group: 2, tab: 0, selected: true, content: .welcome),
    ])

    let plan = LaunchRestorer.plan(behavior: .restoreLastSession, session: session) { url in
      url == kept
    }
    guard case .restore(let restored) = plan else {
      Issue.record("Expected a restore with the readable workspace still open")
      return
    }

    let groups = restored.grouped
    #expect(groups.map { $0.map(\.groupIndex) } == [[0], [2]])
    #expect(groups[0].count == 1)
    #expect(groups[0][0].isSelectedInGroup == true)
    guard case .workspace(let keptWorkspace) = groups[0][0].content else {
      Issue.record("Expected the readable workspace to remain")
      return
    }
    #expect(keptWorkspace.fileURL == kept)
    guard case .welcome = groups[1][0].content else {
      Issue.record("Expected the Welcome window to remain")
      return
    }
    let urls = restored.windows.compactMap { window -> URL? in
      guard case .workspace(let workspace) = window.content else { return nil }
      return workspace.fileURL
    }
    #expect(urls == [kept])
  }

  @Test("Every saved workspace file missing plans Welcome")
  func allFilesMissingPlansWelcome() {
    let session = LaunchSession(windows: [
      savedWindow(url: URL(fileURLWithPath: "/tmp/a.sqlws"), group: 0, tab: 0),
      savedWindow(url: URL(fileURLWithPath: "/tmp/b.sqlws"), group: 1, tab: 0),
    ])
    guard
      case .welcome = LaunchRestorer.plan(
        behavior: .restoreLastSession, session: session, readable: { _ in false })
    else {
      Issue.record("When every saved file is unreadable, launch shows Welcome")
      return
    }
  }

  @Test("An untitled workspace stays when saved files are missing")
  func untitledSurvivesMissingFile() {
    let tabID = UUID()
    let session = LaunchSession(windows: [
      window(
        x: 4, group: 0, tab: 0, selected: true,
        content: .workspace(
          LaunchWorkspace(
            workspace: Workspace(name: "Scratch"),
            textOverlays: [
              LaunchTextOverlay(tabId: tabID, text: .script("select draft"))
            ]
          ))),
      savedWindow(url: URL(fileURLWithPath: "/tmp/missing.sqlws"), group: 1, tab: 0),
    ])

    let plan = LaunchRestorer.plan(behavior: .restoreLastSession, session: session) { _ in false }
    guard case .restore(let restored) = plan else {
      Issue.record("Expected the untitled workspace to be restored")
      return
    }
    #expect(restored.grouped.map { $0.map(\.groupIndex) } == [[0]])
    guard case .workspace(let workspace) = restored.windows.first?.content else {
      Issue.record("Expected the remaining window to be the untitled workspace")
      return
    }
    #expect(workspace.fileURL == nil)
    #expect(workspace.workspace?.name == "Scratch")
    #expect(
      workspace.textOverlays == [LaunchTextOverlay(tabId: tabID, text: .script("select draft"))])
  }

  @Test("Two windows in one group and a lone window keep tab order and front-to-back groups")
  func groupsTabbedWindowsAndALoneWindow() {
    let session = LaunchSessionCapture.session(
      windows: [
        descriptor(group: "pair", tab: 0, selected: false, ordered: 5, x: 20),
        descriptor(
          group: "lone", tab: 0, selected: true, ordered: 0, x: 10, miniaturized: true),
        descriptor(group: "pair", tab: 1, selected: true, ordered: 1, x: 30),
      ],
      workspaces: [:])

    let groups = session.grouped
    #expect(groups.map { $0.map(\.groupIndex) } == [[0], [1, 1]])
    #expect(groups.map { $0.map(\.tabIndex) } == [[0], [0, 1]])
    #expect(groups.map { $0.map(\.isSelectedInGroup) } == [[true], [false, true]])
    #expect(groups.map { $0.map(\.frame.x) } == [[10], [20, 30]])
    #expect(groups[0][0].isMiniaturized == true)
    #expect(groups[1][1].isMiniaturized == false)
  }

  @Test("Welcome, a saved workspace, and an untitled workspace record their own content")
  func welcomeSavedAndUntitled() throws {
    let savedURL = URL(fileURLWithPath: "/tmp/notes.sqlws")
    let bookmark = Data([0x11, 0x22])
    let folderBookmark = Data([0x33])
    let saved = WorkspaceManager(
      workspace: Workspace(name: "Notes", fileURL: savedURL), restoreTabs: false)
    saved.workspaceBookmark = bookmark
    saved.folderBookmark = folderBookmark

    let connection = ConnectionConfig(
      host: "db.example", database: "app", username: "ada", password: secret)
    let untitled = WorkspaceManager(
      workspace: Workspace(name: "Scratch", connectionConfig: connection), restoreTabs: false)

    let session = LaunchSessionCapture.session(
      windows: [
        descriptor(group: "welcome", tab: 0, selected: true, ordered: 2, x: 1),
        descriptor(
          group: "saved", tab: 0, selected: true, ordered: 1, x: 2,
          content: .workspace(saved.id)),
        descriptor(
          group: "untitled", tab: 0, selected: true, ordered: 0, x: 3,
          content: .workspace(untitled.id)),
      ],
      workspaces: [saved.id: saved, untitled.id: untitled])

    #expect(session.grouped.map { $0.map(\.frame.x) } == [[3], [2], [1]])
    guard case .welcome = session.grouped[2][0].content else {
      Issue.record("Expected the back window to stay Welcome")
      return
    }

    guard case .workspace(let savedWorkspace) = session.grouped[1][0].content else {
      Issue.record("Expected the middle window to be the saved workspace")
      return
    }
    #expect(savedWorkspace.fileURL == savedURL)
    #expect(savedWorkspace.bookmark == bookmark)
    #expect(savedWorkspace.folderBookmark == folderBookmark)
    #expect(savedWorkspace.workspace == nil)
    #expect(savedWorkspace.textOverlays.isEmpty)

    guard case .workspace(let draft) = session.grouped[0][0].content else {
      Issue.record("Expected the front window to be the untitled workspace")
      return
    }
    #expect(draft.fileURL == nil)
    #expect(draft.bookmark == nil)
    #expect(draft.workspace?.name == "Scratch")
    #expect(draft.workspace?.connectionConfig?.password == "")
    #expect(untitled.workspace.connectionConfig?.password == secret)

    let data = try JSONEncoder().encode(session)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains(secret))
  }

  @Test("Dirty live text is kept, a clean saved file is not, and a preview tab is dropped")
  func overlaysFollowLiveEditors() throws {
    let manager = WorkspaceManager(workspace: Workspace(name: "Draft"), restoreTabs: false)
    let notebookID = manager.newNotebook()
    let cellID = UUID()
    let notebookModel = try #require(manager.viewModel(for: notebookID))
    notebookModel.notebook.cells = [
      NotebookCell(id: cellID, cellType: .sql, content: "select live")
    ]
    let notebookDocument = try #require(manager.notebookDocument(for: notebookID))
    notebookDocument.notebook.cells = [
      NotebookCell(cellType: .sql, content: "select stale")
    ]

    let cleanID = manager.newSQLFile()
    editTab(cleanID, in: manager, fileURL: URL(fileURLWithPath: "/tmp/clean.sql"), dirty: false)
    try #require(manager.viewModel(for: cleanID)).editorContent = "select clean"

    let dirtyID = manager.newSQLFile()
    editTab(dirtyID, in: manager, fileURL: URL(fileURLWithPath: "/tmp/dirty.sql"), dirty: true)
    try #require(manager.editorDocument(for: dirtyID)).content = "select stale sql"
    try #require(manager.viewModel(for: dirtyID)).editorContent = "select dirty"

    let previewID = manager.newSQLFile()
    editTab(previewID, in: manager, dirty: true, preview: true)
    try #require(manager.viewModel(for: previewID)).editorContent = "select preview"

    let session = LaunchSessionCapture.session(
      windows: [
        descriptor(
          group: "draft", tab: 0, selected: true, ordered: 0, x: 4,
          content: .workspace(manager.id))
      ],
      workspaces: [manager.id: manager])

    guard case .workspace(let workspace) = session.windows.first?.content else {
      Issue.record("Expected the captured window to be the draft workspace")
      return
    }
    let overlays = Dictionary(
      uniqueKeysWithValues: workspace.textOverlays.map { ($0.tabId, $0.text) })
    #expect(
      overlays[notebookID]
        == .notebook([LaunchNotebookCell(id: cellID, cellType: .sql, content: "select live")]))
    #expect(overlays[dirtyID] == .script("select dirty"))
    #expect(overlays[cleanID] == nil)
    #expect(overlays[previewID] == nil)

    let savedTabIDs = Set(workspace.workspace?.tabs.map(\.id) ?? [])
    #expect(savedTabIDs.contains(notebookID))
    #expect(savedTabIDs.contains(cleanID))
    #expect(savedTabIDs.contains(dirtyID))
    #expect(!savedTabIDs.contains(previewID))
  }

  @Test("restoreOverlayTab replaces an existing tab's text and marks it dirty")
  func restoreOverlayTabReplacesExistingText() throws {
    defer { LaunchRestorer.resetLaunchState() }
    let manager = WorkspaceManager(workspace: Workspace(name: "Draft"), restoreTabs: false)
    let tabID = manager.newNotebook()
    manager.markClean(tabId: tabID)
    let cellID = UUID()

    manager.restoreOverlayTab(
      LaunchTextOverlay(
        tabId: tabID,
        text: .notebook([
          LaunchNotebookCell(id: cellID, cellType: .sql, content: "select restored")
        ])))

    let viewModel = try #require(manager.viewModel(for: tabID))
    #expect(viewModel.notebook.cells.map(\.id) == [cellID])
    #expect(viewModel.notebook.cells.map(\.content) == ["select restored"])
    let document = try #require(manager.notebookDocument(for: tabID))
    #expect(document.notebook.cells.map(\.content) == ["select restored"])
    #expect(manager.tabs.first { $0.id == tabID }?.isDirty == true)
    #expect(manager.tabs.count == 1)
  }

  @Test("Notebook overlay keeps saved cell metadata, updates content, and follows overlay order")
  func notebookOverlayKeepsCellMetadata() throws {
    defer { LaunchRestorer.resetLaunchState() }
    let manager = WorkspaceManager(workspace: Workspace(name: "Draft"), restoreTabs: false)
    let tabID = manager.newNotebook()
    let document = try #require(manager.notebookDocument(for: tabID))
    let savedID = UUID()
    let spec = ChartSpec(kind: .bar, xColumn: nil, yColumns: ["y"], seriesColumn: nil)
    let parameters = [QueryParameter(name: "id", value: "4")]
    var notebook = document.notebook
    notebook.cells = [
      NotebookCell(
        id: savedID, content: "select saved", isResultVisible: false, chartSpec: spec,
        parameters: parameters, savesParameterValues: true)
    ]
    document.notebook = notebook
    let freshID = UUID()

    manager.restoreOverlayTab(
      LaunchTextOverlay(
        tabId: tabID,
        text: .notebook([
          LaunchNotebookCell(id: freshID, cellType: .sql, content: "select fresh"),
          LaunchNotebookCell(id: savedID, cellType: .sql, content: "select edited"),
        ])))

    let viewModel = try #require(manager.viewModel(for: tabID))
    let restored = try #require(manager.notebookDocument(for: tabID)).notebook.cells
    for cells in [restored, viewModel.notebook.cells] {
      #expect(cells.map(\.id) == [freshID, savedID])
      #expect(cells.map(\.content) == ["select fresh", "select edited"])
      #expect(cells[1].chartSpec == spec)
      #expect(cells[1].parameters == parameters)
      #expect(cells[1].savesParameterValues == true)
      #expect(cells[1].isResultVisible == false)
      #expect(cells[0].chartSpec == nil)
      #expect(cells[0].parameters.isEmpty)
    }
  }

  @Test("restoreOverlayTab creates a missing tab with the overlay id and text")
  func restoreOverlayTabCreatesMissingTab() throws {
    defer { LaunchRestorer.resetLaunchState() }
    let manager = WorkspaceManager(workspace: Workspace(name: "Draft"), restoreTabs: false)
    let tabID = UUID()

    manager.restoreOverlayTab(
      LaunchTextOverlay(tabId: tabID, text: .script("select missing")))

    let tab = try #require(manager.tabs.first { $0.id == tabID })
    #expect(tab.isDirty == true)
    #expect(manager.viewModel(for: tabID)?.editorContent == "select missing")
    #expect(manager.editorDocument(for: tabID)?.content == "select missing")
  }

  @Test("Markdown overlay text and a markdown tab reference survive a Codable round trip")
  func markdownRoundTrip() throws {
    let text = LaunchOverlayText.markdown("# a\r\n")
    let decodedText = try JSONDecoder().decode(
      LaunchOverlayText.self, from: JSONEncoder().encode(text))
    #expect(decodedText == text)

    let reference = WorkspaceTabReference(
      fileURL: URL(fileURLWithPath: "/tmp/note.md"), documentType: .markdown, title: "note.md")
    let decodedReference = try JSONDecoder().decode(
      WorkspaceTabReference.self, from: JSONEncoder().encode(reference))
    #expect(decodedReference == reference)
  }

  @Test("A dirty untitled markdown note is captured as markdown text")
  func dirtyMarkdownNoteCaptured() throws {
    let manager = WorkspaceManager(workspace: Workspace(name: "Draft"), restoreTabs: false)
    let noteID = manager.newMarkdownFile()
    try #require(manager.viewModel(for: noteID)).editorContent = "# live\r\n"

    let session = LaunchSessionCapture.session(
      windows: [
        descriptor(
          group: "draft", tab: 0, selected: true, ordered: 0, x: 4,
          content: .workspace(manager.id))
      ],
      workspaces: [manager.id: manager])

    guard case .workspace(let workspace) = session.windows.first?.content else {
      Issue.record("Expected the captured window to be the draft workspace")
      return
    }
    let overlays = Dictionary(
      uniqueKeysWithValues: workspace.textOverlays.map { ($0.tabId, $0.text) })
    #expect(overlays[noteID] == .markdown("# live\r\n"))
  }

  @Test("restoreOverlayTab creates a missing markdown note with the overlay id and text")
  func restoreMarkdownOverlayCreatesMissingTab() throws {
    defer { LaunchRestorer.resetLaunchState() }
    let manager = WorkspaceManager(workspace: Workspace(name: "Draft"), restoreTabs: false)
    let tabID = UUID()

    manager.restoreOverlayTab(LaunchTextOverlay(tabId: tabID, text: .markdown("# missing")))

    let tab = try #require(manager.tabs.first { $0.id == tabID })
    #expect(tab.documentType == .markdown)
    #expect(tab.title == "Untitled.md")
    #expect(tab.isDirty == true)
    let viewModel = try #require(manager.viewModel(for: tabID))
    #expect(viewModel.viewMode == .markdown)
    #expect(viewModel.editorContent == "# missing")
    #expect(manager.editorDocument(for: tabID)?.content == "# missing")
  }

  @Test("restoreOverlayTab replaces a markdown tab's text and keeps it a markdown note")
  func restoreMarkdownOverlayReplacesExistingText() throws {
    defer { LaunchRestorer.resetLaunchState() }
    let manager = WorkspaceManager(workspace: Workspace(name: "Draft"), restoreTabs: false)
    let tabID = manager.newMarkdownFile()
    manager.markClean(tabId: tabID)

    manager.restoreOverlayTab(LaunchTextOverlay(tabId: tabID, text: .markdown("# restored")))

    let tab = try #require(manager.tabs.first { $0.id == tabID })
    #expect(tab.documentType == .markdown)
    #expect(tab.isDirty == true)
    let viewModel = try #require(manager.viewModel(for: tabID))
    #expect(viewModel.viewMode == .markdown)
    #expect(viewModel.editorContent == "# restored")
    #expect(manager.editorDocument(for: tabID)?.content == "# restored")
    #expect(manager.tabs.count == 1)
  }

  @Test("takeFrontWindowClaim returns the front window once, then nil")
  func takeFrontWindowClaimIsSingleUse() {
    defer { LaunchRestorer.resetLaunchState() }
    LaunchRestorer.isRestoring = true
    let step = window(
      x: 12, y: 34, width: 800, height: 600,
      miniaturized: true, group: 0, tab: 0, selected: true, content: .welcome)
    LaunchRestorer.stageFrontWindowClaim(step)

    guard let claimed = LaunchRestorer.takeFrontWindowClaim() else {
      Issue.record("Expected the staged front window")
      return
    }
    #expect(claimed.frame == step.frame)
    #expect(claimed.isMiniaturized == true)
    #expect(claimed.groupIndex == 0)
    #expect(claimed.tabIndex == 0)
    if case .welcome = claimed.content {
    } else {
      Issue.record("Expected the claimed window to be Welcome")
    }
    if case .some = LaunchRestorer.takeFrontWindowClaim() {
      Issue.record("takeFrontWindowClaim should return nil after the front window is claimed")
    }
    #expect(LaunchRestorer.isRestoring == true)
  }

  private func window(
    x: Double,
    y: Double = 0,
    width: Double = 100,
    height: Double = 100,
    miniaturized: Bool = false,
    group: Int,
    tab: Int,
    selected: Bool,
    content: LaunchWindowContent
  ) -> LaunchWindow {
    LaunchWindow(
      frame: WindowFrame(x: x, y: y, width: width, height: height),
      isMiniaturized: miniaturized,
      groupIndex: group,
      tabIndex: tab,
      isSelectedInGroup: selected,
      content: content
    )
  }

  private func descriptor(
    group: String,
    tab: Int,
    selected: Bool,
    ordered: Int,
    x: Double,
    miniaturized: Bool = false,
    content: LaunchSessionCapture.WindowDescriptor.Content = .welcome
  ) -> LaunchSessionCapture.WindowDescriptor {
    LaunchSessionCapture.WindowDescriptor(
      frame: WindowFrame(x: x, y: 0, width: 800, height: 600),
      isMiniaturized: miniaturized,
      groupID: group,
      tabIndex: tab,
      isSelectedInGroup: selected,
      orderedIndex: ordered,
      content: content)
  }

  private func editTab(
    _ id: UUID, in manager: WorkspaceManager, fileURL: URL? = nil, dirty: Bool,
    preview: Bool = false
  ) {
    guard let index = manager.tabs.firstIndex(where: { $0.id == id }) else { return }
    manager.tabs[index].fileURL = fileURL
    manager.tabs[index].isDirty = dirty
    manager.tabs[index].isPreview = preview
  }

  private func savedWindow(url: URL, group: Int, tab: Int, selected: Bool = true) -> LaunchWindow {
    window(
      x: Double(group * 10 + tab),
      group: group,
      tab: tab,
      selected: selected,
      content: .workspace(LaunchWorkspace(fileURL: url))
    )
  }
}
