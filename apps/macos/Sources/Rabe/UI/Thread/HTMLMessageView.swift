import AppKit
import RabeKit
import SwiftUI
import WebKit

/// HTML mail in a hardened `WKWebView` (BRIEFING §5.5 + audit P1):
/// - page JavaScript off (`allowsContentJavaScript = false`),
/// - non-persistent data store, `loadHTMLString(_, baseURL: nil)`,
/// - navigation: only `http`/`https` (→ browser) and `mailto` (→ composer),
///   everything else cancelled,
/// - dark-mode adaptation and height measurement run in our own content world,
/// - a content rule list blocks `http(s)` loads while remote images are off
///   (on top of the CSP in `wrapForDisplay`).
struct HTMLMessageView: NSViewRepresentable {
    let html: String            // already wrapped by `wrapForDisplay`
    let darkMode: Bool
    let remoteAllowed: Bool
    let onHeight: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onHeight: onHeight) }

    func makeNSView(context: Context) -> RabeWebView {
        let web = WebViewPool.shared.take(remoteAllowed: remoteAllowed)
        context.coordinator.attach(web)
        context.coordinator.load(html: html, dark: darkMode)
        return web
    }

    func updateNSView(_ web: RabeWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        if context.coordinator.loadedHTML != html || context.coordinator.dark != darkMode {
            context.coordinator.load(html: html, dark: darkMode)
        }
    }

    static func dismantleNSView(_ web: RabeWebView, coordinator: Coordinator) {
        coordinator.detach()
        WebViewPool.shared.give(web)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        var onHeight: (CGFloat) -> Void
        private(set) var loadedHTML = ""
        private(set) var dark = false
        private weak var web: RabeWebView?
        /// M2.11b: set until the view has a width; loading earlier is what
        /// produced the one-character-per-line layout and the wrong height.
        private var pending: (html: String, dark: Bool)?
        /// M2.15 1.2: Messpunkte für „Inhalt erscheint zu spät“.
        private var loadStart = CFAbsoluteTimeGetCurrent()
        private var loadBytes = 0
        private var awaitingFinish = false

        init(onHeight: @escaping (CGFloat) -> Void) { self.onHeight = onHeight }

        func attach(_ web: RabeWebView) {
            self.web = web
            web.navigationDelegate = self
            web.uiDelegate = self
            web.onWidthChange = { [weak self] in
                self?.flushIfReady()
                self?.measure()
            }
            web.configuration.userContentController.removeScriptMessageHandler(forName: "rabeHeight", contentWorld: WebViewPool.world)
            web.configuration.userContentController.add(self, contentWorld: WebViewPool.world, name: "rabeHeight")
        }

        func detach() {
            web?.onWidthChange = nil
            web?.configuration.userContentController.removeScriptMessageHandler(forName: "rabeHeight", contentWorld: WebViewPool.world)
            web?.navigationDelegate = nil
            web?.uiDelegate = nil
        }

        func load(html: String, dark: Bool) {
            loadedHTML = html
            self.dark = dark
            pending = (html, dark)
            loadStart = CFAbsoluteTimeGetCurrent()
            loadBytes = html.utf8.count
            // M2.15 1.2: hat die Ansicht schon Breite (Pool, gleiche Fenster-
            // breite), wird sofort geladen. Nur bei Breite 0 — frische Ansicht
            // ohne Layout — wartet der nächste Durchgang; eine bei Breite 0
            // geladene Seite meldet ein Vielfaches ihrer Höhe (M2.11b).
            if let web, HTMLHeightGate.readyToLoad(viewWidth: web.bounds.width) {
                flushIfReady()
            } else {
                DispatchQueue.main.async { [weak self] in self?.flushIfReady() }
            }
        }

        /// Loads once the view has a width. Before that a page lays out one
        /// character per line and reports a document many times its real height.
        private func flushIfReady() {
            guard let pending, let web, HTMLHeightGate.readyToLoad(viewWidth: web.bounds.width) else { return }
            self.pending = nil
            awaitingFinish = true
            PerfLog.shared.write(String(format: "html_flush wait=%.1f w=%.0f bytes=%d",
                                        (CFAbsoluteTimeGetCurrent() - loadStart) * 1000, web.bounds.width, loadBytes))
            web.loadHTMLString(pending.html, baseURL: nil)
        }

        private var remeasureScheduled = false
        /// Eine verworfene Messung darf nicht die alte (falsche) Höhe stehen lassen.
        private func scheduleRemeasure() {
            guard !remeasureScheduled else { return }
            remeasureScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.remeasureScheduled = false
                self?.measure()
            }
        }

        /// Re-measures in our own content world; the page's JavaScript stays off.
        /// Solange der Web-Prozess noch mit Breite 0 rechnet, wird die Messung
        /// verworfen und kurz darauf wiederholt (gemessen: 3852 statt 156 pt).
        func measure(attempt: Int = 0) {
            guard let web, web.bounds.width > 0 else { return }
            let world = WebViewPool.world
            web.evaluateJavaScript(WebViewPool.measureScript, in: nil, in: world) { [weak self] result in
                guard let self else { return }
                guard case .success(let value) = result, let arr = value as? [Any],
                      let h = (arr.first as? NSNumber)?.doubleValue else { return }
                let inner = (arr.dropFirst().first as? NSNumber)?.doubleValue ?? -1
                MainActor.assumeIsolated {
                    if HTMLHeightGate.accepts(height: CGFloat(h), viewWidth: web.bounds.width,
                                              innerWidth: CGFloat(inner)) {
                        self.onHeight(CGFloat(h))
                    } else if attempt < 8 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                            self?.measure(attempt: attempt + 1)
                        }
                    }
                }
            }
        }

        // Height from the observer script (own world, not the page's).
        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let pair = message.body as? [Any]
            guard let value = ((pair?.first as? NSNumber) ?? (message.body as? NSNumber))?.doubleValue else { return }
            let inner = (pair?.dropFirst().first as? NSNumber)?.doubleValue ?? -1
            MainActor.assumeIsolated {
                let width = web?.bounds.width ?? 0
                guard HTMLHeightGate.accepts(height: CGFloat(value), viewWidth: width, innerWidth: CGFloat(inner)) else {
                    scheduleRemeasure()
                    return
                }
                onHeight(CGFloat(value))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if awaitingFinish {
                awaitingFinish = false
                PerfLog.shared.write(String(format: "html_loaded ms=%.1f bytes=%d w=%.0f",
                                            (CFAbsoluteTimeGetCurrent() - loadStart) * 1000, loadBytes, webView.bounds.width))
            }
            let world = WebViewPool.world
            if dark {
                webView.evaluateJavaScript(AppModel.shared.client?.darkModeScript() ?? "", in: nil, in: world) { _ in }
            }
            webView.evaluateJavaScript(WebViewPool.measureScript, in: nil, in: world) { [weak self] result in
                if case .success(let value) = result, let arr = value as? [Any], let h = (arr.first as? NSNumber)?.doubleValue {
                    let inner = (arr.dropFirst().first as? NSNumber)?.doubleValue ?? -1
                    MainActor.assumeIsolated {
                        let inner = (arr.dropFirst().first as? NSNumber)?.doubleValue ?? -1
                        guard HTMLHeightGate.accepts(height: CGFloat(h), viewWidth: webView.bounds.width,
                                                     innerWidth: CGFloat(inner)) else { return }
                        self?.onHeight(CGFloat(h))
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "about", action.navigationType == .other { return .allow }   // our loadHTMLString
            switch scheme {
            case "http", "https":
                if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            case "mailto":
                if action.navigationType == .linkActivated { AppModel.shared.composeMailto(url) }
            default:
                break
            }
            return .cancel
        }

        // target=_blank and window.open: never a new web view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}

/// Mail content never scrolls by itself: wheel events go to the list.
final class RabeWebView: WKWebView {
    var remoteAllowed = false
    /// This view carries the block rule list (N1).
    var hasBlockList = false
    /// M2.11b: a width change must re-measure the document. A page that was laid
    /// out while the view still had width 0 wraps one character per line and
    /// reports a ~20× too tall document; WebKit never corrects that on its own.
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = -1
    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0, abs(width - lastWidth) > 0.5 else { return }
        lastWidth = width
        onWidthChange?()
    }
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

/// Small pool so opening threads does not create a web content process each time.
@MainActor
final class WebViewPool {
    static let shared = WebViewPool()
    static let world = WKContentWorld.world(name: "rabe")

    static let measureScript = """
    (function(){ var b=document.body, e=document.documentElement;
      var h=Math.ceil(Math.max(b ? b.scrollHeight : 0, e ? e.scrollHeight : 0));
      return [h, window.innerWidth || 0]; })()
    """
    /// Re-reports the height when images or fonts change the layout.
    private static let observerScript = """
    (function(){
      function send(){ var b=document.body, e=document.documentElement;
        var h=Math.ceil(Math.max(b?b.scrollHeight:0, e?e.scrollHeight:0));
        try { window.webkit.messageHandlers.rabeHeight.postMessage([h, window.innerWidth || 0]); } catch(_){} }
      try { new ResizeObserver(send).observe(document.documentElement); } catch(_){}
      window.addEventListener('load', send); send();
    })();
    """

    private var free: [RabeWebView] = []
    /// Views currently showing a mail (M2.5: their selection is the quote source).
    private var live: [WeakWebView] = []
    private var blockList: WKContentRuleList?
    /// Views handed out before the rule list finished compiling (N1).
    private var awaitingBlockList: [WeakWebView] = []

    private struct WeakWebView {
        weak var web: RabeWebView?
    }

    private init() {
        // http(s) loads blocked unless the view allows remote images.
        let rules = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "rabe-block-remote", encodedContentRuleList: rules) { list, error in
            MainActor.assumeIsolated {
                if let error { PerfLog.shared.write("rulelist_failed \(error.localizedDescription)") }
                self.blockList = list
                guard let list else { return }
                for web in self.free where !web.remoteAllowed { web.configuration.userContentController.add(list) }
                // A view that was taken before the list existed would run on the
                // CSP alone; give it the list as soon as compiling is done.
                for entry in self.awaitingBlockList {
                    guard let web = entry.web, !web.remoteAllowed, !web.hasBlockList else { continue }
                    web.configuration.userContentController.add(list)
                    web.hasBlockList = true
                }
                self.awaitingBlockList.removeAll { $0.web == nil || $0.web?.remoteAllowed == true || $0.web?.hasBlockList == true }
            }
        }
    }

    func take(remoteAllowed: Bool) -> RabeWebView {
        if let i = free.firstIndex(where: { $0.remoteAllowed == remoteAllowed }) {
            let web = free.remove(at: i)
            live.append(WeakWebView(web: web))
            return web
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.suppressesIncrementalRendering = true
        // M2.15 1.2: bleibt wie in M2.5 gesetzt. Der Verdacht, es halte den
        // Mailinhalt zurück, hat sich im Sandbox-Beleg nicht bestätigt (Mail
        // mit 3-s-Bild: Text in beiden Einstellungen nach 1 s da).
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.observerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
        var hasList = false
        if !remoteAllowed, let blockList { controller.add(blockList); hasList = true }
        config.userContentController = controller
        let web = RabeWebView(frame: .zero, configuration: config)
        web.remoteAllowed = remoteAllowed
        web.hasBlockList = hasList
        if !remoteAllowed, !hasList { awaitingBlockList.append(WeakWebView(web: web)) }
        web.setValue(false, forKey: "drawsBackground")
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        live.append(WeakWebView(web: web))
        return web
    }

    /// `⇧R` (`quote-selection`): the text the user marked in one of the visible
    /// HTML mails. Runs in our own content world, so the page's JavaScript stays
    /// off; every other web view answers with an empty string.
    static let selectionScript = """
    (function(){ try { var s = window.getSelection(); return s ? s.toString() : ""; } catch (e) { return ""; } })()
    """

    func selectedText() async -> String {
        live.removeAll { $0.web == nil }
        for entry in live {
            guard let web = entry.web, !web.isLoading else { continue }
            let value: String = await withCheckedContinuation { continuation in
                web.evaluateJavaScript(Self.selectionScript, in: nil, in: Self.world) { result in
                    switch result {
                    case .success(let any): continuation.resume(returning: any as? String ?? "")
                    case .failure: continuation.resume(returning: "")
                    }
                }
            }
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return ""
    }

    /// Starts one web content process at launch, so the first HTML mail does
    /// not wait for it (first open after launch rendered no body).
    func warmUp(remoteAllowed: Bool) {
        guard free.isEmpty else { return }
        let web = take(remoteAllowed: remoteAllowed)
        web.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        free.append(web)
    }

    func give(_ web: RabeWebView) {
        live.removeAll { $0.web === web || $0.web == nil }
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
        if free.count < 4 { free.append(web) }
    }
}
