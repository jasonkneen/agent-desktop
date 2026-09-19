import SwiftUI
import WebKit

/// Wraps noVNC and signs in for you. The password lives in a file both
/// accounts can read, so there is no reason to make anyone type it.
struct ViewerView: NSViewRepresentable {
  let url: URL
  let password: String

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    // noVNC reads the password from the query string. The page is served from
    // our own loopback bridge and never leaves this machine.
    let web = WKWebView(frame: .zero, configuration: config)
    web.navigationDelegate = context.coordinator
    var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    var items = comps.queryItems ?? []
    items.append(URLQueryItem(name: "password", value: password))
    comps.queryItems = items
    web.load(URLRequest(url: comps.url!))
    return web
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}
  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, WKNavigationDelegate {}
}

struct ViewerWindow: View {
  @ObservedObject var model: WizardModel
  let bridge: Bridge
  @State private var takenOver = false

  var body: some View {
    VStack(spacing: 0) {
      ViewerView(url: bridge.url, password: password)
      Divider()
      HStack(spacing: 12) {
        Circle().fill(Theme.done).frame(width: 8, height: 8)
        Text("Watching \(model.paths.account)'s desktop").font(.caption)
        Spacer()
        Toggle("I'm driving", isOn: $takenOver)
          .toggleStyle(.switch)
          .help("Tell the agent to keep its hands off while you use this desktop")
      }
      .padding(.horizontal, 14).padding(.vertical, 8)
      .background(.ultraThinMaterial)
    }
    .frame(minWidth: 900, minHeight: 620)
  }

  private var password: String {
    (try? String(contentsOf: model.paths.vncPassword, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
}
