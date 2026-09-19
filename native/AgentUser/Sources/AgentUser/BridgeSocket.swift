import Foundation
import CryptoKit
import Network

/// The WebSocket half of the bridge: RFC 6455 handshake, then a byte pump in
/// both directions between the browser and the VNC server.
///
/// noVNC sends binary frames carrying raw RFB, so this only needs binary,
/// close and ping — no text, no extensions, no compression.
extension Bridge {
  static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  func upgrade(_ conn: NWConnection, head: String, pending: Data) {
    guard let key = Self.header(head, "sec-websocket-key") else { conn.cancel(); return }
    let accept = Data(Insecure.SHA1.hash(data: Data((key + Self.guid).utf8))).base64EncodedString()

    var response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                 + "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n"
    // noVNC asks for the "binary" subprotocol; echo it back or it bails.
    if let proto = Self.header(head, "sec-websocket-protocol"),
       proto.lowercased().contains("binary") {
      response += "Sec-WebSocket-Protocol: binary\r\n"
    }
    response += "\r\n"

    let vnc = NWConnection(host: "127.0.0.1",
                           port: NWEndpoint.Port(rawValue: vncPort)!,
                           using: .tcp)
    vnc.start(queue: DispatchQueue(label: "agentuser.vnc"))

    conn.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
      guard let self else { return }
      self.pumpVNCToBrowser(vnc: vnc, browser: conn)
      self.pumpBrowserToVNC(browser: conn, vnc: vnc, buffer: pending)
    })
  }

  static func header(_ head: String, _ name: String) -> String? {
    for line in head.split(separator: "\r\n").dropFirst() {
      let bits = line.split(separator: ":", maxSplits: 1)
      guard bits.count == 2, bits[0].lowercased().trimmingCharacters(in: .whitespaces) == name
      else { continue }
      return bits[1].trimmingCharacters(in: .whitespaces)
    }
    return nil
  }

  /// VNC → browser. Raw RFB bytes become unmasked binary frames; a server
  /// never masks.
  private func pumpVNCToBrowser(vnc: NWConnection, browser: NWConnection) {
    vnc.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
      if let data, !data.isEmpty {
        browser.send(content: Self.frame(data), completion: .idempotent)
      }
      if done || error != nil {
        browser.cancel(); vnc.cancel(); return
      }
      self.pumpVNCToBrowser(vnc: vnc, browser: browser)
    }
  }

  /// Browser → VNC. Frames arrive masked and may be split across reads, so
  /// keep a buffer and only consume whole frames.
  private func pumpBrowserToVNC(browser: NWConnection, vnc: NWConnection, buffer: Data) {
    var buf = buffer
    while let (op, payload, used) = Self.parseFrame(buf) {
      buf = Data(buf.dropFirst(used))
      switch op {
      case 0x8: browser.cancel(); vnc.cancel(); return          // close
      case 0x9: browser.send(content: Self.frame(payload, opcode: 0xA), completion: .idempotent)
      case 0x1, 0x2: vnc.send(content: payload, completion: .idempotent)
      default: break
      }
    }
    browser.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
      if let data, !data.isEmpty {
        self.pumpBrowserToVNC(browser: browser, vnc: vnc, buffer: buf + data)
        return
      }
      if done || error != nil { browser.cancel(); vnc.cancel(); return }
      self.pumpBrowserToVNC(browser: browser, vnc: vnc, buffer: buf)
    }
  }

  /// Encode one unmasked frame. Final fragment only; noVNC never needs more.
  static func frame(_ payload: Data, opcode: UInt8 = 0x2) -> Data {
    var out = Data([0x80 | opcode])
    let n = payload.count
    if n < 126 {
      out.append(UInt8(n))
    } else if n <= 0xFFFF {
      out.append(126)
      out.append(contentsOf: withUnsafeBytes(of: UInt16(n).bigEndian, Array.init))
    } else {
      out.append(127)
      out.append(contentsOf: withUnsafeBytes(of: UInt64(n).bigEndian, Array.init))
    }
    out.append(payload)
    return out
  }

  /// Decode one frame. Returns nil while the buffer holds only part of one,
  /// so the caller can wait for more rather than guessing.
  static func parseFrame(_ buf: Data) -> (opcode: UInt8, payload: Data, consumed: Int)? {
    guard buf.count >= 2 else { return nil }
    let b = [UInt8](buf)
    let opcode = b[0] & 0x0F
    let masked = (b[1] & 0x80) != 0
    var len = Int(b[1] & 0x7F)
    var i = 2
    if len == 126 {
      guard b.count >= 4 else { return nil }
      len = Int(b[2]) << 8 | Int(b[3]); i = 4
    } else if len == 127 {
      guard b.count >= 10 else { return nil }
      len = 0
      for k in 2..<10 { len = len << 8 | Int(b[k]) }
      i = 10
    }
    var mask = [UInt8]()
    if masked {
      guard b.count >= i + 4 else { return nil }
      mask = Array(b[i..<(i + 4)]); i += 4
    }
    guard b.count >= i + len else { return nil }
    var payload = Array(b[i..<(i + len)])
    if masked {
      for k in 0..<payload.count { payload[k] ^= mask[k % 4] }
    }
    return (opcode, Data(payload), i + len)
  }
}
