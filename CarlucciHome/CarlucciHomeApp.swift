import SwiftUI
import WebKit
import UniformTypeIdentifiers

@main
struct CarlucciHomeApp: App {
    var body: some Scene {
        WindowGroup {
            WebAppView()
                .ignoresSafeArea()
                .background(Color(red: 0.94, green: 0.95, blue: 0.98))
        }
    }
}

/// Serve i file dell'app da carlucci://app/ — un'origine stabile, così IndexedDB
/// conserva i dati tra un avvio e l'altro (come fa Capacitor).
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "carlucci"
    let root = Bundle.main.resourceURL!.appendingPathComponent("Web")

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(String(path.dropFirst()))
        guard let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        task.didReceive(resp); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

struct WebAppView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: BundleSchemeHandler.scheme)
        cfg.allowsInlineMediaPlayback = true
        let ucc = cfg.userContentController
        ucc.add(context.coordinator, name: "native")
        let current = UIApplication.shared.alternateIconName ?? "AppIcon"
        ucc.addUserScript(WKUserScript(source: "window.__NATIVE_IOS__ = true; window.__APP_ICON__ = '\(current)';",
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = UIColor(red: 0.94, green: 0.95, blue: 0.98, alpha: 1)
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.bounces = false
        context.coordinator.webView = wv
        wv.load(URLRequest(url: URL(string: "carlucci://app/index.html")!))
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?

        // Messaggi dall'app web: salva/apri file e stampa
        func userContentController(_ ucc: WKUserContentController, didReceive msg: WKScriptMessage) {
            guard let body = msg.body as? [String: Any], let action = body["action"] as? String else { return }
            switch action {
            case "saveFile":
                guard let name = body["name"] as? String, let b64 = body["data"] as? String,
                      let data = Data(base64Encoded: b64) else { return }
                let safe = name.replacingOccurrences(of: "/", with: "-")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
                try? data.write(to: url, options: .atomic)
                share([url])
            case "print":
                guard let html = body["html"] as? String else { return }
                let pc = UIPrintInteractionController.shared
                pc.printFormatter = UIMarkupTextPrintFormatter(markupText: html)
                pc.present(animated: true)
            case "setIcon":
                guard let name = body["name"] as? String else { return }
                let target: String? = (name == "AppIcon") ? nil : name
                guard UIApplication.shared.supportsAlternateIcons,
                      UIApplication.shared.alternateIconName != target else { return }
                UIApplication.shared.setAlternateIconName(target) { [weak self] err in
                    let ok = err == nil
                    let js = "window.onNativeIconChanged && window.onNativeIconChanged('\(name)', \(ok))"
                    DispatchQueue.main.async { self?.webView?.evaluateJavaScript(js) }
                }
            default: break
            }
        }

        func share(_ items: [Any]) {
            guard let wv = webView, let root = wv.window?.rootViewController else { return }
            var top = root; while let p = top.presentedViewController { top = p }
            let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
            vc.popoverPresentationController?.sourceView = wv
            vc.popoverPresentationController?.sourceRect = CGRect(x: wv.bounds.midX, y: wv.bounds.maxY - 80, width: 1, height: 1)
            top.present(vc, animated: true)
        }

        // Link esterni (http/https/mailto/tel) → Safari o app di sistema
        func webView(_ wv: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, let s = url.scheme?.lowercased(),
               s != BundleSchemeHandler.scheme, s != "about", s != "blob", s != "data" {
                UIApplication.shared.open(url); decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        // window.open: niente popup, eventuali link esterni vanno a Safari
        func webView(_ wv: WKWebView, createWebViewWith c: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") {
                UIApplication.shared.open(url)
            }
            return nil
        }
    }
}
