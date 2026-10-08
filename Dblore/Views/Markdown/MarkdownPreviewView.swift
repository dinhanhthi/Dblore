//
//  MarkdownPreviewView.swift
//  Dblore
//
//  Preview mode for a Markdown note tab: hosts the bundled Milkdown editor in a WKWebView.
//  The pure bridge logic (messages, source sync, link policy, theme) lives in MarkdownPreviewBridge.
//

import SwiftUI
import WebKit

/// Owns the preview web view and the native side of the editor bridge.
@MainActor
@Observable
final class MarkdownPreviewController: NSObject, WKNavigationDelegate, WKUIDelegate {
  @ObservationIgnored let webView: WKWebView
  private(set) var isReady = false
  /// The editor page or its content failed to load; the preview cannot be shown
  private(set) var didFail = false

  @ObservationIgnored private let htmlURL: URL?
  @ObservationIgnored private var sync: MarkdownPreviewSync?
  @ObservationIgnored private var onText: ((String) -> Void)?
  /// Last note text known to the controller, re-shown after a web content process crash
  @ObservationIgnored private var latestText: String?
  @ObservationIgnored private var colorScheme: ColorScheme = .light
  @ObservationIgnored private var isPageLoaded = false
  @ObservationIgnored private var isLoadPending = false
  @ObservationIgnored private var allowsNextPageLoad = false

  private static let handlerName = "dblore"

  override init() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    webView = WKWebView(frame: .zero, configuration: configuration)
    htmlURL = Bundle.main.url(forResource: "markdown-editor", withExtension: "html")
    super.init()

    configuration.userContentController.add(
      WeakScriptMessageHandler(self), name: Self.handlerName)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.underPageBackgroundColor = NSColor(Color.appBackground)
    #if DEBUG
      webView.isInspectable = true
    #endif

    NotificationCenter.default.addObserver(
      self, selector: #selector(accentColorChanged), name: .accentColorChanged, object: nil)
    loadPage()
  }

  /// Shows `source` in the editor; `onText` receives note text after real WYSIWYG edits.
  /// Queued until the page has loaded; the latest call wins.
  func show(source: String, onText: @escaping (String) -> Void) {
    sync = MarkdownPreviewSync(source: source)
    latestText = source
    self.onText = onText
    isReady = false
    isLoadPending = true
    loadEditorIfPossible()
  }

  /// Stops forwarding editor edits; `show` attaches a new receiver.
  func detach() {
    onText = nil
  }

  /// Current editor content as note text; nil when not ready, unchanged, or on a script error.
  func currentText() async -> String? {
    guard isReady else { return nil }
    let result = try? await webView.callAsyncJavaScript(
      "return dblore.getMarkdown()", arguments: [:], in: nil, contentWorld: .page)
    guard let markdown = result as? String, let text = sync?.text(forSnapshot: markdown) else {
      return nil
    }
    latestText = text
    return text
  }

  /// Pushes the Oxide tokens for `colorScheme` (and the current accent) to the page.
  func applyTheme(_ colorScheme: ColorScheme) {
    self.colorScheme = colorScheme
    guard isPageLoaded else { return }
    webView.callAsyncJavaScript(
      "dblore.setTheme(vars)",
      arguments: ["vars": MarkdownEditorTheme.variables(colorScheme: colorScheme)],
      in: nil, in: .page, completionHandler: nil)
  }

  @objc private func accentColorChanged() {
    applyTheme(colorScheme)
  }

  // MARK: - Page loading

  private func loadPage() {
    isPageLoaded = false
    guard let htmlURL else {
      fail("markdown-editor.html is missing from the app bundle")
      return
    }
    didFail = false
    allowsNextPageLoad = true
    webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
  }

  private func loadEditorIfPossible() {
    guard isPageLoaded, isLoadPending, let source = sync?.source else { return }
    isLoadPending = false
    didFail = false
    webView.callAsyncJavaScript(
      "await dblore.load(markdown, theme)",
      arguments: [
        "markdown": source,
        "theme": MarkdownEditorTheme.variables(colorScheme: colorScheme),
      ],
      in: nil, in: .page
    ) { [weak self] result in
      if case .failure(let error) = result {
        let error = error as NSError
        self?.fail("Markdown editor failed to load the note: \(error.domain) \(error.code)")
      }
    }
  }

  private func fail(_ message: String) {
    didFail = true
    Task { await AppLogger.shared.error(message, category: "Markdown") }
  }

  fileprivate func receive(_ message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame,
      let bridgeMessage = MarkdownBridgeMessage(body: message.body)
    else { return }
    switch bridgeMessage {
    case .ready, .changed:
      if case .ready = bridgeMessage { isReady = true }
      guard let text = sync?.text(for: bridgeMessage) else { return }
      latestText = text
      onText?(text)
    case .openLink(let href):
      guard let url = MarkdownLinkPolicy.externalURL(href) else { return }
      NSWorkspace.shared.open(url)
    }
  }

  private func isEditorPage(_ url: URL?) -> Bool {
    guard let url, let htmlURL, url.isFileURL else { return false }
    return url.standardizedFileURL.path == htmlURL.standardizedFileURL.path
  }

  // MARK: - WKNavigationDelegate

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    if allowsNextPageLoad, navigationAction.targetFrame?.isMainFrame == true,
      isEditorPage(navigationAction.request.url)
    {
      allowsNextPageLoad = false
      decisionHandler(.allow)
    } else {
      decisionHandler(.cancel)
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    isPageLoaded = true
    loadEditorIfPossible()
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    guard !isPageLoaded else { return }
    fail("Markdown editor page failed to load: \(error)")
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    guard !isPageLoaded else { return }
    fail("Markdown editor page failed to load: \(error)")
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    isReady = false
    if let latestText {
      sync = MarkdownPreviewSync(source: latestText)
      isLoadPending = true
    }
    loadPage()
  }

  // MARK: - WKUIDelegate

  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    nil
  }
}

/// Forwards script messages without the user content controller retaining the controller.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  private weak var controller: MarkdownPreviewController?

  init(_ controller: MarkdownPreviewController) {
    self.controller = controller
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    controller?.receive(message)
  }
}

/// Hosts the controller's web view and keeps its theme in sync with the color scheme.
struct MarkdownPreviewView: NSViewRepresentable {
  let controller: MarkdownPreviewController
  @Environment(\.colorScheme) private var colorScheme

  final class Coordinator {
    var appliedScheme: ColorScheme?
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> WKWebView {
    controller.webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    guard context.coordinator.appliedScheme != colorScheme else { return }
    context.coordinator.appliedScheme = colorScheme
    controller.applyTheme(colorScheme)
  }
}
