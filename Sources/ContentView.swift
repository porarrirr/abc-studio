import SwiftUI
import UniformTypeIdentifiers
import WebKit

private final class WebBridge: ObservableObject {
    @Published var showImporter = false
    @Published var importError: String?
    weak var webView: WKWebView?

    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let abc = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16) else {
                throw ImportFailure.unsupportedEncoding
            }
            let source = jsonString(abc)
            let name = jsonString(url.lastPathComponent)
            webView?.evaluateJavaScript("ABCStudio.importABC(\(source), \(name))")
        } catch {
            importError = error.localizedDescription
        }
    }

    private func jsonString(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }

    private enum ImportFailure: LocalizedError {
        case unsupportedEncoding
        var errorDescription: String? { "この ABC ファイルの文字コードを読み込めません。UTF-8 または UTF-16 で保存してください。" }
    }
}

struct ContentView: View {
    @StateObject private var bridge = WebBridge()
    private let abcType = UTType(filenameExtension: "abc") ?? .plainText

    var body: some View {
        StudioWebView(bridge: bridge)
            .ignoresSafeArea(.container, edges: .bottom)
            .fileImporter(isPresented: $bridge.showImporter,
                          allowedContentTypes: [abcType, .plainText],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { bridge.importFile(url) }
                case .failure(let error):
                    bridge.importError = error.localizedDescription
                }
            }
            .alert("読み込みエラー", isPresented: Binding(
                get: { bridge.importError != nil },
                set: { if !$0 { bridge.importError = nil } }
            )) {
                Button("閉じる") { bridge.importError = nil }
            } message: {
                Text(bridge.importError ?? "")
            }
    }
}

private struct StudioWebView: UIViewRepresentable {
    @ObservedObject var bridge: WebBridge

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: "abcstudio")
        configuration.userContentController.add(context.coordinator, name: "app")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.961, green: 0.961, blue: 0.937, alpha: 1)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = false
        bridge.webView = webView
        webView.load(URLRequest(url: URL(string: "abcstudio://local/index.html")!))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let bridge: WebBridge
        init(bridge: WebBridge) { self.bridge = bridge }
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "open": bridge.showImporter = true
            case "save":
                if let abc = body["abc"] as? String {
                    UserDefaults.standard.set(abc, forKey: "lastABC")
                    UserDefaults.standard.set(body["filename"] as? String ?? "", forKey: "lastFilename")
                }
            default: break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let abc = UserDefaults.standard.string(forKey: "lastABC") else { return }
            let name = UserDefaults.standard.string(forKey: "lastFilename") ?? ""
            let abcJSON = String(data: try! JSONEncoder().encode(abc), encoding: .utf8)!
            let nameJSON = String(data: try! JSONEncoder().encode(name), encoding: .utf8)!
            webView.evaluateJavaScript("ABCStudio.importABC(\(abcJSON), \(nameJSON), false)")
        }
    }
}

private final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              url.host == "local",
              let root = Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true) else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let path = url.path.removingPercentEncoding ?? url.path
        let components = path.split(separator: "/")
        guard !components.contains(".."), !components.isEmpty else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let file = components.reduce(root) { $0.appendingPathComponent(String($1)) }
        do {
            let data = try Data(contentsOf: file)
            let mime: String
            switch file.pathExtension.lowercased() {
            case "html": mime = "text/html"
            case "css": mime = "text/css"
            case "js": mime = "application/javascript"
            case "mp3": mime = "audio/mpeg"
            default: mime = "application/octet-stream"
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": mime,
                                                          "Content-Length": String(data.count),
                                                          "Access-Control-Allow-Origin": "*"])!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
