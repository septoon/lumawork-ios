import Foundation
import SwiftUI
import WebKit

struct SimpleOneBrowserDestination: Identifiable {
    let id = UUID()
    let url: URL
    let authKey: String?
    var title = "SimpleOne"
}

struct SimpleOneEmbeddedBrowser: View {
    let destination: SimpleOneBrowserDestination
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SimpleOneWebView(url: destination.url, authKey: destination.authKey)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle(destination.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ModalCloseButton(action: dismiss.callAsFunction)
                    }
                }
        }
    }
}

struct SimpleOneWebView: UIViewRepresentable {
    let url: URL
    let authKey: String?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: Self.configuration())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        load(url, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        load(url, in: webView)
    }

    private func load(_ url: URL, in webView: WKWebView) {
        guard let authKey,
              !authKey.isEmpty,
              let cookieDomain = url.host,
              let cookie = HTTPCookie(properties: [
            .domain: cookieDomain,
            .path: "/",
            .name: "auth",
            .value: authKey,
            .secure: "TRUE"
        ]) else {
            webView.load(URLRequest(url: url))
            return
        }

        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
            webView.load(URLRequest(url: url))
        }
    }

    private static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(WKUserScript(
            source: multicardTabScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        return configuration
    }

    private static let multicardTabScript = """
    (() => {
      const selectTab = () => {
        const candidates = Array.from(document.querySelectorAll('button, [role="tab"], a, div, span'));
        const tab = candidates.find((element) => {
          const text = (element.textContent || '').trim().toLowerCase();
          return text === 'мультикарта сервисные';
        });
        if (tab) {
          tab.click();
          return true;
        }
        return false;
      };
      if (selectTab()) { return; }
      let attempts = 0;
      const timer = setInterval(() => {
        attempts += 1;
        if (selectTab() || attempts >= 20) {
          clearInterval(timer);
        }
      }, 500);
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }

            let scheme = url.scheme?.lowercased()
            if let scheme, !["http", "https", "about"].contains(scheme) {
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            completionHandler()
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(false)
        }
    }
}
