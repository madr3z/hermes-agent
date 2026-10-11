import SwiftUI
import WebKit

struct RemoteSurface: UIViewRepresentable {
    let control: RemoteControl
    func makeCoordinator() -> Coordinator { Coordinator(control) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "remote")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        control.webView = view
        guard let path = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Remote") else {
            control.error = "The remote renderer is missing from this app build."; return view
        }
        view.loadFileURL(path, allowingReadAccessTo: path.deletingLastPathComponent())
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.control?.close()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "remote")
        view.navigationDelegate = nil
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var control: RemoteControl?
        init(_ control: RemoteControl) { self.control = control }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            control?.rendererMessage(type, body: body)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The viewer has no browser or network authority; guest pixels are never HTML.
            let document = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Remote")
            let allowed = navigationAction.request.url == document && navigationAction.navigationType == .other
            decisionHandler(allowed ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { control?.error = error.localizedDescription }
    }
}
