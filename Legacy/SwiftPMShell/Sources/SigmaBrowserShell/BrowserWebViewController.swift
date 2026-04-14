import AppKit
import BrowserCore
import WebKit

private let clickBridgeScript = """
document.addEventListener('click', function(event) {
  let target = event.target;
  while (target && target.tagName !== 'A') {
    target = target.parentElement;
  }
  if (!target || !target.href) {
    return;
  }
  if (!event.metaKey && !event.shiftKey) {
    return;
  }
  window.webkit.messageHandlers.pageLinkBridge.postMessage({
    url: target.href,
    metaKey: !!event.metaKey,
    shiftKey: !!event.shiftKey
  });
  event.preventDefault();
  event.stopPropagation();
}, true);
"""

@MainActor
final class BrowserWebViewController: NSViewController {
    private let pageID: UUID
    private var pane: BrowserPaneFocus
    private let store: WorkspaceStore
    private let shellStore: BrowserShellStore
    private let sessionManager: BrowserSessionManager
    private let downloadManager: DownloadManager

    private var pageObserverToken: UUID?
    private(set) var webView: TrackingWebView?
    private var webViewObservers: [NSKeyValueObservation] = []
    private var faviconTask: Task<Void, Never>?

    init(
        pageID: UUID,
        pane: BrowserPaneFocus,
        store: WorkspaceStore,
        shellStore: BrowserShellStore,
        sessionManager: BrowserSessionManager,
        downloadManager: DownloadManager
    ) {
        self.pageID = pageID
        self.pane = pane
        self.store = store
        self.shellStore = shellStore
        self.sessionManager = sessionManager
        self.downloadManager = downloadManager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildWebViewIfNeeded()
        pageObserverToken = store.observe { [weak self] store in
            self?.applyStoreUpdate(store)
        }
    }

    func updatePane(_ pane: BrowserPaneFocus) {
        self.pane = pane
        webView?.paneFocus = pane
    }

    func prepareForSuspension() {
        if let webView {
            store.updatePageNavigation(pageID: pageID, title: webView.title, url: webView.url)
        }
        faviconTask?.cancel()
        webViewObservers = []
        shellStore.removePageRuntime(for: pageID)
        webView?.removeFromSuperview()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    private func buildWebViewIfNeeded() {
        guard webView == nil,
              let page = store.page(for: pageID),
              let workspace = store.workspace(for: page.workspaceID) else {
            return
        }

        let configuration = sessionManager.configuration(for: workspace)
        configuration.userContentController.add(self, name: "pageLinkBridge")
        let script = WKUserScript(source: clickBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        configuration.userContentController.addUserScript(script)

        let webView = TrackingWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.paneFocus = pane
        webView.onBecameFirstResponder = { [weak self] pane in
            self?.store.focusPane(pane)
        }
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.webView = webView
        installObservers(for: webView)
        syncRuntimeState(using: webView)

        let targetURL = URL(string: page.restorationState.lastCommittedURL) ?? page.url
        if let targetURL {
            webView.load(URLRequest(url: targetURL))
        }
    }

    private func applyStoreUpdate(_ store: WorkspaceStore) {
        if webView == nil {
            buildWebViewIfNeeded()
        }

        guard let webView,
              let page = store.page(for: pageID),
              let currentURLString = webView.url?.absoluteString else {
            return
        }

        if currentURLString != page.urlString, let url = page.url {
            webView.load(URLRequest(url: url))
        }
    }

    private func installObservers(for webView: TrackingWebView) {
        webViewObservers = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.syncRuntimeState(using: webView)
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.syncRuntimeState(using: webView)
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.syncRuntimeState(using: webView)
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.syncRuntimeState(using: webView)
                }
            },
        ]
    }

    private func syncRuntimeState(using webView: WKWebView) {
        shellStore.updatePageRuntime(
            pageID: pageID,
            isLoading: webView.isLoading,
            estimatedProgress: webView.estimatedProgress,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward
        )
    }

    private func handleLinkedNavigation(url: URL, openInSplit: Bool) {
        if openInSplit {
            _ = store.openChildPage(from: pageID, url: url, targetPane: .split)
        } else {
            _ = store.openChildPage(from: pageID, url: url, targetPane: pane)
        }
    }

    private func captureFavicon(for webView: WKWebView) {
        guard let pageURL = webView.url else {
            return
        }

        faviconTask?.cancel()
        faviconTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let script = """
            (function() {
              var link = document.querySelector('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="mask-icon"]');
              return link ? link.href : null;
            })();
            """

            let iconURL: URL?
            do {
                let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
                if let rawValue = result as? String, let resolved = URL(string: rawValue) {
                    iconURL = resolved
                } else {
                    iconURL = Self.defaultFaviconURL(for: pageURL)
                }
            } catch {
                iconURL = Self.defaultFaviconURL(for: pageURL)
            }

            guard let iconURL else {
                self.shellStore.updateFavicon(for: pageURL, iconURL: nil, pngData: nil)
                return
            }

            do {
                let (data, _) = try await URLSession.shared.data(from: iconURL)
                self.shellStore.updateFavicon(for: pageURL, iconURL: iconURL, pngData: data)
            } catch {
                self.shellStore.updateFavicon(for: pageURL, iconURL: iconURL, pngData: nil)
            }
        }
    }

    private static func defaultFaviconURL(for pageURL: URL) -> URL? {
        guard let scheme = pageURL.scheme,
              let host = pageURL.host else {
            return nil
        }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }
}

extension BrowserWebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        syncRuntimeState(using: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        store.updatePageNavigation(pageID: pageID, title: webView.title, url: webView.url)
        syncRuntimeState(using: webView)
        captureFavicon(for: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        syncRuntimeState(using: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        syncRuntimeState(using: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloadManager.adopt(download, sourceURL: navigationAction.request.url)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloadManager.adopt(download, sourceURL: navigationResponse.response.url)
    }
}

extension BrowserWebViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else {
            return nil
        }

        let openInSplit = navigationAction.modifierFlags.contains(.shift)
        handleLinkedNavigation(url: url, openInSplit: openInSplit)
        return nil
    }
}

extension BrowserWebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "pageLinkBridge",
              let payload = message.body as? [String: Any],
              let rawURL = payload["url"] as? String,
              let url = URL(string: rawURL) else {
            return
        }

        let openInSplit = (payload["shiftKey"] as? Bool) == true
        handleLinkedNavigation(url: url, openInSplit: openInSplit)
    }
}

@MainActor
final class TrackingWebView: WKWebView {
    var paneFocus: BrowserPaneFocus = .main
    var onBecameFirstResponder: ((BrowserPaneFocus) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecameFirstResponder?(paneFocus)
        }
        return accepted
    }
}
