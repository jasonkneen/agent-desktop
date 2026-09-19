import Foundation

/// The real world. Everything here is read-only and cheap enough to poll.
public struct LiveProbe: SystemProbe {
  public init() {}

  public func userExists(_ name: String) -> Bool {
    run("/usr/bin/id", ["-u", name]) != nil
  }

  /// A login session shows a loginwindow for that user; Dock means the desktop
  /// is actually up rather than still authenticating.
  public func hasGUISession(_ name: String) -> Bool {
    run("/usr/bin/pgrep", ["-u", name, "-x", "Dock"]) != nil
  }

  public func isExecutable(_ url: URL) -> Bool {
    FileManager.default.isExecutableFile(atPath: url.path)
  }

  public func portOpen(_ port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var tv = timeval(tv_sec: 0, tv_usec: 300_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    return withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }

  public func fileOwner(_ url: URL) -> String? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.ownerAccountName] as? String
  }

  public func contents(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  public func modified(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }

  /// agensis-cu alive under that account means an MCP client has it loaded —
  /// something is driving that desktop, not merely watching it.
  public func isDriving(_ account: String) -> Bool {
    run("/usr/bin/pgrep", ["-u", account, "-f", "agensis-cu"]) != nil
  }

  public func drivingWhat(_ account: String) -> String? {
    // Cheap and approximate: the newest non-system GUI app in that session.
    // Returning nil is fine — the row just says an agent is working.
    guard let out = run("/bin/ps", ["-u", account, "-o", "comm="]) else { return nil }
    let apps = out.split(separator: "\n")
      .filter { $0.contains(".app/Contents/MacOS/") }
      .compactMap { $0.split(separator: "/").last.map(String.init) }
      .filter { !["Dock", "Finder", "ControlCenter", "SystemUIServer"].contains($0) }
    return apps.last
  }

  @discardableResult
  private func run(_ tool: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
