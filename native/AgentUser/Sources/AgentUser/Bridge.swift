import Foundation
import Network

/// Serves noVNC over HTTP and bridges its WebSocket to the VNC server's TCP
/// port — the job websockify did. Doing it here removes a Python dependency
/// and the "websockify is not on PATH" failure that came with it.
///
/// Localhost only. The VNC server is already bound to 127.0.0.1; nothing here
/// widens that.
public final class Bridge: @unchecked Sendable {
  public let webPort: UInt16
  public let vncPort: UInt16
  private let webRoot: URL
  private var listener: NWListener?
  private let queue = DispatchQueue(label: "agentuser.bridge")

  public init(webRoot: URL, webPort: UInt16 = 6080, vncPort: UInt16 = 5902) {
    self.webRoot = webRoot
    self.webPort = webPort
    self.vncPort = vncPort
  }

  public var url: URL {
    URL(string: "http://127.0.0.1:\(webPort)/vnc.html?autoconnect=1&resize=scale")!
  }

  public func start() throws {
    let params = NWParameters.tcp
    params.requiredInterfaceType = .loopback
    params.allowLocalEndpointReuse = true
    let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: webPort)!)
    l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
    l.start(queue: queue)
    listener = l
  }

  public func stop() {
    listener?.cancel()
    listener = nil
  }

  private func accept(_ conn: NWConnection) {
    conn.start(queue: queue)
    receiveRequest(conn, buffer: Data())
  }

  /// Read until the end of the HTTP headers, then either upgrade to a
  /// WebSocket relay or serve a static file.
  private func receiveRequest(_ conn: NWConnection, buffer: Data) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
      guard let self else { return }
      var buf = buffer
      if let data { buf.append(data) }
      if error != nil || (done && buf.isEmpty) { conn.cancel(); return }

      guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
        if buf.count > 64 * 1024 { conn.cancel(); return }
        self.receiveRequest(conn, buffer: buf)
        return
      }

      let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
      let rest = buf[end.upperBound...]
      if head.lowercased().contains("upgrade: websocket") {
        self.upgrade(conn, head: head, pending: Data(rest))
      } else {
        self.serveFile(conn, head: head)
      }
    }
  }

  private func serveFile(_ conn: NWConnection, head: String) {
    guard let line = head.split(separator: "\r\n").first,
          case let parts = line.split(separator: " "), parts.count >= 2 else {
      conn.cancel(); return
    }
    var path = String(parts[1])
    if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
    if path == "/" { path = "/vnc.html" }

    // Refuse anything that escapes the web root.
    let file = webRoot.appending(path: String(path.dropFirst())).standardizedFileURL
    guard file.path.hasPrefix(webRoot.standardizedFileURL.path),
          let body = try? Data(contentsOf: file) else {
      send(conn, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".data(using: .utf8)!, close: true)
      return
    }
    let header = "HTTP/1.1 200 OK\r\nContent-Type: \(Self.mime(file.pathExtension))\r\n"
               + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    send(conn, Data(header.utf8) + body, close: true)
  }

  static func mime(_ ext: String) -> String {
    switch ext.lowercased() {
    case "html", "htm": return "text/html; charset=utf-8"
    case "js", "mjs": return "application/javascript; charset=utf-8"
    case "css": return "text/css; charset=utf-8"
    case "json": return "application/json"
    case "png": return "image/png"
    case "svg": return "image/svg+xml"
    case "ico": return "image/x-icon"
    case "woff2": return "font/woff2"
    default: return "application/octet-stream"
    }
  }

  private func send(_ conn: NWConnection, _ data: Data, close: Bool) {
    conn.send(content: data, completion: .contentProcessed { _ in
      if close { conn.cancel() }
    })
  }
}
